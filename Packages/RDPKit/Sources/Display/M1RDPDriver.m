//
//  M1RDPDriver.m
//  M1-Skeleton
//

#import "M1RDPDriver.h"
#import "M1DriverLogic.h"
#import "M1ScreenLock.h"
#import "M1WindowLayout.h"
#import "VDManager.h"
#import "P0VDisplayControl.h"
#import "ProbeUtil.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <libproc.h>
#import <unistd.h>
#import <strings.h>

NSString * const M1RDPDriverErrorDomain = @"M1RDPDriver";

static NSError *M1DrvErr(M1RDPDriverErrorCode code, NSString *desc) {
    return [NSError errorWithDomain:M1RDPDriverErrorDomain code:code
        userInfo:@{ NSLocalizedDescriptionKey: desc ?: @"M1RDPDriver error" }];
}

// macOS 13 实测：虚拟屏 mode 提交与禁屏重配置期间，ScreensharingAgent 的 CGDisplayStream
// 会与 WindowServer 竞态，崩溃栈为 DisplayStreamStateSW::CopyFrame 或 layer_blit_byte_ANY
// （见 RESULTS-BY-OS.md §5.28）。冻结窗口必须覆盖「建屏 → 禁屏提交 + settle」整段，
// 只放在禁屏事务里太晚。M1_C09_QUIESCE_SS=0 可关闭该规避。
static BOOL M1ShouldQuiesceScreenSharing(void) {
    if ([P0OSPolicy()[@"osMajor"] integerValue] != 13) return NO;
    const char *q = getenv("M1_C09_QUIESCE_SS");
    return !(q && !strcasecmp(q, "0"));
}

#pragma mark - 进程查找（复用 P0V 的 libproc 路径，不依赖 shell）

static pid_t M1FindPID(NSString *name) {
    int count = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (count <= 0) return -1;
    pid_t *pids = calloc((size_t)count, sizeof(pid_t));
    if (!pids) return -1;
    count = proc_listpids(PROC_ALL_PIDS, 0, pids, count * (int)sizeof(pid_t));
    pid_t found = -1;
    for (int i = 0; i < count / (int)sizeof(pid_t); i++) {
        pid_t p = pids[i];
        if (p <= 0) continue;
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(p, path, sizeof(path)) <= 0) continue;
        NSString *base = [[NSString stringWithUTF8String:path] lastPathComponent];
        if ([base isEqualToString:name]) { found = p; break; }
    }
    free(pids);
    return found;
}

static void M1PostUnicodeToPid(pid_t pid, UniChar u, CGKeyCode code, BOOL down) {
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, code, down);
    if (!e) return;
    if (u != 0) CGEventKeyboardSetUnicodeString(e, 1, &u);
    CGEventPostToPid(pid, e);
    CFRelease(e);
}

@interface M1RDPDriver ()
@property (nonatomic, strong, nullable) VDManager *vd;
@property (nonatomic, strong, nullable) P0VDisplaySnapshot *snapshot;
@property (nonatomic, assign) IOPMAssertionID displayAssertion;
@property (nonatomic, assign) IOPMAssertionID systemAssertion;
@property (nonatomic, strong, readwrite, nullable) NSArray<NSNumber *> *lastActiveDisplayIDs;
@property (nonatomic, copy, readwrite, nullable) NSString *snapshotPath;
@property (nonatomic, assign) BOOL screenSharingQuiesced;
@property (nonatomic, strong, nullable) M1WindowLayoutSnapshot *windowLayoutSnapshot;
@property (nonatomic, strong) M1WindowLayoutAXProvider *windowLayoutProvider;
@property (nonatomic, copy, nullable) NSSet<NSNumber *> *disabledDisplayIDs;
@property (nonatomic, copy, readwrite, nullable) NSDictionary *lastWindowRestoreSummary;
@end

@implementation M1RDPDriver

- (instancetype)init {
    self = [super init];
    if (self) {
        _snapshotBasePath = NSTemporaryDirectory();
        _displayAssertion = kIOPMNullAssertionID;
        _systemAssertion = kIOPMNullAssertionID;
        _windowLayoutProvider = [M1WindowLayoutAXProvider new];
    }
    return self;
}

