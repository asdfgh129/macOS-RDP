//
//  M1StreamSession.m
//  VeilRD — RDPKit
//
//  从 M1-Skeleton/stream_probe.m 抽出的节点实现（第 4 轮），行为保持一致：
//  控制包优先、帧分片走独立队列、VT 会话预热由入口负责、A-02 时钟探针由客户端
//  进入 STREAMING 后定时发出。入口只装配采集/窗口/输入，不重复实现协议层。
//

#import "M1StreamSession.h"

#import <Cocoa/Cocoa.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <libproc.h>
#import <unistd.h>

#import "ProtocolCodec.h"
#import "M1DatagramSink.h"
#import "M1ControlLink.h"
#import "M1FrameReceiver.h"

static const uint8_t kMagicControl = 0x43;   // 'C'  M1ControlLink
static const uint8_t kMagicFrame   = 0x4D;   // 'M'  P1FrameMagic 首字节

double M1StreamNowMs(void) {
    return [[NSDate date] timeIntervalSince1970] * 1000.0;
}

static BOOL M1SavePixelBufferPNG(CVPixelBufferRef pb, NSString *path) {
    if (!pb || path.length == 0) return NO;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    if (!ci) return NO;
    static CIContext *ctx = nil;
    if (!ctx) ctx = [CIContext contextWithOptions:nil];
    CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
    if (!cg) return NO;
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, (__bridge CFStringRef)@"public.png", 1, NULL);
    if (!dst) { CGImageRelease(cg); return NO; }
    CGImageDestinationAddImage(dst, cg, NULL);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(cg);
    return ok;
}

#pragma mark - 控制链路专用 sink

// 控制包插到传输队列最前，不与整帧分片一起排队。
// 补片请求晚到几百毫秒就等于没发——接收端早已按期限判丢。
@interface M1PriorityDatagramSink : NSObject <M1DatagramSink>
@property (nonatomic, strong) M1QuicTransport *transport;
+ (instancetype)sinkForTransport:(M1QuicTransport *)transport;
@end

@implementation M1PriorityDatagramSink
+ (instancetype)sinkForTransport:(M1QuicTransport *)transport {
    M1PriorityDatagramSink *s = [M1PriorityDatagramSink new];
    s.transport = transport;
    return s;
}
- (BOOL)sendDatagram:(NSData *)datagram error:(NSError **)error {
    return [self.transport sendPriorityDatagram:datagram error:error];
}
@end

#pragma mark - M1StreamNode

@interface M1StreamNode ()
// 控制消息交付专用串行队列。收包回调跑在传输线程上，直接交付会让会话处理
// （换屏建屏/写盘等，秒级）堵住 ACK 与心跳的收包，双方控制链路在 2s 重传
// 预算内误判失败（FR-07 实测：换屏 2.2s 后两端心跳同时消失、结果回包丢失）。
@property (nonatomic, strong) dispatch_queue_t controlDeliveryQueue;
@property (nonatomic, strong) dispatch_source_t livenessTimer;
// 一次接入只通知一次（bye 正常挥手与传输失败可能双双到达）。
@property (nonatomic, assign) BOOL sessionClosedNotified;
// 会话收尾时留存最后一轮控制面计数（link/channel 随即拆掉，不能再实时读）。
@property (nonatomic, strong, nullable) NSDictionary<NSString *, id> *lastControlDiagnostics;
// 本次 attach 绑定的入站连接。streamConn 在 didAcceptConnection 就被写成新连接，
// 收尾时必须按「本轮」引用取消，否则会把下一位客户端的连接一起收掉。
@property (nonatomic, strong, nullable) M1QuicTransport *sessionTransport;
- (void)notifySessionClosedOnce;
- (void)detachSessionObjects;
@end

@implementation M1StreamNode

