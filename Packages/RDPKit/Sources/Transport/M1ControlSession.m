//
//  M1ControlSession.m
//  M1-Skeleton
//

#import "M1ControlSession.h"
#import "M1WallClock.h"
#import "ProtocolCodec.h"
#import "P1InputCodec.h"
#include <stdatomic.h>

NSString * const M1ControlSessionErrorDomain = @"M1ControlSession";

static NSError *M1SessErr(M1ControlSessionErrorCode code, NSString *msg) {
    return [NSError errorWithDomain:M1ControlSessionErrorDomain code:code
                            userInfo:@{NSLocalizedDescriptionKey: msg ?: @""}];
}

static NSString *M1ArchName(void) {
#if defined(__x86_64__)
    return @"x86_64";
#elif defined(__arm64__)
    return @"arm64";
#else
    return @"unknown";
#endif
}

@implementation M1ControlSessionConfig

- (instancetype)init {
    if ((self = [super init])) {
        _hostName = @"macOS-RDP host";
        _specs = @[ @{ @"w": @1920, @"h": @1080, @"hidpi": @NO, @"refresh": @60 } ];
        _fps = 20;
        _bitrateKbps = 12000;
        _heartbeatIntervalMs = 1000;
    }
    return self;
}

@end

@interface M1ControlSession () {
    // 统计在两条线程上写（发送=调用方线程，接收=控制收包队列），读出可能在第三条线程。
    atomic_uint_fast64_t _inputSent;
    atomic_uint_fast64_t _inputReceived;
    atomic_uint_fast64_t _inputDropped;
    atomic_uint_fast64_t _inputRejected;
    atomic_uint_fast64_t _kfRequestsSent;
    atomic_uint_fast64_t _kfRequestsReceived;
    atomic_uint_fast64_t _nacksSent;
    atomic_uint_fast64_t _nacksReceived;
    atomic_bool _hasClockOffset;
    _Atomic int64_t _clockOffsetUs;
    _Atomic double _timeSyncRttMs;
    atomic_uint_fast64_t _timeSyncSamples;
    atomic_uint_fast64_t _sessionUpdatesSent;
    atomic_uint_fast64_t _sessionUpdatesApplied;
    _Atomic int64_t _nextUpdateID;
}
@property (nonatomic, strong) M1ControlChannel *channel;
@property (nonatomic, strong) M1ControlSessionConfig *config;
@property (nonatomic, readwrite) P1SessionStateMachine *stateMachine;
@property (nonatomic, readwrite) M1ControlRole role;
@property (nonatomic, strong) NSMutableArray<NSString *> *log;
@property (nonatomic, readwrite) BOOL reachedStreaming;
@property (nonatomic, readwrite, nullable) NSDictionary *remoteHello;
@property (nonatomic, readwrite, nullable) NSDictionary *remoteCapabilities;
@property (nonatomic, readwrite, nullable) NSString *sessionID;
@property (nonatomic, readwrite) NSArray<NSDictionary *> *remoteDisplays;
@property (nonatomic, readwrite, nullable) NSError *lastError;
@property (nonatomic, strong) dispatch_queue_t hbQueue;
@property (nonatomic, strong) dispatch_source_t hbTimer;
@property (nonatomic, assign) BOOL began;
@property (nonatomic, assign) BOOL closed;
// 注入速率限制（PROTOCOL §3.1：单会话 ≤1000 event/s，超限丢 move/scroll）
@property (nonatomic, strong) P1InputRateLimiter *inputLimiter;
// 每屏独立的请求限流时间戳（displayID → 毫秒）。多屏各自丢帧时互不挤占。
// 访问统一走 @synchronized(self)：请求来自多个屏的重组队列。
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *lastKfMsByDisplay;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *lastNackMsByDisplay;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *lastWholeNackMsByDisplay;
@end

@implementation M1ControlSession

- (instancetype)initWithChannel:(M1ControlChannel *)channel
                         config:(M1ControlSessionConfig *)config {
    if ((self = [super init])) {
        _channel = channel;
        _config = config;
        _role = config.role;
        _stateMachine = [P1SessionStateMachine new];
        _log = [NSMutableArray arrayWithObject:P1SessionStateName(P1SessionStateDiscovered)];
        _remoteDisplays = @[];
        _hbQueue = dispatch_queue_create("m1.control.heartbeat", DISPATCH_QUEUE_SERIAL);
        atomic_init(&_inputSent, 0);
        atomic_init(&_inputReceived, 0);
        atomic_init(&_inputDropped, 0);
        atomic_init(&_inputRejected, 0);
        atomic_init(&_kfRequestsSent, 0);
        atomic_init(&_kfRequestsReceived, 0);
        atomic_init(&_nacksSent, 0);
        atomic_init(&_nacksReceived, 0);
        _lastKfMsByDisplay = [NSMutableDictionary dictionary];
        _lastNackMsByDisplay = [NSMutableDictionary dictionary];
        _lastWholeNackMsByDisplay = [NSMutableDictionary dictionary];
        atomic_init(&_hasClockOffset, false);
        atomic_init(&_clockOffsetUs, 0);
        atomic_store(&_timeSyncRttMs, 0.0);
        atomic_init(&_timeSyncSamples, 0);
        atomic_init(&_sessionUpdatesSent, 0);
        atomic_init(&_sessionUpdatesApplied, 0);
        atomic_init(&_nextUpdateID, 0);
        _inputLimiter = [[P1InputRateLimiter alloc] initWithEventsPerSecond:P1InputMaxEventsPerSecond];
        channel.delegate = self;
    }
    return self;
}

