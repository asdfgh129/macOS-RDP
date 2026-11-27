//
//  P0VDisplayControl.m
//  P0V-DisplayIsolation
//

#import "P0VDisplayControl.h"
#import "ProbeUtil.h"

#import <dlfcn.h>
#import <fcntl.h>
#import <mach-o/dyld.h>
#import <spawn.h>
#import <signal.h>
#import <stdatomic.h>
#import <libproc.h>
#import <math.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>
#import <sys/wait.h>

extern char **environ;

// 本项目虚拟屏 vendor（与 P0-TahoeProbe/VDManager.m 的 kVendorID 保持一致）。
static const uint32_t kP0VVirtualVendorID = 0x5030;

#pragma mark - 私有符号

typedef CGError (*P0VSLSConfigureDisplayEnabledFn)(CGDisplayConfigRef, CGDirectDisplayID, bool);
typedef CGError (*P0VSLSGetDisplayListFn)(uint32_t, CGDirectDisplayID *, uint32_t *);

static P0VSLSConfigureDisplayEnabledFn gConfigureDisplayEnabled = NULL;
static P0VSLSGetDisplayListFn gGetDisplayList = NULL;
static dispatch_once_t gSymbolOnce;

static void P0VLoadPrivateSymbols(void) {
    dispatch_once(&gSymbolOnce, ^{
        void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
                          RTLD_LAZY | RTLD_GLOBAL);
        if (!sl) sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                             RTLD_LAZY | RTLD_GLOBAL);
        if (!sl) {
            P0Error(@"dlopen SkyLight 失败: %s", dlerror());
            return;
        }
        gConfigureDisplayEnabled = (P0VSLSConfigureDisplayEnabledFn)dlsym(sl, "SLSConfigureDisplayEnabled");
        gGetDisplayList = (P0VSLSGetDisplayListFn)dlsym(sl, "SLSGetDisplayList");
        if (!gConfigureDisplayEnabled) P0Error(@"SLSConfigureDisplayEnabled 符号缺失");
        if (!gGetDisplayList) P0Error(@"SLSGetDisplayList 符号缺失");
    });
}

BOOL P0VPrivateDisplayControlAvailable(void) {
    P0VLoadPrivateSymbols();
    return gConfigureDisplayEnabled != NULL;
}

#pragma mark - C-09 屏幕共享 agent 竞态规避

static NSArray<NSNumber *> *P0VProcessPIDsWithBaseName(NSString *baseName) {
    int count = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (count <= 0) return @[];
    pid_t *pids = calloc((size_t)count, sizeof(pid_t));
    if (!pids) return @[];
    count = proc_listpids(PROC_ALL_PIDS, 0, pids, count * (int)sizeof(pid_t));
    NSMutableArray *out = [NSMutableArray array];
    for (int i = 0; i < count / (int)sizeof(pid_t); i++) {
        pid_t p = pids[i];
        if (p <= 0) continue;
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(p, path, sizeof(path)) <= 0) continue;
        if ([[[NSString stringWithUTF8String:path] lastPathComponent] isEqualToString:baseName]) {
            [out addObject:@(p)];
        }
    }
    free(pids);
    return out;
}

NSArray<NSNumber *> *P0VStopScreenSharingAgents(void) {
    NSArray *pids = P0VProcessPIDsWithBaseName(@"ScreensharingAgent");
    for (NSNumber *n in pids) {
        pid_t p = (pid_t)n.intValue;
        if (kill(p, SIGSTOP) != 0) {
            P0Error(@"C-09: SIGSTOP ScreensharingAgent(%d) 失败: %s", p, strerror(errno));
        }
    }
    if (pids.count) P0Log(@"C-09: 冻结 ScreensharingAgent %@（显示重配置窗口内）", pids);
    return pids;
}

void P0VResumeScreenSharingAgents(void) {
    NSArray *pids = P0VProcessPIDsWithBaseName(@"ScreensharingAgent");
    for (NSNumber *n in pids) {
        pid_t p = (pid_t)n.intValue;
        if (kill(p, SIGCONT) != 0 && errno != ESRCH) {
            P0Error(@"C-09: SIGCONT ScreensharingAgent(%d) 失败: %s", p, strerror(errno));
        }
    }
    if (pids.count) P0Log(@"C-09: 恢复 ScreensharingAgent %@", pids);
}

#pragma mark - 记录

@implementation P0VDisplayRecord

- (BOOL)isP0Virtual {
    return self.vendorID == kP0VVirtualVendorID;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        @"displayID": @(self.displayID),
        @"bounds": @{
            @"x": @(self.bounds.origin.x),
            @"y": @(self.bounds.origin.y),
            @"w": @(self.bounds.size.width),
            @"h": @(self.bounds.size.height),
        },
        @"main": @(self.isMain),
        @"builtin": @(self.isBuiltin),
        @"online": @(self.online),
        @"active": @(self.active),
        @"vendorID": @(self.vendorID),
        @"modelID": @(self.modelID),
        @"serialNumber": @(self.serialNumber),
        @"points": [NSString stringWithFormat:@"%zux%zu", self.pointWidth, self.pointHeight],
        @"pixels": [NSString stringWithFormat:@"%zux%zu", self.pixelWidth, self.pixelHeight],
        @"pointWidth": @(self.pointWidth),
        @"pointHeight": @(self.pointHeight),
        @"pixelWidth": @(self.pixelWidth),
        @"pixelHeight": @(self.pixelHeight),
        @"refreshRate": @(self.refreshRate),
        @"mirrorOf": @(self.mirrorOf),
        @"isP0Virtual": @(self.isP0Virtual),
    };
}