- (instancetype)init {
    if ((self = [super init])) {
        _identityPath = @".state/rdp-identity.p12";
        _identityPass = @"rdpdev";
        _alpn = @"rdp1";
        _readySem = dispatch_semaphore_create(0);
        _streamingSem = dispatch_semaphore_create(0);
        _controlDeliveryQueue = dispatch_queue_create("m1.stream.control-delivery",
                                                      DISPATCH_QUEUE_SERIAL);
        _fps = 20;
        _bitrateKbps = 12000;
        _controlArrivals = [NSMutableArray array];
        _simState = 0x9E3779B97F4A7C15ull ^ (uint64_t)getpid();
    }
    return self;
}

- (void)dealloc {
    if (_livenessTimer) dispatch_source_cancel(_livenessTimer);
}

// 控制面静默看门狗：对端每 1s 一条心跳，8s 一条都没到就说明控制面已死
// （链路重传耗尽 / 对端投递队列卡住），此时画面仍可能在流，不主动判死
// 就会一直「假在线」（2026-11-25 FR-07 实测：心跳消失 20s 无任何报错）。
- (void)startLivenessWatchdog {
    if (self.livenessTimer) return;
    __weak typeof(self) weakSelf = self;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 self.controlDeliveryQueue);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC),
                              1000 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{
        M1StreamNode *s = weakSelf;
        if (!s) return;
        if (!s.streaming || s.lastControlArrivalMs <= 0) return;
        double gapMs = M1StreamNowMs() - s.lastControlArrivalMs;
        if (gapMs <= 8000) return;
        fprintf(stderr, "  [%s] 控制面静默 %.1fs，判定控制链路失效\n",
                s.isHost ? "host" : "client", gapMs / 1000.0);
        fflush(stderr);
        [s stopLivenessWatchdog];
        if (!s.error) {
            s.error = [NSError errorWithDomain:@"M1StreamSession" code:5
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"控制面静默 %.1fs", gapMs / 1000.0]}];
        }
        [s.session closeWithReason:@"control-timeout"];
        dispatch_semaphore_signal(s.streamingSem);
    });
    self.livenessTimer = t;
    dispatch_resume(t);
}

- (void)stopLivenessWatchdog {
    if (!self.livenessTimer) return;
    dispatch_source_cancel(self.livenessTimer);
    self.livenessTimer = nil;
}

- (void)notifySessionClosedOnce {
    @synchronized (self) {
        if (self.sessionClosedNotified) return;
        self.sessionClosedNotified = YES;
    }
    // 通知必须落在控制交付队列上：收尾（还屏/拆链路/停管线）跑在入口的
    // onSessionClosed 里，而下一轮 session-start 也在同一条队列上处理，
    // 串行才能保证「收尾完成」先于「下一轮建屏」（实测：两轮显示事务并发，
    // 第二轮建出的屏被上一轮销毁）。传输线程触发的失败路径也走这里。
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.controlDeliveryQueue, ^{
        M1StreamNode *s = weakSelf;
        if (!s) return;
        [s detachSessionObjects];
        if (s.onSessionClosed) s.onSessionClosed();
    });
}

// 按引用拆掉本轮的控制对象（对新一轮已 attach 的对象无影响）。
- (void)detachSessionObjects {
    self.lastControlDiagnostics = [self controlDiagnostics];
    M1ControlLink *link = self.link;
    M1ControlSession *session = self.session;
    M1ControlChannel *channel = self.channel;
    M1QuicTransport *conn = self.sessionTransport;
    link.delegate = nil;
    session.delegate = nil;
    if (self.link == link) self.link = nil;
    if (self.session == session) self.session = nil;
    if (self.channel == channel) self.channel = nil;
    if (self.sessionTransport == conn) self.sessionTransport = nil;
    // 出帧出口也要断开：否则旧连接的迟到错误会被认成本轮（新一轮 accept 已覆盖时不动）。
    if (self.streamConn == conn) self.streamConn = nil;
    // 本轮连接已无用：取消后 listener 才能接下一轮（cancel 是幂等空操作）。
    [conn cancel];
}

