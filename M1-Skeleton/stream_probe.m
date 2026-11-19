//
//  stream_probe.m
//  M1-Skeleton
//
//  M1-A 第 4 步验收 + M1-B 第 1 步：跨进程推流落盘 / 上屏 + 输入回传。
//
//    host   : SCK 采集 → VT 编码 → M1FrameSender → QUIC datagram
//             ← input 事件 → M1InjectionPlan → M1InputInjector（record/real）
//    client : QUIC datagram → M1FrameReceiver 重组 → VT 解码 → PNG / 窗口上屏
//             窗口鼠标键盘 → 归一化 → input 事件 → 控制通道
//
//  关键点（D-14 C-14.2）：控制帧与视频帧**共用同一条 datagram 连接**，靠首字节魔数分流：
//    0x43 'C'  → M1ControlLink（seq/ACK 自建可靠性）→ M1ControlChannel → M1ControlSession
//    0x4D 'M'  → 帧分片（P1FrameMagic = 0x4D52 'MR'）→ M1FrameReceiver
//  这条分流正是 M1-C 要验证的前提：推流时 1s 心跳不能被视频帧挤掉。
//
//  用法：
//    ./stream_probe --host [--port N] [--port-file PATH] [--duration-ms N]
//                     [--display ID] [--fps N] [--inject record|real] [--out JSON]
//    ./stream_probe --client --port N --fingerprint HEX [--duration-ms N]
//                     [--outdir DIR] [--save-frames N] [--window [WxH]]
//                     [--port-file PATH] [--out JSON]
//
//    --window  : 起 NSWindow 把解码帧直接画到屏幕上，并采集鼠标/键盘回传 Host。
//    --inject  : record（默认，只记录注入计划，单机环回不干扰真实桌面）
//                real  （真 CGEventPost，双机验收用）
//
//  验收判据：
//    1. 双端到达 STREAMING，且状态序列逐条一致
//    2. 客户端解出画面帧数 > 0，且 decoded/sent ≥ 0.9
//    3. 推流期间控制通道最大到达间隔 < 3s（心跳 1s，容许 3 倍抖动）
//    4. PNG 落盘可肉眼验
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import "ProtocolCodec.h"
#import "M1QuicTransport.h"
#import "M1ControlLink.h"
#import "M1ControlChannel.h"
#import "M1ControlSession.h"
#import "M1FramePipeline.h"
#import "M1FrameReceiver.h"
#import "M1VideoEncoder.h"
#import "M1FrameView.h"
#import "M1InputInjector.h"

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
// Host 侧：收到客户端输入事件（已在 M1ControlSession 过校验与限速）。
@property (nonatomic, copy, nullable) void (^onInputEvent)(NSDictionary *event);

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
    // 收包在传输队列、打印在主线程：不加锁会撞上「枚举中修改」直接崩进程
    // （双机跑得快，收尾打印时正好还有心跳/bye 在进来，已实测崩过一次）。
    @synchronized (self.controlArrivals) {
        if (self.streamStartMs > 0 && self.controlArrivals.count < 256) {
            [self.controlArrivals addObject:@(round(now - self.streamStartMs))];
        }
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

- (void)controlSession:(M1ControlSession *)session didReceiveInputEvent:(NSDictionary *)event {
    if (self.onInputEvent) self.onInputEvent(event);
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
// 每一帧解码结果的直通出口（窗口上屏用）。在帧队列上回调，实现方需自行切线程。
@property (nonatomic, copy, nullable) void (^onPixelBuffer)(CVPixelBufferRef pb, uint32_t frameSeq);
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
            // 上屏：M1FrameView 内部自己 Retain + 转线程，这里直接递过去
            if (self.onPixelBuffer) self.onPixelBuffer(pb, frameSeq);

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
    NSArray<NSNumber *> *arrivals;
    @synchronized (n.controlArrivals) { arrivals = [n.controlArrivals copy]; }
    for (NSNumber *v in arrivals) [parts addObject:v.stringValue];
    printf("  %s 控制到达(ms): %s\n", tag, [parts componentsJoinedByString:@","].UTF8String);
}

// ---- P2 双机对接：本机能力自检 ----
// 为什么放在 stream_probe 里而不是单独写个工具：屏幕录制与辅助功能授权是按
// 「可执行文件的 code requirement」记的，换一个二进制查出来的结果不代表本二进制
// （已踩过：同一份源码重建后 AX 从 1 变 0）。所以必须由真正干活的那个进程自查。

// 本机可对接的 IPv4（排除回环与 169.254 自分配地址）。
static NSArray<NSString *> *P2LANAddresses(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    struct ifaddrs *head = NULL;
    if (getifaddrs(&head) != 0) return out;
    for (struct ifaddrs *p = head; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        if (!(p->ifa_flags & IFF_UP) || (p->ifa_flags & IFF_LOOPBACK)) continue;
        char buf[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *sin = (struct sockaddr_in *)p->ifa_addr;
        if (!inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) continue;
        NSString *ip = [NSString stringWithUTF8String:buf];
        if ([ip hasPrefix:@"169.254."]) continue;   // 自分配地址，跨机基本连不通
        [out addObject:[NSString stringWithFormat:@"%@(%s)", ip, p->ifa_name]];
    }
    freeifaddrs(head);
    return out;
}

// 返回 0 = 就绪。输出 `[preflight] k=v` 行，脚本只认最后那行 ok=。
static int P2RunPreflight(NSString *role, BOOL needAX) {
    BOOL ax = AXIsProcessTrusted();
    BOOL capture = CGPreflightScreenCaptureAccess();
    uint32_t activeCount = 0;
    CGGetActiveDisplayList(0, NULL, &activeCount);

    CFDictionaryRef sess = CGSessionCopyCurrentDictionary();
    NSDictionary *sd = (__bridge_transfer NSDictionary *)sess;
    BOOL locked = [sd[@"CGSSessionScreenIsLocked"] boolValue];
    BOOL onConsole = sd.count > 0 && [sd[@"kCGSSessionOnConsoleKey"] boolValue];
    BOOL asleep = CGDisplayIsAsleep(CGMainDisplayID());

    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    if (!onConsole) [fails addObject:@"不在控制台 GUI 会话（SSH 里跑不了采集/上屏）"];
    if (locked)     [fails addObject:@"屏幕已锁定：SCK 拿不到 display，窗口也收不到输入"];
    if (asleep)     [fails addObject:@"显示器已睡眠：先 caffeinate -d -u"];
    if (activeCount == 0) [fails addObject:@"没有 active 显示器"];
    if ([role isEqualToString:@"host"]) {
        if (!capture) [fails addObject:@"缺屏幕录制授权（系统设置→隐私与安全性→屏幕录制）"];
        if (needAX && !ax) [fails addObject:@"缺辅助功能授权（--inject real 需要）"];
    }

    printf("[preflight] role=%s\n", role.UTF8String);
    printf("[preflight] ax=%d capture=%d locked=%d asleep=%d onConsole=%d active=%u\n",
           (int)ax, (int)capture, (int)locked, (int)asleep, (int)onConsole, activeCount);
    printf("[preflight] proto frameHeaderVersion=%u headerSize=%lu maxPayload=%lu\n",
           (unsigned)P1FrameHeaderVersion, (unsigned long)P1FrameHeaderSize,
           (unsigned long)P1FrameMaxPayload);
    for (NSString *ip in P2LANAddresses()) printf("[preflight] ip=%s\n", ip.UTF8String);
    for (NSString *f in fails) printf("[preflight] fail=%s\n", f.UTF8String);
    printf("[preflight] ok=%d\n", fails.count == 0 ? 1 : 0);
    return fails.count == 0 ? 0 : 1;
}

static void PrintUsage(void) {
    fprintf(stderr,
        "用法:\n"
        "  stream_probe --host [--port N] [--port-file PATH] [--duration-ms N]\n"
        "                    [--display ID] [--fps N] [--out JSON]\n"
        "  stream_probe --preflight host|client [--inject real]   # 本机能力自检\n"
        "  stream_probe --client --connect IP --port N --fingerprint HEX [--duration-ms N]\n"
        "                    [--outdir DIR] [--save-frames N] [--out JSON]\n"
        "                    [--window [WxH]] [--keep-front] [--input-synth \"X,Y;X,Y;...\"]\n"
        "                    [--manual SECS]\n"
        "  --input-synth: 进程内合成鼠标移动（内容坐标，左上原点），\n"
        "                 用于驱动端没有辅助功能授权、无法投递系统事件时。\n"
        "  --manual:      不造事件，改为给出「立刻动鼠标」的提示（响铃 3 声 + 窗口标题 +\n"
        "                 倒计时日志），由真人去操作，SECS 秒后提示停手。\n");
}

// 手动驱动提示：自动化里驱动不了「真人动鼠标」这一跳——真光标要么被前台应用抢走，
// 要么打进 letterbox 黑边。这里反过来：代码只负责给出无歧义的开始/结束信号，
// 由人真的去操作。信号三路冗余（响铃 / 窗口标题 / 日志）：操作的人可能在看窗口
// 而不看终端，也可能终端被滚屏淹没。
static void M1StartManualCue(NSWindow *win, M1FrameView *view,
                             M1ControlSession *session, int secs) {
    static BOOL started = NO;
    if (started || secs <= 0 || !win || !view) return;  // 首帧回调与兜底定时器都会调，只认第一次
    started = YES;

    for (int i = 0; i < 3; i++) NSBeep();
    win.title = [NSString stringWithFormat:
                 @"▶▶ 现在动鼠标：点一下窗口，在画面里左右划 %d 秒", secs];
    printf("\n[manual] ================ 开始：现在动鼠标 ================\n");
    printf("[manual] ① 先点一下这个客户端窗口（要它成为前台应用，否则系统不投递移动事件）\n");
    printf("[manual] ② 在画面区域里左右慢慢划，别停在上下黑边上\n");
    printf("[manual] ③ %d 秒后自动结束（再响一声），窗口标题里有倒计时\n", secs);
    printf("[manual] =====================================================\n");
    fflush(stdout);

    for (int s = 1; s <= secs; s++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            int left = secs - s;
            // 实测反应延迟有 7s 左右（第一轮 18s 里前 7s 采集一直是 0 条）：
            // 一条都没收到就每 5 秒再提醒一次，别让人错过那三声。
            BOOL idle = (view.inputEventsEmitted == 0);
            if (idle && left > 0 && (s % 5) == 0) {
                NSBeep(); NSBeep();
                printf("[manual] （还没收到任何移动——点一下窗口，在里面划两下）\n");
            }
            win.title = [NSString stringWithFormat:@"%@▶▶ 动鼠标（剩 %d 秒）· 已采集 %lu 条",
                         idle ? @"？" : @"", left, (unsigned long)view.inputEventsEmitted];
            printf("[manual] 剩 %2d 秒 · 窗口采集 %lu 条 · 已上行 %lu 条\n", left,
                   (unsigned long)view.inputEventsEmitted,
                   (unsigned long)session.inputEventsSent);
            fflush(stdout);
            if (left <= 0) {
                NSBeep();
                win.title = @"✓ 时间到，可以停手了（等收尾统计）";
                printf("[manual] ================ 时间到，停手 ================\n");
                fflush(stdout);
            }
        });
    }
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
        BOOL windowMode = NO;
        double windowW = 1280, windowH = 720;
        NSString *injectMode = nil;   // nil / record / real
        NSString *synthSpec = nil;    // "X,Y;X,Y" 内容坐标（左上原点）
        BOOL windowTop = NO;
        BOOL keepFront = NO;
        int manualSecs = 0;           // >0：不造事件，改为提示真人动鼠标 SECS 秒
        NSString *connectHost = @"127.0.0.1";   // 双机时改成对端的局域网地址
        NSString *preflightRole = nil;          // host / client：只做本机能力自检后退出

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
            else if (!strcmp(argv[i], "--inject") && i + 1 < argc)
                injectMode = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--input-synth") && i + 1 < argc)
                synthSpec = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--manual") && i + 1 < argc)
                manualSecs = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--connect") && i + 1 < argc)
                connectHost = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--preflight")) {
                preflightRole = (i + 1 < argc && argv[i + 1][0] != '-')
                              ? [NSString stringWithUTF8String:argv[++i]] : @"host";
            }
            else if (!strcmp(argv[i], "--keep-front")) {
                // 自动化验证用：WindowServer 只把 mouseMoved 投给「前台应用」，
                // 窗口 visible/key/active 全 1 也可能被别的 App 抢回前台
                // （实测脚本跑的时候 frontmost=Chrome，一条 move 都收不到）。
                keepFront = YES;
            }
            else if (!strcmp(argv[i], "--window-top")) {
                // 自动化验证用：把客户端窗口抬到浮动层，避免测试期间被别的
                // 应用窗口盖住——窗口一旦被遮，WindowServer 就不投递 mouseMoved。
                windowTop = YES;
            }
            else if (!strcmp(argv[i], "--window")) {
                windowMode = YES;
                // 可选 --window 1600x900；不给就 1280x720。
                if (i + 1 < argc && strchr(argv[i + 1], 'x') && isdigit(argv[i + 1][0])) {
                    int w = 0, h = 0;
                    if (sscanf(argv[++i], "%dx%d", &w, &h) == 2 && w > 0 && h > 0) {
                        windowW = w; windowH = h;
                    }
                }
            }
            else { PrintUsage(); return 1; }
        }
        if (preflightRole) {
            return P2RunPreflight(preflightRole, [injectMode isEqualToString:@"real"]);
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
            // 双机对接要人工把这三项抄到另一台机器上，单独打一块免得漏。
            printf("\n===== 给客户端的三项 =====\n");
            NSArray<NSString *> *ips = P2LANAddresses();
            printf("  IP   : %s\n", ips.count ? ips.firstObject.UTF8String
                                              : "（没有局域网 IPv4，只有回环）");
            if (ips.count > 1) {
                printf("  其他 : ");
                for (NSUInteger k = 1; k < ips.count; k++)
                    printf("%s ", ips[k].UTF8String);
                printf("\n");
            }
            printf("  端口 : %u\n", host.port);
            printf("  指纹 : %s\n", localFp.UTF8String);
            printf("=========================\n\n");

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

            // ---- 输入回传（M1-B）----
            // record 是默认档：单机环回时 Host 和 Client 是同一个桌面，
            // 真注入会把光标从这个窗口移走、甚至点中别的 app，验证反而失真。
            M1RecordingEventSink *recorder = nil;
            M1InputInjector *injector = nil;
            __block NSUInteger injectFails = 0;
            __block NSUInteger injectOK = 0;
            // 真注入时用光标位移证明「主机真的被动了」，不是只收到了计划。
            CGPoint cursorStart = CGPointZero, cursorEnd = CGPointZero;
            {
                CGEventRef c = CGEventCreate(NULL);
                if (c) { cursorStart = CGEventGetLocation(c); CFRelease(c); }
            }
            if (injectMode.length > 0) {
                id<M1EventSink> sink = nil;
                if ([injectMode isEqualToString:@"real"]) {
                    sink = [M1CGEventSink new];
                } else if ([injectMode isEqualToString:@"record"]) {
                    recorder = [M1RecordingEventSink new];
                    sink = recorder;
                } else {
                    printf("✗ 未知 --inject 模式：%s（只支持 record / real）\n",
                           injectMode.UTF8String);
                    [pipe stop];
                    [host shutdown];
                    return 1;
                }
                // 目标 rect 用被采集那块屏的 Quartz bounds：
                // CGDisplayBounds 的原点在主屏左上、y 向下，与协议 y=0 在上一致。
                CGRect targetRect = CGDisplayBounds(displayID);
                injector = [[M1InputInjector alloc] initWithSink:sink];
                injector.targetDisplayRect = targetRect;
                host.onInputEvent = ^(NSDictionary *event) {
                    NSError *injErr = nil;
                    if (![injector injectEvent:event error:&injErr]) injectFails += 1;
                    else injectOK += 1;
                };
                printf("  输入注入 %s，目标 rect=(%.0f,%.0f %.0fx%.0f)\n",
                       injectMode.UTF8String, targetRect.origin.x, targetRect.origin.y,
                       targetRect.size.width, targetRect.size.height);
            } else {
                printf("  输入注入未启用（--inject record|real 可开启）\n");
            }

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
            if (injectMode.length > 0) {
                M1ControlSession *hs = host.session;
                printf("  输入：收到 %lu / 丢弃 %lu / 拒绝 %lu / 注入失败 %lu"
                       "（注入计划 %lu 条）\n",
                       (unsigned long)hs.inputEventsReceived,
                       (unsigned long)hs.inputEventsDropped,
                       (unsigned long)hs.inputEventsRejected,
                       (unsigned long)injectFails,
                       (unsigned long)recorder.postCount);
                CGEventRef c1 = CGEventCreate(NULL);
                if (c1) { cursorEnd = CGEventGetLocation(c1); CFRelease(c1); }
                printf("  注入成功 %lu 次；光标 (%.0f,%.0f) → (%.0f,%.0f)，位移 %.0f px\n",
                       (unsigned long)injectOK,
                       cursorStart.x, cursorStart.y, cursorEnd.x, cursorEnd.y,
                       hypot(cursorEnd.x - cursorStart.x, cursorEnd.y - cursorStart.y));
                NSArray<NSDictionary *> *plans = recorder.plans;
                NSUInteger show = MIN(plans.count, (NSUInteger)6);
                for (NSUInteger i = 0; i < show; i++) {
                    NSDictionary *pl = plans[i];
                    if ([pl[@"kind"] isEqualToString:@"mouse"]) {
                        printf("    #%lu mouse %s %s @ (%.0f, %.0f)\n",
                               (unsigned long)i + 1,
                               [pl[@"button"] UTF8String], [pl[@"action"] UTF8String],
                               [pl[@"x"] doubleValue], [pl[@"y"] doubleValue]);
                    } else if ([pl[@"kind"] isEqualToString:@"key"]) {
                        printf("    #%lu key keyCode=%d unicode=%s\n",
                               (unsigned long)i + 1,
                               [pl[@"keyCode"] intValue],
                               [pl[@"unicode"] UTF8String] ?: "");
                    } else if ([pl[@"kind"] isEqualToString:@"scroll"]) {
                        printf("    #%lu scroll dx=%.1f dy=%.1f\n",
                               (unsigned long)i + 1,
                               [pl[@"dx"] doubleValue], [pl[@"dy"] doubleValue]);
                    } else {
                        printf("    #%lu flags=0x%llx\n", (unsigned long)i + 1,
                               [pl[@"flags"] unsignedLongLongValue]);
                    }
                }
            }
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
            json[@"encodeFailures"] = @(ps.encodeFailures);
            json[@"framesDroppedBeforeEncoder"] = @(ps.framesDroppedBeforeEncoder);
            json[@"firstFrameLatencyMs"] = @(round(ps.firstFrameLatencyMs));
            json[@"payloadBytes"] = @(ps.payloadBytesSent);
            json[@"controlDatagrams"] = @(host.controlDatagrams);
            json[@"frameDatagrams"] = @(host.frameDatagrams);
            json[@"maxControlGapMs"] = @(round(host.maxControlGapMs));
            if (injectMode.length > 0) {
                json[@"injectMode"] = injectMode;
                json[@"inputReceived"] = @(host.session.inputEventsReceived);
                json[@"inputDropped"] = @(host.session.inputEventsDropped);
                json[@"inputRejected"] = @(host.session.inputEventsRejected);
                json[@"inputInjectFails"] = @(injectFails);
                json[@"inputInjected"] = @(injectOK);
                json[@"cursorStart"] = @[ @(round(cursorStart.x)), @(round(cursorStart.y)) ];
                json[@"cursorEnd"] = @[ @(round(cursorEnd.x)), @(round(cursorEnd.y)) ];
                json[@"cursorMovedPx"] = @(round(hypot(cursorEnd.x - cursorStart.x,
                                                       cursorEnd.y - cursorStart.y)));
                json[@"inputPlans"] = recorder.plans ?: @[];
            }
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

        // 窗口模式：先建 NSWindow，保证首帧一到就能上屏（渲染本身在独立队列，
        // 帧到了先排队，run loop 起来后立即贴图）。
        M1FrameView *frameView = nil;
        __block NSUInteger synthPosted = 0;   // 进程内合成鼠标事件的投递次数（收尾时进 JSON）
        __block BOOL closedByUser = NO;
        NSWindow *frameWindow = nil;
        if (windowMode) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            NSRect content = NSMakeRect(0, 0, windowW, windowH);
            frameWindow = [[NSWindow alloc]
                initWithContentRect:content
                          styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                     NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                            backing:NSBackingStoreBuffered
                              defer:NO];
            frameWindow.title = [NSString stringWithFormat:
                @"macOS-RDP 客户端 %d×%d（Esc 退出）", (int)windowW, (int)windowH];
            frameWindow.releasedWhenClosed = NO;
            // 不设这个，NSWindow 默认不投递 mouseMoved（tracking area 之外的那条路）。
            frameWindow.acceptsMouseMovedEvents = YES;
            frameView = [[M1FrameView alloc] initWithFrame:content];
            frameWindow.contentView = frameView;
            [frameWindow center];
            if (windowTop) frameWindow.level = NSFloatingWindowLevel;
            [frameWindow makeKeyAndOrderFront:nil];
            [[NSNotificationCenter defaultCenter]
                addObserverForName:NSWindowWillCloseNotification
                            object:frameWindow
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                closedByUser = YES;
                [NSApp stop:nil];
            }];
            printf("窗口已打开 %dx%d（Esc 或关窗退出）\n", (int)windowW, (int)windowH);
        }

        StreamClientNode *client = [StreamClientNode new];
        client.expectedFingerprint = fingerprint;
        client.fps = fps;
        client.outdir = outdir;
        client.saveFrames = saveFrames;
        [client prepareReceiver];
        if (frameView) {
            __weak M1FrameView *weakView = frameView;
            __weak StreamClientNode *weakClient = client;
            __block BOOL printedAnchors = NO;
            client.onPixelBuffer = ^(CVPixelBufferRef pb, uint32_t seq) {
                [weakView presentPixelBuffer:pb];
                // 首帧到了才有 videoSize，才能算「画面中心」的全局坐标。
                // 驱动端不能拿「屏幕中心」当「画面中心」：窗口内容里视频是按比例
                // letterbox 的，屏幕中心很可能落在黑边上，而黑边按设计不产生输入
                // （踩过：真光标驱动 4 次，视图收到 8 个 mouseMoved，主机 0 条）。
                if (printedAnchors || weakView.videoSize.width <= 0) return;
                printedAnchors = YES;
                CGRect vr = weakView.videoRect;              // 视图坐标
                NSPoint c = NSMakePoint(NSMidX(vr), NSMidY(vr));
                NSScreen *scr = frameWindow.screen ?: NSScreen.mainScreen;
                CGFloat topY = NSMaxY(scr.frame);
                NSPoint win = [weakView convertPoint:c toView:nil];
                NSPoint sCenter = [frameWindow convertPointToScreen:win];
                NSPoint winL = [weakView convertPoint:NSMakePoint(NSMidX(vr) - 200, NSMidY(vr)) toView:nil];
                NSPoint winR = [weakView convertPoint:NSMakePoint(NSMidX(vr) + 200, NSMidY(vr)) toView:nil];
                NSPoint sL = [frameWindow convertPointToScreen:winL];
                NSPoint sR = [frameWindow convertPointToScreen:winR];
                printf("  [anchors] center=(%.0f,%.0f) left=(%.0f,%.0f) right=(%.0f,%.0f) "
                       "videoW=%.0f\n",
                       sCenter.x, topY - sCenter.y, sL.x, topY - sL.y,
                       sR.x, topY - sR.y, vr.size.width);
                // 首帧真的上屏了才喊人动手：先等 0.8s 让首次 CA 提交完成，
                // 否则窗口还在「启动中」，最早几下移动会被吞掉（实测）。
                if (manualSecs > 0) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        M1StartManualCue(frameWindow, weakView, weakClient.session, manualSecs);
                    });
                }
            };
        }

        NSError *err = nil;
        printf("连接 %s:%u\n", connectHost.UTF8String, port);
        if (![client startAsClientTo:connectHost port:port timeout:12000 error:&err]) {
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
        if (frameView) {
            NSDictionary *remoteDisplay = client.session.remoteDisplays.firstObject;
            frameView.displayID = [remoteDisplay[@"displayID"] unsignedIntValue];
            printf("  目标屏 displayID=%u（w=%d h=%d），开始捕获窗口输入\n",
                   frameView.displayID,
                   [remoteDisplay[@"w"] intValue], [remoteDisplay[@"h"] intValue]);

            __block NSUInteger winSent = 0, winSendFail = 0;
            frameView.onInputEvent = ^(NSDictionary *event) {
                NSError *sendErr = nil;
                if ([client.session sendInputEvent:event error:&sendErr]) winSent += 1;
                else winSendFail += 1;
            };
            frameView.onCloseRequest = ^{ closedByUser = YES; [NSApp stop:nil]; };

            if (manualSecs > 0) {
                // 兜底：万一一帧都没解出来（黑屏/解码失败），25s 后也把提示打出来，
                // 否则执行的人会一直干等一个永远不来的信号。
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    M1StartManualCue(frameWindow, frameView, client.session, manualSecs);
                });
            }

            // 合成鼠标驱动：这台机器上由 agent 拉起的命令行工具没有「辅助功能」授权
            // （AXIsProcessTrusted=0）。实测 CGWarpMouseCursorPosition 能改光标位置，
            // 但窗口一条 mouseMoved 都收不到（连本地事件监听都是 0），CGEventPost 的
            // 合成事件同样被丢弃。此时改用 NSEvent 在进程内投递：走的是同一条
            // NSWindow sendEvent → hitTest → M1FrameView.mouseMoved: 分发路径，
            // 只差「系统把物理事件交给 App」这一跳，其余全链路（坐标换算→协议编码→
            // 传输→主机解析→注入计划）都是真的。
            if (synthSpec.length > 0) {
                NSArray<NSString *> *pairs = [synthSpec componentsSeparatedByString:@";"];
                for (NSUInteger k = 0; k < pairs.count; k++) {
                    NSString *item = [pairs[k] stringByTrimmingCharactersInSet:
                                      [NSCharacterSet whitespaceCharacterSet]];
                    double sx = 0, sy = 0;
                    if (sscanf(item.UTF8String, "%lf,%lf", &sx, &sy) != 2) continue;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(1200 + (int64_t)k * 350) * NSEC_PER_MSEC),
                                   dispatch_get_main_queue(), ^{
                        if (closedByUser) return;
                        // 内容坐标（左上原点）→ 窗口坐标（左下原点）
                        NSPoint win = NSMakePoint(sx, windowH - sy);
                        NSEvent *ev = [NSEvent mouseEventWithType:NSEventTypeMouseMoved
                                                        location:win
                                                   modifierFlags:0
                                                       timestamp:[NSProcessInfo processInfo].systemUptime
                                                    windowNumber:frameWindow.windowNumber
                                                         context:nil
                                                     eventNumber:0
                                                      clickCount:0
                                                        pressure:0];
                        [frameWindow sendEvent:ev];
                        synthPosted += 1;
                        printf("  [synth] mouseMoved 内容(%.0f,%.0f) → 窗口(%.0f,%.0f)\n",
                               sx, sy, win.x, win.y);
                    });
                }
            }

            // 到点自动收尾。stop: 之后必须再投一个事件，否则 run loop 可能还挂在等事件上。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)durationMs * (int64_t)NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if (!closedByUser) [NSApp stop:nil];
                [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                                    location:NSZeroPoint
                                               modifierFlags:0
                                                   timestamp:0
                                                windowNumber:0
                                                     context:nil
                                                     subtype:0
                                                       data1:0
                                                       data2:0]
                         atStart:NO];
            });

            // 激活必须发生在事件循环跑起来之后：在 run 之前调 activateIgnoringOtherApps:
            // 常常不生效，窗口拿不到 key，keyDown 也收不到（M1-B 实测踩过）。
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSApp activateIgnoringOtherApps:YES];
                [frameWindow makeKeyAndOrderFront:nil];
            });
            if (keepFront) {
                // 每 300ms 重抢一次前台。注意别动 window.level：实测把窗口设成
                // NSFloatingWindowLevel 之后反而一条 mouseMoved 都收不到。
                dispatch_source_t tick = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                                dispatch_get_main_queue());
                dispatch_source_set_timer(tick, dispatch_time(DISPATCH_TIME_NOW, 0),
                                          300ull * NSEC_PER_MSEC, 30ull * NSEC_PER_MSEC);
                dispatch_source_set_event_handler(tick, ^{
                    if (![NSApp isActive]) [NSApp activateIgnoringOtherApps:YES];
                    if (!frameWindow.isKeyWindow) [frameWindow makeKeyAndOrderFront:nil];
                });
                dispatch_resume(tick);
            }
            // 定位「窗口收不到事件」时要看的三件事：窗口是否可见、是否被遮住、是不是 key。
            for (NSNumber *delayMs in @[@800, @2500]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)delayMs.integerValue * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    if (windowTop) {
                        // 持续保持前台：实测有别的应用会把激活抢回去，一旦本进程
                        // 不是 active，WindowServer 就不往这个窗口投 mouseMoved
                        // （窗口看起来仍是 visible/key，只有 active 变了）。
                        static dispatch_source_t ticker;
                        if (!ticker) {
                            ticker = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                            dispatch_get_main_queue());
                            dispatch_source_set_timer(ticker,
                                dispatch_time(DISPATCH_TIME_NOW, 0), 500ull * NSEC_PER_MSEC,
                                50ull * NSEC_PER_MSEC);
                            dispatch_source_set_event_handler(ticker, ^{
                                [NSApp activateIgnoringOtherApps:YES];
                                [frameWindow makeKeyAndOrderFront:nil];
                            });
                            dispatch_resume(ticker);
                        }
                    }
                    NSRect f = frameWindow.frame;
                    printf("  [窗口 +%dms] visible=%d key=%d active=%d occluded=%d "
                           "frame=(%.0f,%.0f %.0fx%.0f) screen=%dx%d\n",
                           delayMs.intValue,
                           (int)frameWindow.isVisible, (int)frameWindow.isKeyWindow,
                           (int)[NSApp isActive],
                           (int)((frameWindow.occlusionState & NSWindowOcclusionStateVisible) == 0),
                           f.origin.x, f.origin.y, f.size.width, f.size.height,
                           (int)[NSScreen mainScreen].frame.size.width,
                           (int)[NSScreen mainScreen].frame.size.height);
                });
            }

            [NSApp run];
            printf("窗口收尾（%s）——上屏 %lu 帧，丢 %lu 帧；输入发出 %lu / 失败 %lu\n",
                   closedByUser ? "用户关闭" : "到时",
                   (unsigned long)frameView.framesRendered,
                   (unsigned long)frameView.framesDropped,
                   (unsigned long)winSent, (unsigned long)winSendFail);
        } else {
            [NSThread sleepForTimeInterval:durationMs / 1000.0];
        }

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
        if (frameView) {
            printf("  上屏：%lu 帧（丢 %lu 积压 / 跳过 %lu 不可见），"
                   "单帧渲染最近 %.1f ms / 峰值 %.1f ms\n",
                   (unsigned long)frameView.framesRendered,
                   (unsigned long)frameView.framesDropped,
                   (unsigned long)frameView.framesSkippedOccluded,
                   frameView.lastRenderMs, frameView.maxRenderMs);
            printf("  输入：窗口采集 %lu 条 → 发出 %lu / 丢弃 %lu / 拒绝 %lu\n",
                   (unsigned long)frameView.inputEventsEmitted,
                   (unsigned long)client.session.inputEventsSent,
                   (unsigned long)client.session.inputEventsDropped,
                   (unsigned long)client.session.inputEventsRejected);
        }
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
        json[@"lastDecodeLatencyMs"] = @(round(rs.lastDecodeLatencyMs * 10) / 10.0);
        json[@"firstFrameLatencyMs"] = @(round(firstFrameLatency));
        json[@"decoderPrewarmMs"] = @(round(rs.decoderPrewarmMs));
        json[@"decoderCreateMs"] = @(round(rs.decoderCreateMs));
        json[@"controlDatagrams"] = @(client.controlDatagrams);
        json[@"frameDatagrams"] = @(client.frameDatagrams);
        json[@"maxControlGapMs"] = @(round(client.maxControlGapMs));
        json[@"maxGapAtOffsetMs"] = @(round(client.maxGapAtOffsetMs));
        @synchronized (client.controlArrivals) {
            json[@"controlArrivals"] = [client.controlArrivals copy];
        }
        json[@"savedPNGs"] = @(client.savedPaths.count);
        if (frameView) {
            json[@"windowed"] = @YES;
            json[@"framesRendered"] = @(frameView.framesRendered);
            json[@"renderDropped"] = @(frameView.framesDropped);
            json[@"renderSkippedOccluded"] = @(frameView.framesSkippedOccluded);
            json[@"lastRenderMs"] = @(round(frameView.lastRenderMs * 10) / 10.0);
            json[@"maxRenderMs"] = @(round(frameView.maxRenderMs * 10) / 10.0);
            json[@"inputEmitted"] = @(frameView.inputEventsEmitted);
            json[@"inputSynthPosted"] = @(synthPosted);
            json[@"inputDriver"] = manualSecs > 0 ? @"manual"
                                 : (synthSpec.length > 0 ? @"synth" : @"physical");
            json[@"manualSecs"] = @(manualSecs);
            json[@"inputSent"] = @(client.session.inputEventsSent);
            json[@"inputDropped"] = @(client.session.inputEventsDropped);
            json[@"inputRejected"] = @(client.session.inputEventsRejected);
        }
        json[@"outdir"] = outdir;
        if (outPath.length > 0) {
            NSData *d = JSONData(json);
            if (d) [d writeToFile:outPath atomically:YES];
        }

        NSString *verdict = @"FAIL";
        NSMutableArray *notes = [NSMutableArray array];
        if (!client.streaming) [notes addObject:@"未到 STREAMING"];
        if (rs.framesDecoded == 0) [notes addObject:@"没解出任何画面"];
        if (client.savedPaths.count == 0 && !frameView) [notes addObject:@"没有 PNG 落盘"];
        if (frameView && frameView.framesRendered == 0) [notes addObject:@"窗口一帧都没贴上"];
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
