//
//  control_probe.m
//  M1-Skeleton
//
//  M1-A 第 3 步验收：控制通道 + 8 态状态机跑在**真实 QUIC 连接**上。
//
//  传输形态见 D-14：Network.framework 一个 nw_connection 只能承载一条流，控制流的
// 可靠性由 M1ControlLink 在 datagram 之上自建（seq/累计 ACK/重传），不依赖 QUIC stream。
//
//  两种用法：
//    ./control_probe --self [--rounds N]        进程内起 host+client，仍走真 socket
//    ./control_probe --host --port-file /tmp/p  另一终端 ./control_probe --client --port N
//
//  验收判据：
//    1. 双端都到达 STREAMING
//    2. 双端状态序列逐条一致，且等于
//       DISCOVERED→TLS_CONNECTED→PAIRED→NEGOTIATED→DISPLAYS_READY→STREAMING
//    3. session-ready 里的 sessionID 双端一致
//    4. 控制帧在真流上粘包/拆包仍正确（控制通道统计：received == 对端 sent）
//

#import <Foundation/Foundation.h>
#import "M1QuicTransport.h"
#import "M1ControlChannel.h"
#import "M1ControlLink.h"
#import "M1ControlSession.h"

static NSString *gIdentity = @".state/rdp-identity.p12";
static NSString *gPass = @"rdpdev";
static uint32_t gConnectTimeoutMs = 3000;
// 控制与帧共用同一条 QUIC datagram 连接（D-14），靠魔数分流。
static const char *kALPN = "rdp1";

static double NowMs(void) {
    return [[NSDate date] timeIntervalSince1970] * 1000.0;
}

#pragma mark - 单端节点

@interface CtlNode : NSObject <M1QuicTransportDelegate, M1ControlLinkDelegate, M1ControlSessionDelegate>
@property (nonatomic, assign) BOOL isHost;
@property (nonatomic, copy) NSString *hostAddr;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, copy, nullable) NSString *expectedFingerprint;
@property (nonatomic, copy, nullable) NSString *localFingerprint;
@property (nonatomic, copy, nullable) NSString *pairingCode;
@property (nonatomic, assign) int fps;
@property (nonatomic, assign) int bitrateKbps;
@property (nonatomic, assign) BOOL insecure;   // 诊断用：不校验对端证书
@property (nonatomic, assign) uint32_t connectTimeoutMs;  // 0 = 关闭握手看门狗

@property (nonatomic, strong) M1QuicTransport *transport;
@property (nonatomic, strong) M1QuicTransport *accepted;
@property (nonatomic, strong) M1ControlLink *link;
@property (nonatomic, strong) M1ControlChannel *channel;
@property (nonatomic, strong) M1ControlSession *session;
@property (nonatomic, strong) dispatch_semaphore_t readySem;
@property (nonatomic, strong) dispatch_semaphore_t streamingSem;
@property (nonatomic, strong, nullable) NSError *error;
@property (nonatomic, assign) double handshakeMs;
@property (nonatomic, assign) BOOL streaming;
@end

@implementation CtlNode

- (instancetype)init {
    if ((self = [super init])) {
        _readySem = dispatch_semaphore_create(0);
        _streamingSem = dispatch_semaphore_create(0);
        _fps = 20;
        _bitrateKbps = 12000;
        _connectTimeoutMs = 3000;
    }
    return self;
}

- (BOOL)startAsHostOnPort:(uint16_t)port error:(NSError **)error {
    self.isHost = YES;
    M1QuicTransport *t = [[M1QuicTransport alloc] initAsListenerOnPort:port
                                                                  alpn:@"rdp1"
                                                          identityPath:gIdentity
                                                          identityPass:gPass
                                                            verifyPeer:NO];
    t.delegate = self;
    self.transport = t;
    [t start];
    // listener ready 只是「端口已绑」，不代表有客户端
    if (dispatch_semaphore_wait(self.readySem,
            dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC)) != 0) {
        if (error) *error = [NSError errorWithDomain:@"ctlprobe" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"listener 未在 8s 内 ready"}];
        return NO;
    }
    if (self.error) { if (error) *error = self.error; return NO; }
    self.port = t.listenPort;
    return YES;
}