+ (instancetype)recordWithDictionary:(NSDictionary *)dict {
    P0VDisplayRecord *r = [[P0VDisplayRecord alloc] init];
    r.displayID = [dict[@"displayID"] unsignedIntValue];

    NSDictionary *b = dict[@"bounds"];
    if ([b isKindOfClass:[NSDictionary class]]) {
        r.bounds = CGRectMake([b[@"x"] doubleValue], [b[@"y"] doubleValue],
                              [b[@"w"] doubleValue], [b[@"h"] doubleValue]);
    }
    r.isMain = [dict[@"main"] boolValue];
    r.isBuiltin = [dict[@"builtin"] boolValue];
    r.online = [dict[@"online"] boolValue];
    r.active = [dict[@"active"] boolValue];
    r.vendorID = [dict[@"vendorID"] unsignedIntValue];
    r.modelID = [dict[@"modelID"] unsignedIntValue];
    r.serialNumber = [dict[@"serialNumber"] unsignedIntValue];
    r.pointWidth = (size_t)[dict[@"pointWidth"] unsignedLongLongValue];
    r.pointHeight = (size_t)[dict[@"pointHeight"] unsignedLongLongValue];
    r.pixelWidth = (size_t)[dict[@"pixelWidth"] unsignedLongLongValue];
    r.pixelHeight = (size_t)[dict[@"pixelHeight"] unsignedLongLongValue];
    r.refreshRate = [dict[@"refreshRate"] doubleValue];
    r.mirrorOf = [dict[@"mirrorOf"] unsignedIntValue];
    return r;
}

@end

#pragma mark - 快照

@implementation P0VDisplaySnapshot

+ (instancetype)captureActive {
    P0VDisplaySnapshot *snap = [[P0VDisplaySnapshot alloc] init];
    snap.capturedAt = [[NSDate date] timeIntervalSince1970];

    NSMutableArray<P0VDisplayRecord *> *records = [NSMutableArray array];
    for (NSNumber *num in P0VActiveDisplayIDs()) {
        CGDirectDisplayID did = num.unsignedIntValue;
        P0VDisplayRecord *r = [[P0VDisplayRecord alloc] init];
        r.displayID = did;
        r.bounds = CGDisplayBounds(did);
        r.isMain = CGDisplayIsMain(did);
        r.isBuiltin = CGDisplayIsBuiltin(did);
        r.online = CGDisplayIsOnline(did);
        r.active = CGDisplayIsActive(did);
        r.vendorID = CGDisplayVendorNumber(did);
        r.modelID = CGDisplayModelNumber(did);
        r.serialNumber = CGDisplaySerialNumber(did);
        r.mirrorOf = CGDisplayMirrorsDisplay(did);

        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(did);
        if (mode) {
            r.pointWidth = CGDisplayModeGetWidth(mode);
            r.pointHeight = CGDisplayModeGetHeight(mode);
            r.pixelWidth = CGDisplayModeGetPixelWidth(mode);
            r.pixelHeight = CGDisplayModeGetPixelHeight(mode);
            r.refreshRate = CGDisplayModeGetRefreshRate(mode);
            r.mode = CFBridgingRelease(mode);
        }
        [records addObject:r];
    }
    snap.displays = records;
    return snap;
}

+ (instancetype)loadFromFile:(NSString *)path {
    NSDictionary *dict = P0ReadJSON(path);
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *rows = dict[@"displays"];
    if (![rows isKindOfClass:[NSArray class]]) return nil;

    P0VDisplaySnapshot *snap = [[P0VDisplaySnapshot alloc] init];
    snap.capturedAt = [dict[@"capturedAt"] doubleValue];
    NSMutableArray<P0VDisplayRecord *> *records = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) continue;
        [records addObject:[P0VDisplayRecord recordWithDictionary:row]];
    }
    snap.displays = records;
    return snap;
}

- (BOOL)writeToFile:(NSString *)path error:(NSError **)error {
    NSMutableArray *rows = [NSMutableArray array];
    for (P0VDisplayRecord *r in self.displays) [rows addObject:[r dictionaryRepresentation]];
    NSDictionary *dict = @{
        @"version": @1,
        @"capturedAt": @(self.capturedAt),
        @"os": P0SystemInfo(),
        @"displays": rows,
    };
    return P0WriteJSON(dict, path, error);
}

- (P0VDisplayRecord *)recordForID:(CGDirectDisplayID)displayID {
    for (P0VDisplayRecord *r in self.displays) {
        if (r.displayID == displayID) return r;
    }
    return nil;
}

- (NSArray<NSNumber *> *)displayIDs {
    NSMutableArray *ids = [NSMutableArray array];
    for (P0VDisplayRecord *r in self.displays) [ids addObject:@(r.displayID)];
    return ids;
}

@end

#pragma mark - 查询

static NSArray<NSNumber *> *P0VDisplayIDsFromCG(CGError (*fn)(uint32_t, CGDirectDisplayID *, uint32_t *)) {
    uint32_t count = 0;
    if (fn(0, NULL, &count) != kCGErrorSuccess || count == 0) return @[];
    CGDirectDisplayID *buf = calloc(count, sizeof(CGDirectDisplayID));
    if (!buf) return @[];
    uint32_t got = count;
    CGError err = fn(count, buf, &got);
    NSMutableArray *out = [NSMutableArray array];
    if (err == kCGErrorSuccess) {
        for (uint32_t i = 0; i < got; i++) [out addObject:@(buf[i])];
    }
    free(buf);
    [out sortUsingSelector:@selector(compare:)];
    return out;
}

