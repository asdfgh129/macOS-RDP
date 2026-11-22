//
//  M1-Skeleton 单测：配对/TOFU、现场接管手势、会话生命周期状态序列。
//  纯 Foundation，不依赖 WindowServer / AppKit / 网络。
//

#import <Foundation/Foundation.h>
#import "M1Pairing.h"
#import "M1Takeover.h"
#import "M1SessionCoordinator.h"
#import "M1DriverLogic.h"
#import "M1InputLogic.h"
#import "M1InputInjector.h"
#import "M1FrameSender.h"
#import "M1DatagramSink.h"
#import "M1MessageSink.h"
#import "M1ControlChannel.h"
#import "M1ControlSession.h"
#import "M1WindowLayout.h"
#import "P1InputCodec.h"
#import <math.h>

static int gPass = 0, gFail = 0;
static void OK(BOOL cond, const char *name) {
    if (cond) { gPass++; printf("[PASS] %s\n", name); }
    else { gFail++; printf("[FAIL] %s\n", name); }
}

static NSString *FP(NSString *seed) {
    // 造一个 64 hex 指纹：seed 重复拼到 64 位。
    NSMutableString *s = [NSMutableString string];
    while (s.length < 64) [s appendString:seed];
    return [s substringToIndex:64];
}

#pragma mark - 配对

static void TestPairing(void) {
    printf("=== pairing ===\n");
    OK(M1GeneratePairingCode().length == 6, "code-len-6");
    OK(M1IsValidPairingCode(@"012345"), "code-valid");
    OK(!M1IsValidPairingCode(@"01234"), "code-short");
    OK(!M1IsValidPairingCode(@"01234a"), "code-nondigit");
    OK(M1NormalizeFingerprint(@"AA:bb:CC") == nil, "fp-short-rejected");
    // 正确长度的指纹规范化
    NSString *raw = FP(@"ab");
    NSString *colon = [[raw componentsSeparatedByString:@""] componentsJoinedByString:@":"];
    OK([M1NormalizeFingerprint(colon) isEqualToString:raw], "fp-colon-normalize");
    OK(M1NormalizeFingerprint(@"zz") == nil, "fp-invalid-nil");

    M1InMemoryPairingStore *store = [M1InMemoryPairingStore new];
    M1PairingState *p = [[M1PairingState alloc] initWithStore:store];
    OK(!p.isPaired, "init-unpaired");
    NSString *code = [p issueCodeAtTime:1000];
    OK(code.length == 6, "issue-code");

    NSError *err = nil;
    NSString *bound = [p confirmCode:code fingerprint:raw atTime:1001 error:&err];
    OK([bound isEqualToString:raw] && p.isPaired, "confirm-paired");
    OK([store.fingerprint isEqualToString:raw], "persisted");
    OK([p verifyFingerprint:colon error:&err], "verify-ok");

    // 指纹变更被拒
    OK(![p verifyFingerprint:FP(@"cd") error:&err] &&
       err.code == M1PairingErrorFingerprintChanged, "fp-change-rejected");
    // 重新配对指纹不一致被拒
    NSString *again = [p issueCodeAtTime:1100];
    OK(![p confirmCode:again fingerprint:FP(@"cd") atTime:1101 error:&err], "repair-fp-mismatch");

    // 过期
    M1PairingState *p2 = [M1PairingState new];
    NSString *c2 = [p2 issueCodeAtTime:1000];
    OK(![p2 confirmCode:c2 fingerprint:raw atTime:1000 + 301 error:&err] &&
       err.code == M1PairingErrorExpired, "code-expired");

    // 试错锁定
    M1PairingState *p3 = [M1PairingState new];
    [p3 issueCodeAtTime:1000];
    for (int i = 0; i < 5; i++) [p3 confirmCode:@"000000" fingerprint:raw atTime:1000 + i error:NULL];
    OK(p3.isLocked, "locked-after-5");
    OK(![p3 confirmCode:@"000000" fingerprint:raw atTime:1000 + 6 error:&err] &&
       err.code == M1PairingErrorTooManyAttempts, "locked-rejects");
    // 锁定过期后重新签发（清锁），再进行正常配对验证
    NSString *c3 = [p3 issueCodeAtTime:2000];
    OK(!p3.isLocked, "reissue-clears-lock");
    OK([p3 confirmCode:c3 fingerprint:raw atTime:2001 error:&err] && p3.isPaired,
       "pair-after-lock-expired");

    [p unpair];
    OK(!p.isPaired && store.fingerprint == nil, "unpair");
}

#pragma mark - 现场接管

static void TestTakeover(void) {
    printf("=== takeover ===\n");
    M1TakeoverDetector *d = [M1TakeoverDetector new];
    OK([d handleSignal:M1TakeoverSignalShiftDown atTime:0] == M1TakeoverVerdictNone, "shift-down");
    OK([d tickAtTime:2.9] == M1TakeoverVerdictNone, "shift-not-yet");
    OK([d tickAtTime:3.0] == M1TakeoverVerdictGestureStarted, "shift-3s-fires");
    OK(d.pendingDisconnect, "pending-set");
    OK([d handleSignal:M1TakeoverSignalShiftUp atTime:3.1] == M1TakeoverVerdictNone &&
       d.pendingDisconnect, "shiftup-not-cancel");
    OK([d tickAtTime:12.9] == M1TakeoverVerdictNone, "grace-not-yet");
    OK([d tickAtTime:13.0] == M1TakeoverVerdictForceDisconnect, "grace-expires");

    // 延后
    M1TakeoverDetector *d2 = [M1TakeoverDetector new];
    [d2 handleSignal:M1TakeoverSignalShiftDown atTime:0];
    [d2 tickAtTime:3.0];
    OK([d2 requestDeferAtTime:5] == M1TakeoverVerdictDeferAccepted, "defer-1");
    OK([d2 requestDeferAtTime:5] == M1TakeoverVerdictDeferAccepted, "defer-2");
    OK(d2.deferCount == 2, "defer-count");
    // 累计封顶
    for (int i = 0; i < 10; i++) [d2 requestDeferAtTime:5];
    OK([d2 requestDeferAtTime:5] == M1TakeoverVerdictDeferRejected, "defer-cap");

    // fail-safe 立即
    M1TakeoverDetector *d3 = [M1TakeoverDetector new];
    [d3 handleSignal:M1TakeoverSignalShiftDown atTime:0];
    OK([d3 handleSignal:M1TakeoverSignalHotplug atTime:1] == M1TakeoverVerdictForceDisconnect,
       "hotplug-immediate");
    OK([d3 handleSignal:M1TakeoverSignalScreenLock atTime:2] == M1TakeoverVerdictForceDisconnect,
       "lock-immediate");
    [d3 reset];
    OK(!d3.shiftHeld && !d3.pendingDisconnect, "reset");
}

#pragma mark - Mock driver + 会话序列

@interface M1MockDriver : NSObject <M1SessionDriver>
@property (nonatomic, strong) NSMutableArray<NSString *> *calls;
@property (nonatomic, assign) BOOL failAtDisable;
@end

@implementation M1MockDriver
- (instancetype)init { self = [super init]; if (self) _calls = [NSMutableArray array]; return self; }
- (BOOL)acquireSleepAssertionError:(NSError **)e { [_calls addObject:@"sleep+"]; return YES; }
- (void)releaseSleepAssertion { [_calls addObject:@"sleep-"]; }
- (BOOL)createVirtualDisplays:(NSArray<NSDictionary *> *)s error:(NSError **)e {
    [_calls addObject:@"createVD"]; return YES;
}
- (NSArray<NSNumber *> *)createdDisplayIDs { return @[@1001]; }
- (BOOL)snapshotAndDisablePhysicalExcept:(NSArray<NSNumber *> *)k error:(NSError **)e {
    [_calls addObject:@"disablePhys"]; return !_failAtDisable;
}
- (BOOL)verifyIsolationError:(NSError **)e { [_calls addObject:@"verifyISO"]; return YES; }
- (BOOL)injectUnlockCredential:(NSString *)c error:(NSError **)e {
    [_calls addObject:@"inject"]; return YES;
}
- (BOOL)restorePhysicalAndDestroyDisplaysError:(NSError **)e {
    [_calls addObject:@"restore"]; return YES;
}
- (BOOL)lockScreenError:(NSError **)e { [_calls addObject:@"lock"]; return YES; }
@end

static void TestSession(void) {
    printf("=== session ===\n");
    M1MockDriver *drv = [M1MockDriver new];
    M1SessionCoordinator *c = [[M1SessionCoordinator alloc] initWithDriver:drv];
    NSArray *specs = @[@{@"width":@1920, @"height":@1080}];
    NSError *err = nil;
    OK([c startWithSpecs:specs needsLogin:NO credential:nil error:&err], "start-ok");
    OK(c.phase == M1HostSessionStreaming, "phase-streaming");
    // 验证步骤顺序：防睡眠 → 建屏 → 禁物理 → 隔离校验（登录关闭时无 inject）
    NSArray *want = @[@"sleep+", @"createVD", @"disablePhys", @"verifyISO"];
    OK([drv.calls isEqualToArray:want], "start-sequence");

    [drv.calls removeAllObjects];
    OK([c endSessionError:&err], "end-ok");
    OK(c.phase == M1HostSessionLocked, "phase-locked");
    want = @[@"restore", @"sleep-", @"lock"];
    OK([drv.calls isEqualToArray:want], "end-sequence-restore-before-lock");

    // 需要登录但无凭据 → 失败
    M1SessionCoordinator *c2 = [[M1SessionCoordinator alloc] initWithDriver:[M1MockDriver new]];
    OK(![c2 startWithSpecs:specs needsLogin:YES credential:nil error:&err], "login-needs-cred");
    OK(err.code == M1SessionErrorNeedCredential, "need-cred-code");

    // 带登录：inject 出现在 disablePhys 之后
    M1MockDriver *drv3 = [M1MockDriver new];
    M1SessionCoordinator *c3 = [[M1SessionCoordinator alloc] initWithDriver:drv3];
    OK([c3 startWithSpecs:specs needsLogin:YES credential:@"pw" error:&err], "login-start-ok");
    NSUInteger di = [drv3.calls indexOfObject:@"disablePhys"];
    NSUInteger ii = [drv3.calls indexOfObject:@"inject"];
    OK(di != NSNotFound && ii != NSNotFound && di < ii, "login-after-disable");

    // 禁屏失败 → 事务性回退 + Failed
    M1MockDriver *drv4 = [M1MockDriver new]; drv4.failAtDisable = YES;
    M1SessionCoordinator *c4 = [[M1SessionCoordinator alloc] initWithDriver:drv4];
    OK(![c4 startWithSpecs:specs needsLogin:NO credential:nil error:&err], "disable-fail");
    OK(c4.phase == M1HostSessionFailed, "phase-failed");
    OK([drv4.calls containsObject:@"restore"] && [drv4.calls containsObject:@"sleep-"],
       "failure-recovers");
}