- (NSArray<NSString *> *)stateLog { return [self.log copy]; }

#pragma mark - 起停

- (void)begin {
    if (self.began) return;
    self.began = YES;
    NSString *roleName = (self.role == M1ControlRoleClient) ? @"client" : @"host";
    NSMutableDictionary *payload = [@{
        @"type": @"hello",
        @"role": roleName,
        @"protoMin": @(P1ProtocolVersion),
        @"protoMax": @(P1ProtocolVersion),
        @"arch": M1ArchName(),
        @"osVersion": [NSProcessInfo processInfo].operatingSystemVersionString ?: @"",
        @"hostName": self.config.hostName ?: @"",
    } mutableCopy];
    if (self.config.localFingerprint.length > 0) {
        payload[@"certFingerprint"] = self.config.localFingerprint;
    }
    [self sendPayload:payload];
}

- (void)closeWithReason:(NSString *)reason {
    if (self.closed) return;
    self.closed = YES;
    [self stopHeartbeat];
    [self sendPayload:@{ @"type": @"bye", @"reason": reason ?: @"normal" }];
}

- (void)abortWithReason:(NSString *)reason {
    if (self.closed) return;
    self.closed = YES;
    [self stopHeartbeat];
    if (self.stateMachine.state == P1SessionStateClosed) return;
    // bye 在断链上大概率发不出去；失败由 failWith 记 first-cause，不影响本地关闭。
    [self sendPayload:@{ @"type": @"bye", @"reason": reason ?: @"local-abort" }];
    [self advance:@"bye"];
}

#pragma mark - 发送

- (BOOL)sendPayload:(NSDictionary *)payload {
    NSError *err = nil;
    if (![self.channel sendMessage:payload error:&err]) {
        [self failWith:M1SessErr(M1ControlSessionErrorSend,
            err.localizedDescription ?: @"控制消息发送失败")];
        return NO;
    }
    return YES;
}

#pragma mark - 状态推进

- (void)recordState {
    P1SessionState st = self.stateMachine.state;
    NSString *name = P1SessionStateName(st);
    if (![self.log.lastObject isEqualToString:name]) [self.log addObject:name];
    if ([self.delegate respondsToSelector:@selector(controlSession:didChangeState:)]) {
        [self.delegate controlSession:self didChangeState:st];
    }
    if (st == P1SessionStateStreaming && !self.reachedStreaming) {
        self.reachedStreaming = YES;
        [self startHeartbeat];
        if ([self.delegate respondsToSelector:@selector(controlSessionDidReachStreaming:)]) {
            [self.delegate controlSessionDidReachStreaming:self];
        }
    }
}

// 所有迁移都过状态机；被拒即视为协议违例（不是「忽略」——静默忽略会把错序掩盖成超时）。
- (BOOL)advance:(NSString *)event {
    NSError *err = nil;
    if (![self.stateMachine handleEvent:event error:&err]) {
        [self failWith:M1SessErr(M1ControlSessionErrorInvalidState,
            err.localizedDescription ?: event)];
        return NO;
    }
    [self recordState];
    return YES;
}

- (void)failWith:(NSError *)error {
    if (self.lastError) return;   // 只报第一因，后续是连锁反应
    self.lastError = error;
    [self stopHeartbeat];
    if ([self.delegate respondsToSelector:@selector(controlSession:didFailWithError:)]) {
        [self.delegate controlSession:self didFailWithError:error];
    }
}

#pragma mark - 接收分发

- (void)controlChannel:(M1ControlChannel *)channel didReceiveMessage:(NSDictionary *)message {
    NSString *type = message[@"type"];
    if (![type isKindOfClass:[NSString class]] || type.length == 0) {
        [self failWith:M1SessErr(M1ControlSessionErrorProtocol, @"控制消息缺 type")];
        return;
    }
    if ([type isEqualToString:@"hello"])            [self handleHello:message];
    else if ([type isEqualToString:@"pair-request"])  [self handlePairRequest:message];
    else if ([type isEqualToString:@"pair-confirm"])  [self handlePairConfirm:message];
    else if ([type isEqualToString:@"capabilities"])  [self handleCapabilities:message];
    else if ([type isEqualToString:@"session-start"]) [self handleSessionStart:message];
    else if ([type isEqualToString:@"session-ready"]) [self handleSessionReady:message];
    else if ([type isEqualToString:@"heartbeat"])     [self handleHeartbeat:message];
    else if ([type isEqualToString:@"input"])         [self handleInput:message];
    else if ([type isEqualToString:@"keyframe-request"]) [self handleKeyframeRequest:message];
    else if ([type isEqualToString:@"frame-nack"])       [self handleFrameNack:message];
    else if ([type isEqualToString:@"keyframe-sent"])    { /* Host 的确认，统计不依赖它 */ }
    else if ([type isEqualToString:@"time-sync"])        [self handleTimeSync:message];
    else if ([type isEqualToString:@"time-sync-reply"])  [self handleTimeSyncReply:message];
    else if ([type isEqualToString:@"session-update"])        [self handleSessionUpdate:message];
    else if ([type isEqualToString:@"session-update-result"]) [self handleSessionUpdateResult:message];
    else if ([type isEqualToString:@"bye"] || [type isEqualToString:@"session-error"]) {
        self.closed = YES;
        [self stopHeartbeat];
        [self advance:type];
    }
    // 其余未知类型静默忽略，避免对端新增消息把老版本判死。
}

- (void)controlChannel:(M1ControlChannel *)channel didFailWithError:(NSError *)error {
    [self failWith:M1SessErr(M1ControlSessionErrorProtocol,
        error.localizedDescription ?: @"控制通道错位")];
}