- (NSDictionary *)probeEnvironment {
    NSError *e = nil;
    NSArray *shareable = P0VActiveDisplayIDs();
    // 只读：验证窗口布局采集链路与 AX 授权，不做任何搬窗。
    M1WindowLayoutSnapshot *layout =
        [_windowLayoutProvider captureLayoutExcludingPIDs:[NSSet setWithObject:@(getpid())]];
    NSArray *layoutWindows = layout.windows ?: @[];
    uint32_t onSnapshotDisplays = 0;
    for (M1WindowInfo *w in layoutWindows) {
        if (w.displayID != 0) onSnapshotDisplays++;
    }
    return @{
        @"activeDisplayIDs": shareable ?: @[],
        @"privateDisplayControl": @(P0VPrivateDisplayControlAvailable()),
        @"windowServerHung": @(P0VWindowServerHung()),
        @"loginwindowPID": @(M1FindPID(@"loginwindow")),
        @"screenLockSymbol": @(M1ScreenLockSymbolAvailable()),
        @"staleVirtualSlots": P0VStaleVirtualSlotIDs() ?: @[],
        @"identityOffset": @([VDManager savedIdentityOffset]),
        @"snapshotBasePath": _snapshotBasePath,
        @"windowLayout": @{
            @"axTrusted": @(_windowLayoutProvider.accessibilityTrusted),
            @"captured": @(layoutWindows.count),
            @"onKnownDisplay": @(onSnapshotDisplays),
            @"knownDisplayCount": @(layout.displayBounds.count ?: 0),
        },
        @"error": e.localizedDescription ?: [NSNull null],
    };
}

#pragma mark - M1SessionDriver

- (BOOL)acquireSleepAssertionError:(NSError **)error {
    // 与 M1-Pre 一致：display + system 双断言，防止 2-3s 屏睡导致采集为空。
    IOReturn r1 = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionLevelOn,
        CFSTR("M1 RDP session"), &_displayAssertion);
    IOReturn r2 = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionLevelOn,
        CFSTR("M1 RDP session"), &_systemAssertion);
    if (r1 != kIOReturnSuccess && r2 != kIOReturnSuccess) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorNoAssertion,
            @"无法建立防睡眠断言（display/system 均失败）");
        return NO;
    }
    return YES; // 单个成功即继续（与 M1-Pre 判据一致）
}

- (void)releaseSleepAssertion {
    if (_displayAssertion != kIOPMNullAssertionID) {
        IOPMAssertionRelease(_displayAssertion);
        _displayAssertion = kIOPMNullAssertionID;
    }
    if (_systemAssertion != kIOPMNullAssertionID) {
        IOPMAssertionRelease(_systemAssertion);
        _systemAssertion = kIOPMNullAssertionID;
    }
}