#pragma mark - 驱动层纯逻辑

static void TestDriverLogic(void) {
    // 凭据序列：每个字符一条 unicode 事件 + 末尾 Return(keyCode=36)
    NSArray *seq = M1CredentialEventSequence(@"ab");
    OK(seq.count == 3, "cred-seq-count-ascii");
    OK([seq[0][@"unicode"] unsignedShortValue] == (UniChar)'a', "cred-seq-char-a");
    OK([seq[1][@"unicode"] unsignedShortValue] == (UniChar)'b', "cred-seq-char-b");
    OK([seq[2][@"keyCode"] unsignedShortValue] == 36 &&
       [seq[2][@"unicode"] unsignedShortValue] == 0, "cred-seq-return");

    // 中文（A-03）：UTF-16 code unit 逐字注入，不依赖键码表
    NSArray *cjk = M1CredentialEventSequence(@"中");
    OK(cjk.count == 2 && [cjk[0][@"unicode"] unsignedShortValue] == 0x4E2D,
       "cred-seq-cjk-unicode");

    // C-09 隔离判定：active ⊆ 虚拟屏 → nil
    OK(M1IsolationLeakedDisplays(@[@1, @2], @[@1, @2]) == nil, "isolation-clean");
    OK(M1IsolationLeakedDisplays(@[@1, @2], @[@1, @2, @3]) == nil, "isolation-subset");
    // 有物理屏泄漏 → 返回泄漏 ID
    NSArray *leaked = M1IsolationLeakedDisplays(@[@1, @2, @9], @[@1, @2]);
    OK(leaked.count == 1 && [leaked[0] unsignedIntValue] == 9, "isolation-leak");

    // 完整判定：空 active 是致命故障，不能被「子集判据」放行
    // （2026-11-18 黑屏：keepIDs 传空 → 连虚拟屏一起禁 → active=[] 却校验通过）
    OK(M1IsolationViolation(@[@1], @[@1]) == nil, "violation-clean");
    OK(M1IsolationViolation(@[], @[@1]) != nil, "violation-empty-active-rejected");
    OK([M1IsolationViolation(@[], @[@1]) containsString:@"no-active"], "violation-empty-reason");
    OK(M1IsolationViolation(@[@1, @9], @[@1]) != nil, "violation-leak-rejected");
    OK(M1IsolationViolation(@[@1, @9], @[@1, @9]) == nil, "violation-multiscreen-clean");
}

#pragma mark - 输入注入逻辑

static void TestInputLogic(void) {
    // flags 映射：CGEventFlags 位（shift=1<<17, ctrl=1<<18, opt=1<<19, cmd=1<<20, caps=1<<16）
    uint64_t all = M1EventFlagsFromDict(@{ @"shift":@1, @"ctrl":@1, @"opt":@1,
                                            @"cmd":@1, @"caps":@1 });
    OK(all == ((1ULL<<16)|(1ULL<<17)|(1ULL<<18)|(1ULL<<19)|(1ULL<<20)), "flags-all-bits");
    OK(M1EventFlagsFromDict(@{ @"shift":@1 }) == (1ULL<<17), "flags-shift-only");
    OK(M1EventFlagsFromDict(nil) == 0, "flags-nil-zero");

    // 归一化坐标 → 目标屏 Quartz 全局坐标（原点 x=100,y=200，尺寸 1920x1080）
    CGRect rect = CGRectMake(100, 200, 1920, 1080);
    CGPoint c = M1PointInDisplayRect(0.5, 0.5, rect);
    OK(c.x == 100 + 960 && c.y == 200 + 540, "point-center");
    CGPoint o = M1PointInDisplayRect(0, 0, rect);
    OK(o.x == 100 && o.y == 200, "point-origin");
    CGPoint clamped = M1PointInDisplayRect(2.0, -1.0, rect);
    OK(clamped.x == 100 + 1920 && clamped.y == 200, "point-clamp");

    // 注入计划：mouse 事件带全局坐标与 flags
    NSError *err = nil;
    NSDictionary *mouse = M1InjectionPlan(@{ @"kind":@"mouse", @"displayID":@42,
        @"x":@0.5, @"y":@0.5, @"button":@"left", @"action":@"down",
        @"flags":@{ @"shift":@1 } }, rect, &err);
    OK(mouse != nil, "plan-mouse-ok");
    OK([mouse[@"x"] doubleValue] == 1060 && [mouse[@"y"] doubleValue] == 740, "plan-mouse-coords");
    OK([mouse[@"flags"] unsignedLongLongValue] == (1ULL<<17), "plan-mouse-flags");
    OK([mouse[@"button"] isEqualToString:@"left"] && [mouse[@"action"] isEqualToString:@"down"],
       "plan-mouse-button-action");

    // 中文 key 事件计划保留 unicode
    NSDictionary *key = M1InjectionPlan(@{ @"kind":@"key", @"displayID":@42,
        @"keyCode":@0, @"unicode":@"中", @"flags":@{} }, rect, &err);
    OK(key && [key[@"unicode"] isEqualToString:@"中"], "plan-key-cjk");

    // flags 全量同步计划
    NSDictionary *flagEv = M1InjectionPlan(@{ @"kind":@"flags",
        @"flags":@{ @"cmd":@1 } }, rect, &err);
    OK(flagEv && [flagEv[@"flags"] unsignedLongLongValue] == (1ULL<<20), "plan-flags");

    // 非法 kind → nil + error
    OK(M1InjectionPlan(@{ @"kind":@"bogus" }, rect, &err) == nil && err != nil, "plan-bad-kind");

    // ---- 客户端上屏的 letterbox 与坐标反算（M1-B）----
    // 画面 1920x1080 放进 1000x1000 的视图：等比后 1000x562.5，上下各留 218.75 黑边。
    CGRect fit = M1AspectFitRect(CGSizeMake(1920, 1080), CGRectMake(0, 0, 1000, 1000));
    OK(fabs(fit.size.width - 1000) < 1e-9 && fabs(fit.size.height - 562.5) < 1e-9,
       "fit-size");
    OK(fabs(fit.origin.x) < 1e-9 && fabs(fit.origin.y - 218.75) < 1e-9, "fit-origin-centered");

    // 竖屏源放进横屏视图：高度受限
    CGRect fitTall = M1AspectFitRect(CGSizeMake(1080, 1920), CGRectMake(0, 0, 1000, 1000));
    OK(fabs(fitTall.size.height - 1000) < 1e-9 && fabs(fitTall.size.width - 562.5) < 1e-9,
       "fit-tall-height-bound");

    // 退化输入不得除零
    CGRect fitBad = M1AspectFitRect(CGSizeMake(0, 0), CGRectMake(0, 0, 1000, 1000));
    OK(fitBad.size.width == 1000 && fitBad.size.height == 1000, "fit-degenerate-passthrough");

    // 视图坐标 → 归一化：视图原点在左下，协议 y=0 在顶边，必须翻 y
    CGPoint centerPt = M1NormalizedPointFromViewPoint(
        CGPointMake(CGRectGetMidX(fit), CGRectGetMidY(fit)), fit);
    OK(fabs(centerPt.x - 0.5) < 1e-9 && fabs(centerPt.y - 0.5) < 1e-9, "norm-center");

    CGPoint topLeft = M1NormalizedPointFromViewPoint(
        CGPointMake(CGRectGetMinX(fit), CGRectGetMaxY(fit)), fit);
    OK(fabs(topLeft.x) < 1e-9 && fabs(topLeft.y) < 1e-9, "norm-top-left");

    CGPoint bottomRight = M1NormalizedPointFromViewPoint(
        CGPointMake(CGRectGetMaxX(fit), CGRectGetMinY(fit)), fit);
    OK(fabs(bottomRight.x - 1.0) < 1e-9 && fabs(bottomRight.y - 1.0) < 1e-9,
       "norm-bottom-right");

    // 落在黑边上：clamp 到边界（调用方本该先判 CGRectContainsPoint 丢掉）
    CGPoint inBar = M1NormalizedPointFromViewPoint(CGPointMake(500, 10), fit);
    OK(fabs(inBar.y - 1.0) < 1e-9, "norm-bar-clamped");

    // 上屏坐标 → 归一化 → 注入计划，必须回到同一个物理点（往返一致性）
    CGRect hostRect = CGRectMake(0, 0, 3440, 1440);
    CGPoint viewPt = CGPointMake(CGRectGetMinX(fit) + fit.size.width * 0.25,
                                 CGRectGetMinY(fit) + fit.size.height * 0.75);
    CGPoint norm = M1NormalizedPointFromViewPoint(viewPt, fit);
    CGPoint back = M1PointInDisplayRect(norm.x, norm.y, hostRect);
    // 视图 y=0.75（偏上）翻成协议 y=0.25（偏上），3440x1440 下就是 860,360
    OK(fabs(norm.y - 0.25) < 1e-9, "norm-roundtrip-flip");
    OK(fabs(back.x - 860) < 1e-6 && fabs(back.y - 360) < 1e-6, "norm-roundtrip");

    // 注入器 + 记录型 sink：确认「归一化事件 → 全局座标」这一跳真的走了 sink
    M1RecordingEventSink *rec = [[M1RecordingEventSink alloc] init];
    M1InputInjector *inj = [[M1InputInjector alloc] initWithSink:rec];
    inj.targetDisplayRect = hostRect;
    NSError *injErr = nil;
    OK([inj injectEvent:@{ @"kind":@"mouse", @"displayID":@1000, @"x":@0.5, @"y":@0.5,
                           @"button":@"left", @"action":@"move", @"flags":@{} } error:&injErr],
       "inject-mouse-ok");
    OK(rec.postCount == 1, "inject-recorded");
    NSDictionary *recPlan = rec.plans.firstObject;
    OK([recPlan[@"x"] doubleValue] == 1720 && [recPlan[@"y"] doubleValue] == 720,
       "inject-plan-center");
    OK([inj injectEvent:@{ @"kind":@"flags", @"flags":@{ @"shift":@1 } } error:&injErr],
       "inject-flags-ok");
    OK(rec.postCount == 2 && [rec.plans.lastObject[@"flags"] unsignedLongLongValue] == (1ULL<<17),
       "inject-flags-recorded");
    [rec reset];
    OK(rec.postCount == 0, "inject-record-reset");
}