NSArray<NSNumber *> *P0VActiveDisplayIDs(void) {
    return P0VDisplayIDsFromCG(CGGetActiveDisplayList);
}

NSArray<NSNumber *> *P0VOnlineDisplayIDs(void) {
    return P0VDisplayIDsFromCG(CGGetOnlineDisplayList);
}

NSArray<NSNumber *> *P0VAllDisplayIDsFromSkyLight(void) {
    P0VLoadPrivateSymbols();
    if (!gGetDisplayList) return nil;
    uint32_t cap = 64;
    for (int attempt = 0; attempt < 3; attempt++) {
        CGDirectDisplayID *buf = calloc(cap, sizeof(CGDirectDisplayID));
        if (!buf) return nil;
        uint32_t got = cap;
        CGError err = gGetDisplayList(cap, buf, &got);
        if (err == kCGErrorSuccess && got < cap) {
            NSMutableArray *out = [NSMutableArray array];
            for (uint32_t i = 0; i < got; i++) [out addObject:@(buf[i])];
            free(buf);
            [out sortUsingSelector:@selector(compare:)];
            return out;
        }
        free(buf);
        if (got < cap) return @[];
        cap *= 4;
    }
    return nil;
}

NSArray<NSNumber *> *P0VStaleVirtualSlotIDs(void) {
    NSArray<NSNumber *> *sls = P0VAllDisplayIDsFromSkyLight();
    if (!sls) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSNumber *num in sls) {
        CGDirectDisplayID did = num.unsignedIntValue;
        if (CGDisplayIsOnline(did) || CGDisplayIsActive(did)) continue;
        if (CGDisplayVendorNumber(did) != UINT32_MAX) continue;
        CGRect b = CGDisplayBounds(did);
        if (b.size.width > 1 || b.size.height > 1) continue;
        [out addObject:num];
    }
    return out;
}

NSArray<NSDictionary *> *P0VDisplayDictionaries(NSArray<NSNumber *> *displayIDs) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSNumber *num in displayIDs) {
        CGDirectDisplayID did = num.unsignedIntValue;
        CGRect bounds = CGDisplayBounds(did);
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(did);
        NSString *points = @"(nil)", *pixels = @"(nil)";
        if (mode) {
            points = [NSString stringWithFormat:@"%zux%zu",
                      CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode)];
            pixels = [NSString stringWithFormat:@"%zux%zu",
                      CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode)];
            CGDisplayModeRelease(mode);
        }
        [out addObject:@{
            @"displayID": @(did),
            @"bounds": P0RectString(bounds),
            @"main": @(CGDisplayIsMain(did)),
            @"builtin": @(CGDisplayIsBuiltin(did)),
            @"online": @(CGDisplayIsOnline(did)),
            @"active": @(CGDisplayIsActive(did)),
            @"asleep": @(CGDisplayIsAsleep(did)),
            @"mirrorOf": @(CGDisplayMirrorsDisplay(did)),
            @"vendorID": @(CGDisplayVendorNumber(did)),
            @"modelID": @(CGDisplayModelNumber(did)),
            @"points": points,
            @"pixels": pixels,
        }];
    }
    return out;
}

#pragma mark - 事务

// WindowServer 的显示配置 IPC 无系统级超时（P0 两次 watchdog 事故的根因）。
// 这里把 begin+configure+commit 整个放进后台线程并加死线；超时后只置位、不重试。
static atomic_bool gWindowServerHung = false;

BOOL P0VWindowServerHung(void) { return atomic_load(&gWindowServerHung); }
void P0VMarkWindowServerHung(void) { atomic_store(&gWindowServerHung, true); }
void P0VResetWindowServerHung(void) { atomic_store(&gWindowServerHung, false); }

static CGConfigureOption P0VOption(P0VCommitScope scope) {
    return scope == P0VCommitScopePermanent ? kCGConfigurePermanently : kCGConfigureForSession;
}

// body 返回 detail；*shouldCommit=NO 时取消事务。
// 返回 YES 仅当 begin 与 commit 都成功且未超时。
//
// 死线分两级（2026-11-27 修正，见 RESULTS-BY-OS §5.48）：
//   软死线 timeoutSec（NFR-06 的 8s）：到点只报「慢提交」，不立刻判挂起；
//   宽限期 P0V_TX_GRACE_SEC（默认 12s）：期间按 verify() 的实际显示状态收敛判定。
// 真机依据：13/14 的独占禁屏与恢复事务在 8s 边界的误报率极高（慢提交 9–12s 才生效，
// 状态最终是对的），一刀切置 WindowServerHung 会把可恢复状态拖成「恢复失败」并让
// 后续 restore 直接被拒。挂起与慢提交的区分不能只看耗时，必须看状态是否收敛。
static int P0VTxGraceSec(void) {
    const char *v = getenv("P0V_TX_GRACE_SEC");
    if (!v || !*v) return 12;
    int n = atoi(v);
    if (n < 0) n = 0;
    if (n > 60) n = 60;
    return n;
}