// 会话结束到下一次 attachSessionTo 之间复位一次性状态：
// 同一 agent 进程服务下一个客户端时，上一轮的 error/计时/控制到达记录不能带进来。
- (void)prepareForNextSession {
    [self stopLivenessWatchdog];
    // 时长到时 host 主动收尾：先走正常挥手，让客户端立刻知道会话结束。
    M1ControlSession *session = self.session;
    if (session && session.stateMachine.state != P1SessionStateClosed) {
        [session closeWithReason:@"session-end"];
    }
    [self detachSessionObjects];
    self.streaming = NO;
    self.error = nil;
    self.handshakeMs = 0;
    self.streamStartMs = 0;
    self.lastControlArrivalMs = 0;
    @synchronized (self.controlArrivals) { [self.controlArrivals removeAllObjects]; }
}

- (void)performOnSessionQueue:(dispatch_block_t)block {
    dispatch_async(self.controlDeliveryQueue, block);
}

#pragma mark 启动

- (BOOL)startAsHostOnPort:(uint16_t)port error:(NSError **)error {
    self.isHost = YES;
    M1QuicTransport *t = [[M1QuicTransport alloc] initAsListenerOnPort:port
                                                                  alpn:self.alpn
                                                          identityPath:self.identityPath
                                                          identityPass:self.identityPass
                                                            verifyPeer:NO];
    t.delegate = self;
    self.listener = t;
    [t start];
    if (dispatch_semaphore_wait(self.readySem,
            dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC)) != 0) {
        if (error) *error = [NSError errorWithDomain:@"M1StreamSession" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"listener 未在 8s 内 ready"}];
        return NO;
    }
    if (self.error) { if (error) *error = self.error; return NO; }
    self.port = t.listenPort;
    return YES;
}

- (BOOL)startAsClientTo:(NSString *)host port:(uint16_t)port
                timeout:(uint32_t)timeoutMs error:(NSError **)error {
    self.isHost = NO;
    M1QuicTransport *t = [[M1QuicTransport alloc] initAsClientToHost:host
                                                                port:port
                                                                alpn:self.alpn
                                                        identityPath:nil
                                                        identityPass:nil
                                                          verifyPeer:YES];
    t.expectedPeerFingerprint = self.expectedFingerprint;
    t.delegate = self;
    self.streamConn = t;
    double t0 = M1StreamNowMs();
    [t start];
    if (![t waitUntilReadyTimeoutMs:timeoutMs]) {
        if (error) *error = [NSError errorWithDomain:@"M1StreamSession" code:2
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"握手未在 %ums 内完成", timeoutMs]}];
        return NO;
    }
    self.handshakeMs = M1StreamNowMs() - t0;
    if (self.error) { if (error) *error = self.error; return NO; }
    return YES;
}

- (void)attachSessionTo:(M1QuicTransport *)conn {
    // 新一轮接入：先把上一轮可能残留的控制对象按引用拆掉，再复位一次性状态。
    [self detachSessionObjects];
    [self stopLivenessWatchdog];
    self.streaming = NO;
    self.error = nil;
    self.handshakeMs = 0;
    self.streamStartMs = 0;
    self.lastControlArrivalMs = 0;
    @synchronized (self.controlArrivals) { [self.controlArrivals removeAllObjects]; }

    self.streamConn = conn;
    self.sessionTransport = conn;
    self.link = [[M1ControlLink alloc] initWithSink:[M1PriorityDatagramSink sinkForTransport:conn]];
    {
        // 慢速建屏（如 13 独占 mode-commit）期间控制 ACK 可能延迟，
        // 放宽重传窗口避免误判丢包。默认 250ms × 20。
        const char *retryMs = getenv("M1_CTRL_RETRY_MS");
        if (retryMs && atoi(retryMs) > 0) self.link.retryIntervalMs = (uint32_t)atoi(retryMs);
        const char *maxTries = getenv("M1_CTRL_MAX_ATTEMPTS");
        if (maxTries && atoi(maxTries) > 0) self.link.maxAttempts = (NSUInteger)atoi(maxTries);
    }
    self.link.delegate = self;
    self.channel = [[M1ControlChannel alloc] initWithSink:self.link];

    M1ControlSessionConfig *cfg = [M1ControlSessionConfig new];
    cfg.role = self.isHost ? M1ControlRoleHost : M1ControlRoleClient;
    cfg.hostName = self.isHost ? @"veild-host" : @"veild-client";
    cfg.localFingerprint = self.localFingerprint;
    cfg.expectedPeerFingerprint = self.expectedFingerprint;
    cfg.fps = self.fps;
    cfg.bitrateKbps = self.bitrateKbps;
    cfg.specs = self.requestedSpecs ?: @[ @{ @"w": @1920, @"h": @1080,
                                             @"hidpi": @NO, @"refresh": @60 } ];
    cfg.heartbeatIntervalMs = 1000;
    self.session = [[M1ControlSession alloc] initWithChannel:self.channel config:cfg];
    self.session.delegate = self;
    self.sessionClosedNotified = NO;
    [self.session begin];
}