#pragma mark - 帧管线：分片发送与重组一致性

// 造确定性载荷：第 i 字节 = (i * 31 + seed) & 0xFF，便于逐字节比对。
static NSData *MakePayload(NSUInteger len, uint8_t seed) {
    NSMutableData *d = [NSMutableData dataWithLength:len];
    uint8_t *p = d.mutableBytes;
    for (NSUInteger i = 0; i < len; i++) p[i] = (uint8_t)(i * 31 + seed);
    return d;
}

static void TestFrameSender(void) {
    printf("=== frame-sender ===\n");

    // --- 单片小帧 ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        NSData *payload = MakePayload(100, 7);
        NSError *err = nil;
        OK([tx sendPayload:payload displayID:101 flags:0 error:&err], "small-send-ok");
        OK(sink.datagrams.count == 1, "small-one-fragment");
        if (sink.datagrams.count == 1) {
            P1FrameHeader h = {0};
            OK(P1UnpackFrameHeader(sink.datagrams[0], &h, NULL), "small-header-unpack");
            OK(h.fragIdx == 0 && h.fragCount == 1, "small-frag-index-count");
            OK(h.payloadLen == 100, "small-payload-len");
            OK((h.flags & P1FrameFlagLastFragment) != 0, "small-last-fragment-set");
            OK(h.displayID == 101, "small-display-id");
            OK(h.frameSeq == 0, "small-seq-zero");
            // 帧头 v3 是 26B
            OK(sink.datagrams[0].length == P1FrameHeaderSize + 100, "small-datagram-bytes");
            OK(h.capturedAtUs == 0, "small-capture-ts-default");
        }
        OK(tx.stats.framesSent == 1 && tx.stats.fragmentsSent == 1, "small-stats");
        OK(tx.stats.bytesSent == P1FrameHeaderSize + 100 && tx.stats.payloadBytesSent == 100,
           "small-stats-bytes");
    }

    // --- 关键帧 + 参数集标志（由 M1EncodedFrame 翻译成 P1FrameFlags）---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        M1EncodedFrame *f = [[M1EncodedFrame alloc] init];
        f.avccPayload = MakePayload(200, 1);
        f.isKeyframe = YES;
        f.carriesParamSets = YES;
        f.capturedAtUs = 1763835600123456ULL;
        NSError *err = nil;
        OK([tx sendFrame:f displayID:7 error:&err], "keyframe-send-ok");
        if (sink.datagrams.count == 1) {
            P1FrameHeader h = {0};
            P1UnpackFrameHeader(sink.datagrams[0], &h, NULL);
            OK((h.flags & P1FrameFlagKeyframe) != 0, "keyframe-flag");
            OK((h.flags & P1FrameFlagHasParamSets) != 0, "paramsets-flag");
            OK(h.capturedAtUs == f.capturedAtUs, "keyframe-capture-ts");
            OK(!(h.flags & P1FrameFlagLastFragment) == NO, "keyframe-single-is-last");
        }
        OK(tx.stats.keyframesSent == 1, "keyframe-stat");
    }

    // --- 多片大帧：3000B → 1150 + 1150 + 700 ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        NSError *err = nil;
        OK([tx sendPayload:MakePayload(3000, 3) displayID:5 flags:0 error:&err], "big-send-ok");
        OK(sink.datagrams.count == 3, "big-three-fragments");
        if (sink.datagrams.count == 3) {
            P1FrameHeader h0 = {0}, h1 = {0}, h2 = {0};
            P1UnpackFrameHeader(sink.datagrams[0], &h0, NULL);
            P1UnpackFrameHeader(sink.datagrams[1], &h1, NULL);
            P1UnpackFrameHeader(sink.datagrams[2], &h2, NULL);
            OK(h0.fragIdx == 0 && h1.fragIdx == 1 && h2.fragIdx == 2, "big-frag-indexes");
            OK(h0.fragCount == 3 && h2.fragCount == 3, "big-frag-count");
            OK(h0.payloadLen == 1150 && h1.payloadLen == 1150 && h2.payloadLen == 700,
               "big-frag-lens");
            OK(!(h0.flags & P1FrameFlagLastFragment), "big-first-not-last");
            OK(!(h1.flags & P1FrameFlagLastFragment), "big-second-not-last");
            OK((h2.flags & P1FrameFlagLastFragment) != 0, "big-third-is-last");
        }
    }

    // --- frameSeq 单调递增 + startSeq 续号 ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink startSeq:100];
        OK(tx.nextFrameSeq == 100, "startseq-initial");
        for (int i = 0; i < 3; i++) {
            [tx sendPayload:MakePayload(10, (uint8_t)i) displayID:1 flags:0 error:NULL];
        }
        OK(tx.nextFrameSeq == 103, "startseq-advance");
        if (sink.datagrams.count == 3) {
            P1FrameHeader h = {0};
            P1UnpackFrameHeader(sink.datagrams[2], &h, NULL);
            OK(h.frameSeq == 102, "startseq-header-seq");
        }
    }

    // --- 空载荷拒绝，且不消耗 seq ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        NSError *err = nil;
        OK(![tx sendPayload:[NSData data] displayID:1 flags:0 error:&err], "empty-payload-rejected");
        OK(err != nil && err.code == M1PipelineErrorEmptyPayload, "empty-payload-error-code");
        OK(tx.nextFrameSeq == 0, "empty-payload-no-seq-consume");
        OK(sink.datagrams.count == 0, "empty-payload-no-datagram");
    }

    // --- 256 片在 v1 会被拒，v2 起必须能发（3440×1440 的关键帧就在这个量级）---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        NSData *big = [NSMutableData dataWithLength:(1150 * 256)];
        NSError *err = nil;
        OK([tx sendPayload:big displayID:1 flags:0 error:&err], "256-fragments-accepted");
        OK(sink.datagrams.count == 256 && err == nil, "256-fragments-emitted");
        OK(tx.nextFrameSeq == 1, "256-fragments-seq-consumed");
    }

    // --- 超过 65535 片 → 分片失败，不消耗 seq（v2 的硬上限）---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        NSData *huge = [NSMutableData dataWithLength:(1150 * 65536)];
        NSError *err = nil;
        OK(![tx sendPayload:huge displayID:1 flags:0 error:&err], "too-many-fragments-rejected");
        OK(err != nil && err.code == M1PipelineErrorFragmentationFailed, "too-many-frag-code");
        OK(tx.nextFrameSeq == 0, "too-many-frag-no-seq-consume");
    }

    // --- sink 中途失败：错误传播 + 统计 + seq 不推进 ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        sink.failAfterCount = 1;   // 第 2 片起失败
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        NSError *err = nil;
        BOOL ok = [tx sendPayload:MakePayload(3000, 9) displayID:1 flags:0 error:&err];
        OK(!ok, "sink-fail-propagates");
        OK(err != nil && err.code == M1PipelineErrorSinkFailed, "sink-fail-error-code");
        OK(tx.stats.sinkFailures == 1, "sink-fail-stat");
        OK(tx.nextFrameSeq == 0, "sink-fail-no-seq-advance");
        OK(tx.stats.framesSent == 0, "sink-fail-no-frame-counted");
        OK(sink.datagrams.count == 1, "sink-fail-partial-delivery");
    }

    // --- 端到端一致性：发送 → 重组必须逐字节还原 ---
    // 这是本组测试的核心：证明发送器产出的分片真的能被 P1FrameReassembler 解开，
    // 而不是只验证「字节数量看起来对」。
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        P1FrameReassembler *rx = [[P1FrameReassembler alloc] init];

        // 覆盖：单片 / 恰好整片 / 刚跨片 / 多片
        NSUInteger lens[] = {1, 1150, 1151, 3000, 2300, 700};
        NSMutableArray<NSData *> *originals = [NSMutableArray array];
        BOOL sentAll = YES;
        for (int i = 0; i < 6; i++) {
            NSData *p = MakePayload(lens[i], (uint8_t)(i * 11));
            [originals addObject:p];
            NSError *err = nil;
            P1FrameFlags fl = (i == 0) ? P1FrameFlagKeyframe : 0;
            if (![tx sendPayload:p displayID:9 flags:fl error:&err]) sentAll = NO;
        }
        OK(sentAll, "roundtrip-all-sent");

        NSMutableArray<NSData *> *recovered = [NSMutableArray array];
        BOOL unpackAll = YES;
        for (NSData *dgram in sink.datagrams) {
            P1FrameHeader h = {0};
            if (!P1UnpackFrameHeader(dgram, &h, NULL)) { unpackAll = NO; continue; }
            if (dgram.length < P1FrameHeaderSize + h.payloadLen) { unpackAll = NO; continue; }
            NSData *body = [dgram subdataWithRange:NSMakeRange(P1FrameHeaderSize, h.payloadLen)];
            for (P1ReassembledFrame *fr in [rx acceptHeader:h payload:body error:NULL]) {
                [recovered addObject:fr.payload];
            }
        }
        OK(unpackAll, "roundtrip-unpack-ok");
        OK(recovered.count == originals.count, "roundtrip-frame-count");
        BOOL allEqual = (recovered.count == originals.count);
        for (NSUInteger i = 0; allEqual && i < originals.count; i++) {
            allEqual = [recovered[i] isEqualToData:originals[i]];
        }
        OK(allEqual, "roundtrip-bytes-identical");
        OK(!rx.needsKeyframe, "roundtrip-no-gap");
        OK(rx.lastCompletedSeq == 5, "roundtrip-last-seq");
    }

    // --- 缺口检测：丢掉中间一帧，超过帧期限后接收端应请求关键帧 ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        for (int i = 0; i < 4; i++) {
            P1FrameFlags fl = (i == 0) ? P1FrameFlagKeyframe : 0;
            [tx sendPayload:MakePayload(64, (uint8_t)i) displayID:1 flags:fl error:NULL];
        }
        P1FrameReassembler *rx = [[P1FrameReassembler alloc] init];
        NSArray<NSNumber *> *keep = @[@0, @2, @3];   // 故意跳过 seq=1
        double t = 1000;
        for (NSNumber *idx in keep) {
            NSData *dgram = sink.datagrams[idx.unsignedIntegerValue];
            P1FrameHeader h = {0};
            P1UnpackFrameHeader(dgram, &h, NULL);
            NSData *body = [dgram subdataWithRange:NSMakeRange(P1FrameHeaderSize, h.payloadLen)];
            [rx acceptHeader:h payload:body nowMs:t error:NULL];
            t += 10;
        }
        OK(!rx.needsKeyframe, "gap-held-within-deadline");
        // 再喂一个更晚的分片，触发期限判丢（此时距首次观察到缺口已 >120ms）
        NSData *dgram = sink.datagrams.lastObject;
        P1FrameHeader h = {0};
        P1UnpackFrameHeader(dgram, &h, NULL);
        NSData *body = [dgram subdataWithRange:NSMakeRange(P1FrameHeaderSize, h.payloadLen)];
        [rx acceptHeader:h payload:body nowMs:t + 200 error:NULL];
        OK(rx.needsKeyframe, "gap-detected-needs-keyframe");
        OK(rx.droppedFrames >= 1, "gap-counts-lost-frame");
    }
}