// ---- 故障注入（只给 Scripts/tests/tx-breaker 用，默认关闭）----
// 真挂起（WindowServer 冻结）在真机上必然连带崩显示栈并踢回 loginwindow，
// 不能靠人工冻结 WS 做验收；这里在同一层把「事务线程不返回」注入出来：
//   P0V_FAULT_TX=hang      事务线程永不返回，WS 仍可响应（模拟提交卡死）
//   P0V_FAULT_TX=wsfreeze  事务线程永不返回，且 WS 探测无响应（模拟真冻结）
// 两种模式都不会真正提交显示配置，物理屏不会被改动。
static int P0VFaultMode(void) {
    static int mode = -1;
    if (mode >= 0) return mode;
    const char *v = getenv("P0V_FAULT_TX");
    if (!v || !*v) mode = 0;
    else if (!strcmp(v, "hang")) mode = 1;
    else if (!strcmp(v, "wsfreeze")) mode = 2;
    else mode = 0;
    return mode;
}

// WindowServer 是否还能响应。真挂起时连 CGDisplayIsActive 都会阻塞，
// 所以「状态收敛」判据必须自己带死线，否则软死线之后会永久卡在 verify() 里，
// 熔断反而永远不会触发（这是 8s 死线修复后剩下的真实缺口）。
// 返回 NO 表示探测超时或注入为冻结。*outConverged 仅在返回 YES 时有效。
static BOOL P0VProbeVerify(BOOL (^verify)(void), int timeoutMs, BOOL *outConverged) {
    __block BOOL converged = NO;
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (P0VFaultMode() == 2) {
            // 故障注入：模拟 WS 完全冻结——探测线程不返回，由下面的 1s 死线兜住
            P0SleepMs(5000);
            return;
        }
        (void)CGDisplayIsActive(CGMainDisplayID());   // 最轻的 WS IPC，先探活
        if (verify) converged = verify();
        dispatch_semaphore_signal(s);
    });
    if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW,
                                                (int64_t)timeoutMs * NSEC_PER_MSEC)) != 0) {
        return NO;   // 线程留在那里也无害：本进程已判定挂起，不再发事务
    }
    if (outConverged) *outConverged = converged;
    return YES;
}

static BOOL P0VPerformTransactionV(P0VCommitScope scope,
                                   int timeoutSec,
                                   NSDictionary * (^body)(CGDisplayConfigRef cfg, BOOL *shouldCommit),
                                   BOOL (^verify)(void),
                                   NSDictionary **outDetail,
                                   NSError **error) {
    if (P0VWindowServerHung()) {
        if (error) *error = [NSError errorWithDomain:@"P0V" code:10
            userInfo:@{NSLocalizedDescriptionKey: @"WindowServer 已判定挂起，拒绝发起新的显示配置事务"}];
        return NO;
    }
    if (timeoutSec <= 0) timeoutSec = 8;   // NFR-06：SPI 挂起 8s 内熔断

    // 目标终态若在事务开始前就已成立，状态收敛不能作为「事务已生效」的证据
    // （否则真挂起会被误判成成功）。
    BOOL verifyUsable = (verify != NULL) && !verify();

    __block CGError beginErr = kCGErrorSuccess;
    __block CGError commitErr = kCGErrorSuccess;
    __block NSDictionary *detail = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (P0VFaultMode() != 0) {
            // 故障注入：既不 commit 也不 cancel，模拟 SPI 永不返回（显示状态不会收敛）。
            P0Error(@"故障注入：P0V_FAULT_TX=%s，事务线程不返回（显示配置未提交）",
                    P0VFaultMode() == 1 ? "hang" : "wsfreeze");
            return;
        }
        CGDisplayConfigRef cfg = NULL;
        beginErr = CGBeginDisplayConfiguration(&cfg);
        if (beginErr == kCGErrorSuccess && cfg) {
            BOOL shouldCommit = YES;
            detail = body(cfg, &shouldCommit);
            if (shouldCommit) {
                commitErr = CGCompleteDisplayConfiguration(cfg, P0VOption(scope));
            } else {
                CGCancelDisplayConfiguration(cfg);
                commitErr = kCGErrorFailure;
            }
        }
        dispatch_semaphore_signal(sem);
    });

    BOOL commitConfirmed = NO;
    BOOL lateCommit = NO;

    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                                  (int64_t)timeoutSec * NSEC_PER_SEC)) == 0) {
        commitConfirmed = YES;
    } else {
        int grace = P0VTxGraceSec();
        P0Error(@"显示配置事务 %ds 未返回：进入 %ds 收敛观察期（先探活 WindowServer，再按实际状态判定，不重复提交）",
                timeoutSec, grace);
        double graceEnd = CFAbsoluteTimeGetCurrent() + grace;
        BOOL wsAlive = YES;
        while (CFAbsoluteTimeGetCurrent() < graceEnd) {
            if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                                           250 * NSEC_PER_MSEC)) == 0) {
                commitConfirmed = YES;
                lateCommit = YES;
                break;
            }
            BOOL converged = NO;
            if (!P0VProbeVerify(verifyUsable ? verify : NULL, 1000, &converged)) {
                wsAlive = NO;   // WS 探测 1s 无响应 ⇒ 真挂起，不再等满宽限期
                break;
            }
            if (converged) { lateCommit = YES; break; }
        }
        if (!lateCommit) {
            atomic_store(&gWindowServerHung, true);
            double elapsed = CFAbsoluteTimeGetCurrent() - t0;
            NSString *reason = wsAlive ? @"state-not-converged" : @"ws-unresponsive";
            P0Error(@"显示配置事务 %.1fs 未生效且%@：判定 WindowServer 挂起；"
                    @"不再重试，交由守护进程兜底恢复",
                    elapsed, wsAlive ? @"显示状态未收敛" : @"WindowServer 探测无响应");
            if (outDetail) {
                *outDetail = @{ @"timedOut": @YES, @"timeoutSec": @(timeoutSec),
                                @"graceSec": @(grace), @"elapsedSec": @(elapsed),
                                @"reason": reason,
                                @"warning": @"事务可能迟到生效，不要重复提交" };
            }
            if (error) *error = [NSError errorWithDomain:@"P0V" code:11
                userInfo:@{NSLocalizedDescriptionKey: @"显示配置事务超时（WindowServer 疑似挂起）"}];
            return NO;
        }
        P0Log(@"显示配置事务迟到 %.1fs 生效（软死线 %ds），按实际状态判定成功",
              CFAbsoluteTimeGetCurrent() - t0, timeoutSec);
        if (!commitConfirmed) {
            // 状态已收敛但提交线程还没回来：此时读 beginErr/commitErr 是竞态，
            // 直接以状态为准返回成功，并明确标注「未确认」，禁止调用方重复提交。
            if (outDetail) {
                *outDetail = @{ @"lateCommit": @YES, @"commitConfirmed": @NO,
                                @"stateVerified": @YES, @"timeoutSec": @(timeoutSec),
                                @"elapsedSec": @(CFAbsoluteTimeGetCurrent() - t0),
                                @"note": @"事务迟到生效，已按实际显示状态判定成功；不要重复提交" };
            }
            return YES;
        }
    }

    NSMutableDictionary *merged = [detail mutableCopy] ?: [NSMutableDictionary dictionary];
    merged[@"beginResult"] = @(beginErr);
    merged[@"commitResult"] = @(commitErr);
    if (lateCommit) {
        merged[@"lateCommit"] = @YES;
        merged[@"elapsedSec"] = @(CFAbsoluteTimeGetCurrent() - t0);
    }
    if (outDetail) *outDetail = merged;

    if (beginErr != kCGErrorSuccess || commitErr != kCGErrorSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:@"P0V" code:12
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"显示配置事务失败（begin=%d commit=%d）",
                     (int)beginErr, (int)commitErr]}];
        }
        return NO;
    }
    return YES;
}