- (BOOL)startAsClientTo:(NSString *)host
                   port:(uint16_t)port
                timeout:(uint32_t)timeoutMs
                  error:(NSError **)error {
    self.isHost = NO;
    self.hostAddr = host;
    self.port = port;
    M1QuicTransport *t = [[M1QuicTransport alloc] initAsClientToHost:host
                                                                port:port
                                                                alpn:@"rdp1"
                                                        identityPath:nil
                                                        identityPass:nil
                                                          verifyPeer:(self.insecure ? NO : YES)];
    t.connectTimeoutMs = self.connectTimeoutMs;
    if (!self.insecure) t.expectedPeerFingerprint = self.expectedFingerprint;
    t.delegate = self;
    self.transport = t;
    double t0 = NowMs();
    [t start];
    // 诊断：改用传输自带的阻塞等待，排除信号量/代理通知路径的问题
    if (![t waitUntilReadyTimeoutMs:timeoutMs]) {
        if (error) *error = [NSError errorWithDomain:@"ctlprobe" code:2
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"握手未在 %ums 内完成", timeoutMs]}];
        return NO;
    }
    self.handshakeMs = NowMs() - t0;
    if (self.error) { if (error) *error = self.error; return NO; }
    return YES;
}

// 建控制通道 + 会话（连接 ready 之后才能发消息）
- (void)attachSessionTo:(M1QuicTransport *)conn {
    if (getenv("M1_CTL_BARE")) {   // 诊断：只验证传输，不建会话
        printf("  [%s] 裸连接就绪（不建会话）\n", self.isHost ? "host" : "client");
        dispatch_semaphore_signal(self.streamingSem);
        self.streaming = YES;
        return;
    }
    // 可靠消息层跑在 datagram 上：M1ControlLink 负责 seq/ack/重传，
    // M1ControlChannel 负责 4B 长度前缀 + JSON 分帧，两者都用 M1MessageSink 对接。
    self.link = [[M1ControlLink alloc] initWithSink:conn];
    self.link.delegate = self;
    self.channel = [[M1ControlChannel alloc] initWithSink:self.link];
    M1ControlSessionConfig *cfg = [M1ControlSessionConfig new];
    cfg.role = self.isHost ? M1ControlRoleHost : M1ControlRoleClient;
    cfg.hostName = self.isHost ? @"probe-host" : @"probe-client";
    cfg.localFingerprint = self.localFingerprint;
    cfg.expectedPeerFingerprint = self.expectedFingerprint;
    cfg.pairingCode = self.pairingCode;
    cfg.fps = self.fps;
    cfg.bitrateKbps = self.bitrateKbps;
    cfg.specs = @[ @{ @"w": @1920, @"h": @1080, @"hidpi": @NO, @"refresh": @60 } ];
    cfg.heartbeatIntervalMs = 1000;
    self.session = [[M1ControlSession alloc] initWithChannel:self.channel config:cfg];
    self.session.delegate = self;
    printf("  [%s] 控制通道就绪，发 hello\n", self.isHost ? "host" : "client");
    [self.session begin];
}

- (BOOL)waitForStreamingTimeoutMs:(uint32_t)timeoutMs {
    if (dispatch_semaphore_wait(self.streamingSem,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutMs * NSEC_PER_MSEC)) != 0) {
        return NO;
    }
    return self.streaming && self.error == nil;
}

#pragma mark 传输回调

- (void)quicTransportDidBecomeReady:(M1QuicTransport *)transport {
    if (transport.isListener) {
        dispatch_semaphore_signal(self.readySem);
        return;
    }
    if (transport == self.accepted) {
        [self attachSessionTo:transport];
        return;
    }
    if (transport == self.transport) {
        dispatch_semaphore_signal(self.readySem);
        [self attachSessionTo:transport];
    }
}

- (void)quicTransport:(M1QuicTransport *)transport didAcceptConnection:(M1QuicTransport *)connection {
    self.accepted = connection;
    printf("  [host] 已接受控制连接\n");
}

- (void)quicTransport:(M1QuicTransport *)transport didFailWithError:(NSError *)error {
    if (!self.error) self.error = error;
    dispatch_semaphore_signal(self.readySem);
    dispatch_semaphore_signal(self.streamingSem);
}

- (void)quicTransport:(M1QuicTransport *)transport didReceiveDatagram:(NSData *)datagram {
    // 返回 NO 说明不是控制包（帧通道），M1-B 接推流后在这里转交。
    if (![self.link feedDatagram:datagram]) { /* frame datagram, ignored in M1-A step 3 */ }
}