#pragma mark - 定向补片（frame-nack 修复）

static NSArray<P1ReassembledFrame *> *RepairFeed(P1FrameReassembler *rx, NSData *dgram, double t) {
    P1FrameHeader h = {0};
    if (!P1UnpackFrameHeader(dgram, &h, NULL)) return @[];
    NSData *body = [dgram subdataWithRange:NSMakeRange(P1FrameHeaderSize, h.payloadLen)];
    return [rx acceptHeader:h payload:body nowMs:t error:NULL];
}

static void TestFrameRepair(void) {
    printf("=== frame repair (frame-nack) ===\n");

    // --- 发送端：只重发请求的下标；未知帧/越界/空集合不误发 ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        NSError *err = nil;
        OK([tx sendPayload:MakePayload(3000, 5) displayID:1 flags:0 error:&err], "nack-tx-send");
        OK(sink.datagrams.count == 3, "nack-tx-three-frags");
        [sink.datagrams removeAllObjects];

        OK([tx resendFragmentsForFrameSeq:0 indices:[NSIndexSet indexSetWithIndex:1] error:&err] == 1,
           "nack-resend-one");
        OK(sink.datagrams.count == 1, "nack-resend-one-dgram");
        if (sink.datagrams.count == 1) {
            P1FrameHeader h = {0};
            P1UnpackFrameHeader(sink.datagrams[0], &h, NULL);
            OK(h.fragIdx == 1 && h.frameSeq == 0, "nack-resend-correct-index");
        }
        OK(tx.fragmentsResent == 1, "nack-resend-stat");

        NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
        [set addIndex:0];
        [set addIndex:2];
        [set addIndex:99];
        [sink.datagrams removeAllObjects];
        OK([tx resendFragmentsForFrameSeq:0 indices:set error:&err] == 2,
           "nack-resend-skips-out-of-range");
        OK(sink.datagrams.count == 2, "nack-resend-two-dgrams");

        OK([tx resendFragmentsForFrameSeq:42 indices:[NSIndexSet indexSetWithIndex:0] error:&err] == 0,
           "nack-resend-unknown-frame");
        OK([tx resendFragmentsForFrameSeq:0 indices:[NSIndexSet indexSet] error:&err] == 0,
           "nack-resend-empty-indices");
    }

    // --- 发送端：按帧数淘汰，旧帧不再重发 ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        tx.fragmentCacheFrames = 2;
        for (int i = 0; i < 3; i++) {
            [tx sendPayload:MakePayload(3000, (uint8_t)i) displayID:1 flags:0 error:NULL];
        }
        NSError *err = nil;
        OK([tx resendFragmentsForFrameSeq:0 indices:[NSIndexSet indexSetWithIndex:0] error:&err] == 0,
           "nack-cache-evicts-oldest");
        OK([tx resendFragmentsForFrameSeq:1 indices:[NSIndexSet indexSetWithIndex:0] error:&err] == 1,
           "nack-cache-keeps-newest-1");
        OK([tx resendFragmentsForFrameSeq:2 indices:[NSIndexSet indexSetWithIndex:0] error:&err] == 1,
           "nack-cache-keeps-newest-2");
    }

    // --- 发送端：缓存关闭（0）一律不重发 ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        tx.fragmentCacheFrames = 0;
        [tx sendPayload:MakePayload(3000, 1) displayID:1 flags:0 error:NULL];
        NSError *err = nil;
        OK([tx resendFragmentsForFrameSeq:0 indices:[NSIndexSet indexSetWithIndex:0] error:&err] == 0,
           "nack-cache-disabled");
    }

    // --- 接收端：缺 1 片 → 60ms 停滞发 NACK；补片到齐后完成并量 RTT ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        [tx sendPayload:MakePayload(6000, 3) displayID:1 flags:P1FrameFlagKeyframe error:NULL];
        OK(sink.datagrams.count == 6, "nack-rx-six-frags");

        P1FrameReassembler *rx = [[P1FrameReassembler alloc] init];
        __block NSUInteger nacks = 0;
        __block uint32_t lastSeq = UINT32_MAX;
        __block uint16_t lastCount = 0;
        __block NSIndexSet *lastMissing = nil;
        __block BOOL lastKey = NO;
        rx.onMissingFragments = ^(uint32_t seq, uint16_t fc, NSIndexSet *mi, BOOL key) {
            nacks++;
            lastSeq = seq;
            lastCount = fc;
            lastMissing = mi;
            lastKey = key;
        };

        double t = 1000;
        for (NSNumber *idx in @[@0, @1, @3, @4, @5]) {
            (void)RepairFeed(rx, sink.datagrams[idx.unsignedIntegerValue], t);
            t += 10;
        }
        OK(nacks == 0, "nack-rx-none-before-request-ms");
        (void)RepairFeed(rx, sink.datagrams[0], 1110);   // 重复片只为推进时钟
        OK(nacks == 1, "nack-rx-emitted-once");
        OK(lastSeq == 0 && lastCount == 6, "nack-rx-frame-and-count");
        OK([lastMissing isEqualToIndexSet:[NSIndexSet indexSetWithIndex:2]],
           "nack-rx-missing-indices");
        OK(lastKey, "nack-rx-keyframe-flag");
        (void)RepairFeed(rx, sink.datagrams[0], 1140);
        OK(nacks == 1, "nack-rx-rate-limited-until-retry");

        NSArray<P1ReassembledFrame *> *done = RepairFeed(rx, sink.datagrams[2], 1150);
        OK(done.count == 1, "nack-rx-frame-completes-after-repair");
        OK(rx.lastRepairRttMs == 40.0, "nack-rx-rtt");
        OK(rx.repairRttSamples == 1 && rx.repairRequests == 1, "nack-rx-stats");
        OK(!rx.needsKeyframe, "nack-rx-no-keyframe-needed");
    }

    // --- 接收端：补片没来 → 120ms 重问，最多 3 次；超过补片窗口判丢并请求关键帧 ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        [tx sendPayload:MakePayload(6000, 4) displayID:1 flags:P1FrameFlagKeyframe error:NULL];

        P1FrameReassembler *rx = [[P1FrameReassembler alloc] init];
        __block NSUInteger nacks = 0;
        rx.onMissingFragments = ^(uint32_t seq, uint16_t fc, NSIndexSet *mi, BOOL key) { nacks++; };

        double t = 2000;
        for (NSNumber *idx in @[@0, @1, @2, @4, @5]) {
            (void)RepairFeed(rx, sink.datagrams[idx.unsignedIntegerValue], t);
            t += 10;
        }
        (void)RepairFeed(rx, sink.datagrams[0], 2120);   // NACK #1
        OK(nacks == 1, "nack-retry-first");
        (void)RepairFeed(rx, sink.datagrams[0], 2150);   // 未到 120ms，不重问
        OK(nacks == 1, "nack-retry-not-too-early");
        (void)RepairFeed(rx, sink.datagrams[0], 2250);   // NACK #2
        OK(nacks == 2, "nack-retry-second");
        (void)RepairFeed(rx, sink.datagrams[0], 2380);   // NACK #3（达到上限）
        OK(nacks == 3, "nack-retry-third");
        (void)RepairFeed(rx, sink.datagrams[0], 2640);   // 补片窗口耗尽 → 判丢
        OK(nacks == 3, "nack-retry-capped");
        OK(rx.needsKeyframe, "nack-retry-gives-up-needs-keyframe");
        OK(rx.droppedFrames == 1, "nack-retry-counts-dropped-frame");
        OK(rx.repairRttSamples == 0 && rx.lastRepairRttMs == 0.0, "nack-retry-no-rtt-sample");
    }

    // --- 接收端：缺失片数超过 maxRepairFragments → 不发 NACK，直接走关键帧 ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        [tx sendPayload:MakePayload(6000, 7) displayID:1 flags:P1FrameFlagKeyframe error:NULL];

        P1FrameReassembler *rx = [[P1FrameReassembler alloc] init];
        rx.maxRepairFragments = 4;
        __block NSUInteger nacks = 0;
        rx.onMissingFragments = ^(uint32_t seq, uint16_t fc, NSIndexSet *mi, BOOL key) { nacks++; };

        (void)RepairFeed(rx, sink.datagrams[0], 3000);
        (void)RepairFeed(rx, sink.datagrams[0], 3100);
        (void)RepairFeed(rx, sink.datagrams[0], 3200);
        OK(nacks == 0, "nack-too-many-missing-no-request");
        OK(rx.needsKeyframe, "nack-too-many-missing-keyframe");
        OK(rx.droppedFrames == 1, "nack-too-many-missing-dropped");
    }

    // --- 发送端：整帧补片请求重发全部分片 ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        NSError *err = nil;
        OK([tx sendPayload:MakePayload(3000, 5) displayID:1 flags:0 error:&err], "whole-tx-send");
        OK(sink.datagrams.count == 3, "whole-tx-three-frags");
        [sink.datagrams removeAllObjects];

        uint64_t resentBefore = tx.fragmentsResent;
        OK([tx resendAllFragmentsForFrameSeq:0 error:&err] == 3, "whole-resend-all");
        OK(sink.datagrams.count == 3, "whole-resend-all-dgrams");
        P1FrameHeader h = {0};
        P1UnpackFrameHeader(sink.datagrams[2], &h, NULL);
        OK(h.frameSeq == 0 && h.fragIdx == 2, "whole-resend-all-order");
        OK(tx.fragmentsResent == resentBefore + 3, "whole-resend-all-stat");
        OK([tx resendAllFragmentsForFrameSeq:42 error:&err] == 0, "whole-resend-unknown-frame");

        tx.fragmentCacheFrames = 0;
        OK([tx resendAllFragmentsForFrameSeq:0 error:&err] == 0, "whole-resend-cache-disabled");
    }

    // --- 接收端：nextSeq 整帧零分片 → 60ms 后请求整帧重发，重试有上限 ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        [tx sendPayload:MakePayload(3000, 1) displayID:1 flags:P1FrameFlagKeyframe error:NULL];
        NSArray<NSData *> *f0 = [sink.datagrams copy];                          // seq0
        [tx sendPayload:MakePayload(3000, 2) displayID:1 flags:0 error:NULL];   // seq1 全丢
        [tx sendPayload:MakePayload(3000, 3) displayID:1 flags:0 error:NULL];   // seq2
        NSArray<NSData *> *f2 = [sink.datagrams subarrayWithRange:
                                 NSMakeRange(f0.count * 2, 3)];

        P1FrameReassembler *rx = [[P1FrameReassembler alloc] init];
        __block NSUInteger nacks = 0;
        __block uint32_t lastSeq = UINT32_MAX;
        __block uint16_t lastCount = 9;
        __block NSUInteger lastMissing = 9;
        __block BOOL lastKey = YES;
        rx.onMissingFragments = ^(uint32_t seq, uint16_t fc, NSIndexSet *mi, BOOL key) {
            nacks++;
            lastSeq = seq;
            lastCount = fc;
            lastMissing = mi.count;
            lastKey = key;
        };

        double t = 1000;
        for (NSData *d in f0) { (void)RepairFeed(rx, d, t); t += 10; }  // 交付 seq0
        for (NSData *d in f2) { (void)RepairFeed(rx, d, t); t += 10; }  // seq2 就绪，缺口从 1030 起
        OK(nacks == 0, "gap-repair-none-before-request-ms");
        (void)RepairFeed(rx, f0[0], 1090);
        OK(nacks == 1, "gap-repair-emitted-once");
        OK(lastSeq == 1 && lastCount == 0 && lastMissing == 0 && !lastKey,
           "gap-repair-whole-frame-args");
        (void)RepairFeed(rx, f0[0], 1120);
        OK(nacks == 1, "gap-repair-retry-not-too-early");
        (void)RepairFeed(rx, f0[0], 1210);
        OK(nacks == 2, "gap-repair-retry-second");
        (void)RepairFeed(rx, f0[0], 1340);
        OK(nacks == 3, "gap-repair-retry-third");
        (void)RepairFeed(rx, f0[0], 1620);
        OK(nacks == 3, "gap-repair-retry-capped");
        OK(rx.needsKeyframe, "gap-repair-gives-up-needs-keyframe");
    }

    // --- 接收端：整帧重发到达 → 续上顺序，不再等关键帧 ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        [tx sendPayload:MakePayload(3000, 1) displayID:1 flags:P1FrameFlagKeyframe error:NULL];
        NSArray<NSData *> *f0 = [sink.datagrams copy];
        [tx sendPayload:MakePayload(3000, 2) displayID:1 flags:0 error:NULL];
        NSArray<NSData *> *f1 = [sink.datagrams subarrayWithRange:
                                 NSMakeRange(f0.count, 3)];
        [tx sendPayload:MakePayload(3000, 3) displayID:1 flags:0 error:NULL];
        NSArray<NSData *> *f2 = [sink.datagrams subarrayWithRange:
                                 NSMakeRange(f0.count * 2, 3)];

        P1FrameReassembler *rx = [[P1FrameReassembler alloc] init];
        __block NSUInteger nacks = 0;
        __block uint32_t nackSeq = UINT32_MAX;
        rx.onMissingFragments = ^(uint32_t seq, uint16_t fc, NSIndexSet *mi, BOOL key) {
            nacks++;
            nackSeq = seq;
        };

        double t = 2000;
        for (NSData *d in f0) { (void)RepairFeed(rx, d, t); t += 10; }
        for (NSData *d in f2) { (void)RepairFeed(rx, d, t); t += 10; }
        (void)RepairFeed(rx, f0[0], 2090);
        OK(nacks == 1 && nackSeq == 1, "gap-repair-request-before-resend");

        NSArray<P1ReassembledFrame *> *out = @[];
        t = 2100;
        for (NSData *d in f1) { out = RepairFeed(rx, d, t); t += 10; }
        OK(out.count == 2, "gap-repair-delivers-whole-chain");
        if (out.count == 2) {
            OK(out[0].frameSeq == 1 && out[1].frameSeq == 2, "gap-repair-resumes-in-order");
        }
        OK(!rx.needsKeyframe, "gap-repair-no-keyframe-after-repair");
        OK(nacks == 1, "gap-repair-single-request-used");
    }

    // --- 接收端：窗口外持续来包（追不上）→ 转关键帧重建，不能静默丢掉整段流 ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        [tx sendPayload:MakePayload(3000, 1) displayID:1 flags:P1FrameFlagKeyframe error:NULL];
        NSArray<NSData *> *f0 = [sink.datagrams copy];
        [sink.datagrams removeAllObjects];
        [tx sendPayload:MakePayload(3000, 2) displayID:1 flags:0 error:NULL];
        [tx sendPayload:MakePayload(3000, 3) displayID:1 flags:0 error:NULL];
        [tx sendPayload:MakePayload(3000, 4) displayID:1 flags:0 error:NULL];
        NSArray<NSData *> *far = [sink.datagrams subarrayWithRange:
                                 NSMakeRange(6, 3)];    // 只取 seq3：窗口=1 时永远超窗

        P1FrameReassembler *rx = [[P1FrameReassembler alloc] init];
        rx.maxFramesInFlight = 1;
        double t = 1000;
        for (NSData *d in f0) { (void)RepairFeed(rx, d, t); t += 10; }
        for (int i = 0; i < 21; i++) {                    // 63 片：不到阈值
            for (NSData *d in far) { (void)RepairFeed(rx, d, t); }
            t += 20;
        }
        OK(!rx.needsKeyframe && rx.droppedFrames == 0, "ahead-below-threshold-survives");
        for (NSData *d in far) { (void)RepairFeed(rx, d, t); }
        OK(rx.needsKeyframe, "ahead-catchup-needs-keyframe");
        OK(rx.droppedFrames >= 1, "ahead-catchup-drops");
        OK([rx.discardBreakdown containsString:@"ahead=64"], "ahead-catchup-breakdown");
    }

}