static BOOL P0VPerformTransaction(P0VCommitScope scope,
                                  int timeoutSec,
                                  NSDictionary * (^body)(CGDisplayConfigRef cfg, BOOL *shouldCommit),
                                  NSDictionary **outDetail,
                                  NSError **error) {
    return P0VPerformTransactionV(scope, timeoutSec, body, NULL, outDetail, error);
}


BOOL P0VApplyDisplayEnabledChanges(NSArray<NSNumber *> *toDisable,
                                   NSArray<NSNumber *> *toEnable,
                                   P0VCommitScope scope,
                                   int timeoutSec,
                                   NSDictionary **detail,
                                   NSError **error) {
    P0VLoadPrivateSymbols();
    if (!gConfigureDisplayEnabled) {
        if (error) *error = [NSError errorWithDomain:@"P0V" code:13
            userInfo:@{NSLocalizedDescriptionKey: @"SLSConfigureDisplayEnabled 不可用"}];
        return NO;
    }
    if (toDisable.count == 0 && toEnable.count == 0) {
        if (detail) *detail = @{ @"noop": @YES };
        return YES;
    }

    // 状态收敛判据：禁用的屏不再 active、启用的屏已 active。
    // 只用公开 CG 查询，不依赖事务返回值（返回值会因慢提交在软死线后失真）。
    BOOL (^verify)(void) = ^BOOL{
        for (NSNumber *num in toDisable) {
            if (CGDisplayIsActive(num.unsignedIntValue)) return NO;
        }
        for (NSNumber *num in toEnable) {
            if (!CGDisplayIsActive(num.unsignedIntValue)) return NO;
        }
        return YES;
    };

    return P0VPerformTransactionV(scope, timeoutSec, ^NSDictionary *(CGDisplayConfigRef cfg, BOOL *shouldCommit) {
        NSMutableArray *ops = [NSMutableArray array];
        NSMutableArray *errors = [NSMutableArray array];

        for (NSNumber *num in toDisable) {
            CGDirectDisplayID did = num.unsignedIntValue;
            CGError e = gConfigureDisplayEnabled(cfg, did, false);
            [ops addObject:@{ @"displayID": @(did), @"enabled": @NO, @"result": @(e) }];
            if (e != kCGErrorSuccess) {
                [errors addObject:[NSString stringWithFormat:@"disable %u -> CGError %d", did, (int)e]];
                *shouldCommit = NO;
                break;
            }
        }
        if (*shouldCommit) {
            for (NSNumber *num in toEnable) {
                CGDirectDisplayID did = num.unsignedIntValue;
                CGError e = gConfigureDisplayEnabled(cfg, did, true);
                [ops addObject:@{ @"displayID": @(did), @"enabled": @YES, @"result": @(e) }];
                if (e != kCGErrorSuccess) {
                    [errors addObject:[NSString stringWithFormat:@"enable %u -> CGError %d", did, (int)e]];
                    *shouldCommit = NO;
                    break;
                }
            }
        }
        return @{ @"ops": ops, @"errors": errors };
    }, verify, detail, error);
}