- (BOOL)createVirtualDisplays:(NSArray<NSDictionary *> *)specs
                        error:(NSError **)error {
    if (P0VWindowServerHung()) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorWindowServerHung,
            @"WindowServer 已挂起，禁止再建屏");
        return NO;
    }
    if (specs.count == 0) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorNoDisplays, @"无 display 规格");
        return NO;
    }
    // 建屏之前先落快照 + 守护：顺序反了，快照里就会混进虚拟屏（见 prepareSessionShield 注释）。
    if (![self prepareSessionShieldError:error]) return NO;

    // 规格透明传入 VDManager（键名 width/height/hiDPI/refreshRate/name 一致）。
    // 保守 canvas 路径只在 Tahoe 启用：Sequoia 15.5 直建目标分辨率即可，
    // 且保守路径不会提前解除残留槽位的镜像态，会让 mode 永远提交不上。
    NSDictionary *policy = P0OSPolicy();
    BOOL conservative = [policy[@"conservativeFirst"] boolValue];
    int modeWaitMs = [policy[@"modeWaitMs"] intValue];

    // 冻结窗口从这里开始：13 上的崩溃发生在建屏/ mode 提交阶段，早于禁屏事务。
    if (M1ShouldQuiesceScreenSharing()) {
        P0VStopScreenSharingAgents();
        self.screenSharingQuiesced = YES;
    }

    _vd = [[VDManager alloc] initWithConfigs:specs
                              identityOffset:[VDManager savedIdentityOffset]
                           conservativeFirst:conservative];
    BOOL ready = [_vd createAll] && [_vd waitUntilUsableTimeoutMs:8000];
    if (!ready && _vd.displayIDs.count > 0) {
        // 常见失败形态是 online 但永不 active，显式 enable 后再给一轮等待。
        [self forceEnableInactiveDisplaysOf:_vd];
        ready = [_vd waitUntilUsableTimeoutMs:8000];
    }
    if (!ready) {
        [_vd destroyAll];
        _vd = nil;
        if (self.screenSharingQuiesced) {
            P0VResumeScreenSharingAgents();
            self.screenSharingQuiesced = NO;
        }
        if (error) *error = M1DrvErr(M1RDPDriverErrorNoDisplays, @"建屏失败或超时");
        return NO;
    }
    if (conservative) {
        // 保守 canvas → 目标分辨率（PR #288：直接大尺寸会得到壁纸+光标）。
        [_vd waitUntilModeMatchesTimeoutMs:modeWaitMs conservative:YES];
        [_vd promoteToTarget];
        [_vd waitUntilModeMatchesTimeoutMs:modeWaitMs conservative:NO];
    }
    self.lastActiveDisplayIDs = P0VActiveDisplayIDs();
    return YES;
}

// FR-07 事务换屏：新 VDManager 先建齐并确认 active，才销毁旧管理器。
// 失败只销毁新建的这一套；旧 _vd 原样保留（调用方此时还没有新管线）。
- (BOOL)replaceVirtualDisplays:(NSArray<NSDictionary *> *)specs
                         error:(NSError **)error {
    if (P0VWindowServerHung()) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorWindowServerHung,
            @"WindowServer 已挂起，禁止换屏");
        return NO;
    }
    if (specs.count == 0) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorNoDisplays, @"无 display 规格");
        return NO;
    }
    VDManager *old = _vd;
    if (!old) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorNoDisplays,
            @"会话内没有可替换的虚拟屏");
        return NO;
    }

    NSDictionary *policy = P0OSPolicy();
    BOOL conservative = [policy[@"conservativeFirst"] boolValue];
    int modeWaitMs = [policy[@"modeWaitMs"] intValue];

    // 13 上的冻结窗口与建屏路径相同：新屏创建 + 旧屏销毁都在窗口内。
    BOOL quiesce = M1ShouldQuiesceScreenSharing();
    if (quiesce) {
        P0VStopScreenSharingAgents();
        self.screenSharingQuiesced = YES;
    }

    VDManager *fresh = [[VDManager alloc] initWithConfigs:specs
                                          identityOffset:[VDManager savedIdentityOffset]
                                       conservativeFirst:conservative];
    BOOL ok = [fresh createAll] && [fresh waitUntilUsableTimeoutMs:8000];
    if (!ok && fresh.displayIDs.count > 0) {
        [self forceEnableInactiveDisplaysOf:fresh];
        ok = [fresh waitUntilUsableTimeoutMs:8000];
    }
    if (ok && conservative) {
        [fresh waitUntilModeMatchesTimeoutMs:modeWaitMs conservative:YES];
        [fresh promoteToTarget];
        [fresh waitUntilModeMatchesTimeoutMs:modeWaitMs conservative:NO];
    }
    if (ok) {
        // 自检：新屏必须真的进了 active list（可见），否则不能拿它替换旧屏。
        NSArray *active = P0VActiveDisplayIDs();
        for (NSNumber *n in fresh.displayIDs) {
            if (![active containsObject:n]) { ok = NO; break; }
        }
    }
    if (!ok) {
        [fresh destroyAll];
        if (quiesce) {
            P0VResumeScreenSharingAgents();
            self.screenSharingQuiesced = NO;
        }
        if (error) *error = M1DrvErr(M1RDPDriverErrorNoDisplays,
            @"换屏失败：新虚拟屏建不起来或不可见（旧屏未动）");
        return NO;
    }

    [old destroyAll];
    _vd = fresh;
    if (quiesce) {
        P0VResumeScreenSharingAgents();
        self.screenSharingQuiesced = NO;
    }
    self.lastActiveDisplayIDs = P0VActiveDisplayIDs();
    return YES;
}

