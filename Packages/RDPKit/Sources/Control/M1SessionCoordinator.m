//
//  M1SessionCoordinator.m
//  M1-Skeleton
//

#import "M1SessionCoordinator.h"

NSString * const M1SessionErrorDomain = @"M1Session";

NSString *M1HostSessionPhaseName(M1HostSessionPhase phase) {
    switch (phase) {
        case M1HostSessionIdle:            return @"Idle";
        case M1HostSessionPreventingSleep: return @"PreventingSleep";
        case M1HostSessionDisplaysCreating:return @"DisplaysCreating";
        case M1HostSessionDisplaysReady:   return @"DisplaysReady";
        case M1HostSessionPhysicalDisabled:return @"PhysicalDisabled";
        case M1HostSessionAuthenticating:  return @"Authenticating";
        case M1HostSessionStreaming:       return @"Streaming";
        case M1HostSessionRecovering:      return @"Recovering";
        case M1HostSessionLocked:          return @"Locked";
        case M1HostSessionFailed:          return @"Failed";
    }
    return @"Unknown";
}

static NSError *M1SessErr(M1SessionErrorCode code, NSString *phase, NSString *desc) {
    return [NSError errorWithDomain:M1SessionErrorDomain code:code
        userInfo:@{ NSLocalizedDescriptionKey: desc,
                    @"phase": phase }];
}

@interface M1SessionCoordinator ()
@property (nonatomic, assign) M1HostSessionPhase phase;
@property (nonatomic, strong) NSArray<NSNumber *> *specsSummary;
@property (nonatomic, strong) M1TakeoverDetector *takeover;
@property (nonatomic, strong) id<M1SessionDriver> driver;
@property (nonatomic, assign) BOOL sleepHeld;
@property (nonatomic, assign) BOOL physicalDisabled;
@property (nonatomic, assign) BOOL virtualCreated;
@property (nonatomic, copy) NSArray<NSDictionary *> *currentSpecs;
@property (nonatomic, copy, readwrite) NSArray<NSNumber *> *createdDisplayIDs;
@end

@implementation M1SessionCoordinator

- (instancetype)initWithDriver:(id<M1SessionDriver>)driver {
    self = [super init];
    if (self) {
        _driver = driver;
        _phase = M1HostSessionIdle;
        _takeover = [[M1TakeoverDetector alloc] init];
        _locksScreenOnEnd = YES;
    }
    return self;
}

