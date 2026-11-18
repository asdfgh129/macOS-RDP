//
//  stream_probe.m
//  M1-Skeleton
//
//  M1-A 第 4 步验收：跨进程推流落盘。
//
//    host   : SCK 采集 → VT 编码 → M1FrameSender → QUIC datagram
//    client : QUIC datagram → M1FrameReceiver 重组 → VT 解码 → PNG
//
//  关键点（D-14 C-14.2）：控制帧与视频帧**共用同一条 datagram 连接**，靠首字节魔数分流：
//    0x43 'C'  → M1ControlLink（seq/ACK 自建可靠性）→ M1ControlChannel → M1ControlSession
//    0x4D 'M'  → 帧分片（P1FrameMagic = 0x4D52 'MR'）→ M1FrameReceiver
//  这条分流正是 M1-C 要验证的前提：推流时 1s 心跳不能被视频帧挤掉。
//
//  用法：
//    ./stream_probe --host [--port N] [--port-file PATH] [--duration-ms N]
//                     [--display ID] [--fps N] [--out JSON]
//    ./stream_probe --client --port N --fingerprint HEX [--duration-ms N]
//                     [--outdir DIR] [--save-frames N] [--out JSON]
//
//  验收判据：
//    1. 双端到达 STREAMING，且状态序列逐条一致
//    2. 客户端解出画面帧数 > 0，且 decoded/sent ≥ 0.9
//    3. 推流期间控制通道最大到达间隔 < 3s（心跳 1s，容许 3 倍抖动）
//    4. PNG 落盘可肉眼验
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import "M1QuicTransport.h"
#import "M1ControlLink.h"
#import "M1ControlChannel.h"
#import "M1ControlSession.h"
#import "M1FramePipeline.h"
#import "M1FrameReceiver.h"
#import "M1VideoEncoder.h"

static NSString *gIdentity = @".state/rdp-identity.p12";
static NSString *gPass = @"rdpdev";
static const char *kALPN = "rdp1";

static const uint8_t kMagicControl = 0x43;   // 'C'  M1ControlLink
static const uint8_t kMagicFrame   = 0x4D;   // 'M'  P1FrameMagic 首字节

static double NowMs(void) {
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

#pragma mark - 单端节点

@interface StreamNode : NSObject <M1QuicTransportDelegate, M1ControlLinkDelegate,
                                 M1ControlSessionDelegate, M1DatagramSink>

@property (nonatomic, assign) BOOL isHost;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, copy, nullable) NSString *expectedFingerprint;
@property (nonatomic, copy, nullable) NSString *localFingerprint;
@property (nonatomic, assign) int fps;
@property (nonatomic, assign) int bitrateKbps;

@property (nonatomic, strong, nullable) M1QuicTransport *listener;
@property (nonatomic, strong, nullable) M1QuicTransport *streamConn;   // 实际承载流量的连接
@property (nonatomic, strong, nullable) M1ControlLink *link;
@property (nonatomic, strong, nullable) M1ControlChannel *channel;
@property (nonatomic, strong, nullable) M1ControlSession *session;
@property (nonatomic, strong) dispatch_semaphore_t readySem;
@property (nonatomic, strong) dispatch_semaphore_t streamingSem;
@property (nonatomic, strong, nullable) NSError *error;
@property (nonatomic, assign) BOOL streaming;
@property (nonatomic, assign) double handshakeMs;
@property (nonatomic, assign) double streamStartMs;   // 进入 STREAMING 的时刻
@property (nonatomic, copy, nullable) void (^onSessionClosed)(void);

// 分流统计
@property (nonatomic, assign) uint64_t controlDatagrams;
@property (nonatomic, assign) uint64_t frameDatagrams;
@property (nonatomic, assign) uint64_t unroutedDatagrams;

// 控制通道到达间隔（判「推流是否挤掉心跳」）
@property (nonatomic, assign) double lastControlArrivalMs;
@property (nonatomic, assign) double maxControlGapMs;
@property (nonatomic, assign) double maxGapAtOffsetMs;    // 最大间隔出现在推流的第几毫秒
@property (nonatomic, strong) NSMutableArray<NSNumber *> *controlArrivals;  // 相对偏移

@end

@implementation StreamNode

- (instancetype)init {
    if ((self = [super init])) {
        _readySem = dispatch_semaphore_create(0);
        _streamingSem = dispatch_semaphore_create(0);
        _fps = 20;
        _bitrateKbps = 12000;
        _controlArrivals = [NSMutableArray array];
    }
    return self;
}