#pragma mark - 建屏后修复

// Tahoe 真机偶发：新建虚拟屏 online 却不 active（WindowServer 脏态，重启能解但
// 无人值守/连续跑测不该依赖重启）。显式 enable 事务能把它拉进 active list
// （2026-11-25 Tahoe 实测：4128835 online=1 active=0 十秒不变，enable 提交后立刻 active=1）。
// 只 enable 本会话新建的虚拟屏，物理屏不动。
- (void)forceEnableInactiveDisplaysOf:(VDManager *)vd {
    NSMutableArray<NSNumber *> *inactive = [NSMutableArray array];
    for (NSNumber *n in vd.displayIDs) {
        if (!CGDisplayIsActive((CGDirectDisplayID)n.unsignedIntValue)) [inactive addObject:n];
    }
    if (inactive.count == 0) return;
    NSDictionary *detail = nil;
    NSError *e = nil;
    BOOL ok = P0VApplyDisplayEnabledChanges(@[], inactive, P0VCommitScopeSession, 20, &detail, &e);
    printf("  [建屏] %lu 块虚拟屏未 active，显式 enable 事务%s%s\n",
           (unsigned long)inactive.count, ok ? "已提交" : "失败",
           ok ? "" : (e.localizedDescription.UTF8String ?: ""));
    fflush(stdout);
}

#pragma mark - 兜底护盾

- (BOOL)prepareSessionShieldError:(NSError **)error {
    if (self.snapshot && self.snapshotPath) return YES;   // 已就位，幂等
    if (P0VWindowServerHung()) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorWindowServerHung,
            @"WindowServer 已挂起，禁止拍快照/起守护");
        return NO;
    }
    P0VDisplaySnapshot *snap = [P0VDisplaySnapshot captureActive];
    if (snap.displayIDs.count == 0) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorSnapshotFailed,
            @"当前没有任何 active display，快照无意义");
        return NO;
    }
    // 窗口布局与显示快照同时拍：建虚拟屏/禁物理屏之后 WindowServer 就会重排窗口。
    if (!self.windowLayoutSnapshot) {
        self.windowLayoutSnapshot =
            [_windowLayoutProvider captureLayoutExcludingPIDs:[NSSet setWithObject:@(getpid())]];
        printf("  [窗口布局] 快照 %lu 个窗口（AX trusted=%d）\n",
               (unsigned long)self.windowLayoutSnapshot.windows.count,
               self.windowLayoutProvider.accessibilityTrusted ? 1 : 0);
        fflush(stdout);
    }
    NSString *path = [NSString stringWithFormat:@"%@m1-session-snapshot-%d.json",
                      _snapshotBasePath, getpid()];
    NSError *snapErr = nil;
    if (![snap writeToFile:path error:&snapErr]) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorSnapshotFailed,
            snapErr.localizedDescription ?: @"快照写盘失败");
        return NO;
    }
    // P0VStartGuardian 内部有就绪握手：宿主没实现 --guardian 会直接失败。
    NSError *guardErr = nil;
    if (!P0VStartGuardian(path, getpid(), &guardErr)) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        if (error) *error = M1DrvErr(M1RDPDriverErrorGuardianFailed,
            guardErr.localizedDescription ?: @"守护进程启动失败");
        return NO;
    }
    self.snapshot = snap;
    self.snapshotPath = path;
    return YES;
}