static CGDisplayModeRef P0VLookupMode(CGDirectDisplayID did,
                                      size_t pointW, size_t pointH,
                                      size_t pixelW, size_t pixelH,
                                      double refresh) CF_RETURNS_RETAINED {
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(did, NULL);
    if (!modes) return NULL;

    CGDisplayModeRef best = NULL;
    double bestScore = INFINITY;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        size_t mw = CGDisplayModeGetWidth(m), mh = CGDisplayModeGetHeight(m);
        size_t mpw = CGDisplayModeGetPixelWidth(m), mph = CGDisplayModeGetPixelHeight(m);
        if (pointW && pointH && (mw != pointW || mh != pointH)) continue;
        if (pixelW && pixelH && (mpw != pixelW || mph != pixelH)) continue;
        double score = fabs(CGDisplayModeGetRefreshRate(m) - refresh);
        if (score < bestScore) { bestScore = score; best = m; }
    }
    // 精确尺寸找不到时退到像素面积最接近的模式：宁可分辨率略有差异，也不能在恢复阶段
    // 把屏留在 1x1 退化态。最终是否还原正确由调用方比较拓扑来判定。
    if (!best) {
        size_t wantArea = pixelW * pixelH;
        size_t bestDelta = SIZE_MAX;
        for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            size_t area = CGDisplayModeGetPixelWidth(m) * CGDisplayModeGetPixelHeight(m);
            size_t delta = area > wantArea ? area - wantArea : wantArea - area;
            if (delta < bestDelta) { bestDelta = delta; best = m; }
        }
    }
    if (best) CGDisplayModeRetain(best);
    CFRelease(modes);
    return best;
}

BOOL P0VRestoreSnapshot(P0VDisplaySnapshot *snapshot,
                        P0VCommitScope scope,
                        int timeoutSec,
                        NSDictionary **detail,
                        NSError **error) {
    if (P0VWindowServerHung()) {
        if (error) *error = [NSError errorWithDomain:@"P0V" code:14
            userInfo:@{NSLocalizedDescriptionKey: @"WindowServer 已判定挂起，跳过恢复事务"}];
        return NO;
    }
    NSArray<NSNumber *> *ids = [snapshot displayIDs];
    if (ids.count == 0) {
        if (detail) *detail = @{ @"note": @"快照为空，无可恢复项" };
        return YES;
    }

    // 第一步：把快照里「当前不在 active list」的屏重新 enable。
    // 已经 active 的屏必须跳过 —— 对已启用屏重复 enable 在部分 WindowServer
    // 版本上会返回错误，导致整个恢复事务被取消。
    NSSet *activeNow = [NSSet setWithArray:P0VActiveDisplayIDs()];
    NSMutableArray<NSNumber *> *toEnable = [NSMutableArray array];
    for (NSNumber *n in ids) if (![activeNow containsObject:n]) [toEnable addObject:n];

    NSDictionary *enableDetail = nil;
    NSError *enableError = nil;
    BOOL enableOK = YES;
    if (toEnable.count > 0) {
        enableOK = P0VApplyDisplayEnabledChanges(@[], toEnable, scope, timeoutSec, &enableDetail, &enableError);
    } else {
        enableDetail = @{ @"skipped": @"all-snapshot-displays-already-active" };
    }
    if (!enableOK) {
        if (detail) *detail = @{ @"phase": @"enable", @"enable": enableDetail ?: @{} };
        if (error) *error = enableError;
        return NO;
    }
    P0SleepMs(800);

    // 第二步：恢复 mirror / mode / origin。逐项尽力而为，不因某一项失败取消整个事务，
    // 否则会把「只差原点」的拓扑留在更糟的状态。
    NSDictionary *topologyDetail = nil;
    NSError *topologyError = nil;
    BOOL topologyOK = P0VPerformTransaction(scope, timeoutSec, ^NSDictionary *(CGDisplayConfigRef cfg, BOOL *shouldCommit) {
        NSMutableArray *ops = [NSMutableArray array];
        NSMutableArray *errors = [NSMutableArray array];

        for (P0VDisplayRecord *r in snapshot.displays) {
            CGDirectDisplayID did = r.displayID;

            CGError mirrorErr = CGConfigureDisplayMirrorOfDisplay(cfg, did, r.mirrorOf);
            [ops addObject:@{ @"displayID": @(did), @"op": @"mirror",
                              @"mirrorOf": @(r.mirrorOf), @"result": @(mirrorErr) }];
            if (mirrorErr != kCGErrorSuccess) {
                [errors addObject:[NSString stringWithFormat:@"mirror %u -> %d", did, (int)mirrorErr]];
            }

            CGDisplayModeRef mode = NULL;
            if (r.mode) {
                mode = (CGDisplayModeRef)CFBridgingRetain(r.mode);
            } else {
                mode = P0VLookupMode(did, r.pointWidth, r.pointHeight,
                                     r.pixelWidth, r.pixelHeight, r.refreshRate);
            }
            if (mode) {
                CGError modeErr = CGConfigureDisplayWithDisplayMode(cfg, did, mode, NULL);
                [ops addObject:@{ @"displayID": @(did), @"op": @"mode",
                                  @"points": [NSString stringWithFormat:@"%zux%zu", r.pointWidth, r.pointHeight],
                                  @"result": @(modeErr) }];
                if (modeErr != kCGErrorSuccess) {
                    [errors addObject:[NSString stringWithFormat:@"mode %u -> %d", did, (int)modeErr]];
                }
                CFRelease(mode);
            } else {
                [ops addObject:@{ @"displayID": @(did), @"op": @"mode", @"result": @"no-match" }];
                [errors addObject:[NSString stringWithFormat:@"mode %u: 无匹配模式", did]];
            }

            CGError originErr = CGConfigureDisplayOrigin(cfg, did,
                                                         (int32_t)llround(r.bounds.origin.x),
                                                         (int32_t)llround(r.bounds.origin.y));
            [ops addObject:@{ @"displayID": @(did), @"op": @"origin",
                              @"origin": [NSString stringWithFormat:@"%.0f,%.0f",
                                          r.bounds.origin.x, r.bounds.origin.y],
                              @"result": @(originErr) }];
            if (originErr != kCGErrorSuccess) {
                [errors addObject:[NSString stringWithFormat:@"origin %u -> %d", did, (int)originErr]];
            }
        }
        return @{ @"ops": ops, @"errors": errors };
    }, &topologyDetail, &topologyError);

    if (detail) {
        *detail = @{
            @"enable": enableDetail ?: @{},
            @"topology": topologyDetail ?: @{},
            @"ok": @(topologyOK),
        };
    }
    if (!topologyOK && error) *error = topologyError;
    return topologyOK;
}