#pragma mark - 各消息处理

- (void)handleHello:(NSDictionary *)msg {
    if (self.remoteHello) return;   // 重复 hello 幂等

    NSNumber *protoMax = msg[@"protoMax"];
    if (![protoMax isKindOfClass:[NSNumber class]] || protoMax.integerValue < P1ProtocolVersion) {
        [self failWith:M1SessErr(M1ControlSessionErrorVersion,
            [NSString stringWithFormat:@"对端协议版本不兼容：protoMax=%@", protoMax ?: @"(缺失)"])];
        return;
    }
    NSString *peerFp = msg[@"certFingerprint"];
    NSString *expected = self.config.expectedPeerFingerprint;
    if (expected.length > 0) {
        if (![peerFp isKindOfClass:[NSString class]] || peerFp.length == 0) {
            [self failWith:M1SessErr(M1ControlSessionErrorFingerprint,
                @"hello 未上报指纹，无法与钉死值比对")];
            return;
        }
        if (![peerFp isEqualToString:expected]) {
            NSString *exp = expected.length > 16 ? [expected substringToIndex:16] : expected;
            NSString *act = peerFp.length > 16 ? [peerFp substringToIndex:16] : peerFp;
            [self failWith:M1SessErr(M1ControlSessionErrorFingerprint,
                [NSString stringWithFormat:@"hello 指纹不符：期望 %@… 实际 %@…", exp, act])];
            return;
        }
    }
    self.remoteHello = msg;
    if (![self advance:@"hello"]) return;

    if (self.role == M1ControlRoleClient) {
        if (self.config.pairingCode.length > 0) {
            // 首次配对：等 Host 回 pair-confirm
            [self sendPayload:@{ @"type": @"pair-request", @"code": self.config.pairingCode }];
        } else {
            // TOFU 已配对：TLS 层已按指纹钉死，本地记一次确认即可
            [self advance:@"pair-confirm"];
        }
    } else {
        if (self.config.pairingCode.length == 0) {
            // Host 侧同样走 TOFU：先认下配对，再发能力集
            if (![self advance:@"pair-confirm"]) return;
            [self hostSendCapabilities];
        }
        // 有配对码时等 client 的 pair-request
    }
}

- (void)handlePairRequest:(NSDictionary *)msg {
    if (self.role != M1ControlRoleHost) {
        [self failWith:M1SessErr(M1ControlSessionErrorProtocol, @"Client 不应收到 pair-request")];
        return;
    }
    NSString *code = msg[@"code"];
    if (self.config.pairingCode.length > 0 && ![code isEqualToString:self.config.pairingCode]) {
        [self failWith:M1SessErr(M1ControlSessionErrorPairingCode, @"配对码不匹配")];
        [self sendPayload:@{ @"type": @"session-error", @"code": @"pairing-code-mismatch",
                             @"detail": @"code mismatch", @"recoverable": @YES }];
        return;
    }
    if (![self advance:@"pair-request"]) return;
    [self sendPayload:@{ @"type": @"pair-confirm",
                         @"certFingerprint": self.config.localFingerprint ?: @"",
                         @"hostName": self.config.hostName ?: @"" }];
    [self hostSendCapabilities];
}

- (void)handlePairConfirm:(NSDictionary *)msg {
    if (self.role != M1ControlRoleClient) return;
    [self advance:@"pair-confirm"];
}

- (void)hostSendCapabilities {
    NSDictionary *caps = @{
        @"type": @"capabilities",
        @"maxDisplays": @8,
        @"maxResolution": @{ @"w": @5120, @"h": @2880 },
        @"hidpi": @YES,
        @"encoders": @[ @"h264-vt" ],
        @"safePoints": @[ @{ @"w": @4096, @"h": @2304, @"fps": @55 } ],
        @"fps": @(self.config.fps),
        @"bitrateKbps": @(self.config.bitrateKbps),
    };
    if (![self sendPayload:caps]) return;
    // Host 自己发完能力集即进入 NEGOTIATED（本端语义里程碑，不需要对端确认）
    [self advance:@"capabilities"];
}

- (void)handleCapabilities:(NSDictionary *)msg {
    if (self.role != M1ControlRoleClient) return;
    self.remoteCapabilities = msg;
    if (![self advance:@"capabilities"]) return;
    // 协商完成，按 Host 能力集里的 fps/码率收敛请求
    NSNumber *hostFps = msg[@"fps"];
    NSNumber *hostKbps = msg[@"bitrateKbps"];
    NSMutableDictionary *start = [@{
        @"type": @"session-start",
        @"specs": self.config.specs ?: @[],
        @"fps": hostFps ?: @(self.config.fps),
        @"bitrateKbps": hostKbps ?: @(self.config.bitrateKbps),
    } mutableCopy];
    if (![self sendPayload:start]) return;
    [self advance:@"session-start"];
}