- (void)disarmShield {
    if (self.snapshotPath) {
        NSString *done = [self.snapshotPath stringByAppendingString:@".done"];
        [@"ok" writeToFile:done atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [[NSFileManager defaultManager]
            removeItemAtPath:[self.snapshotPath stringByAppendingString:@".guardian-ready"]
                       error:NULL];
    }
    self.snapshot = nil;
    self.snapshotPath = nil;
}

- (NSArray<NSNumber *> *)createdDisplayIDs {
    return _vd.displayIDs ?: @[];
}

- (BOOL)snapshotAndDisablePhysicalExcept:(NSArray<NSNumber *> *)keepIDs
                                   error:(NSError **)error {
    if (P0VWindowServerHung()) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorWindowServerHung, @"WindowServer 已挂起");
        return NO;
    }
    // 护盾未就绪（无快照 / 无守护）时绝不禁屏：没有兜底的禁屏只能靠强制重启收场。
    if (!self.snapshot || self.snapshotPath.length == 0) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorGuardianFailed,
            @"未预备快照与守护进程，拒绝禁屏");
        return NO;
    }

    // 本会话虚拟屏一律保留：调用方传空数组时，旧实现会把刚建好的虚拟屏也禁掉，
    // 系统随即进入零显示状态（黑屏、无光标、无法唤醒）——2026-11-18 事故成因之一。
    NSMutableSet *keep = [NSMutableSet setWithArray:keepIDs ?: @[]];
    [keep addObjectsFromArray:[self createdDisplayIDs]];
    if (keep.count == 0) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorNoDisplays,
            @"keep 集合为空：禁屏后不会有任何显示留存，拒绝执行");
        return NO;
    }

    NSMutableArray *physical = [NSMutableArray array];
    for (NSNumber *n in P0VActiveDisplayIDs()) {
        if (![keep containsObject:n]) [physical addObject:n];
    }
    if (physical.count == 0) {
        if (self.screenSharingQuiesced) {
            P0VResumeScreenSharingAgents();
            self.screenSharingQuiesced = NO;
        }
        return YES; // 已全是目标虚拟屏，无需配置事务
    }

    // 13 上 CGDisplayStream 与显示重配置竞态的冻结窗口已从建屏开始（§5.28），
    // 这里只负责在禁屏提交 + settle 后恢复。

    NSDictionary *detail = nil;
    NSError *disableErr = nil;
    BOOL ok = P0VApplyDisplayEnabledChanges(physical, @[], P0VCommitScopeSession,
                                            20, &detail, &disableErr);

    [NSThread sleepForTimeInterval:1.0]; // 等登录 UI 迁移（D-08 实测触发条件）
    if (self.screenSharingQuiesced) {
        P0VResumeScreenSharingAgents();
        self.screenSharingQuiesced = NO;
    }

    if (!ok) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorDisableFailed,
            disableErr.localizedDescription ?: @"禁用物理屏失败");
        return NO;
    }

    // 禁屏后自检：本会话虚拟屏必须还在 active list，否则等于把系统画布一起关了。
    NSArray *activeNow = P0VActiveDisplayIDs();
    NSMutableArray<NSNumber *> *missing = [NSMutableArray array];
    for (NSNumber *n in [self createdDisplayIDs]) {
        if (![activeNow containsObject:n]) [missing addObject:n];
    }
    if (missing.count > 0 || activeNow.count == 0) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorDisableFailed,
            [NSString stringWithFormat:
                @"禁屏后零显示（虚拟屏 %@ 不在 active list，当前 active=%lu），立即回滚",
                missing, (unsigned long)activeNow.count]);
        self.lastActiveDisplayIDs = activeNow;
        return NO;
    }
    self.lastActiveDisplayIDs = activeNow;
    self.disabledDisplayIDs = [NSSet setWithArray:physical];
    return YES;
}

- (BOOL)verifyIsolationError:(NSError **)error {
    // C-09：禁屏后 active 必须 ⊆ 本会话虚拟屏，且不能为空集。
    NSArray *active = P0VActiveDisplayIDs();
    NSString *violation = M1IsolationViolation(active, [self createdDisplayIDs]);
    self.lastActiveDisplayIDs = active;
    if (violation.length > 0) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorIsolationViolated,
            [NSString stringWithFormat:@"C-09 违规：%@", violation]);
        return NO;
    }
    return YES;
}