#pragma mark - 守护进程

static NSString *P0VGuardianLogPath(void) { return @"/tmp/p0v-display-guardian.log"; }

static BOOL P0VFileExists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static void P0VWriteGuardianResult(NSString *snapshotPath, NSDictionary *result) {
    NSString *path = [snapshotPath stringByAppendingString:@".guardian-result.json"];
    NSError *err = nil;
    if (!P0WriteJSON(result, path, &err)) {
        P0Error(@"守护进程写结果失败: %@", err.localizedDescription);
    }
}

// 守护兜底恢复之后，把「不属于快照的 P0 虚拟屏」一并禁用。
// 场景：快照在创建虚拟屏之前拍下（M1 新顺序），进程若在建屏后被杀，虚拟屏会成为
// 无主孤儿槽位，甚至被 WindowServer 当成 main；只恢复快照不足以清掉它，
// 物理屏拓扑仍被孤儿占位（表现为恢复后画面错位 / 黑屏）。
static NSInteger P0VDisableOrphanVirtualDisplays(P0VDisplaySnapshot *snapshot) {
    NSSet *known = [NSSet setWithArray:[snapshot displayIDs]];
    NSMutableArray<NSNumber *> *orphans = [NSMutableArray array];
    for (NSDictionary *d in P0VDisplayDictionaries(P0VActiveDisplayIDs())) {
        if ([d[@"vendorID"] unsignedIntValue] != kP0VVirtualVendorID) continue;
        NSNumber *did = d[@"displayID"];
        if (did && ![known containsObject:did]) [orphans addObject:did];
    }
    if (orphans.count == 0) return 0;

    NSDictionary *detail = nil;
    NSError *err = nil;
    if (!P0VApplyDisplayEnabledChanges(orphans, @[], P0VCommitScopeSession, 20, &detail, &err)) {
        P0Error(@"清理无主虚拟屏失败: %@", err.localizedDescription);
        return -1;
    }
    P0Log(@"已禁用 %lu 块无主虚拟屏 %@", (unsigned long)orphans.count, orphans);
    return (NSInteger)orphans.count;
}