- (BOOL)waitForStreamingTimeoutMs:(uint32_t)timeoutMs {
    // timeoutMs == 0 → 无限等待，直到对端接入（自动化联调时 host 常无人值守）。
    if (timeoutMs == 0) {
        for (;;) {
            if (dispatch_semaphore_wait(self.streamingSem,
                    dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0) {
                if (self.streaming && self.error == nil) return YES;
                if (self.error) {
                    printf("  [%s] 本次尝试失败：%s（继续等待重试）\n",
                           self.isHost ? "host" : "client",
                           self.error.localizedDescription.UTF8String ?: "unknown");
                    if (self.onAttemptFailed) self.onAttemptFailed();
                    fflush(stdout);
                    self.error = nil;
                }
                continue;
            }
            printf("  [%s] 仍在等待对端…（--wait-ms 0 = 无限等待，Ctrl-C 结束）\n",
                   self.isHost ? "host" : "client");
            fflush(stdout);
        }
    }
    if (dispatch_semaphore_wait(self.streamingSem,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutMs * NSEC_PER_MSEC)) != 0) {
        return NO;
    }
    return self.streaming && self.error == nil;
}

#pragma mark M1DatagramSink（帧管线出口）

- (double)simRandom {
    uint64_t x = self.simState;
    x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
    self.simState = x;
    return (double)((x * 0x2545F4914F6CDD1Dull) >> 11) / 9007199254740992.0;
}

- (BOOL)sendDatagram:(NSData *)datagram error:(NSError **)error {
    M1QuicTransport *conn = self.streamConn;
    if (!conn) {
        if (error) *error = [NSError errorWithDomain:@"M1StreamSession" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"连接未就绪"}];
        return NO;
    }
    if (self.isHost && (self.simLossPct > 0 || self.simReorderPct > 0)) {
        if (self.simLossPct > 0 && [self simRandom] * 100.0 < self.simLossPct) {
            self.simFragmentsDropped += 1;
            return YES;
        }
        if (self.simReorderPct > 0) {
            if (self.simHeld) {
                NSData *held = self.simHeld;
                self.simHeld = nil;
                self.simReordered += 1;
                if (![conn sendDatagram:datagram error:error]) return NO;
                return [conn sendDatagram:held error:error];
            }
            if ([self simRandom] * 100.0 < self.simReorderPct) {
                self.simHeld = datagram;
                return YES;
            }
        }
    }
    return [conn sendDatagram:datagram error:error];
}

- (void)flushSimulatedHeld {
    if (!self.simHeld) return;
    NSData *held = self.simHeld;
    self.simHeld = nil;
    if (self.streamConn) [self.streamConn sendDatagram:held error:NULL];
}

#pragma mark 传输回调

- (void)quicTransportDidBecomeReady:(M1QuicTransport *)transport {
    if (transport == self.listener) {
        dispatch_semaphore_signal(self.readySem);
        return;
    }
    if (transport != self.streamConn) {
        dispatch_semaphore_signal(self.readySem);
    }
    [self attachSessionTo:transport];
}