- (BOOL)injectUnlockCredential:(NSString *)credential
                         error:(NSError **)error {
    pid_t lw = M1FindPID(@"loginwindow");
    if (lw <= 0) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorNoLoginwindow, @"找不到 loginwindow 进程");
        return NO;
    }
    NSArray<NSDictionary *> *seq = M1CredentialEventSequence(credential);
    for (NSDictionary *ev in seq) {
        UniChar u = (UniChar)[ev[@"unicode"] unsignedShortValue];
        CGKeyCode code = (CGKeyCode)[ev[@"keyCode"] unsignedShortValue];
        M1PostUnicodeToPid(lw, u, code, YES);
        M1PostUnicodeToPid(lw, u, code, NO);
    }
    [NSThread sleepForTimeInterval:1.2]; // 等解锁（与 V-04 判据一致）
    return YES; // 结果由上层 capture/会话态校验，不在此声称解锁成功
}

- (BOOL)restorePhysicalAndDestroyDisplaysError:(NSError **)error {
    // 兜底解除 C-09 窗口内可能残留的冻结；对未冻结的进程发 SIGCONT 是安全的空操作。
    P0VResumeScreenSharingAgents();
    self.screenSharingQuiesced = NO;
    BOOL ok = YES;
    // 1. 恢复物理屏快照（先启用物理屏）
    if (self.snapshot && self.snapshotPath && !P0VWindowServerHung()) {
        NSDictionary *detail = nil;
        NSError *restoreErr = nil;
        if (!P0VRestoreSnapshot(self.snapshot, P0VCommitScopeSession, 20, &detail, &restoreErr)) {
            ok = NO;
            if (error) *error = M1DrvErr(M1RDPDriverErrorRestoreFailed,
                restoreErr.localizedDescription ?: @"恢复物理屏失败");
        }
    }
    // 2. 通知守护：恢复完成，无需兜底
    if (self.snapshotPath) {
        NSString *done = [self.snapshotPath stringByAppendingString:@".done"];
        [@"ok" writeToFile:done atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        // 就绪标记只是握手用的，留着会让下次同路径 spawn 误判「已就绪」。
        [[NSFileManager defaultManager]
            removeItemAtPath:[self.snapshotPath stringByAppendingString:@".guardian-ready"]
                       error:NULL];
    }
    // 3. 销毁虚拟屏（必须持有 vd 引用直到此刻）
    [_vd destroyAll];
    _vd = nil;
    self.snapshot = nil;
    self.lastActiveDisplayIDs = P0VActiveDisplayIDs();

    // 4. 窗口搬回：物理屏已恢复、虚拟屏已销毁，WindowServer 的重排已发生。
    //    best-effort，失败不影响显示恢复结论；摘要留给上层落盘。
    if (self.windowLayoutSnapshot && self.disabledDisplayIDs.count > 0) {
        // WindowServer 恢复显示后还会继续搬窗口；0.3s 时 AX 查询常超时（§5.34 实测）。
        [NSThread sleepForTimeInterval:1.0];
        M1WindowLayoutRestorer *restorer =
            [[M1WindowLayoutRestorer alloc] initWithProvider:self.windowLayoutProvider];
        self.lastWindowRestoreSummary =
            [restorer restoreSnapshot:self.windowLayoutSnapshot
                   disabledDisplayIDs:self.disabledDisplayIDs];
        NSDictionary *s = self.lastWindowRestoreSummary;
        printf("  [窗口布局] 恢复 captured=%lu planned=%lu restored=%lu failed=%lu "
               "skipped=%lu trusted=%d\n",
               (unsigned long)[s[@"captured"] unsignedIntegerValue],
               (unsigned long)[s[@"planned"] unsignedIntegerValue],
               (unsigned long)[s[@"restored"] unsignedIntegerValue],
               (unsigned long)[s[@"failed"] unsignedIntegerValue],
               (unsigned long)[s[@"skipped"] unsignedIntegerValue],
               [s[@"trusted"] boolValue] ? 1 : 0);
        fflush(stdout);
    }
    self.windowLayoutSnapshot = nil;
    self.disabledDisplayIDs = nil;

    // 5. 收尾自检：恢复完必须至少还有一块 active 屏，否则说明拓扑没回来。
    if (ok && self.lastActiveDisplayIDs.count == 0) {
        ok = NO;
        if (error) *error = M1DrvErr(M1RDPDriverErrorRestoreFailed,
            @"恢复后仍无任何 active display");
    }
    return ok;
}

- (BOOL)lockScreenError:(NSError **)error {
    return M1LockScreenNow(error);
}

@end