#pragma mark - 控制通道（分帧 / 粘包 / 拆包）

@interface M1TestCollector : NSObject <M1ControlChannelDelegate>
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *messages;
@property (nonatomic, strong) NSMutableArray<NSError *> *errors;
@end

@implementation M1TestCollector
- (instancetype)init {
    if ((self = [super init])) {
        _messages = [NSMutableArray array];
        _errors = [NSMutableArray array];
    }
    return self;
}
- (void)controlChannel:(M1ControlChannel *)channel didReceiveMessage:(NSDictionary *)message {
    [self.messages addObject:message];
}
- (void)controlChannel:(M1ControlChannel *)channel didFailWithError:(NSError *)error {
    [self.errors addObject:error];
}
@end

static void TestControlChannel(void) {
    printf("=== control channel framing ===\n");

    M1MemoryMessageSink *sink = [M1MemoryMessageSink new];
    M1ControlChannel *tx = [[M1ControlChannel alloc] initWithSink:sink];
    NSError *err = nil;
    OK([tx sendMessage:@{@"type": @"hello", @"role": @"client"} error:&err], "ctl-send-hello");
    OK([tx sendMessage:@{@"type": @"heartbeat", @"ts": @1} error:&err], "ctl-send-hb");
    OK(sink.messages.count == 2, "ctl-two-frames-written");
    OK(tx.nextSeq == 3, "ctl-seq-monotonic");

    // 一次投喂两条完整帧（粘包）
    M1ControlChannel *rx = [[M1ControlChannel alloc] initWithSink:[M1MemoryMessageSink new]];
    M1TestCollector *col = [M1TestCollector new];
    rx.delegate = col;
    [rx feedBytes:[sink concatenated]];
    OK(col.messages.count == 2, "ctl-coalesced-two-messages");
    OK([col.messages[0][@"type"] isEqualToString:@"hello"], "ctl-order-preserved");
    OK([col.messages[0][@"seq"] intValue] == 1 && [col.messages[1][@"seq"] intValue] == 2,
       "ctl-seq-preserved");

    // 逐字节拆包：3 字节时还凑不出长度前缀，必须缓冲而不是报错
    M1ControlChannel *rx2 = [[M1ControlChannel alloc] initWithSink:[M1MemoryMessageSink new]];
    M1TestCollector *col2 = [M1TestCollector new];
    rx2.delegate = col2;
    NSData *frame = sink.messages[0];
    [rx2 feedBytes:[frame subdataWithRange:NSMakeRange(0, 3)]];
    OK(col2.messages.count == 0 && rx2.bufferedBytes == 3, "ctl-partial-prefix-buffered");
    [rx2 feedBytes:[frame subdataWithRange:NSMakeRange(3, 5)]];
    OK(col2.messages.count == 0, "ctl-partial-body-waits");
    [rx2 feedBytes:[frame subdataWithRange:NSMakeRange(8, frame.length - 8)]];
    OK(col2.messages.count == 1, "ctl-partial-completed");
    OK(col2.errors.count == 0, "ctl-partial-no-error");

    // 长度前缀不可信 ⇒ 报协议错，而不是继续攒内存
    M1ControlChannel *rx3 = [[M1ControlChannel alloc] initWithSink:[M1MemoryMessageSink new]];
    M1TestCollector *col3 = [M1TestCollector new];
    rx3.delegate = col3;
    uint8_t bad[8] = {0xFF, 0xFF, 0xFF, 0xFF, 'x', 'x', 'x', 'x'};
    [rx3 feedBytes:[NSData dataWithBytes:bad length:sizeof(bad)]];
    OK(rx3.protocolErrors == 1 && col3.errors.count == 1, "ctl-bad-prefix-reported");
}