- (void)handleSessionStart:(NSDictionary *)msg {
    if (self.role != M1ControlRoleHost) {
        [self failWith:M1SessErr(M1ControlSessionErrorProtocol, @"Client 不应收到 session-start")];
        return;
    }
    NSArray *specs = msg[@"specs"];
    if (![specs isKindOfClass:[NSArray class]] || specs.count == 0) {
        [self failWith:M1SessErr(M1ControlSessionErrorProtocol, @"session-start 缺 specs")];
        [self sendPayload:@{ @"type": @"session-error", @"code": @"bad-spec",
                             @"detail": @"missing specs", @"recoverable": @YES }];
        return;
    }
    // 屏数是系统边界：超出能力的请求直接拒绝，不交给建屏去撞资源上限。
    if (specs.count > 8) {
        [self failWith:M1SessErr(M1ControlSessionErrorProtocol,
            [NSString stringWithFormat:@"session-start 屏数 %lu 超过上限 8",
             (unsigned long)specs.count])];
        [self sendPayload:@{ @"type": @"session-error", @"code": @"SPEC_UNSUPPORTED",
                             @"detail": @"too many displays", @"recoverable": @NO }];
        return;
    }
    if (![self advance:@"session-start"]) return;

    // 真实显示由 Host 的委托准备（建虚拟屏 → 禁物理屏）；没接委托时退回
    // M1-A 的合成占位（带 synthetic:true，客户端据此知道不能当真实显示用）。
    NSArray<NSDictionary *> *displays = nil;
    if ([self.delegate respondsToSelector:
            @selector(controlSession:prepareDisplaysForSessionStart:error:)]) {
        NSError *prepErr = nil;
        displays = [self.delegate controlSession:self
                    prepareDisplaysForSessionStart:msg
                                          error:&prepErr];
        if (!displays) {
            NSError *err = prepErr ?: M1SessErr(M1ControlSessionErrorProtocol,
                @"Host 未能准备显示");
            [self sendPayload:@{ @"type": @"session-error", @"code": @"CREATE_FAILED",
                                 @"detail": err.localizedDescription ?: @"",
                                 @"recoverable": @YES }];
            [self failWith:err];
            return;
        }
    }
    if (displays.count == 0) {
        NSMutableArray *synthetic = [NSMutableArray array];
        for (NSUInteger i = 0; i < specs.count; i++) {
            NSDictionary *s = [specs[i] isKindOfClass:[NSDictionary class]] ? specs[i] : @{};
            [synthetic addObject:@{
                @"displayID": @(1000 + i),
                @"w": s[@"w"] ?: @0,
                @"h": s[@"h"] ?: @0,
                @"synthetic": @YES,
            }];
        }
        displays = synthetic;
    }
    NSString *sid = [[NSUUID UUID] UUIDString];
    self.sessionID = sid;
    if (![self sendPayload:@{ @"type": @"session-ready", @"sessionID": sid,
                              @"displays": displays }]) return;
    [self advance:@"session-ready"];
}

- (void)handleSessionReady:(NSDictionary *)msg {
    if (self.role != M1ControlRoleClient) return;
    NSString *sid = msg[@"sessionID"];
    if (![sid isKindOfClass:[NSString class]] || sid.length == 0) {
        [self failWith:M1SessErr(M1ControlSessionErrorProtocol, @"session-ready 缺 sessionID")];
        return;
    }
    self.sessionID = sid;
    NSArray *displays = msg[@"displays"];
    self.remoteDisplays = [displays isKindOfClass:[NSArray class]] ? displays : @[];
    [self advance:@"session-ready"];
}

- (void)handleHeartbeat:(NSDictionary *)msg {
    if (self.stateMachine.state == P1SessionStateStreaming) [self advance:@"heartbeat"];
}

#pragma mark - 输入（PROTOCOL §3.1）

- (NSUInteger)inputEventsSent     { return (NSUInteger)atomic_load(&_inputSent); }
- (NSUInteger)inputEventsReceived { return (NSUInteger)atomic_load(&_inputReceived); }
- (NSUInteger)inputEventsDropped  { return (NSUInteger)atomic_load(&_inputDropped); }
- (NSUInteger)inputEventsRejected { return (NSUInteger)atomic_load(&_inputRejected); }

- (BOOL)sendInputEvent:(NSDictionary *)event error:(NSError **)error {
    if (self.role != M1ControlRoleClient) {
        atomic_fetch_add(&_inputRejected, 1);
        if (error) *error = M1SessErr(M1ControlSessionErrorProtocol,
            @"Host 侧不应发送 input 事件");
        return NO;
    }
    // 只有 STREAMING 态才有目标屏可注入。这里刻意不 failWith：
    // 输入是高频路径，握手/重连窗口里丢几条不该把会话判死。
    if (self.closed || self.stateMachine.state != P1SessionStateStreaming) {
        atomic_fetch_add(&_inputDropped, 1);
        if (error) *error = M1SessErr(M1ControlSessionErrorInvalidState,
            @"会话未处于 STREAMING，输入事件未发送");
        return NO;
    }

    NSError *normErr = nil;
    NSDictionary *normalized = P1NormalizeInputEvent(event, &normErr);
    if (!normalized) {
        // 畸形事件属于客户端 bug，计数但不掀会话（否则一次坐标 NaN 就断线）。
        atomic_fetch_add(&_inputRejected, 1);
        if (error) *error = normErr;
        return NO;
    }
    // displayID 与 seq 由这里补齐：seq 由 M1ControlChannel 统一分配（与控制消息同一序列），
    // 保证对端按同一套单调序号做丢包观察。
    // displayID 两处都带：PROTOCOL §3.1 写在消息层，P1InputCodec 放在 event 内。
    // 对端两种读法都能取到值，省掉一次「文档与实现不一致」的踩坑（见 D-17）。
    NSMutableDictionary *payload = [@{ @"type": @"input", @"event": normalized } mutableCopy];
    if (normalized[@"displayID"]) payload[@"displayID"] = normalized[@"displayID"];
    if (![self sendPayload:payload]) return NO;
    atomic_fetch_add(&_inputSent, 1);
    return YES;
}