#pragma mark 启动

- (BOOL)startAsHostOnPort:(uint16_t)port error:(NSError **)error {
    self.isHost = YES;
    M1QuicTransport *t = [[M1QuicTransport alloc] initAsListenerOnPort:port
                                                                  alpn:@(kALPN)
                                                          identityPath:gIdentity
                                                          identityPass:gPass
                                                            verifyPeer:NO];
    t.delegate = self;
    self.listener = t;
    [t start];
    if (dispatch_semaphore_wait(self.readySem,
            dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC)) != 0) {
        if (error) *error = [NSError errorWithDomain:@"streamprobe" code:1
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
                                                                alpn:@(kALPN)
                                                        identityPath:nil
                                                        identityPass:nil
                                                          verifyPeer:YES];
    t.expectedPeerFingerprint = self.expectedFingerprint;
    t.delegate = self;
    self.streamConn = t;
    double t0 = NowMs();
    [t start];
    if (![t waitUntilReadyTimeoutMs:timeoutMs]) {
        if (error) *error = [NSError errorWithDomain:@"streamprobe" code:2
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"握手未在 %ums 内完成", timeoutMs]}];
        return NO;
    }
    self.handshakeMs = NowMs() - t0;
    if (self.error) { if (error) *error = self.error; return NO; }
    return YES;
}

- (void)attachSessionTo:(M1QuicTransport *)conn {
    self.streamConn = conn;
    self.link = [[M1ControlLink alloc] initWithSink:conn];
    self.link.delegate = self;
    self.channel = [[M1ControlChannel alloc] initWithSink:self.link];

    M1ControlSessionConfig *cfg = [M1ControlSessionConfig new];
    cfg.role = self.isHost ? M1ControlRoleHost : M1ControlRoleClient;
    cfg.hostName = self.isHost ? @"stream-host" : @"stream-client";
    cfg.localFingerprint = self.localFingerprint;
    cfg.expectedPeerFingerprint = self.expectedFingerprint;
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

#pragma mark M1DatagramSink（帧管线出口）

- (BOOL)sendDatagram:(NSData *)datagram error:(NSError **)error {
    M1QuicTransport *conn = self.streamConn;
    if (!conn) {
        if (error) *error = [NSError errorWithDomain:@"streamprobe" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"连接未就绪"}];
        return NO;
    }
    return [conn sendDatagram:datagram error:error];
}

#pragma mark 传输回调

- (void)quicTransportDidBecomeReady:(M1QuicTransport *)transport {
    if (transport == self.listener) {
        dispatch_semaphore_signal(self.readySem);
        return;
    }
    if (transport != self.streamConn) {
        // 服务端接受的入站连接
        dispatch_semaphore_signal(self.readySem);
    }
    [self attachSessionTo:transport];
}

- (void)quicTransport:(M1QuicTransport *)transport
   didAcceptConnection:(M1QuicTransport *)connection {
    printf("  [host] 已接受连接\n");
}