#pragma mark - 控制会话（双端状态序列）

@interface M1TestSessionWatcher : NSObject <M1ControlSessionDelegate>
@property (nonatomic, strong, nullable) NSError *error;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *inputs;
@property (nonatomic) NSUInteger keyframeRequests;
@end

@implementation M1TestSessionWatcher
- (instancetype)init {
    if ((self = [super init])) _inputs = [NSMutableArray array];
    return self;
}
- (void)controlSessionDidRequestKeyframe:(M1ControlSession *)session {
    _keyframeRequests++;
}
- (void)controlSession:(M1ControlSession *)session didFailWithError:(NSError *)error {
    if (!self.error) self.error = error;
}
- (void)controlSession:(M1ControlSession *)session didReceiveInputEvent:(NSDictionary *)event {
    [_inputs addObject:event];
}
@end

// 把两端的控制通道用队列接起来：发送只入队，由 Pump 逐个送达，避免回调重入。
static void Pump(NSMutableArray<NSArray *> *pending) {
    NSUInteger guard = 0;
    while (pending.count > 0 && guard++ < 500) {
        NSArray *item = pending.firstObject;
        [pending removeObjectAtIndex:0];
        M1ControlChannel *dest = item[0];
        [dest feedBytes:item[1]];
    }
}

static NSError *ErrOf(id v) {
    return [v isKindOfClass:[NSError class]] ? (NSError *)v : nil;
}

// 建一对真实会话（帧通道不参与，只跑控制流），返回观测结果。
// 显式给两端的本地指纹，才能构造「指纹不符」这类负向场景。
static NSDictionary *RunPairFull(NSString *clientCode, NSString *hostCode,
                                 NSString *clientLocal, NSString *clientExpect,
                                 NSString *hostLocal, NSString *hostExpect) {
    M1MemoryMessageSink *c2h = [M1MemoryMessageSink new];
    M1MemoryMessageSink *h2c = [M1MemoryMessageSink new];
    M1ControlChannel *cCh = [[M1ControlChannel alloc] initWithSink:c2h];
    M1ControlChannel *hCh = [[M1ControlChannel alloc] initWithSink:h2c];
    NSMutableArray<NSArray *> *pending = [NSMutableArray array];
    c2h.onSend = ^BOOL(NSData *m, NSError **e) { [pending addObject:@[ hCh, m ]]; return YES; };
    h2c.onSend = ^BOOL(NSData *m, NSError **e) { [pending addObject:@[ cCh, m ]]; return YES; };

    M1ControlSessionConfig *cc = [M1ControlSessionConfig new];
    cc.role = M1ControlRoleClient;
    cc.localFingerprint = clientLocal;
    cc.expectedPeerFingerprint = clientExpect;
    cc.pairingCode = clientCode;
    cc.heartbeatIntervalMs = 0;
    cc.specs = @[ @{ @"w": @1920, @"h": @1080, @"hidpi": @NO, @"refresh": @60 } ];

    M1ControlSessionConfig *hc = [M1ControlSessionConfig new];
    hc.role = M1ControlRoleHost;
    hc.localFingerprint = hostLocal;
    hc.expectedPeerFingerprint = hostExpect;
    hc.pairingCode = hostCode;
    hc.heartbeatIntervalMs = 0;

    M1ControlSession *client = [[M1ControlSession alloc] initWithChannel:cCh config:cc];
    M1ControlSession *host = [[M1ControlSession alloc] initWithChannel:hCh config:hc];
    M1TestSessionWatcher *cw = [M1TestSessionWatcher new];
    M1TestSessionWatcher *hw = [M1TestSessionWatcher new];
    client.delegate = cw;
    host.delegate = hw;

    [client begin];
    [host begin];
    Pump(pending);

    return @{ @"client": client, @"host": host,
              @"clientWatcher": cw, @"hostWatcher": hw,
              @"clientChannel": cCh, @"hostChannel": hCh,
              @"pending": pending,
              @"clientError": cw.error ?: (id)[NSNull null],
              @"hostError": hw.error ?: (id)[NSNull null] };
}

// 常规场景：本地指纹取「对端期望值」，两端自然对得上。
static NSDictionary *RunPair(NSString *clientCode, NSString *hostCode,
                             NSString *clientExpect, NSString *hostExpect) {
    return RunPairFull(clientCode, hostCode,
                       hostExpect ? hostExpect : FP(@"cd"), clientExpect,
                       clientExpect ? clientExpect : FP(@"ab"), hostExpect);
}

static void TestControlSessionOverPipe(void) {
    printf("=== control session (TOFU) ===\n");
    NSDictionary *r = RunPair(nil, nil, FP(@"ab"), FP(@"cd"));
    M1ControlSession *client = r[@"client"];
    M1ControlSession *host = r[@"host"];

    OK(client.reachedStreaming, "ctl-client-streaming");
    OK(host.reachedStreaming, "ctl-host-streaming");
    OK([r[@"clientError"] isKindOfClass:[NSNull class]], "ctl-client-no-error");
    OK([r[@"hostError"] isKindOfClass:[NSNull class]], "ctl-host-no-error");

    NSArray *expect = @[@"DISCOVERED", @"TLS_CONNECTED", @"PAIRED",
                        @"NEGOTIATED", @"DISPLAYS_READY", @"STREAMING"];
    OK([client.stateLog isEqualToArray:expect], "ctl-client-state-sequence");
    OK([host.stateLog isEqualToArray:expect], "ctl-host-state-sequence");
    OK([client.stateLog isEqualToArray:host.stateLog], "ctl-state-logs-identical");
    OK(host.sessionID.length > 0 && [host.sessionID isEqualToString:client.sessionID],
       "ctl-session-id-agree");
    OK(client.remoteDisplays.count == 1, "ctl-displays-count");
    OK([client.remoteDisplays.firstObject[@"synthetic"] boolValue], "ctl-display-synthetic-marked");
    OK([client.stateMachine canAcceptInput], "ctl-input-allowed-in-streaming");
}