int P0VRunGuardian(NSString *snapshotPath, pid_t parentPID) {
    // 守护进程在独立进程组里，但仍显式忽略终端信号，避免被同组操作误杀。
    signal(SIGHUP, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    signal(SIGTERM, SIG_IGN);

    // 就绪握手：必须在做任何事之前写 ready 文件。
    // 父进程（P0VStartGuardian）等到这个文件才会允许禁屏；写不出来就说明本进程
    // 根本没接管守护职责，此时父进程必须放弃禁屏，而不是在没有兜底的情况下黑屏。
    NSString *readyPath = [snapshotPath stringByAppendingString:@".guardian-ready"];
    NSError *readyErr = nil;
    if (![@"ready" writeToFile:readyPath atomically:YES
                      encoding:NSUTF8StringEncoding error:&readyErr]) {
        P0Error(@"守护进程写就绪文件失败（%@）: %@", readyPath,
                readyErr.localizedDescription);
        return 4;
    }

    char rawPath[PATH_MAX] = {0};
    uint32_t size = sizeof(rawPath);
    if (_NSGetExecutablePath(rawPath, &size) != 0) rawPath[0] = '\0';
    // proc_pidpath 返回的是 exec 时的真实路径；这里同样 realpath，
    // 否则符号链接路径与真实路径不等，守护进程会误判父进程已退出。
    char selfPath[PATH_MAX] = {0};
    if (rawPath[0]) {
        if (!realpath(rawPath, selfPath)) strlcpy(selfPath, rawPath, sizeof(selfPath));
    }

    P0Log(@"守护进程启动：parent=%d snapshot=%@", parentPID, snapshotPath);

    while (1) {
        if (kill(parentPID, 0) != 0) break;
        // PID 被回收后可能复用给别的进程；路径不同即视为父进程已退出。
        char parentPath[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(parentPID, parentPath, sizeof(parentPath)) <= 0) break;
        if (selfPath[0] && strcmp(parentPath, selfPath) != 0) break;
        usleep(250 * 1000);
    }

    // 父进程正常收尾时会先写 .done；给它一点时间落盘。
    usleep(400 * 1000);
    NSString *donePath = [snapshotPath stringByAppendingString:@".done"];
    if (P0VFileExists(donePath)) {
        P0Log(@"父进程已正常恢复并写 done，守护进程退出");
        P0VResumeScreenSharingAgents();
        P0VWriteGuardianResult(snapshotPath, @{ @"acted": @NO, @"reason": @"parent-clean" });
        return 0;
    }

    // 父进程若在禁屏窗口内死亡，agent 会一直处于 SIGSTOP；先解冻再做兜底恢复。
    P0VResumeScreenSharingAgents();
    P0Error(@"父进程未正常收尾，守护进程开始兜底恢复物理屏");
    P0VDisplaySnapshot *snap = [P0VDisplaySnapshot loadFromFile:snapshotPath];
    if (!snap) {
        P0Error(@"守护进程无法读取快照: %@", snapshotPath);
        P0VWriteGuardianResult(snapshotPath, @{ @"acted": @YES, @"ok": @NO, @"error": @"snapshot-unreadable" });
        return 2;
    }

    NSDictionary *detail = nil;
    NSError *err = nil;
    BOOL ok = P0VRestoreSnapshot(snap, P0VCommitScopeSession, 20, &detail, &err);
    if (!ok && !P0VWindowServerHung()) {
        P0Log(@"首次兜底恢复失败，1s 后重试一次");
        P0SleepMs(1000);
        ok = P0VRestoreSnapshot(snap, P0VCommitScopeSession, 20, &detail, NULL);
    }

    // 恢复物理屏之后清掉本会话遗留的虚拟屏，避免孤儿占位（见函数注释）。
    NSInteger orphansDisabled = 0;
    if (ok) orphansDisabled = P0VDisableOrphanVirtualDisplays(snap);

    NSDictionary *result = @{
        @"acted": @YES,
        @"ok": @(ok),
        @"error": err.localizedDescription ?: @"",
        @"detail": detail ?: @{},
        @"orphansDisabled": @(orphansDisabled),
        @"activeIDs": P0VActiveDisplayIDs(),
        @"snapshotIDs": [snap displayIDs],
    };
    P0Log(@"守护进程兜底恢复 %@", ok ? @"成功" : @"失败");
    P0VWriteGuardianResult(snapshotPath, result);
    return ok ? 0 : 3;
}

BOOL P0VStartGuardian(NSString *snapshotPath, pid_t parentPID, NSError **error) {
    char exe[PATH_MAX] = {0};
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) != 0) {
        if (error) *error = [NSError errorWithDomain:@"P0V" code:20
            userInfo:@{NSLocalizedDescriptionKey: @"无法取得自身可执行文件路径"}];
        return NO;
    }
    char resolved[PATH_MAX] = {0};
    if (!realpath(exe, resolved)) strlcpy(resolved, exe, sizeof(resolved));

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    const char *logPath = P0VGuardianLogPath().fileSystemRepresentation;
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logPath,
                                     O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, logPath,
                                     O_WRONLY | O_CREAT | O_APPEND, 0644);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    // 独立进程组：终端 Ctrl+C 只打到探针本身，守护进程留下完成兜底恢复。
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);

    char pidArg[32];
    snprintf(pidArg, sizeof(pidArg), "%d", parentPID);
    char *argv[] = {
        resolved,
        "--guardian",
        (char *)snapshotPath.fileSystemRepresentation,
        "--parent-pid",
        pidArg,
        NULL,
    };

    // 清掉可能残留的就绪标记，握手必须由本次 spawn 的子进程自己写。
    NSString *readyPath = [snapshotPath stringByAppendingString:@".guardian-ready"];
    [[NSFileManager defaultManager] removeItemAtPath:readyPath error:NULL];

    pid_t child = 0;
    int rc = posix_spawn(&child, resolved, &actions, &attr, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);

    if (rc != 0) {
        if (error) *error = [NSError errorWithDomain:@"P0V" code:21
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"posix_spawn 守护进程失败: %s", strerror(rc)]}];
        return NO;
    }

    // 就绪握手（必须）：spawn 成功 ≠ 守护在跑。
    // 2026-11-18 事故：pipeline_kiosk_probe 没实现 --guardian，子进程打印用法后立刻退出，
    // 父进程却以为「有兜底」继续禁屏，最终全屏黑死、只能强制重启。
    // 因此这里必须等到 ready 文件，否则视为「无兜底」，直接失败。
    BOOL ready = NO;
    BOOL childExited = NO;
    int childStatus = 0;
    for (int i = 0; i < 60; i++) {          // 最多 3s
        if ([[NSFileManager defaultManager] fileExistsAtPath:readyPath]) { ready = YES; break; }
        pid_t w = waitpid(child, &childStatus, WNOHANG);
        if (w == child) { childExited = YES; break; }
        usleep(50 * 1000);
    }
    if (!ready) {
        if (!childExited) {
            kill(child, SIGKILL);
            waitpid(child, &childStatus, 0);
        }
        if (error) *error = [NSError errorWithDomain:@"P0V" code:22
            userInfo:@{NSLocalizedDescriptionKey: childExited
                ? [NSString stringWithFormat:
                    @"守护进程启动即退出（exit=%d）：宿主二进制很可能没有实现 --guardian，"
                    @"禁止在无兜底的情况下禁屏", WIFEXITED(childStatus) ? WEXITSTATUS(childStatus) : -1]
                : @"守护进程 3s 内未就绪，禁止在无兜底的情况下禁屏"}];
        return NO;
    }
    P0Log(@"已启动守护进程 pid=%d（就绪握手通过，日志 %@）", (int)child, P0VGuardianLogPath());
    return YES;
}