- (void)quicTransport:(M1QuicTransport *)transport
   didAcceptConnection:(M1QuicTransport *)connection {
    // 提前记下当前连接：握手阶段就失败时，didFailWithError 才认得出是本轮。
    if (transport == self.listener && self.streamConn != connection) {
        self.streamConn = connection;
    }
    const char *peer = connection.peerDescription.UTF8String;
    printf("  [host] 已接受连接%s%s\n", peer ? " from " : "", peer ?: "");
    fflush(stdout);
}

- (void)quicTransport:(M1QuicTransport *)transport didFailWithError:(NSError *)error {
    // 已淘汰的旧连接：收尾时取消也会走这里，不能把错误记到新一轮会话头上。
    if (transport != self.listener && transport != self.streamConn) return;
    if (!self.error) self.error = error;
    // 会话中途传输断掉（客户端来不及挥手）：也按会话结束通知一次，
    // 否则 host 只能干等到 --duration-ms 才清理旧管线。
    if (self.streaming) {
        self.streaming = NO;
        [self notifySessionClosedOnce];
    }
    dispatch_semaphore_signal(self.readySem);
    dispatch_semaphore_signal(self.streamingSem);
}

- (void)quicTransport:(M1QuicTransport *)transport didReceiveDatagram:(NSData *)datagram {
    if (datagram.length == 0) return;
    uint8_t magic = ((const uint8_t *)datagram.bytes)[0];
    if (magic == kMagicControl) {
        self.controlDatagrams += 1;
        [self.link feedDatagram:datagram];
        return;
    }
    if (magic == kMagicFrame) {
        self.frameDatagrams += 1;
        [self onFrameDatagram:datagram];
        return;
    }
    self.unroutedDatagrams += 1;
}

- (void)onFrameDatagram:(NSData *)datagram { (void)datagram; }

- (void)controlLink:(M1ControlLink *)link didDeliverMessage:(NSData *)message {
    double now = M1StreamNowMs();
    if (self.streaming && self.lastControlArrivalMs > 0) {
        double gap = now - self.lastControlArrivalMs;
        if (gap > self.maxControlGapMs) {
            self.maxControlGapMs = gap;
            self.maxGapAtOffsetMs = self.streamStartMs > 0 ? now - self.streamStartMs : 0;
        }
    }
    self.lastControlArrivalMs = now;
    @synchronized (self.controlArrivals) {
        if (self.streamStartMs > 0 && self.controlArrivals.count < 256) {
            [self.controlArrivals addObject:@(round(now - self.streamStartMs))];
        }
    }
    // 交付切到专用串行队列（见 controlDeliveryQueue 注释）；link 端已先回 ACK。
    NSData *msg = message;
    dispatch_async(self.controlDeliveryQueue, ^{
        [self.channel feedBytes:msg];
    });
}

- (void)controlLink:(M1ControlLink *)link didFailWithError:(NSError *)error {
    // 对端已挥手后的残余重传耗尽属正常收尾，不当故障报。
    if (self.session.stateMachine.state != P1SessionStateClosed) {
        fprintf(stderr, "  [%s] 控制链路失败: %s\n", self.isHost ? "host" : "client",
                error.localizedDescription.UTF8String);
        fflush(stderr);
        if (!self.error) self.error = error;
    }
    [self stopLivenessWatchdog];
    dispatch_semaphore_signal(self.streamingSem);
}

- (NSDictionary<NSString *, id> *)controlDiagnostics {
    M1ControlLink *link = self.link;
    if (!link) return self.lastControlDiagnostics ?: @{};
    NSMutableDictionary *d = [[link diagnostics] mutableCopy];
    d[@"dgramControl"] = @(self.controlDatagrams);
    d[@"dgramFrame"] = @(self.frameDatagrams);
    d[@"dgramUnrouted"] = @(self.unroutedDatagrams);
    M1ControlChannel *ch = self.channel;
    d[@"chanSent"] = @(ch.sentCount);
    d[@"chanReceived"] = @(ch.receivedCount);
    d[@"chanErrors"] = @(ch.protocolErrors);
    return d;
}