- (void)handleInput:(NSDictionary *)msg {
    if (self.role != M1ControlRoleHost) {
        [self failWith:M1SessErr(M1ControlSessionErrorProtocol, @"Client 不应收到 input")];
        return;
    }
    // 未进入 STREAMING 就没有目标屏，事件无处可去。不计 rejected（不是畸形），
    // 计 dropped 以便观察对端是不是抢跑。
    if (self.closed || self.stateMachine.state != P1SessionStateStreaming) {
        atomic_fetch_add(&_inputDropped, 1);
        return;
    }
    // displayID 兼容两种位置：event 内（P1InputCodec 实际实现）与消息层（PROTOCOL §3.1 文档）。
    NSDictionary *rawEvent = msg[@"event"];
    NSMutableDictionary *eventIn = [rawEvent isKindOfClass:[NSDictionary class]]
                                 ? [rawEvent mutableCopy] : nil;
    if (eventIn && !eventIn[@"displayID"] && msg[@"displayID"]) {
        eventIn[@"displayID"] = msg[@"displayID"];
    }
    NSError *normErr = nil;
    NSDictionary *event = P1NormalizeInputEvent(eventIn, &normErr);
    if (!event) {
        atomic_fetch_add(&_inputRejected, 1);
        return;
    }
    double now = [[NSDate date] timeIntervalSince1970];
    if (![self.inputLimiter shouldAcceptEvent:event atTime:now]) {
        atomic_fetch_add(&_inputDropped, 1);
        return;
    }
    atomic_fetch_add(&_inputReceived, 1);
    if ([self.delegate respondsToSelector:@selector(controlSession:didReceiveInputEvent:)]) {
        [self.delegate controlSession:self didReceiveInputEvent:event];
    }
}

#pragma mark - 关键帧请求

- (NSUInteger)keyframeRequestsSent { return (NSUInteger)atomic_load(&_kfRequestsSent); }
- (NSUInteger)keyframeRequestsReceived { return (NSUInteger)atomic_load(&_kfRequestsReceived); }

// 限流查表：返回 YES 表示窗口内还没有请求；不落时间戳（发送成功后才记）。
- (BOOL)rateLimitAllows:(NSDictionary<NSNumber *, NSNumber *> *)table
              displayID:(uint32_t)displayID
             intervalMs:(double)intervalMs
                  nowMs:(double)nowMs {
    @synchronized (self) {
        NSNumber *last = table[@(displayID)];
        return !(last && last.doubleValue > 0 && nowMs - last.doubleValue < intervalMs);
    }
}

- (void)markRateLimit:(NSMutableDictionary<NSNumber *, NSNumber *> *)table
            displayID:(uint32_t)displayID
                nowMs:(double)nowMs {
    @synchronized (self) { table[@(displayID)] = @(nowMs); }
}

// 请求载荷里的 displayID：显式值为 0 时回退到 session-ready 的第一块屏。
- (NSNumber *)wireDisplayIDFor:(uint32_t)displayID {
    if (displayID != 0) return @(displayID);
    NSNumber *first = self.remoteDisplays.firstObject[@"displayID"];
    return [first isKindOfClass:[NSNumber class]] ? first : nil;
}

- (BOOL)requestKeyframeForDisplay:(uint32_t)displayID error:(NSError **)error {
    if (error) *error = nil;
    if (self.role != M1ControlRoleClient) {
        if (error) *error = M1SessErr(M1ControlSessionErrorProtocol,
            @"只有 Client 发送 keyframe-request");
        return NO;
    }
    if (self.closed || self.stateMachine.state != P1SessionStateStreaming) {
        if (error) *error = M1SessErr(M1ControlSessionErrorInvalidState,
            @"会话未处于 STREAMING，关键帧请求未发送");
        return NO;
    }
    double now = [[NSDate date] timeIntervalSince1970] * 1000.0;
    if (![self rateLimitAllows:self.lastKfMsByDisplay displayID:displayID
                    intervalMs:300.0 nowMs:now]) {
        if (error) *error = M1SessErr(M1ControlSessionErrorRateLimited,
            @"关键帧请求限流（300ms/屏）");
        return NO;
    }
    NSMutableDictionary *payload = [@{ @"type": @"keyframe-request",
                                       @"reason": @"loss" } mutableCopy];
    NSNumber *wireID = [self wireDisplayIDFor:displayID];
    if (wireID) payload[@"displayID"] = wireID;
    if (![self sendPayload:payload]) return NO;
    [self markRateLimit:self.lastKfMsByDisplay displayID:displayID nowMs:now];
    atomic_fetch_add(&_kfRequestsSent, 1);
    return YES;
}

- (void)handleKeyframeRequest:(NSDictionary *)msg {
    if (self.role != M1ControlRoleHost) {
        [self failWith:M1SessErr(M1ControlSessionErrorProtocol,
            @"Host 不应收到 keyframe-request")];
        return;
    }
    if (self.closed || self.stateMachine.state != P1SessionStateStreaming) return;
    uint32_t displayID = 0;
    NSNumber *d = msg[@"displayID"];
    if ([d isKindOfClass:[NSNumber class]]) displayID = d.unsignedIntValue;
    atomic_fetch_add(&_kfRequestsReceived, 1);
    if ([self.delegate respondsToSelector:
            @selector(controlSession:didRequestKeyframeForDisplay:)]) {
        [self.delegate controlSession:self didRequestKeyframeForDisplay:displayID];
    }
}

#pragma mark - 定向补片

- (NSUInteger)frameNacksSent { return (NSUInteger)atomic_load(&_nacksSent); }
- (NSUInteger)frameNacksReceived { return (NSUInteger)atomic_load(&_nacksReceived); }