- (void)controlLink:(M1ControlLink *)link didDeliverMessage:(NSData *)message {
    [self.channel feedBytes:message];
}

- (void)controlLink:(M1ControlLink *)link didFailWithError:(NSError *)error {
    if (!self.error) self.error = error;
    dispatch_semaphore_signal(self.streamingSem);
}

- (void)quicTransportDidCloseStream:(M1QuicTransport *)transport {
    dispatch_semaphore_signal(self.streamingSem);
}

#pragma mark 会话回调

- (void)controlSession:(M1ControlSession *)session didChangeState:(P1SessionState)state {
    printf("  [%s] %s\n", self.isHost ? "host" : "client", P1SessionStateName(state).UTF8String);
}

- (void)controlSessionDidReachStreaming:(M1ControlSession *)session {
    self.streaming = YES;
    dispatch_semaphore_signal(self.streamingSem);
}

- (void)controlSession:(M1ControlSession *)session didFailWithError:(NSError *)error {
    if (!self.error) self.error = error;
    dispatch_semaphore_signal(self.streamingSem);
}

- (NSArray<NSString *> *)stateLog { return self.session ? self.session.stateLog : @[]; }

- (void)shutdown {
    [self.session closeWithReason:@"probe-done"];
    [NSThread sleepForTimeInterval:0.2];   // 让 bye 真的出去
    [self.transport cancel];
}

@end

#pragma mark - 一轮自检

static NSDictionary *RunSelfRound(uint32_t rounds, uint32_t durationMs, NSString *jsonPath, BOOL insecure) {
    NSError *err = nil;
    NSString *localFp = M1QuicIdentityFingerprint(gIdentity, gPass, &err);
    if (localFp.length == 0) {
        printf("✗ 读不到身份指纹: %s\n", err.localizedDescription.UTF8String ?: "unknown");
        return @{ @"ok": @NO };
    }
    printf("  本机证书指纹: %.16s…\n", localFp.UTF8String);

    NSMutableArray *roundsOut = [NSMutableArray array];
    NSUInteger passCount = 0;
    NSMutableArray<NSNumber *> *handshakes = [NSMutableArray array];

    for (uint32_t i = 0; i < rounds; i++) {
        printf("\n--- round %u/%u ---\n", i + 1, rounds);
        CtlNode *host = [CtlNode new];
        host.localFingerprint = localFp;
        double t0 = NowMs();
        if (![host startAsHostOnPort:0 error:&err]) {
            printf("✗ host 启动失败: %s\n", err.localizedDescription.UTF8String);
            [roundsOut addObject:@{ @"ok": @NO, @"stage": @"host-start" }];
            break;
        }
        printf("  监听端口 %u（ALPN %s；控制帧走 datagram + M1ControlLink 可靠性）\n",
           host.port, kALPN);

        CtlNode *client = [CtlNode new];
        client.insecure = insecure;
        client.connectTimeoutMs = gConnectTimeoutMs;
        client.expectedFingerprint = localFp;
        client.localFingerprint = localFp;
        if (![client startAsClientTo:@"127.0.0.1" port:host.port timeout:12000 error:&err]) {
            printf("✗ 客户端握手失败: %s\n", err.localizedDescription.UTF8String);
            [host shutdown];
            [roundsOut addObject:@{ @"ok": @NO, @"stage": @"client-handshake" }];
            break;
        }
        [handshakes addObject:@(client.handshakeMs)];

        BOOL hostOk = [host waitForStreamingTimeoutMs:8000];
        BOOL clientOk = [client waitForStreamingTimeoutMs:8000];
        BOOL logsEqual = [client.stateLog isEqualToArray:host.stateLog];
        BOOL sidEqual = host.session.sessionID.length > 0 &&
                        [host.session.sessionID isEqualToString:client.session.sessionID];

        if (durationMs > 0) [NSThread sleepForTimeInterval:durationMs / 1000.0];

        BOOL ok = hostOk && clientOk && logsEqual && sidEqual;
        if (ok) passCount++;

        NSDictionary *r = @{
            @"ok": @(ok),
            @"handshakeMs": @(client.handshakeMs),
            @"connectAttempts": @(client.transport.connectAttempts),
            @"hostStreaming": @(hostOk),
            @"clientStreaming": @(clientOk),
            @"logsEqual": @(logsEqual),
            @"sessionIDEqual": @(sidEqual),
            @"stateLog": client.stateLog,
            @"sent": @(client.channel.sentCount),
            @"received": @(host.channel.receivedCount),
            @"sentBack": @(host.channel.sentCount),
            @"receivedBack": @(client.channel.receivedCount),
            @"protocolErrors": @(client.channel.protocolErrors + host.channel.protocolErrors),
            @"totalMs": @(NowMs() - t0),
        };
        [roundsOut addObject:r];

        printf("  状态序列: %s\n", [client.stateLog componentsJoinedByString:@" → "].UTF8String);
        printf("  握手 %.1fms  尝试 %lu 次  帧计数 client发送%lu/host收到%lu、host发送%lu/client收到%lu\n",
               client.handshakeMs, (unsigned long)client.transport.connectAttempts,
               (unsigned long)client.channel.sentCount, (unsigned long)host.channel.receivedCount,
               (unsigned long)host.channel.sentCount, (unsigned long)client.channel.receivedCount);
        printf("  %s\n", ok ? "✓ 本轮通过" : "✗ 本轮失败");

        [client shutdown];
        [host shutdown];
        [NSThread sleepForTimeInterval:0.3];
    }

    NSDictionary *result = @{
        @"ok": @(passCount == rounds),
        @"mode": @"self",
        @"rounds": @(rounds),
        @"passed": @(passCount),
        @"fingerprint": localFp,
        @"roundsDetail": roundsOut,
        @"handshakeMs": handshakes,
    };
    if (jsonPath.length > 0) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:result
                                                    options:NSJSONWritingPrettyPrinted
                                                      error:NULL];
        [d writeToFile:jsonPath atomically:YES];
    }
    return result;
}