static void TestControlSessionPairingCode(void) {
    printf("=== control session (pairing code) ===\n");
    NSDictionary *ok = RunPair(@"123456", @"123456", nil, nil);
    OK([(M1ControlSession *)ok[@"client"] reachedStreaming] &&
       [(M1ControlSession *)ok[@"host"] reachedStreaming],
       "ctl-pair-code-success");

    NSDictionary *bad = RunPair(@"000000", @"123456", nil, nil);
    NSError *hostErr = ErrOf(bad[@"hostError"]);
    OK(hostErr != nil && hostErr.code == M1ControlSessionErrorPairingCode,
       "ctl-pair-code-mismatch-rejected");
    OK(![(M1ControlSession *)bad[@"host"] reachedStreaming], "ctl-pair-code-mismatch-not-streaming");

    // hello 指纹与钉死值不符必须拒绝（Client 期望 zz，Host 实际通告 ab）
    NSDictionary *fpBad = RunPairFull(nil, nil, FP(@"cd"), FP(@"zz"), FP(@"ab"), FP(@"cd"));
    NSError *fpErr = ErrOf(fpBad[@"clientError"]);
    OK(fpErr != nil && fpErr.code == M1ControlSessionErrorFingerprint,
       "ctl-hello-fingerprint-mismatch");
    OK(![(M1ControlSession *)fpBad[@"client"] reachedStreaming],
       "ctl-fingerprint-mismatch-not-streaming");
}

#pragma mark - 控制会话（输入通路）

// 输入是对外行为的核心：坐标一旦偏了，画面再清晰也没法用。
// 这里钉住四件事：事件原样到达、畸形事件被拒不掀会话、非 STREAMING 静默丢弃、
// Host 不能反向发 input。
static void TestControlSessionInput(void) {
    printf("=== control session (input) ===\n");
    NSDictionary *r = RunPair(nil, nil, FP(@"ab"), FP(@"cd"));
    M1ControlSession *client = r[@"client"];
    M1ControlSession *host = r[@"host"];
    M1TestSessionWatcher *hw = r[@"hostWatcher"];
    NSMutableArray<NSArray *> *pending = r[@"pending"];
    OK(client.reachedStreaming && host.reachedStreaming, "in-both-streaming");

    NSError *err = nil;
    OK([client sendInputEvent:P1MakeMouseEvent(1000, 0.25, 0.75, @"left", @"move", nil)
                        error:&err], "in-send-mouse");
    Pump(pending);
    OK(hw.inputs.count == 1, "in-host-received");
    OK([hw.inputs.firstObject[@"kind"] isEqualToString:@"mouse"], "in-kind-mouse");
    OK(fabs([hw.inputs.firstObject[@"x"] doubleValue] - 0.25) < 1e-9 &&
       fabs([hw.inputs.firstObject[@"y"] doubleValue] - 0.75) < 1e-9,
       "in-coords-preserved");
    OK([hw.inputs.firstObject[@"displayID"] intValue] == 1000, "in-displayid-preserved");
    OK([hw.inputs.firstObject[@"button"] isEqualToString:@"left"], "in-button-preserved");

    OK([client sendInputEvent:P1MakeKeyEvent(1000, 0, @"A", @{ @"cmd": @1 }) error:&err],
       "in-send-key");
    OK([client sendInputEvent:P1MakeScrollEvent(1000, 0, -12, nil) error:&err], "in-send-scroll");
    OK([client sendInputEvent:P1MakeFlagsEvent(@{ @"cmd": @0 }) error:&err], "in-send-flags");
    Pump(pending);
    OK(hw.inputs.count == 4, "in-multi-received");
    OK([hw.inputs[1][@"unicode"] isEqualToString:@"A"], "in-key-unicode");
    OK([hw.inputs[1][@"flags"][@"cmd"] boolValue], "in-key-flags-preserved");
    OK(fabs([hw.inputs[2][@"dy"] doubleValue] + 12.0) < 1e-9, "in-scroll-preserved");
    OK([hw.inputs[3][@"kind"] isEqualToString:@"flags"], "in-flags-kind");
    OK([client inputEventsSent] == 4, "in-sent-count");

    // 畸形事件（坐标越界）：拒绝、计数、不过线、不掀会话
    NSUInteger sentBefore = client.inputEventsSent;
    OK(![client sendInputEvent:@{ @"kind": @"mouse", @"x": @2.0, @"y": @0.5 } error:&err],
       "in-reject-bad-coord");
    OK(client.inputEventsRejected == 1 && client.inputEventsSent == sentBefore,
       "in-reject-counted");
    Pump(pending);
    OK(hw.inputs.count == 4, "in-reject-not-delivered");
    OK(client.lastError == nil && host.reachedStreaming, "in-reject-keeps-session");

    // displayID 写在消息层（PROTOCOL §3.1 文档写法）时 Host 也要能取到——
    // 否则「文档照抄的客户端」推到真机就是 displayID=0、输入落不到目标屏。
    M1ControlChannel *cCh = r[@"clientChannel"];
    OK([cCh sendMessage:@{ @"type": @"input", @"displayID": @777,
                           @"event": @{ @"kind": @"flags", @"flags": @{} } } error:&err],
       "in-message-level-displayid-send");
    Pump(pending);
    OK([hw.inputs.lastObject[@"displayID"] intValue] == 777, "in-message-level-displayid");

    // Host 反向发 input 不合法
    OK(![host sendInputEvent:P1MakeFlagsEvent(nil) error:&err], "in-host-cannot-send");

    // 未进入 STREAMING：丢弃而不是报错（输入是高频路径，状态抖动不该中断会话）
    M1MemoryMessageSink *deadSink = [M1MemoryMessageSink new];
    M1ControlChannel *deadCh = [[M1ControlChannel alloc] initWithSink:deadSink];
    M1ControlSessionConfig *cfg = [M1ControlSessionConfig new];
    cfg.role = M1ControlRoleClient;
    cfg.heartbeatIntervalMs = 0;
    M1ControlSession *lone = [[M1ControlSession alloc] initWithChannel:deadCh config:cfg];
    NSError *preErr = nil;
    OK(![lone sendInputEvent:P1MakeMouseEvent(1, 0.5, 0.5, @"left", @"move", nil)
                        error:&preErr], "in-pre-streaming-dropped");
    OK(lone.inputEventsDropped == 1, "in-pre-streaming-drop-counted");
    OK(preErr.code == M1ControlSessionErrorInvalidState, "in-pre-streaming-error-code");
}

#pragma mark - 控制会话（关键帧请求）

// 帧通道丢帧后最关键的一条线：Client 的请求必须真的过线，Host 必须被回调；
// 同时 300ms 限流要生效（连环丢包不该把控制通道刷满）。
static void TestControlSessionKeyframe(void) {
    printf("=== control session (keyframe request) ===\n");
    NSDictionary *r = RunPair(nil, nil, FP(@"ab"), FP(@"cd"));
    M1ControlSession *client = r[@"client"];
    M1ControlSession *host = r[@"host"];
    M1TestSessionWatcher *hw = r[@"hostWatcher"];
    NSMutableArray<NSArray *> *pending = r[@"pending"];
    OK(client.reachedStreaming && host.reachedStreaming, "kf-both-streaming");

    NSError *err = nil;
    OK([client requestKeyframeWithError:&err], "kf-send-first");
    Pump(pending);
    OK(hw.keyframeRequests == 1, "kf-host-callback");
    OK(host.keyframeRequestsReceived == 1, "kf-host-count");
    OK(client.keyframeRequestsSent == 1, "kf-client-sent-count");

    // 300ms 内的第二次必须被限流，且不再上线
    err = nil;
    OK(![client requestKeyframeWithError:&err] &&
       err.code == M1ControlSessionErrorRateLimited, "kf-rate-limited");
    Pump(pending);
    OK(hw.keyframeRequests == 1, "kf-rate-limit-not-delivered");
    OK(client.keyframeRequestsSent == 1, "kf-rate-limit-not-counted");

    usleep(320 * 1000);
    OK([client requestKeyframeWithError:&err], "kf-send-after-window");
    Pump(pending);
    OK(hw.keyframeRequests == 2, "kf-second-delivered");

    // Host 不能发、非 STREAMING 不能发
    OK(![host requestKeyframeWithError:&err] &&
       err.code == M1ControlSessionErrorProtocol, "kf-host-cannot-send");

    M1MemoryMessageSink *deadSink = [M1MemoryMessageSink new];
    M1ControlChannel *deadCh = [[M1ControlChannel alloc] initWithSink:deadSink];
    M1ControlSessionConfig *cfg = [M1ControlSessionConfig new];
    cfg.role = M1ControlRoleClient;
    cfg.heartbeatIntervalMs = 0;
    M1ControlSession *lone = [[M1ControlSession alloc] initWithChannel:deadCh config:cfg];
    err = nil;
    OK(![lone requestKeyframeWithError:&err] &&
       err.code == M1ControlSessionErrorInvalidState, "kf-pre-streaming-rejected");
}

#pragma mark - 控制会话（时钟同步）

