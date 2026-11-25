//
//  M1StreamSession.h
//  VeilRD — RDPKit
//
//  单端流会话节点：QUIC 传输 + 控制链路（与帧分片共用一条 datagram，按首字节分流）
//  + 会话状态机 + 客户端重组/解码。从 stream_probe 抽出为共享模块（第 4 轮），
//  由 stream_probe、veild-host-agent、VeilRD client 三处共同消费。
//
//  职责边界：
//    · 本模块只负责「建链 / 会话 / 收发分流 / 重组解码」，不含采集、窗口、
//      输入注入、独占显示——这些留给各入口按角色装配。
//    · 控制帧 0x43 'C' → M1ControlLink；帧分片 0x4D 'M' → M1FrameReceiver。
//
//  线程约定：
//    · QUIC / 控制回调在传输队列；onFrameDatagram: 由子类转到帧队列，
//      绝不阻塞收包队列（首帧建 VT 解码会话实测可到 1s）。
//    · onPixelBuffer 在帧队列回调，上屏方需自行切主线程。
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

#import "M1QuicTransport.h"
#import "M1ControlLink.h"
#import "M1ControlChannel.h"
#import "M1ControlSession.h"
#import "M1FrameReceiver.h"

NS_ASSUME_NONNULL_BEGIN

double M1StreamNowMs(void);

#pragma mark - 通用节点

@interface M1StreamNode : NSObject <M1QuicTransportDelegate, M1ControlLinkDelegate,
                                    M1ControlSessionDelegate, M1DatagramSink>

// 身份与 ALPN（产品默认值与 stream_probe 一致；入口可覆写证书路径/口令）
@property (nonatomic, copy) NSString *identityPath;   // 默认 .state/rdp-identity.p12
@property (nonatomic, copy) NSString *identityPass;   // 默认 rdpdev
@property (nonatomic, copy) NSString *alpn;           // 默认 rdp1

@property (nonatomic, assign) BOOL isHost;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, copy, nullable) NSString *expectedFingerprint;
@property (nonatomic, copy, nullable) NSString *localFingerprint;
@property (nonatomic, assign) int fps;
@property (nonatomic, assign) int bitrateKbps;

@property (nonatomic, strong, nullable) M1QuicTransport *listener;
@property (nonatomic, strong, nullable) M1QuicTransport *streamConn;
@property (nonatomic, strong, nullable) M1ControlLink *link;
@property (nonatomic, strong, nullable) M1ControlChannel *channel;
@property (nonatomic, strong, nullable) M1ControlSession *session;
@property (nonatomic, strong) dispatch_semaphore_t readySem;
@property (nonatomic, strong) dispatch_semaphore_t streamingSem;
@property (nonatomic, strong, nullable) NSError *error;
@property (nonatomic, assign) BOOL streaming;
@property (nonatomic, assign) double handshakeMs;
@property (nonatomic, assign) double streamStartMs;
// 会话结束（对端 bye 或传输中途失败）：一次接入只回调一次。
// Host 常驻的多会话模式靠它在客户端离开时立即清理，而不是干等 duration。
@property (nonatomic, copy, nullable) void (^onSessionClosed)(void);
// Host：收到客户端输入事件（已在 M1ControlSession 过校验与限速）
@property (nonatomic, copy, nullable) void (^onInputEvent)(NSDictionary *event);
// Host：为 session-start 准备真实显示；nil = 失败，空数组 = 沿用合成占位
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *(^displayProvider)(NSDictionary *message,
                                                                              NSError **error);
// Host：session-update 事务换屏；nil/错误 = 失败（旧屏保持可用），返回新的 displays[]
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *(^onSessionUpdateSpecs)(NSArray<NSDictionary *> *specs,
                                                                                   NSError **error);
// Host：keyframe-request / frame-nack（控制交付队列上调用，与传输收包线程分离）。
//   displayID 是请求目标屏；0 表示旧版客户端未带（单屏按唯一管线、多屏按全部管线）。
@property (nonatomic, copy, nullable) void (^onKeyframeRequest)(uint32_t displayID);
@property (nonatomic, copy, nullable) void (^onFrameNack)(uint32_t displayID, uint32_t frameSeq,
                                                          uint16_t fragCount, NSIndexSet *indices);
// 单次接入失败（握手/会话错误）：独占模式必须在此恢复显示
@property (nonatomic, copy, nullable) void (^onAttemptFailed)(void);
// Client：session-start 请求的规格；nil = 1920x1080
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *requestedSpecs;
// Client：session-update 结果（控制交付队列上调用；ok=NO 时会话仍可用）
@property (nonatomic, copy, nullable) void (^onSessionUpdateResult)(int64_t updateID, BOOL ok,
                                                               NSArray<NSDictionary *> *displays,
                                                               NSString * _Nullable detail);