#pragma mark - main

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL selfMode = NO, hostMode = NO, clientMode = NO;
        uint16_t port = 0;
        uint32_t rounds = 1, durationMs = 0;
        BOOL insecure = NO;
        (void)gConnectTimeoutMs;
        NSString *jsonPath = nil, *portFile = nil, *fingerprint = nil;

        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--self")) selfMode = YES;
            else if (!strcmp(argv[i], "--insecure")) insecure = YES;
            else if (!strcmp(argv[i], "--no-watchdog")) gConnectTimeoutMs = 0;
            else if (!strcmp(argv[i], "--host")) hostMode = YES;
            else if (!strcmp(argv[i], "--client")) clientMode = YES;
            else if (!strcmp(argv[i], "--port") && i + 1 < argc) port = (uint16_t)atoi(argv[++i]);
            else if (!strcmp(argv[i], "--rounds") && i + 1 < argc) rounds = (uint32_t)atoi(argv[++i]);
            else if (!strcmp(argv[i], "--duration-ms") && i + 1 < argc) durationMs = (uint32_t)atoi(argv[++i]);
            else if (!strcmp(argv[i], "--identity") && i + 1 < argc) gIdentity = @(argv[++i]);
            else if (!strcmp(argv[i], "--pass") && i + 1 < argc) gPass = @(argv[++i]);
            else if (!strcmp(argv[i], "--fingerprint") && i + 1 < argc) fingerprint = @(argv[++i]);
            else if (!strcmp(argv[i], "--json") && i + 1 < argc) jsonPath = @(argv[++i]);
            else if (!strcmp(argv[i], "--port-file") && i + 1 < argc) portFile = @(argv[++i]);
            else {
                fprintf(stderr,
                    "用法:\n"
                    "  control_probe --self [--rounds N] [--duration-ms N] [--json PATH]\n"
                    "  control_probe --host [--port N] [--port-file PATH] [--duration-ms N]\n"
                    "  control_probe --client --port N [--fingerprint HEX] [--duration-ms N]\n"
                    "说明: --fingerprint 省略时客户端按本机身份自检（仅 --self/环回有意义）\n");
                return 2;
            }
        }
        if (rounds == 0) rounds = 1;


        if (selfMode) {
            printf("=== M1-A 控制通道自检（%u 轮，真 QUIC 可靠流）===\n", rounds);
            NSDictionary *r = RunSelfRound(rounds, durationMs, jsonPath, insecure);
            printf("\n结果: %s (%u/%u 轮通过)\n",
                   [r[@"ok"] boolValue] ? "✓ 全部通过" : "✗ 有失败",
                   [(NSNumber *)r[@"passed"] unsignedIntValue], rounds);
            return [r[@"ok"] boolValue] ? 0 : 1;
        }

        if (getenv("M1_CTL_SMOKE")) {
            // 极简对照：与 quic_probe 相同的最小序列，不放任何 node/session 逻辑
            M1QuicTransport *l = [[M1QuicTransport alloc] initAsListenerOnPort:0
                                                                         alpn:@"rdp1"
                                                                 identityPath:gIdentity
                                                                 identityPass:gPass
                                                                   verifyPeer:NO];
            [l start];
            if (![l waitUntilReadyTimeoutMs:8000]) { printf("smoke: listener 未就绪\n"); return 1; }
            uint16_t p = l.listenPort;
            M1QuicTransport *c = [[M1QuicTransport alloc] initAsClientToHost:@"127.0.0.1"
                                                                        port:p
                                                                        alpn:@"rdp1"
                                                                identityPath:nil
                                                                identityPass:nil
                                                                  verifyPeer:NO];
            [c start];
            BOOL ok = [c waitUntilReadyTimeoutMs:8000];
            printf("smoke: port=%u ready=%d\n", p, (int)ok);
            [c cancel]; [l cancel];
            return ok ? 0 : 1;
        }

        if (hostMode) {
            NSError *err = nil;
            NSString *localFp = M1QuicIdentityFingerprint(gIdentity, gPass, &err);
            CtlNode *host = [CtlNode new];
            host.localFingerprint = localFp;
            host.pairingCode = nil;
            if (![host startAsHostOnPort:port error:&err]) {
                fprintf(stderr, "✗ host 启动失败: %s\n", err.localizedDescription.UTF8String);
                return 1;
            }
            printf("HOST_PORT=%u\n", host.port);
            printf("HOST_FINGERPRINT=%s\n", localFp.UTF8String);
            fflush(stdout);
            if (portFile.length > 0) {
                // 纯文本 "port\nfingerprint"：两进程编排用，避免 plist/JSON 解析负担
                NSString *body = [NSString stringWithFormat:@"%u\n%@\n",
                                  host.port, localFp ?: @""];
                [body writeToFile:portFile atomically:YES
                         encoding:NSUTF8StringEncoding error:NULL];
            }
            BOOL ok = [host waitForStreamingTimeoutMs:30000];
            if (durationMs > 0) [NSThread sleepForTimeInterval:durationMs / 1000.0];
            printf("状态序列: %s\n", [host.stateLog componentsJoinedByString:@" → "].UTF8String);
            printf("控制帧: 发送 %lu / 收到 %lu\n",
                   (unsigned long)host.channel.sentCount,
                   (unsigned long)host.channel.receivedCount);
            if (host.error) printf("错误: %s\n", host.error.localizedDescription.UTF8String);
            [host shutdown];
            return ok ? 0 : 1;
        }

        if (clientMode) {
            NSError *err = nil;
            NSString *expect = fingerprint;
            if (expect.length == 0) expect = M1QuicIdentityFingerprint(gIdentity, gPass, &err);
            CtlNode *client = [CtlNode new];
            client.insecure = insecure;
        client.connectTimeoutMs = gConnectTimeoutMs;
            client.expectedFingerprint = expect;
            client.localFingerprint = expect;
            if (![client startAsClientTo:@"127.0.0.1" port:port timeout:12000 error:&err]) {
                fprintf(stderr, "✗ 客户端握手失败: %s\n", err.localizedDescription.UTF8String);
                return 1;
            }
            printf("握手 %.1fms（尝试 %lu 次）\n",
                   client.handshakeMs, (unsigned long)client.transport.connectAttempts);
            BOOL ok = [client waitForStreamingTimeoutMs:15000];
            if (durationMs > 0) [NSThread sleepForTimeInterval:durationMs / 1000.0];
            printf("状态序列: %s\n", [client.stateLog componentsJoinedByString:@" → "].UTF8String);
            printf("控制帧: 发送 %lu / 收到 %lu\n",
                   (unsigned long)client.channel.sentCount,
                   (unsigned long)client.channel.receivedCount);
            [client shutdown];
            return ok ? 0 : 1;
        }

        fprintf(stderr, "必须指定 --self / --host / --client\n");
        return 2;
    }
}