- (BOOL)requestFragmentsForDisplay:(uint32_t)displayID
                          frameSeq:(uint32_t)frameSeq
                          fragCount:(uint16_t)fragCount
                            indices:(NSIndexSet *)indices
                              error:(NSError **)error {
    if (error) *error = nil;
    if (self.role != M1ControlRoleClient) {
        if (error) *error = M1SessErr(M1ControlSessionErrorProtocol,
            @"只有 Client 发送 frame-nack");
        return NO;
    }
    if (self.closed || self.stateMachine.state != P1SessionStateStreaming) {
        if (error) *error = M1SessErr(M1ControlSessionErrorInvalidState,
            @"会话未处于 STREAMING，补片请求未发送");
        return NO;
    }
    if (fragCount == 0 || indices.count == 0 || indices.count > 64) {
        if (error) *error = M1SessErr(M1ControlSessionErrorProtocol,
            @"补片请求参数非法（片数或缺失下标越界）");
        return NO;
    }
    if (indices.lastIndex >= fragCount) {
        if (error) *error = M1SessErr(M1ControlSessionErrorProtocol,
            @"补片下标超出 fragCount");
        return NO;
    }
    double now = [[NSDate date] timeIntervalSince1970] * 1000.0;
    // 同批多帧停滞可能在同一毫秒内各请求一次；限流按屏独立。
    if (![self rateLimitAllows:self.lastNackMsByDisplay displayID:displayID
                    intervalMs:5.0 nowMs:now]) {
        if (error) *error = M1SessErr(M1ControlSessionErrorRateLimited,
            @"补片请求限流（5ms/屏）");
        return NO;
    }
    NSMutableArray<NSNumber *> *idx = [NSMutableArray arrayWithCapacity:indices.count];
    [indices enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        [idx addObject:@(i)];
    }];
    NSMutableDictionary *payload = [@{ @"type": @"frame-nack",
                                       @"frameSeq": @(frameSeq),
                                       @"fragCount": @(fragCount),
                                       @"indices": idx } mutableCopy];
    NSNumber *wireID = [self wireDisplayIDFor:displayID];
    if (wireID) payload[@"displayID"] = wireID;
    if (![self sendPayload:payload]) return NO;
    [self markRateLimit:self.lastNackMsByDisplay displayID:displayID nowMs:now];
    atomic_fetch_add(&_nacksSent, 1);
    return YES;
}

- (BOOL)requestWholeFrameForDisplay:(uint32_t)displayID
                           frameSeq:(uint32_t)frameSeq
                              error:(NSError **)error {
    if (error) *error = nil;
    if (self.role != M1ControlRoleClient) {
        if (error) *error = M1SessErr(M1ControlSessionErrorProtocol,
            @"只有 Client 发送 frame-nack");
        return NO;
    }
    if (self.closed || self.stateMachine.state != P1SessionStateStreaming) {
        if (error) *error = M1SessErr(M1ControlSessionErrorInvalidState,
            @"会话未处于 STREAMING，整帧补片请求未发送");
        return NO;
    }
    double now = [[NSDate date] timeIntervalSince1970] * 1000.0;
    if (![self rateLimitAllows:self.lastWholeNackMsByDisplay displayID:displayID
                    intervalMs:5.0 nowMs:now]) {
        if (error) *error = M1SessErr(M1ControlSessionErrorRateLimited,
            @"整帧补片请求限流（5ms/屏）");
        return NO;
    }
    NSMutableDictionary *payload = [@{ @"type": @"frame-nack",
                                       @"frameSeq": @(frameSeq),
                                       @"all": @YES } mutableCopy];
    NSNumber *wireID = [self wireDisplayIDFor:displayID];
    if (wireID) payload[@"displayID"] = wireID;
    if (![self sendPayload:payload]) return NO;
    [self markRateLimit:self.lastWholeNackMsByDisplay displayID:displayID nowMs:now];
    atomic_fetch_add(&_nacksSent, 1);
    return YES;
}

- (void)handleFrameNack:(NSDictionary *)msg {
    if (self.role != M1ControlRoleHost) {
        [self failWith:M1SessErr(M1ControlSessionErrorProtocol,
            @"Host 不应收到 frame-nack")];
        return;
    }
    if (self.closed || self.stateMachine.state != P1SessionStateStreaming) return;
    NSNumber *seqNum = msg[@"frameSeq"];
    if (![seqNum isKindOfClass:[NSNumber class]]) return;
    uint32_t displayID = 0;
    NSNumber *d = msg[@"displayID"];
    if ([d isKindOfClass:[NSNumber class]]) displayID = d.unsignedIntValue;
    NSNumber *allNum = msg[@"all"];
    if ([allNum isKindOfClass:[NSNumber class]] && allNum.boolValue) {
        // 整帧零分片：没有缺片下标可校验，交给发送端按 frameSeq 重发全部分片。
        atomic_fetch_add(&_nacksReceived, 1);
        if ([self.delegate respondsToSelector:
                @selector(controlSession:didRequestFragmentsForDisplay:frameSeq:fragCount:indices:)]) {
            [self.delegate controlSession:self
              didRequestFragmentsForDisplay:displayID
                                  frameSeq:(uint32_t)seqNum.unsignedIntValue
                                  fragCount:0
                                    indices:[NSIndexSet indexSet]];
        }
        return;
    }
    NSNumber *cntNum = msg[@"fragCount"];
    NSArray *rawIndices = msg[@"indices"];
    if (![cntNum isKindOfClass:[NSNumber class]] ||
        ![rawIndices isKindOfClass:[NSArray class]] ||
        rawIndices.count == 0 || rawIndices.count > 64) {
        return;   // 畸形补片请求静默忽略：它来自帧通道的推测，不该掀掉会话
    }
    uint16_t fragCount = (uint16_t)cntNum.unsignedIntegerValue;
    if (fragCount == 0) return;
    NSMutableIndexSet *indices = [NSMutableIndexSet indexSet];
    for (id v in rawIndices) {
        if (![v isKindOfClass:[NSNumber class]]) return;
        NSUInteger i = [v unsignedIntegerValue];
        if (i >= fragCount) return;
        [indices addIndex:i];
    }
    if (indices.count == 0) return;
    atomic_fetch_add(&_nacksReceived, 1);
    if ([self.delegate respondsToSelector:
            @selector(controlSession:didRequestFragmentsForDisplay:frameSeq:fragCount:indices:)]) {
        [self.delegate controlSession:self
          didRequestFragmentsForDisplay:displayID
                              frameSeq:(uint32_t)seqNum.unsignedIntValue
                              fragCount:fragCount
                                indices:indices];
    }
}