- (void)quicTransport:(M1QuicTransport *)transport didFailWithError:(NSError *)error {
    if (!self.error) self.error = error;
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

// 子类/使用方覆写：host 侧不需要重组，client 侧交给 M1FrameReceiver
- (void)onFrameDatagram:(NSData *)datagram {}

- (void)controlLink:(M1ControlLink *)link didDeliverMessage:(NSData *)message {
    double now = NowMs();
    if (self.lastControlArrivalMs > 0) {
        double gap = now - self.lastControlArrivalMs;
        if (gap > self.maxControlGapMs) {
            self.maxControlGapMs = gap;
            self.maxGapAtOffsetMs = self.streamStartMs > 0 ? now - self.streamStartMs : 0;
        }
    }
    self.lastControlArrivalMs = now;
    if (self.streamStartMs > 0 && self.controlArrivals.count < 256) {
        [self.controlArrivals addObject:@(round(now - self.streamStartMs))];
    }
    [self.channel feedBytes:message];
}

- (void)controlLink:(M1ControlLink *)link didFailWithError:(NSError *)error {
    if (!self.error) self.error = error;
    dispatch_semaphore_signal(self.streamingSem);
}

#pragma mark 会话回调

- (void)controlSession:(M1ControlSession *)session didChangeState:(P1SessionState)state {
    printf("  [%s] %s\n", self.isHost ? "host" : "client", P1SessionStateName(state).UTF8String);
    if (state == P1SessionStateClosed && self.onSessionClosed) self.onSessionClosed();
}

- (void)controlSessionDidReachStreaming:(M1ControlSession *)session {
    self.streaming = YES;
    if (self.streamStartMs == 0) self.streamStartMs = NowMs();
    dispatch_semaphore_signal(self.streamingSem);
}

- (void)controlSession:(M1ControlSession *)session didFailWithError:(NSError *)error {
    if (!self.error) self.error = error;
    dispatch_semaphore_signal(self.streamingSem);
}

- (NSArray<NSString *> *)stateLog { return self.session ? self.session.stateLog : @[]; }

- (void)shutdown {
    [self.session closeWithReason:@"probe-done"];
    [NSThread sleepForTimeInterval:0.25];   // 让 bye 真的出去
    [self.streamConn cancel];
    [self.listener cancel];
}

@end

#pragma mark - 客户端节点（带重组/解码）

@interface StreamClientNode : StreamNode

@property (nonatomic, strong) M1FrameReceiver *receiver;
@property (nonatomic, copy) NSString *outdir;
@property (nonatomic, assign) NSUInteger saveFrames;      // 保存前 N 帧
@property (nonatomic, assign) NSUInteger savedFrames;
@property (nonatomic, assign) NSUInteger reservedSaves;    // 已占用但尚未落盘的槽位
@property (nonatomic, strong) dispatch_queue_t saveQueue;  // PNG 编码专用串行队列
@property (nonatomic, strong) dispatch_queue_t frameQueue; // 重组+解码专用串行队列
@property (nonatomic, assign) uint64_t keyframeRequests;
@property (nonatomic, assign) double firstFrameMs;
@property (nonatomic, assign) double lastFrameMs;
@property (nonatomic, assign) uint32_t lastSavedSeq;
@property (nonatomic, assign) BOOL hasSavedSeq;
@property (nonatomic, assign) double maxAcceptBlockMs;     // 单次重组+解码入口的最长阻塞
@property (nonatomic, assign) double maxAcceptBlockAtMs;   // 出现在推流第几毫秒
@property (nonatomic, assign) int32_t decodedWidth;
@property (nonatomic, assign) int32_t decodedHeight;
@property (nonatomic, copy) NSMutableArray<NSString *> *savedPaths;

@end

@implementation StreamClientNode

- (instancetype)init {
    if ((self = [super init])) {
        _savedPaths = [NSMutableArray array];
        _saveFrames = 5;
        _saveQueue = dispatch_queue_create("m1.stream.png", DISPATCH_QUEUE_SERIAL);
        _frameQueue = dispatch_queue_create("m1.stream.frames", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)prepareReceiver {
    __weak typeof(self) weakSelf = self;
    self.receiver = [[M1FrameReceiver alloc]
        initWithOnFrame:^(CVPixelBufferRef pb, uint32_t frameSeq) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            double now = NowMs();
            if (self.firstFrameMs == 0) self.firstFrameMs = now;
            self.lastFrameMs = now;
            self.decodedWidth = (int32_t)CVPixelBufferGetWidth(pb);
            self.decodedHeight = (int32_t)CVPixelBufferGetHeight(pb);

            // PNG 编码必须离开接收/解码线程。
            //
            // VT 的输出回调可能就在调用线程上执行（不保证异步），而 CIContext + PNG
            // 编码一帧 1080p 要几十到几百毫秒。放在这里会直接堵住 nw_connection 的
            // 收包队列——实测 6 张 PNG 就让控制心跳断了 4.5s（见 RESULTS-BY-OS §5.7）。
            // 因此这里只做「占槽 + retain」，编码丢到独立串行队列。
            if (self.outdir.length > 0 && self.reservedSaves < self.saveFrames &&
                !(self.hasSavedSeq && frameSeq == self.lastSavedSeq)) {
                self.reservedSaves += 1;
                self.lastSavedSeq = frameSeq;
                self.hasSavedSeq = YES;
                CVPixelBufferRef held = CVPixelBufferRetain(pb);
                NSString *name = [NSString stringWithFormat:@"frame-%03u.png", frameSeq];
                NSString *path = [self.outdir stringByAppendingPathComponent:name];
                dispatch_async(self.saveQueue, ^{
                    if (M1SavePixelBufferPNG(held, path)) {
                        self.savedFrames += 1;
                        [self.savedPaths addObject:path];
                    }
                    CVPixelBufferRelease(held);
                });
            }
        }
        onNeedKeyframe:^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.keyframeRequests += 1;
        }];
}

// 等帧队列排空（否则统计偏小）
- (void)flushFrames {
    dispatch_sync(self.frameQueue, ^{});
}

// 等所有排队中的 PNG 编码完成（结果打印前必须调用，否则统计偏小）
- (void)flushSaves {
    dispatch_sync(self.saveQueue, ^{});
}

- (void)onFrameDatagram:(NSData *)datagram {
    // 绝不在这里做重组/解码。
    //
    // 这个回调跑在 nw_connection 的收包队列上，而首个关键帧要现场建 VT 解码会话
    // （实测单次 1092ms）。同步做的话控制包会全部排在后面——实测心跳断 1.5s，
    // 且首帧延迟被推到 3.5s。帧处理整体丢到独立串行队列，收包队列立刻返回。
    dispatch_async(self.frameQueue, ^{
        double t0 = NowMs();
        [self.receiver acceptDatagram:datagram error:NULL];
        double dt = NowMs() - t0;
        if (dt > self.maxAcceptBlockMs) {
            self.maxAcceptBlockMs = dt;
            self.maxAcceptBlockAtMs = self.streamStartMs > 0 ? t0 - self.streamStartMs : 0;
        }
    });
}


@end

#pragma mark - 主流程


// 诊断：把传输层 / 链路层统计和控制包到达时间线打出来。
// 「心跳是否被推流挤掉」只能靠这两组数据判断——单看最大间隔无法区分
// 「发送端就没发出去」和「发出去了但在链路上丢了」。
static void PrintFlowStats(StreamNode *n, const char *tag) {
    M1QuicTransportStats *ts = n.streamConn.stats;
    printf("  %s 传输: sent=%llu recv=%llu sendErr=%llu | 链路: sent=%lu delivered=%lu "
           "retrans=%lu dup=%lu ooo=%lu acks=%lu\n",
           tag, ts.datagramsSent, ts.datagramsReceived, ts.sendErrors,
           (unsigned long)n.link.sentMessages, (unsigned long)n.link.deliveredMessages,
           (unsigned long)n.link.retransmits, (unsigned long)n.link.duplicatesSeen,
           (unsigned long)n.link.heldOutOfOrder, (unsigned long)n.link.acksReceived);
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSNumber *v in n.controlArrivals) [parts addObject:v.stringValue];
    printf("  %s 控制到达(ms): %s\n", tag, [parts componentsJoinedByString:@","].UTF8String);
}