static void TestControlSessionTimeSync(void) {
    printf("=== control session (time sync) ===\n");
    NSDictionary *r = RunPair(nil, nil, FP(@"ab"), FP(@"cd"));
    M1ControlSession *client = r[@"client"];
    M1ControlSession *host = r[@"host"];
    NSMutableArray<NSArray *> *pending = r[@"pending"];
    OK(client.reachedStreaming && host.reachedStreaming, "ts-both-streaming");

    NSError *err = nil;
    OK(![host requestTimeSyncWithError:&err] &&
       err.code == M1ControlSessionErrorProtocol, "ts-host-cannot-send");
    OK(!client.hasClockOffset && client.timeSyncSamples == 0, "ts-no-sample-initially");

    err = nil;
    OK([client requestTimeSyncWithError:&err], "ts-send-probe");
    Pump(pending);
    OK(client.timeSyncSamples == 1, "ts-reply-counted");
    OK(client.hasClockOffset, "ts-offset-set");
    // 同机同进程时钟，offset 应接近 0；只验数量级，避免依赖 CI 机器负载。
    OK(llabs((long long)client.clockOffsetUs) < 500000, "ts-offset-small");
    OK(client.timeSyncRttMs >= 0 && client.timeSyncRttMs < 1000, "ts-rtt-sane");

    // 未进 STREAMING 的 Client 不能发
    M1MemoryMessageSink *deadSink = [M1MemoryMessageSink new];
    M1ControlChannel *deadCh = [[M1ControlChannel alloc] initWithSink:deadSink];
    M1ControlSessionConfig *cfg = [M1ControlSessionConfig new];
    cfg.role = M1ControlRoleClient;
    cfg.heartbeatIntervalMs = 0;
    M1ControlSession *lone = [[M1ControlSession alloc] initWithChannel:deadCh config:cfg];
    err = nil;
    OK(![lone requestTimeSyncWithError:&err] &&
       err.code == M1ControlSessionErrorInvalidState, "ts-pre-streaming-rejected");
}

#pragma mark - 窗口布局

@interface FakeWindowLayoutProvider : NSObject <M1WindowLayoutProvider>
@property (nonatomic, assign) BOOL accessibilityTrusted;
@property (nonatomic, strong) M1WindowLayoutSnapshot *current;
@property (nonatomic, strong) NSMutableArray<NSValue *> *moves;
@end

@implementation FakeWindowLayoutProvider

- (instancetype)init {
    self = [super init];
    if (self) _moves = [NSMutableArray array];
    return self;
}

- (M1WindowLayoutSnapshot *)captureLayoutExcludingPIDs:(NSSet<NSNumber *> *)pids {
    return self.current;
}

- (BOOL)moveWindow:(M1WindowInfo *)window
         fromFrame:(CGRect)currentFrame
           toFrame:(CGRect)targetFrame
             error:(NSError **)error {
    [self.moves addObject:M1RectValue(targetFrame)];
    return YES;
}

@end

static M1WindowInfo *Win(pid_t pid, uint32_t num, CGRect frame, uint32_t disp) {
    return [M1WindowInfo infoWithOwnerPID:pid windowNumber:num ownerName:@"App"
                                    title:@"W" frame:frame displayID:disp layer:0];
}

static void TestWindowLayout(void) {
    printf("=== window layout ===\n");
    CGRect d1 = CGRectMake(0, 0, 1920, 1080);
    CGRect d2 = CGRectMake(1920, 0, 1280, 720);
    NSDictionary *bounds = @{ @1: M1RectValue(d1),
                              @2: M1RectValue(d2) };

    M1WindowLayoutSnapshot *snap = [M1WindowLayoutSnapshot new];
    snap.displayBounds = @{ @1: M1RectValue(d1),
                            @3: M1RectValue(CGRectMake(-1280, -200, 1280, 720)) };
    snap.mainDisplayID = 1;
    snap.windows = @[ Win(100, 7, CGRectMake(100, 120, 800, 600), 1),
                      Win(101, 9, CGRectMake(-1000, -100, 640, 480), 3) ];

    M1WindowLayoutSnapshot *rt =
        [M1WindowLayoutSnapshot snapshotWithDictionary:[snap dictionaryRepresentation]];
    OK(rt && rt.windows.count == 2 && rt.mainDisplayID == 1, "layout-json-roundtrip");
    OK(rt && CGRectEqualToRect(rt.windows[1].frame, snap.windows[1].frame) &&
       rt.windows[1].displayID == 3, "layout-json-negative-frame");
    OK(rt && CGRectEqualToRect(M1RectGetValue(rt.displayBounds[@3]),
                               CGRectMake(-1280, -200, 1280, 720)),
       "layout-json-display-bounds");

    // 被禁屏（1）上的窗口被搬到了 2 → 需要搬回原位
    M1WindowInfo *moved = Win(100, 7, CGRectMake(2300, 40, 800, 600), 2);
    NSArray<M1WindowRestoreTask *> *tasks =
        [M1WindowLayoutPlanner planFromSnapshot:snap
                                        windows:@[moved]
                             disabledDisplayIDs:[NSSet setWithObject:@1]
                                  currentBounds:bounds];
    OK(tasks.count == 1 &&
       CGRectEqualToRect(tasks.firstObject.targetFrame, snap.windows[0].frame),
       "layout-plan-displaced");

    // 仍在原位 → 跳过
    M1WindowInfo *inPlace = Win(100, 7, CGRectMake(100, 120, 800, 600), 1);
    tasks = [M1WindowLayoutPlanner planFromSnapshot:snap
                                            windows:@[inPlace]
                                 disabledDisplayIDs:[NSSet setWithObject:@1]
                                      currentBounds:bounds];
    OK(tasks.count == 0, "layout-plan-inplace-skip");

    // 快照时在保留屏（2）上的窗口即使位置变了也不是本模块的责任
    M1WindowLayoutSnapshot *keptSnap = [M1WindowLayoutSnapshot new];
    keptSnap.displayBounds = snap.displayBounds;
    keptSnap.windows = @[ Win(102, 11, CGRectMake(2000, 100, 600, 400), 2) ];
    M1WindowInfo *keptNow = Win(102, 11, CGRectMake(100, 100, 600, 400), 1);
    tasks = [M1WindowLayoutPlanner planFromSnapshot:keptSnap
                                            windows:@[keptNow]
                                 disabledDisplayIDs:[NSSet setWithObject:@1]
                                      currentBounds:bounds];
    OK(tasks.count == 0, "layout-plan-kept-display-skip");

    // 窗口已关闭 → 跳过
    tasks = [M1WindowLayoutPlanner planFromSnapshot:snap
                                            windows:@[]
                                 disabledDisplayIDs:[NSSet setWithObject:@1]
                                      currentBounds:bounds];
    OK(tasks.count == 0, "layout-plan-vanished-skip");

    // 同 pid 不同 windowNumber 不能误匹配
    M1WindowInfo *otherWin = Win(100, 8, CGRectMake(2300, 40, 800, 600), 2);
    tasks = [M1WindowLayoutPlanner planFromSnapshot:snap
                                            windows:@[otherWin]
                                 disabledDisplayIDs:[NSSet setWithObject:@1]
                                      currentBounds:bounds];
    OK(tasks.count == 0, "layout-plan-window-number-match");

    // 原位在屏外（负坐标）→ 夹回至少 120pt 可见
    M1WindowLayoutSnapshot *offSnap = [M1WindowLayoutSnapshot new];
    offSnap.displayBounds = snap.displayBounds;
    offSnap.windows = @[ Win(103, 13, CGRectMake(-700, 100, 800, 600), 1) ];
    M1WindowInfo *offNow = Win(103, 13, CGRectMake(2300, 40, 800, 600), 2);
    tasks = [M1WindowLayoutPlanner planFromSnapshot:offSnap
                                            windows:@[offNow]
                                 disabledDisplayIDs:[NSSet setWithObject:@1]
                                      currentBounds:bounds];
    OK(tasks.count == 1 && fabs(tasks.firstObject.targetFrame.origin.x + 680) < 0.01 &&
       fabs(tasks.firstObject.targetFrame.origin.y - 100) < 0.01,
       "layout-plan-clamp-visible");

    // 恢复器：授权时执行搬窗
    FakeWindowLayoutProvider *fake = [FakeWindowLayoutProvider new];
    fake.accessibilityTrusted = YES;
    M1WindowLayoutSnapshot *nowSnap = [M1WindowLayoutSnapshot new];
    nowSnap.displayBounds = bounds;
    nowSnap.windows = @[ moved ];
    fake.current = nowSnap;
    M1WindowLayoutRestorer *restorer = [[M1WindowLayoutRestorer alloc] initWithProvider:fake];
    NSDictionary *summary = [restorer restoreSnapshot:snap
                                   disabledDisplayIDs:[NSSet setWithObject:@1]];
    OK([summary[@"planned"] unsignedIntegerValue] == 1 &&
       [summary[@"restored"] unsignedIntegerValue] == 1 && fake.moves.count == 1,
       "layout-restore-applies");
    OK(CGRectEqualToRect(M1RectGetValue(fake.moves.firstObject), snap.windows[0].frame),
       "layout-restore-target-frame");

    // 未授权：只计划不搬，不算失败
    FakeWindowLayoutProvider *noAX = [FakeWindowLayoutProvider new];
    noAX.accessibilityTrusted = NO;
    noAX.current = nowSnap;
    restorer = [[M1WindowLayoutRestorer alloc] initWithProvider:noAX];
    summary = [restorer restoreSnapshot:snap disabledDisplayIDs:[NSSet setWithObject:@1]];
    OK([summary[@"trusted"] boolValue] == NO &&
       [summary[@"skipped"] unsignedIntegerValue] == 1 && noAX.moves.count == 0,
       "layout-restore-untrusted-skip");
}

int main(void) {
    @autoreleasepool {
        TestPairing();
        TestTakeover();
        TestSession();
        TestDriverLogic();
        TestInputLogic();
        TestFrameSender();
        TestFrameRepair();
        TestControlChannel();
        TestControlSessionOverPipe();
        TestControlSessionPairingCode();
        TestControlSessionInput();
        TestControlSessionKeyframe();
        TestControlSessionTimeSync();
        TestWindowLayout();
        printf("\n=== %d passed, %d failed ===\n", gPass, gFail);
        printf("%s\n", gFail == 0 ? "ALL PASS" : "FAILURES");
        return gFail == 0 ? 0 : 1;
    }
}