- (BOOL)startWithSpecs:(NSArray<NSDictionary *> *)specs
             needsLogin:(BOOL)needsLogin
             credential:(nullable NSString *)credential
                  error:(NSError * _Nullable * _Nullable)error {
    if (needsLogin && credential.length == 0) {
        if (error) *error = M1SessErr(M1SessionErrorNeedCredential,
            M1HostSessionPhaseName(_phase), @"远程登录需要凭据");
        return NO;
    }
    NSArray<NSNumber *> *summary = [self summaryForSpecs:specs error:error];
    if (!summary) return NO;
    self.specsSummary = summary;
    self.currentSpecs = specs;

    // step 0 防睡眠断言（D-08 前置）
    _phase = M1HostSessionPreventingSleep;
    NSError *stepErr = nil;
    if (![_driver acquireSleepAssertionError:&stepErr]) {
        _phase = M1HostSessionFailed;
        if (error) *error = M1SessErr(M1SessionErrorStepFailed,
            M1HostSessionPhaseName(_phase), stepErr.localizedDescription ?: @"防睡眠断言失败");
        return NO;
    }
    self.sleepHeld = YES;

    // step 2 建齐全部虚拟屏（必须先于禁物理屏）
    CFAbsoluteTime tCreateStart = CFAbsoluteTimeGetCurrent();
    _phase = M1HostSessionDisplaysCreating;
    if (![_driver createVirtualDisplays:specs error:&stepErr]) {
        [self recoverBestEffort];
        _phase = M1HostSessionFailed;
        if (error) *error = M1SessErr(M1SessionErrorStepFailed,
            M1HostSessionPhaseName(_phase), stepErr.localizedDescription ?: @"建屏失败");
        return NO;
    }
    self.virtualCreated = YES;
    self.createdDisplayIDs = [_driver createdDisplayIDs];
    _phase = M1HostSessionDisplaysReady;
    CFAbsoluteTime tDisableStart = CFAbsoluteTimeGetCurrent();

    // step 3 禁物理屏 + C-09 隔离校验
    NSArray *keep = [_driver createdDisplayIDs];
    if (self.extraKeepDisplayIDs.count > 0) {
        keep = [keep arrayByAddingObjectsFromArray:self.extraKeepDisplayIDs];
    }
    if (![_driver snapshotAndDisablePhysicalExcept:keep error:&stepErr]) {
        [self recoverBestEffort];
        _phase = M1HostSessionFailed;
        if (error) *error = M1SessErr(M1SessionErrorStepFailed,
            M1HostSessionPhaseName(_phase), stepErr.localizedDescription ?: @"禁用物理屏失败");
        return NO;
    }
    self.physicalDisabled = YES;
    // keep 了额外物理屏（诊断模式）就不可能满足 C-09，跳过但保持 phase 语义。
    if (self.extraKeepDisplayIDs.count == 0 && ![_driver verifyIsolationError:&stepErr]) {
        [self recoverBestEffort];
        _phase = M1HostSessionFailed;
        if (error) *error = M1SessErr(M1SessionErrorStepFailed,
            M1HostSessionPhaseName(_phase), stepErr.localizedDescription ?: @"C-09 显示空间隔离校验失败");
        return NO;
    }
    _phase = M1HostSessionPhysicalDisabled;
    printf("  [建屏] 用时：建屏 %.2fs，禁屏/校验 %.2fs\n",
           tDisableStart - tCreateStart, CFAbsoluteTimeGetCurrent() - tDisableStart);
    fflush(stdout);

    // step 4 远程登录（Path A）：零物理屏后登录 UI 自动迁移到虚拟屏
    if (needsLogin) {
        _phase = M1HostSessionAuthenticating;
        if (![_driver injectUnlockCredential:credential error:&stepErr]) {
            [self recoverBestEffort];
            _phase = M1HostSessionFailed;
            if (error) *error = M1SessErr(M1SessionErrorStepFailed,
                M1HostSessionPhaseName(_phase), stepErr.localizedDescription ?: @"凭据注入/解锁失败");
            return NO;
        }
    }

    // step 5 STREAMING（帧管线 D-10 接入点，本版只推进状态）
    _phase = M1HostSessionStreaming;
    return YES;
}

- (BOOL)endSessionError:(NSError * _Nullable * _Nullable)error {
    if (_phase == M1HostSessionIdle || _phase == M1HostSessionLocked ||
        _phase == M1HostSessionFailed) {
        return YES;
    }
    _phase = M1HostSessionRecovering;
    if (![self recoverBestEffort]) {
        _phase = M1HostSessionFailed;
        if (error) *error = M1SessErr(M1SessionErrorRecoveryFailed,
            M1HostSessionPhaseName(_phase), @"恢复物理屏/销毁虚拟屏失败");
        return NO;
    }
    if (!self.locksScreenOnEnd) {
        _phase = M1HostSessionLocked;
        [_takeover reset];
        return YES;
    }
    // D-06 step 2：恢复后真锁屏
    NSError *lockErr = nil;
    if (![_driver lockScreenError:&lockErr]) {
        // 锁屏失败不是灾难（Path B 高安全档才强制），记录但不判失败。
        _phase = M1HostSessionLocked;
        return YES;
    }
    _phase = M1HostSessionLocked;
    [_takeover reset];
    return YES;
}

- (BOOL)takeoverNowError:(NSError * _Nullable * _Nullable)error {
    // 现场优先：跳过 10s 缓冲，立即断开（endSession 内含恢复 + 锁屏）。
    return [self endSessionError:error];
}

#pragma mark - 内部

// 事务性回退：恢复物理屏并销毁虚拟屏，释放断言。best-effort，失败记日志不抛出。
- (BOOL)recoverBestEffort {
    BOOL ok = YES;
    // 建屏成功即可能泄漏虚拟屏（含「禁屏失败」路径），必须统一由 driver 恢复。
    if (self.virtualCreated || self.physicalDisabled) {
        NSError *e = nil;
        if (![_driver restorePhysicalAndDestroyDisplaysError:&e]) ok = NO;
        self.physicalDisabled = NO;
        self.virtualCreated = NO;
    }
    if (self.sleepHeld) {
        [_driver releaseSleepAssertion];
        self.sleepHeld = NO;
    }
    return ok;
}