static void PrintUsage(void) {
    fprintf(stderr,
        "用法:\n"
        "  stream_probe --host [--port N] [--port-file PATH] [--duration-ms N]\n"
        "                    [--display ID] [--fps N] [--out JSON]\n"
        "  stream_probe --client --port N --fingerprint HEX [--duration-ms N]\n"
        "                    [--outdir DIR] [--save-frames N] [--out JSON]\n");
}

static NSData *JSONData(NSDictionary *dict) {
    return [NSJSONSerialization dataWithJSONObject:dict
                                           options:NSJSONWritingPrettyPrinted
                                             error:NULL];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);   // 后台运行 + 被回收时不丢日志
        BOOL hostMode = NO, clientMode = NO;
        uint16_t port = 0;
        NSString *portFile = nil;
        NSString *outPath = nil;
        NSString *outdir = nil;
        NSString *fingerprint = nil;
        int durationMs = 5000;
        int fps = 20;
        CGDirectDisplayID displayID = CGMainDisplayID();
        NSUInteger saveFrames = 5;
        double bpp = 0.12;
        int32_t outW = 0, outH = 0;

        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--host")) hostMode = YES;
            else if (!strcmp(argv[i], "--client")) clientMode = YES;
            else if (!strcmp(argv[i], "--port") && i + 1 < argc) port = (uint16_t)atoi(argv[++i]);
            else if (!strcmp(argv[i], "--port-file") && i + 1 < argc)
                portFile = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--duration-ms") && i + 1 < argc) durationMs = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--fps") && i + 1 < argc) fps = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--display") && i + 1 < argc)
                displayID = (CGDirectDisplayID)strtoul(argv[++i], NULL, 10);
            else if (!strcmp(argv[i], "--out") && i + 1 < argc)
                outPath = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--outdir") && i + 1 < argc)
                outdir = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--save-frames") && i + 1 < argc)
                saveFrames = (NSUInteger)atoi(argv[++i]);
            else if (!strcmp(argv[i], "--fingerprint") && i + 1 < argc)
                fingerprint = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--identity") && i + 1 < argc)
                gIdentity = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--pass") && i + 1 < argc)
                gPass = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--bpp") && i + 1 < argc) bpp = atof(argv[++i]);
            else if (!strcmp(argv[i], "--width") && i + 1 < argc) outW = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--height") && i + 1 < argc) outH = atoi(argv[++i]);
            else { PrintUsage(); return 1; }
        }
        if (!hostMode && !clientMode) { PrintUsage(); return 1; }

        // 进程级 VT 预热：与后面的握手并发进行。首次会话初始化实测 0.3~1.5s，
        // 不预热就整段压在首帧延迟上。按角色只预热本端要用的那一侧，
        // 避免主机/客户端两个方向混在一起测不出各自收益。
        // 用 UTILITY：预热本身不急，不能和握手/首帧采集抢 CPU（i5 上实测会反噬）。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (hostMode) [M1VideoEncoder prewarm];
            else          [M1FrameReceiver prewarmDecoder];
        });

        if (hostMode) {
            NSError *err = nil;
            NSString *localFp = M1QuicIdentityFingerprint(gIdentity, gPass, &err);
            if (localFp.length == 0) {
                printf("✗ 读不到身份指纹: %s\n",
                       err.localizedDescription.UTF8String ?: "unknown");
                return 3;
            }

            StreamNode *host = [StreamNode new];
            host.localFingerprint = localFp;
            host.fps = fps;

            if (![host startAsHostOnPort:port error:&err]) {
                printf("✗ listener 启动失败: %s\n", err.localizedDescription.UTF8String);
                return 3;
            }
            printf("host 监听端口 %u\n", host.port);
            printf("  证书指纹 %s\n", localFp.UTF8String);

            if (portFile.length > 0) {
                NSString *payload = [NSString stringWithFormat:@"%u\n%@\n", host.port, localFp];
                [payload writeToFile:portFile atomically:YES
                            encoding:NSUTF8StringEncoding error:NULL];
            }

            printf("等待客户端接入…\n");
            if (![host waitForStreamingTimeoutMs:15000]) {
                printf("✗ 15s 内未进入 STREAMING: %s\n",
                       host.error.localizedDescription.UTF8String ?: "无客户端");
                return 4;
            }
            printf("双端已 STREAMING，开始推流（%d ms / %d fps）\n", durationMs, fps);

            M1FramePipelineConfig *cfg = [M1FramePipelineConfig new];
            cfg.targetFps = fps;
            cfg.bitsPerPixel = bpp;
            cfg.outputWidth = outW;
            cfg.outputHeight = outH;
            __block int errCount = 0;
            M1FramePipeline *pipe =
                [[M1FramePipeline alloc] initWithDisplayID:displayID
                                                    config:cfg
                                                      sink:host
                                                   onError:^(NSError *e) {
                    errCount += 1;
                    if (errCount <= 3) printf("  [管线错误] %s\n",
                                              e.localizedDescription.UTF8String);
                }];
            if (![pipe start:&err]) {
                printf("✗ 管线启动失败: %s\n", err.localizedDescription.UTF8String);
                [host shutdown];
                return 5;
            }
            printf("  采集尺寸 %dx%d\n", pipe.pixelWidth, pipe.pixelHeight);

            // 对端 bye 之后立即停管线：否则继续往死连接投递，只会把 sendFailures 刷大。
            __block BOOL stopped = NO;
            host.onSessionClosed = ^{
                if (stopped) return;
                stopped = YES;
                printf("  [host] 对端关闭会话，停止推流\n");
                [pipe stop];
            };

            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:durationMs / 1000.0];
            double pipelineStartMs = NowMs();
            double firstSentMs = 0;
            while (!stopped && [deadline timeIntervalSinceNow] > 0) {
                if (firstSentMs == 0 && pipe.nextFrameSeq > 0) {
                    firstSentMs = NowMs();
                    printf("  首帧发出：管线启动后 %.0f ms（采集首帧 %.0f ms）\n",
                           firstSentMs - pipelineStartMs, pipe.stats.firstFrameLatencyMs);
                }
                [NSThread sleepForTimeInterval:0.01];
            }
            [pipe stop];

            M1FramePipelineStats *ps = pipe.stats;
            printf("\n--- host 结果 ---\n");
            printf("  %s\n", ps.summary.UTF8String);
            printf("  实际尺寸 %dx%d  nextFrameSeq=%u\n",
                   pipe.pixelWidth, pipe.pixelHeight, pipe.nextFrameSeq);
            printf("  控制包 %llu / 帧包 %llu / 未分流 %llu\n",
                   host.controlDatagrams, host.frameDatagrams, host.unroutedDatagrams);
            printf("  控制通道最大到达间隔 %.0f ms（出现在推流 %.0f ms 处）\n",
                   host.maxControlGapMs, host.maxGapAtOffsetMs);
            PrintFlowStats(host, "host");
            printf("  状态序列: %s\n", [host.stateLog componentsJoinedByString:@" → "].UTF8String);

            NSMutableDictionary *json = [NSMutableDictionary dictionary];
            json[@"role"] = @"host";
            json[@"port"] = @(host.port);
            json[@"streaming"] = @(host.streaming);
            json[@"stateLog"] = host.stateLog;
            json[@"pixelWidth"] = @(pipe.pixelWidth);
            json[@"pixelHeight"] = @(pipe.pixelHeight);
            json[@"framesSent"] = @(ps.framesSent);
            json[@"framesEncoded"] = @(ps.framesEncoded);
            json[@"framesCaptured"] = @(ps.framesCaptured);
            json[@"fragmentsSent"] = @(ps.fragmentsSent);
            json[@"payloadBytes"] = @(ps.payloadBytesSent);
            json[@"keyframes"] = @(ps.keyframes);
            json[@"sendFailures"] = @(ps.sendFailures);
            json[@"controlDatagrams"] = @(host.controlDatagrams);
            json[@"frameDatagrams"] = @(host.frameDatagrams);
            json[@"maxControlGapMs"] = @(round(host.maxControlGapMs));
            if (outPath.length > 0) {
                NSData *d = JSONData(json);
                if (d) [d writeToFile:outPath atomically:YES];
            }
            [host shutdown];
            return (ps.framesSent > 0) ? 0 : 2;
        }

        // ---- client ----
        if (port == 0 || fingerprint.length == 0) {
            fprintf(stderr, "✗ --client 需要 --port 与 --fingerprint\n");
            return 1;
        }
        if (outdir.length == 0) {
            outdir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"m1-stream-%d", (int)getpid()]];
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:outdir
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:NULL];

        StreamClientNode *client = [StreamClientNode new];
        client.expectedFingerprint = fingerprint;
        client.fps = fps;
        client.outdir = outdir;
        client.saveFrames = saveFrames;
        [client prepareReceiver];

        NSError *err = nil;
        if (![client startAsClientTo:@"127.0.0.1" port:port timeout:12000 error:&err]) {
            printf("✗ 握手失败: %s\n", err.localizedDescription.UTF8String);
            return 3;
        }
        printf("握手完成 %.1f ms\n", client.handshakeMs);
        if (![client waitForStreamingTimeoutMs:15000]) {
            printf("✗ 15s 内未进入 STREAMING: %s\n",
                   client.error.localizedDescription.UTF8String ?: "unknown");
            return 4;
        }
        printf("已 STREAMING，接收 %d ms\n", durationMs);
        [NSThread sleepForTimeInterval:durationMs / 1000.0];

        [client flushFrames];
        [client flushSaves];
        M1FrameReceiverStats *rs = client.receiver.stats;
        double recvSpan = (client.lastFrameMs > client.firstFrameMs)
                          ? (client.lastFrameMs - client.firstFrameMs) : 0;
        double decodeFps = (recvSpan > 0) ? (rs.framesDecoded - 1) / (recvSpan / 1000.0) : 0;

        printf("\n--- client 结果 ---\n");
        printf("  receiver: datagrams=%llu completed=%llu decoded=%llu dropped=%llu "
               "decodeFail=%llu keyReq=%llu malformed=%llu\n",
               rs.datagramsReceived, rs.framesCompleted, rs.framesDecoded,
               rs.framesDropped, rs.decodeFailures, rs.keyframeRequests,
               rs.malformedDatagrams);
        double firstFrameLatency = (client.firstFrameMs > 0 && client.streamStartMs > 0)
            ? client.firstFrameMs - client.streamStartMs : 0;
        printf("  解码尺寸 %dx%d  解码帧率 %.1f fps  首帧延迟 %.0f ms\n",
               client.decodedWidth, client.decodedHeight, decodeFps, firstFrameLatency);
        printf("  解码器：进程预热 %.0f ms，真实建会话 %.0f ms\n",
               rs.decoderPrewarmMs, rs.decoderCreateMs);
        printf("  控制包 %llu / 帧包 %llu / 未分流 %llu\n",
               client.controlDatagrams, client.frameDatagrams, client.unroutedDatagrams);
        printf("  帧队列单次处理最长 %.0f ms（推流 %.0f ms 处）\n",
               client.maxAcceptBlockMs, client.maxAcceptBlockAtMs);
        printf("  控制通道最大到达间隔 %.0f ms（出现在推流 %.0f ms 处）\n",
               client.maxControlGapMs, client.maxGapAtOffsetMs);
        PrintFlowStats(client, "client");
        printf("  状态序列: %s\n", [client.stateLog componentsJoinedByString:@" → "].UTF8String);
        printf("  已保存 PNG %lu 张 → %s\n",
               (unsigned long)client.savedPaths.count, outdir.UTF8String);
        for (NSString *p in client.savedPaths) printf("    %s\n", p.lastPathComponent.UTF8String);

        NSMutableDictionary *json = [NSMutableDictionary dictionary];
        json[@"role"] = @"client";
        json[@"streaming"] = @(client.streaming);
        json[@"stateLog"] = client.stateLog;
        json[@"handshakeMs"] = @(round(client.handshakeMs * 10) / 10.0);
        json[@"datagrams"] = @(rs.datagramsReceived);
        json[@"framesCompleted"] = @(rs.framesCompleted);
        json[@"framesDecoded"] = @(rs.framesDecoded);
        json[@"framesDropped"] = @(rs.framesDropped);
        json[@"decodeFailures"] = @(rs.decodeFailures);
        json[@"keyframeRequests"] = @(rs.keyframeRequests);
        json[@"malformed"] = @(rs.malformedDatagrams);
        json[@"decodedWidth"] = @(client.decodedWidth);
        json[@"decodedHeight"] = @(client.decodedHeight);
        json[@"decodeFps"] = @(round(decodeFps * 10) / 10.0);
        json[@"firstFrameLatencyMs"] = @(round(firstFrameLatency));
        json[@"decoderPrewarmMs"] = @(round(rs.decoderPrewarmMs));
        json[@"decoderCreateMs"] = @(round(rs.decoderCreateMs));
        json[@"controlDatagrams"] = @(client.controlDatagrams);
        json[@"frameDatagrams"] = @(client.frameDatagrams);
        json[@"maxControlGapMs"] = @(round(client.maxControlGapMs));
        json[@"maxGapAtOffsetMs"] = @(round(client.maxGapAtOffsetMs));
        json[@"controlArrivals"] = client.controlArrivals;
        json[@"savedPNGs"] = @(client.savedPaths.count);
        json[@"outdir"] = outdir;
        if (outPath.length > 0) {
            NSData *d = JSONData(json);
            if (d) [d writeToFile:outPath atomically:YES];
        }

        NSString *verdict = @"FAIL";
        NSMutableArray *notes = [NSMutableArray array];
        if (!client.streaming) [notes addObject:@"未到 STREAMING"];
        if (rs.framesDecoded == 0) [notes addObject:@"没解出任何画面"];
        if (client.savedPaths.count == 0) [notes addObject:@"没有 PNG 落盘"];
        if (client.maxControlGapMs > 3000) {
            [notes addObject:[NSString stringWithFormat:@"控制通道最大间隔 %.0fms 超 3s（疑似被推流挤掉）",
                              client.maxControlGapMs]];
        }
        if (client.unroutedDatagrams > 0) {
            [notes addObject:[NSString stringWithFormat:@"%llu 个包魔数不认识",
                              client.unroutedDatagrams]];
        }
        if (notes.count == 0) verdict = @"PASS";
        printf("  判定: %s\n", verdict.UTF8String);
        for (NSString *n in notes) printf("    · %s\n", n.UTF8String);

        [client shutdown];
        return [verdict isEqualToString:@"PASS"] ? 0 : 2;
    }
}