#pragma mark 会话回调

- (void)controlSession:(M1ControlSession *)session didChangeState:(P1SessionState)state {
    printf("  [%s] %s\n", self.isHost ? "host" : "client", P1SessionStateName(state).UTF8String);
    if (state == P1SessionStateClosed) {
        // 对端挥手后控制通道不再有消息。继续记账会把「客户端断开 → 本端
        // --duration 结束」的空窗算成心跳被挤（§5.36 r2 host 15.1 s 即此）。
        self.streaming = NO;
        self.lastControlArrivalMs = 0;
        [self stopLivenessWatchdog];
        [self notifySessionClosedOnce];
    }
}

- (void)controlSessionDidReachStreaming:(M1ControlSession *)session {
    self.streaming = YES;
    // 建屏/守护进程握手期间最后一包控制消息可能在 STREAMING 前十几秒就到，
    // 首包心跳会把它算成一次巨大间隔（§5.36 r3 host 18.1 s 即此）。进入
    // STREAMING 时清零，首个心跳只播种、不记账。
    self.lastControlArrivalMs = 0;
    if (self.streamStartMs == 0) self.streamStartMs = M1StreamNowMs();
    dispatch_semaphore_signal(self.streamingSem);
    [self startLivenessWatchdog];

    // A-02：进入 STREAMING 后打 8 个时钟同步探针（200ms 起步、150ms 间隔）。
    // 取 RTT 最小的样本，避免控制队列排队时间被误算成时钟差。
    if (!self.isHost) {
        for (int i = 0; i < 8; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(200 + i * 150) * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if (session.stateMachine.state == P1SessionStateStreaming) {
                    [session requestTimeSyncWithError:NULL];
                }
            });
        }
    }
}

- (void)controlSession:(M1ControlSession *)session didFailWithError:(NSError *)error {
    // 主动挥手后的 bye 发送失败等收尾错误不算会话故障。
    if (self.session.stateMachine.state != P1SessionStateClosed) {
        fprintf(stderr, "  [%s] 控制会话失败: %s\n", self.isHost ? "host" : "client",
                error.localizedDescription.UTF8String);
        fflush(stderr);
        if (!self.error) self.error = error;
    }
    [self stopLivenessWatchdog];
    dispatch_semaphore_signal(self.streamingSem);
}

- (void)controlSession:(M1ControlSession *)session didReceiveInputEvent:(NSDictionary *)event {
    if (self.onInputEvent) self.onInputEvent(event);
}

- (void)controlSession:(M1ControlSession *)session
    didRequestKeyframeForDisplay:(uint32_t)displayID {
    if (self.onKeyframeRequest) self.onKeyframeRequest(displayID);
}

- (void)controlSession:(M1ControlSession *)session
 didRequestFragmentsForDisplay:(uint32_t)displayID
             frameSeq:(uint32_t)frameSeq
             fragCount:(uint16_t)fragCount
               indices:(NSIndexSet *)indices {
    if (self.onFrameNack) self.onFrameNack(displayID, frameSeq, fragCount, indices);
}

- (NSArray<NSDictionary *> *)controlSession:(M1ControlSession *)session
                 prepareDisplaysForSessionStart:(NSDictionary *)message
                                       error:(NSError **)error {
    if (!self.displayProvider) return @[];
    return self.displayProvider(message, error);
}

- (NSArray<NSDictionary *> *)controlSession:(M1ControlSession *)session
                    applySessionUpdateSpecs:(NSArray<NSDictionary *> *)specs
                                     error:(NSError **)error {
    if (!self.onSessionUpdateSpecs) return nil;
    return self.onSessionUpdateSpecs(specs, error);
}