#pragma mark - FR-07 会话内换屏

// start 与 applySpecs 共用：返回 w*10000+h 的摘要表；非法返回 nil 并填 error。
- (NSArray<NSNumber *> *)summaryForSpecs:(NSArray<NSDictionary *> *)specs
                                   error:(NSError **)error {
    if (specs.count == 0) {
        if (error) *error = M1SessErr(M1SessionErrorBadSpecs,
            M1HostSessionPhaseName(_phase), @"display 规格为空");
        return nil;
    }
    NSMutableArray *summary = [NSMutableArray array];
    for (NSDictionary *spec in specs) {
        NSNumber *w = spec[@"width"], *h = spec[@"height"];
        if (!w || !h || w.unsignedIntegerValue < 2 || h.unsignedIntegerValue < 2) {
            if (error) *error = M1SessErr(M1SessionErrorBadSpecs,
                M1HostSessionPhaseName(_phase), @"非法 display 规格");
            return nil;
        }
        [summary addObject:@(w.unsignedIntegerValue * 10000 + h.unsignedIntegerValue)];
    }
    return summary;
}

- (BOOL)applySpecs:(NSArray<NSDictionary *> *)specs
             error:(NSError * _Nullable * _Nullable)error {
    if (error) *error = nil;
    if (_phase != M1HostSessionStreaming) {
        if (error) *error = M1SessErr(M1SessionErrorStepFailed,
            M1HostSessionPhaseName(_phase), @"只有 STREAMING 态可以换屏");
        return NO;
    }
    NSError *specErr = nil;
    NSArray<NSNumber *> *summary = [self summaryForSpecs:specs error:&specErr];
    if (!summary) {
        if (error) *error = specErr;
        return NO;
    }

    NSArray<NSDictionary *> *oldSpecs = self.currentSpecs ?: @[];
    NSArray<NSNumber *> *oldSummary = self.specsSummary ?: @[];
    NSError *stepErr = nil;
    if (![_driver replaceVirtualDisplays:specs error:&stepErr]) {
        // 驱动契约：失败时旧屏未动；这里只换错误语义，不碰 phase。
        if (error) *error = [NSError errorWithDomain:M1SessionErrorDomain
            code:M1SessionErrorStepFailed
            userInfo:@{ NSLocalizedDescriptionKey: stepErr.localizedDescription ?: @"换屏失败",
                        @"phase": M1HostSessionPhaseName(_phase),
                        @"code": @"CREATE_FAILED" }];
        return NO;
    }
    self.createdDisplayIDs = [_driver createdDisplayIDs];
    self.specsSummary = summary;
    self.currentSpecs = specs;

    // 新屏已顶上但隔离不成立（外部屏冒出来）：换回旧规格，保持会话可用。
    if (self.extraKeepDisplayIDs.count == 0 && ![_driver verifyIsolationError:&stepErr]) {
        NSError *rollbackErr = nil;
        if (oldSpecs.count > 0 && [_driver replaceVirtualDisplays:oldSpecs error:&rollbackErr]) {
            self.createdDisplayIDs = [_driver createdDisplayIDs];
            self.specsSummary = oldSummary;
            self.currentSpecs = oldSpecs;
            if (error) *error = [NSError errorWithDomain:M1SessionErrorDomain
                code:M1SessionErrorStepFailed
                userInfo:@{ NSLocalizedDescriptionKey: @"换屏后隔离校验失败，已回滚旧屏",
                            @"phase": M1HostSessionPhaseName(_phase),
                            @"code": @"VISIBILITY_FAILED" }];
        } else if (error) {
            *error = [NSError errorWithDomain:M1SessionErrorDomain
                code:M1SessionErrorStepFailed
                userInfo:@{ NSLocalizedDescriptionKey: @"换屏后隔离校验失败且回滚失败",
                            @"phase": M1HostSessionPhaseName(_phase),
                            @"code": @"VISIBILITY_FAILED" }];
        }
        return NO;
    }
    return YES;
}

@end
