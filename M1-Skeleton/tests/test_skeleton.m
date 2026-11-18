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
#import "M1FrameSender.h"
#import "M1DatagramSink.h"

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
            OK(sink.datagrams[0].length == 16 + 100, "small-datagram-bytes");
        }
        OK(tx.stats.framesSent == 1 && tx.stats.fragmentsSent == 1, "small-stats");
        OK(tx.stats.bytesSent == 116 && tx.stats.payloadBytesSent == 100, "small-stats-bytes");
    }

    // --- 关键帧 + 参数集标志（由 M1EncodedFrame 翻译成 P1FrameFlags）---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        M1EncodedFrame *f = [[M1EncodedFrame alloc] init];
        f.avccPayload = MakePayload(200, 1);
        f.isKeyframe = YES;
        f.carriesParamSets = YES;
        NSError *err = nil;
        OK([tx sendFrame:f displayID:7 error:&err], "keyframe-send-ok");
        if (sink.datagrams.count == 1) {
            P1FrameHeader h = {0};
            P1UnpackFrameHeader(sink.datagrams[0], &h, NULL);
            OK((h.flags & P1FrameFlagKeyframe) != 0, "keyframe-flag");
            OK((h.flags & P1FrameFlagHasParamSets) != 0, "paramsets-flag");
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

    // --- 超过 255 片 → 分片失败，不消耗 seq ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        NSData *huge = [NSMutableData dataWithLength:(1150 * 256)];
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
            NSData *full = [rx acceptHeader:h payload:body error:NULL];
            if (full) [recovered addObject:full];
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

    // --- 缺口检测：丢掉中间一帧后接收端应请求关键帧 ---
    {
        M1MemoryDatagramSink *sink = [[M1MemoryDatagramSink alloc] init];
        M1FrameSender *tx = [[M1FrameSender alloc] initWithSink:sink];
        for (int i = 0; i < 3; i++) {
            [tx sendPayload:MakePayload(64, (uint8_t)i) displayID:1 flags:0 error:NULL];
        }
        P1FrameReassembler *rx = [[P1FrameReassembler alloc] init];
        NSArray<NSNumber *> *keep = @[@0, @2];   // 故意跳过 seq=1
        for (NSNumber *idx in keep) {
            NSData *dgram = sink.datagrams[idx.unsignedIntegerValue];
            P1FrameHeader h = {0};
            P1UnpackFrameHeader(dgram, &h, NULL);
            NSData *body = [dgram subdataWithRange:NSMakeRange(P1FrameHeaderSize, h.payloadLen)];
            [rx acceptHeader:h payload:body error:NULL];
        }
        OK(rx.needsKeyframe, "gap-detected-needs-keyframe");
    }
}

int main(void) {
    @autoreleasepool {
        TestPairing();
        TestTakeover();
        TestSession();
        TestDriverLogic();
        TestInputLogic();
        TestFrameSender();
        printf("\n=== %d passed, %d failed ===\n", gPass, gFail);
        printf("%s\n", gFail == 0 ? "ALL PASS" : "FAILURES");
        return gFail == 0 ? 0 : 1;
    }
}