#pragma mark - 时钟同步

- (BOOL)requestTimeSyncWithError:(NSError **)error {
    if (error) *error = nil;
    if (self.role != M1ControlRoleClient) {
        if (error) *error = M1SessErr(M1ControlSessionErrorProtocol,
            @"只有 Client 发起 time-sync");
        return NO;
    }
    if (self.closed || self.stateMachine.state != P1SessionStateStreaming) {
        if (error) *error = M1SessErr(M1ControlSessionErrorInvalidState,
            @"会话未处于 STREAMING，time-sync 未发送");
        return NO;
    }
    return [self sendPayload:@{ @"type": @"time-sync", @"t0": @(M1WallClockUs()) }];
}

- (void)handleTimeSync:(NSDictionary *)msg {
    if (self.role != M1ControlRoleHost) return;   // Client 收到同向探针说明对端实现错位
    if (self.closed || self.stateMachine.state != P1SessionStateStreaming) return;
    NSNumber *t0 = msg[@"t0"];
    if (![t0 isKindOfClass:[NSNumber class]]) return;
    [self sendPayload:@{ @"type": @"time-sync-reply",
                         @"t0": t0,
                         @"t1": @(M1WallClockUs()) }];
}

- (void)handleTimeSyncReply:(NSDictionary *)msg {
    if (self.role != M1ControlRoleClient) return;
    NSNumber *t0n = msg[@"t0"];
    NSNumber *t1n = msg[@"t1"];
    if (![t0n isKindOfClass:[NSNumber class]] ||
        ![t1n isKindOfClass:[NSNumber class]]) return;
    uint64_t t0 = t0n.unsignedLongLongValue;
    uint64_t t1 = t1n.unsignedLongLongValue;
    uint64_t t2 = M1WallClockUs();
    if (t0 == 0 || t1 == 0 || t2 <= t0) return;
    double rttMs = (double)(t2 - t0) / 1000.0;
    // 超长样本多半是控制队列被阻塞，偏移包含排队噪声，直接丢弃。
    if (rttMs > 5000.0) return;
    int64_t offsetUs = (int64_t)t1 - (int64_t)((t0 + t2) / 2);
    @synchronized (self) {
        if (!atomic_load(&_hasClockOffset) || rttMs <= atomic_load(&_timeSyncRttMs)) {
            atomic_store(&_clockOffsetUs, offsetUs);
            atomic_store(&_timeSyncRttMs, rttMs);
            atomic_store(&_hasClockOffset, true);
        }
        atomic_fetch_add(&_timeSyncSamples, 1);
    }
}

- (BOOL)hasClockOffset { return atomic_load(&_hasClockOffset); }
- (int64_t)clockOffsetUs { return atomic_load(&_clockOffsetUs); }
- (double)timeSyncRttMs { return atomic_load(&_timeSyncRttMs); }
- (NSUInteger)timeSyncSamples { return (NSUInteger)atomic_load(&_timeSyncSamples); }

#pragma mark - 动态协商（FR-07）

// session-start 与 session-update 共用同一套规格校验；上限与 capabilities 保持一致。
static BOOL M1ValidateSpecs(NSArray *specs, NSString **reason) {
    if (![specs isKindOfClass:[NSArray class]] || specs.count == 0) {
        if (reason) *reason = @"specs 为空";
        return NO;
    }
    if (specs.count > 8) {
        if (reason) *reason = [NSString stringWithFormat:@"屏数 %lu 超过上限 8",
                               (unsigned long)specs.count];
        return NO;
    }
    for (id s in specs) {
        if (![s isKindOfClass:[NSDictionary class]]) {
            if (reason) *reason = @"spec 不是对象";
            return NO;
        }
        NSNumber *w = s[@"w"], *h = s[@"h"];
        if (![w isKindOfClass:[NSNumber class]] || ![h isKindOfClass:[NSNumber class]]) {
            if (reason) *reason = @"spec 缺 w/h";
            return NO;
        }
        if (w.unsignedIntegerValue < 2 || w.unsignedIntegerValue > 8192 ||
            h.unsignedIntegerValue < 2 || h.unsignedIntegerValue > 8192) {
            if (reason) *reason = [NSString stringWithFormat:@"分辨率越界 %@x%@", w, h];
            return NO;
        }
    }
    return YES;
}

- (NSUInteger)sessionUpdatesSent { return (NSUInteger)atomic_load(&_sessionUpdatesSent); }
- (NSUInteger)sessionUpdatesApplied { return (NSUInteger)atomic_load(&_sessionUpdatesApplied); }