- (void)controlSession:(M1ControlSession *)session
 didCompleteSessionUpdate:(int64_t)updateID
                     ok:(BOOL)ok
               displays:(NSArray<NSDictionary *> *)displays
            errorDetail:(NSString *)detail {
    if (self.onSessionUpdateResult) {
        self.onSessionUpdateResult(updateID, ok, displays, detail);
    }
}

- (int64_t)requestSessionUpdateWithSpecs:(NSArray<NSDictionary *> *)specs
                                   error:(NSError **)error {
    if (!self.session) {
        if (error) *error = [NSError errorWithDomain:@"M1StreamSession" code:1
            userInfo:@{ NSLocalizedDescriptionKey: @"会话未建立" }];
        return 0;
    }
    return [self.session requestSessionUpdateWithSpecs:specs error:error];
}

- (NSArray<NSString *> *)stateLog { return self.session ? self.session.stateLog : @[]; }

- (void)shutdown {
    [self stopLivenessWatchdog];
    [self.session closeWithReason:@"session-done"];
    [NSThread sleepForTimeInterval:0.25];   // 让 bye 真的出去
    [self.streamConn cancel];
    [self.listener cancel];
}

@end

#pragma mark - M1StreamClientNode

@implementation M1StreamClientNode {
    // displayID → 串行帧队列。每屏独立解码，互不阻塞（首帧建 VT 会话可达 1s）。
    NSMutableDictionary<NSNumber *, dispatch_queue_t> *_frameQueues;
    // 出现第二块屏后 PNG 文件名带 displayID，避免不同屏的同序号帧互相覆盖。
    BOOL _multiDisplay;
}

