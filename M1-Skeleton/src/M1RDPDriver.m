//
//  M1RDPDriver.m
//  M1-Skeleton
//

#import "M1RDPDriver.h"
#import "M1DriverLogic.h"
#import "M1ScreenLock.h"
#import "VDManager.h"
#import "P0VDisplayControl.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <libproc.h>
#import <unistd.h>

NSString * const M1RDPDriverErrorDomain = @"M1RDPDriver";

static NSError *M1DrvErr(M1RDPDriverErrorCode code, NSString *desc) {
    return [NSError errorWithDomain:M1RDPDriverErrorDomain code:code
        userInfo:@{ NSLocalizedDescriptionKey: desc ?: @"M1RDPDriver error" }];
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
@end

@implementation M1RDPDriver

- (instancetype)init {
    self = [super init];
    if (self) {
        _snapshotBasePath = NSTemporaryDirectory();
        _displayAssertion = kIOPMNullAssertionID;
        _systemAssertion = kIOPMNullAssertionID;
    }
    return self;
}

- (NSDictionary *)probeEnvironment {
    NSError *e = nil;
    NSArray *shareable = P0VActiveDisplayIDs();
    return @{
        @"activeDisplayIDs": shareable ?: @[],
        @"privateDisplayControl": @(P0VPrivateDisplayControlAvailable()),
        @"windowServerHung": @(P0VWindowServerHung()),
        @"loginwindowPID": @(M1FindPID(@"loginwindow")),
        @"screenLockSymbol": @(M1ScreenLockSymbolAvailable()),
        @"staleVirtualSlots": P0VStaleVirtualSlotIDs() ?: @[],
        @"identityOffset": @([VDManager savedIdentityOffset]),
        @"snapshotBasePath": _snapshotBasePath,
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
    _vd = [[VDManager alloc] initWithConfigs:specs
                              identityOffset:[VDManager savedIdentityOffset]
                           conservativeFirst:YES];
    if (![_vd createAll] || ![_vd waitUntilUsableTimeoutMs:8000]) {
        [_vd destroyAll];
        _vd = nil;
        if (error) *error = M1DrvErr(M1RDPDriverErrorNoDisplays, @"建屏失败或超时");
        return NO;
    }
    // 保守 canvas → 目标分辨率（PR #288：直接大尺寸会得到壁纸+光标）。
    [_vd waitUntilModeMatchesTimeoutMs:10000 conservative:YES];
    [_vd promoteToTarget];
    [_vd waitUntilModeMatchesTimeoutMs:10000 conservative:NO];
    self.lastActiveDisplayIDs = P0VActiveDisplayIDs();
    return YES;
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
    if (physical.count == 0) return YES; // 已全是目标虚拟屏，无需配置事务

    NSDictionary *detail = nil;
    NSError *disableErr = nil;
    BOOL ok = P0VApplyDisplayEnabledChanges(physical, @[], P0VCommitScopeSession,
                                            20, &detail, &disableErr);
    if (!ok) {
        if (error) *error = M1DrvErr(M1RDPDriverErrorDisableFailed,
            disableErr.localizedDescription ?: @"禁用物理屏失败");
        return NO;
    }
    [NSThread sleepForTimeInterval:1.0]; // 等登录 UI 迁移（D-08 实测触发条件）

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

    // 4. 收尾自检：恢复完必须至少还有一块 active 屏，否则说明拓扑没回来。
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