- (int64_t)requestSessionUpdateWithSpecs:(NSArray<NSDictionary *> *)specs
                                   error:(NSError **)error {
    if (error) *error = nil;
    if (self.role != M1ControlRoleClient) {
        if (error) *error = M1SessErr(M1ControlSessionErrorProtocol,
            @"只有 Client 发起 session-update");
        return 0;
    }
    if (self.closed || self.stateMachine.state != P1SessionStateStreaming) {
        if (error) *error = M1SessErr(M1ControlSessionErrorInvalidState,
            @"会话未处于 STREAMING，session-update 未发送");
        return 0;
    }
    NSString *why = nil;
    if (!M1ValidateSpecs(specs, &why)) {
        if (error) *error = M1SessErr(M1ControlSessionErrorProtocol, why);
        return 0;
    }
    int64_t updateID = atomic_fetch_add(&_nextUpdateID, 1) + 1;
    if (![self sendPayload:@{ @"type": @"session-update",
                              @"updateID": @(updateID),
                              @"specs": specs }]) return 0;
    atomic_fetch_add(&_sessionUpdatesSent, 1);
    return updateID;
}

- (void)handleSessionUpdate:(NSDictionary *)msg {
    if (self.role != M1ControlRoleHost) {
        [self failWith:M1SessErr(M1ControlSessionErrorProtocol,
            @"Host 才接收 session-update")];
        return;
    }
    // 非 STREAMING 无屏可换；不回结果会让客户端一直等，但此时状态本身已异常。
    if (self.closed || self.stateMachine.state != P1SessionStateStreaming) return;

    NSNumber *idNum = msg[@"updateID"];
    int64_t updateID = [idNum isKindOfClass:[NSNumber class]] ? idNum.longLongValue : 0;

    void (^replyFail)(NSString *, NSString *) = ^(NSString *code, NSString *detail) {
        [self sendPayload:@{ @"type": @"session-update-result",
                             @"updateID": @(updateID),
                             @"ok": @NO,
                             @"error": @{ @"code": code, @"detail": detail ?: @"" } }];
    };
    NSString *why = nil;
    if (!M1ValidateSpecs(msg[@"specs"], &why)) {
        replyFail(@"SPEC_UNSUPPORTED", why);
        return;
    }
    if (![self.delegate respondsToSelector:
            @selector(controlSession:applySessionUpdateSpecs:error:)]) {
        replyFail(@"UPDATE_UNSUPPORTED", @"Host 不支持动态换屏");
        return;
    }
    NSError *applyErr = nil;
    NSArray<NSDictionary *> *displays =
        [self.delegate controlSession:self applySessionUpdateSpecs:msg[@"specs"]
                                error:&applyErr];
    if (!displays) {
        NSString *code = applyErr.userInfo[@"code"];
        if (![code isKindOfClass:[NSString class]] || code.length == 0) {
            code = @"UPDATE_FAILED";
        }
        replyFail(code, applyErr.localizedDescription ?: @"换屏失败");
        return;
    }
    self.remoteDisplays = displays;
    atomic_fetch_add(&_sessionUpdatesApplied, 1);
    [self sendPayload:@{ @"type": @"session-update-result",
                         @"updateID": @(updateID),
                         @"ok": @YES,
                         @"displays": displays }];
}

- (void)handleSessionUpdateResult:(NSDictionary *)msg {
    if (self.role != M1ControlRoleClient) return;
    NSNumber *idNum = msg[@"updateID"];
    int64_t updateID = [idNum isKindOfClass:[NSNumber class]] ? idNum.longLongValue : 0;
    NSNumber *okNum = msg[@"ok"];
    BOOL ok = [okNum isKindOfClass:[NSNumber class]] && okNum.boolValue;
    NSArray<NSDictionary *> *displays = msg[@"displays"];
    if (![displays isKindOfClass:[NSArray class]]) displays = @[];
    NSString *detail = nil;
    if (!ok) {
        NSDictionary *err = msg[@"error"];
        if ([err isKindOfClass:[NSDictionary class]]) {
            NSString *code = err[@"code"];
            NSString *d = err[@"detail"];
            NSString *c = [code isKindOfClass:[NSString class]] ? code : @"UPDATE_FAILED";
            detail = [d isKindOfClass:[NSString class]] && d.length > 0
                   ? [NSString stringWithFormat:@"%@: %@", c, d] : c;
        } else {
            detail = @"UPDATE_FAILED";
        }
    } else {
        self.remoteDisplays = displays;
        atomic_fetch_add(&_sessionUpdatesApplied, 1);
    }
    if ([self.delegate respondsToSelector:
            @selector(controlSession:didCompleteSessionUpdate:ok:displays:errorDetail:)]) {
        [self.delegate controlSession:self didCompleteSessionUpdate:updateID
                                   ok:ok displays:displays errorDetail:detail];
    }
}

#pragma mark - 心跳

- (void)startHeartbeat {
    uint32_t intervalMs = self.config.heartbeatIntervalMs;
    if (intervalMs == 0 || self.hbTimer) return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.hbQueue);
    uint64_t ns = (uint64_t)intervalMs * NSEC_PER_MSEC;
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)ns), ns, ns / 10);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(t, ^{
        M1ControlSession *s = weakSelf;
        if (!s || s.closed) return;
        [s sendPayload:@{ @"type": @"heartbeat",
                          @"ts": @([[NSDate date] timeIntervalSince1970] * 1000.0) }];
    });
    self.hbTimer = t;
    dispatch_resume(t);
}

- (void)stopHeartbeat {
    if (!self.hbTimer) return;
    dispatch_source_cancel(self.hbTimer);
    self.hbTimer = nil;
}

@end
