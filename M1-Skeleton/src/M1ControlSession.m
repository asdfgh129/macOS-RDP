//
//  M1ControlSession.m
//  M1-Skeleton
//

#import "M1ControlSession.h"
#import "ProtocolCodec.h"

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

@interface M1ControlSession ()
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
    else if ([type isEqualToString:@"bye"] || [type isEqualToString:@"session-error"]) {
        self.closed = YES;
        [self stopHeartbeat];
        [self advance:type];
    }
    // 其余类型（input / keyframe-*）属帧通道阶段，这里静默忽略。
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
        @"maxDisplays": @1,
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
    if (![self advance:@"session-start"]) return;

    // ★ M1-A：不建真屏，按请求规格合成占位 display 并显式标注 synthetic。
    //   M1-B 接 VDManager 后这里换成真实 displayID。
    NSMutableArray *displays = [NSMutableArray array];
    for (NSUInteger i = 0; i < specs.count; i++) {
        NSDictionary *s = [specs[i] isKindOfClass:[NSDictionary class]] ? specs[i] : @{};
        [displays addObject:@{
            @"displayID": @(1000 + i),
            @"w": s[@"w"] ?: @0,
            @"h": s[@"h"] ?: @0,
            @"synthetic": @YES,
        }];
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