// Client：STREAMING 中请求换屏；返回 updateID（0 = 未发送）
- (int64_t)requestSessionUpdateWithSpecs:(NSArray<NSDictionary *> *)specs
                                   error:(NSError **)error;

// 发送端故障注入（只影响帧分片，不影响控制包）
@property (nonatomic, assign) double simLossPct;
@property (nonatomic, assign) double simReorderPct;
@property (nonatomic, assign) uint64_t simFragmentsDropped;
@property (nonatomic, assign) uint64_t simReordered;
@property (nonatomic, assign) uint64_t simState;
@property (nonatomic, strong, nullable) NSData *simHeld;

// 分流统计
@property (nonatomic, assign) uint64_t controlDatagrams;
@property (nonatomic, assign) uint64_t frameDatagrams;
@property (nonatomic, assign) uint64_t unroutedDatagrams;

// 控制面诊断快照：datagram 分流 + 链路重传/去重 + 通道解析计数。
// 控制面静默失效（收不到结果/心跳）时靠它区分「没到」「被扣住」「解析错」。
- (NSDictionary<NSString *, id> *)controlDiagnostics;

// 控制通道到达间隔（判「推流是否挤掉心跳」）
@property (nonatomic, assign) double lastControlArrivalMs;
@property (nonatomic, assign) double maxControlGapMs;
@property (nonatomic, assign) double maxGapAtOffsetMs;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *controlArrivals;

- (BOOL)startAsHostOnPort:(uint16_t)port error:(NSError **)error;
- (BOOL)startAsClientTo:(NSString *)host port:(uint16_t)port
                timeout:(uint32_t)timeoutMs error:(NSError **)error;
- (void)attachSessionTo:(M1QuicTransport *)conn;
- (BOOL)waitForStreamingTimeoutMs:(uint32_t)timeoutMs;

// 会话结束后复位一次性状态（streaming/error/计时/控制到达记录），
// 让同一进程可以接下一个客户端。管线/显示资源由入口自行清理。
- (void)prepareForNextSession;

// M1DatagramSink（帧管线出口）；子类覆写 onFrameDatagram 实现收流侧
- (BOOL)sendDatagram:(NSData *)datagram error:(NSError **)error;
- (void)onFrameDatagram:(NSData *)datagram;
- (void)flushSimulatedHeld;

- (NSArray<NSString *> *)stateLog;
- (void)shutdown;

@end

#pragma mark - 客户端节点（重组 + 解码 + 可选 PNG 落盘）

@interface M1StreamClientNode : M1StreamNode

// 多屏：每块屏（帧头 displayID）一个重组/解码器与一条串行帧队列。
// receiver 是首块屏的快捷方式，单屏场景等价于旧行为。
@property (nonatomic, strong, nullable) M1FrameReceiver *receiver;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, M1FrameReceiver *> *receivers;
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *receiverDisplayIDs;
- (nullable M1FrameReceiver *)receiverForDisplayID:(uint32_t)displayID
    NS_SWIFT_NAME(receiver(forDisplayID:));

@property (nonatomic, copy, nullable) NSString *outdir;
@property (nonatomic, assign) NSUInteger saveFrames;
@property (nonatomic, assign) NSUInteger savedFrames;
@property (nonatomic, assign) NSUInteger reservedSaves;
@property (nonatomic, strong) dispatch_queue_t saveQueue;
@property (nonatomic, assign) uint64_t keyframeRequests;
@property (nonatomic, assign) uint64_t keyframeRequestsSent;
@property (nonatomic, assign) uint64_t keyframeRequestFailures;
@property (nonatomic, assign) uint64_t repairRequests;
@property (nonatomic, assign) uint64_t repairRequestsSent;
@property (nonatomic, assign) uint64_t repairWholeFrameRequests;
@property (nonatomic, assign) double firstFrameMs;
@property (nonatomic, assign) double lastFrameMs;
@property (nonatomic, assign) uint32_t lastSavedSeq;
@property (nonatomic, assign) BOOL hasSavedSeq;
@property (nonatomic, assign) double maxAcceptBlockMs;
@property (nonatomic, assign) double maxAcceptBlockAtMs;
@property (nonatomic, assign) int32_t decodedWidth;
@property (nonatomic, assign) int32_t decodedHeight;
@property (nonatomic, strong) NSMutableArray<NSString *> *savedPaths;
// 在对应屏的帧队列回调；上屏方需自行切主线程。
// displayID 来自帧头，多屏时据此把画面送到对应窗口。
@property (nonatomic, copy, nullable) void (^onPixelBuffer)(uint32_t displayID,
                                                        CVPixelBufferRef pb,
                                                        uint32_t frameSeq,
                                                        uint64_t capturedAtUs);

// 等待所有屏的帧队列排空（退出前取统计/落盘用）。
- (void)flushFrames;
- (void)flushSaves;

@end

NS_ASSUME_NONNULL_END