- (instancetype)init {
    if ((self = [super init])) {
        _savedPaths = [NSMutableArray array];
        _receivers = [NSMutableDictionary dictionary];
        _frameQueues = [NSMutableDictionary dictionary];
        _saveFrames = 5;
        _saveQueue = dispatch_queue_create("m1.stream.png", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (M1FrameReceiver *)receiverForDisplayID:(uint32_t)displayID {
    @synchronized (self) { return self.receivers[@(displayID)]; }
}

- (NSArray<NSNumber *> *)receiverDisplayIDs {
    @synchronized (self) {
        return [self.receivers.allKeys sortedArrayUsingSelector:@selector(compare:)];
    }
}

- (dispatch_queue_t)frameQueueForDisplayID:(uint32_t)displayID {
    NSNumber *key = @(displayID);
    @synchronized (self) {
        dispatch_queue_t q = _frameQueues[key];
        if (!q) {
            q = dispatch_queue_create("m1.stream.frames", DISPATCH_QUEUE_SERIAL);
            _frameQueues[key] = q;
        }
        return q;
    }
}

// 懒建：第一片到达才知道帧头 displayID。创建后立即登记，后续分片复用同一解码器。
- (M1FrameReceiver *)ensureReceiverForDisplayID:(uint32_t)displayID {
    M1FrameReceiver *rx = nil;
    @synchronized (self) {
        rx = self.receivers[@(displayID)];
        if (rx) return rx;
    }

    __weak typeof(self) weakSelf = self;
    rx = [[M1FrameReceiver alloc]
        initWithOnFrame:^(CVPixelBufferRef pb, uint32_t frameSeq, uint64_t capturedAtUs) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            double now = M1StreamNowMs();
            BOOL multi;
            @synchronized (self) {
                if (self.firstFrameMs == 0) self.firstFrameMs = now;
                self.lastFrameMs = now;
                self.decodedWidth = (int32_t)CVPixelBufferGetWidth(pb);
                self.decodedHeight = (int32_t)CVPixelBufferGetHeight(pb);
                multi = self->_multiDisplay;
            }
            if (self.onPixelBuffer) self.onPixelBuffer(displayID, pb, frameSeq, capturedAtUs);

            // PNG 编码离开接收/解码线程：实测 6 张同步 PNG 让心跳断了 4.5s。
            BOOL reserve = NO;
            if (self.outdir.length > 0) {
                @synchronized (self) {
                    if (self.reservedSaves < self.saveFrames) {
                        self.reservedSaves += 1;
                        reserve = YES;
                    }
                }
            }
            if (reserve) {
                CVPixelBufferRef held = CVPixelBufferRetain(pb);
                NSString *name = multi
                    ? [NSString stringWithFormat:@"frame-d%u-%03u.png", displayID, frameSeq]
                    : [NSString stringWithFormat:@"frame-%03u.png", frameSeq];
                NSString *path = [self.outdir stringByAppendingPathComponent:name];
                dispatch_async(self.saveQueue, ^{
                    if (M1SavePixelBufferPNG(held, path)) {
                        @synchronized (self) {
                            self.savedFrames += 1;
                            [self.savedPaths addObject:path];
                        }
                    }
                    CVPixelBufferRelease(held);
                });
            }
        }
        onNeedKeyframe:^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            @synchronized (self) { self.keyframeRequests += 1; }
            NSError *kfErr = nil;
            if ([self.session requestKeyframeForDisplay:displayID error:&kfErr]) {
                @synchronized (self) { self.keyframeRequestsSent += 1; }
                [[self receiverForDisplayID:displayID] noteKeyframeRequestSent];
            } else if (kfErr.code != M1ControlSessionErrorRateLimited) {
                @synchronized (self) { self.keyframeRequestFailures += 1; }
            }
        }];

    // 缺 1~3 片先走定向补片，比整帧 IDR 快一个量级；整帧零分片改请求整帧重发。
    rx.onNeedRepair = ^(uint32_t frameSeq, uint16_t fragCount,
                        NSIndexSet *missingIndices, BOOL keyframe) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        (void)keyframe;
        @synchronized (self) { self.repairRequests += 1; }
        NSError *nackErr = nil;
        BOOL sent;
        if (missingIndices.count == 0) {
            @synchronized (self) { self.repairWholeFrameRequests += 1; }
            sent = [self.session requestWholeFrameForDisplay:displayID
                                                    frameSeq:frameSeq
                                                       error:&nackErr];
        } else {
            sent = [self.session requestFragmentsForDisplay:displayID
                                                   frameSeq:frameSeq
                                                   fragCount:fragCount
                                                     indices:missingIndices
                                                       error:&nackErr];
        }
        if (sent) {
            @synchronized (self) { self.repairRequestsSent += 1; }
        }
    };

    @synchronized (self) {
        if (!self.receivers[@(displayID)]) {
            self.receivers[@(displayID)] = rx;
            if (!self.receiver) self.receiver = rx;
            if (self.receivers.count > 1) _multiDisplay = YES;
        }
        return self.receivers[@(displayID)];
    }
}

- (void)flushFrames {
    NSArray<dispatch_queue_t> *queues;
    @synchronized (self) { queues = _frameQueues.allValues; }
    for (dispatch_queue_t q in queues) dispatch_sync(q, ^{});
}

- (void)flushSaves { dispatch_sync(self.saveQueue, ^{}); }

- (void)onFrameDatagram:(NSData *)datagram {
    // 先解帧头拿 displayID，再投到该屏的帧队列。绝不在这里做重组/解码：
    // 首帧建 VT 解码会话实测 1092ms，同步做会堵住控制心跳。
    P1FrameHeader hdr;
    uint32_t displayID = 0;
    if (P1UnpackFrameHeader(datagram, &hdr, NULL)) displayID = hdr.displayID;
    dispatch_queue_t q = [self frameQueueForDisplayID:displayID];
    dispatch_async(q, ^{
        M1FrameReceiver *rx = [self ensureReceiverForDisplayID:displayID];
        double t0 = M1StreamNowMs();
        [rx acceptDatagram:datagram error:NULL];
        double dt = M1StreamNowMs() - t0;
        @synchronized (self) {
            if (dt > self.maxAcceptBlockMs) {
                self.maxAcceptBlockMs = dt;
                self.maxAcceptBlockAtMs = self.streamStartMs > 0 ? t0 - self.streamStartMs : 0;
            }
        }
    });
}

@end
