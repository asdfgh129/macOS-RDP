//
//  M1FrameReceiver.h
//  M1-Skeleton
//
//  帧通道接收端：datagram → 帧头解析 → 分片重组 → AVCC 解析 → VT 硬解。
//
//  两个用途：
//    1. Host 侧管线自检（环回：采集→编码→分片→重组→解码，验证链路真的能还原画面）；
//    2. 将来客户端渲染的复用底座（M1 之后接 Metal 呈现）。
//
//  丢帧语义（PROTOCOL.md §4）：检测到 frameSeq 缺口即丢弃该帧并请求关键帧；
//  关键帧到达前不产出画面，避免花屏。
//

#ifndef M1FrameReceiver_h
#define M1FrameReceiver_h

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "M1PipelineTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface M1FrameReceiverStats : NSObject
@property (nonatomic, readonly) uint64_t datagramsReceived;
@property (nonatomic, readonly) uint64_t malformedDatagrams;
@property (nonatomic, readonly) uint64_t framesCompleted;    // 重组收齐并按序交付的帧
@property (nonatomic, readonly) uint64_t framesDecoded;      // 成功解出画面
@property (nonatomic, readonly) uint64_t framesDropped;      // 帧级：期限判丢 + 无参数集/解码前置失败
@property (nonatomic, readonly) uint64_t droppedKeyframes;      // 因缺片收不齐而被丢弃的关键帧数
@property (nonatomic, readonly) uint64_t droppedPFrames;        // 同上，P 帧数
@property (nonatomic, readonly, copy) NSArray<NSString *> *recentDropDetails; // 最近 16 条丢帧细节
@property (nonatomic, readonly) uint64_t fragmentsDiscarded; // 随丢帧/重复/迟到一起丢弃的分片数
@property (nonatomic, readonly, copy) NSString *discardBreakdown; // wipe/ahead/winFull/stale 明细
@property (nonatomic, readonly, copy) NSString *debugState;          // 重组器内部状态快照
@property (nonatomic, readonly) uint64_t decodeFailures;
@property (nonatomic, readonly) uint64_t keyframeRequests;   // 请求关键帧的「次数」（缺口 episode）
@property (nonatomic, readonly) uint64_t repairRequests;     // 定向补片请求数（缺 1~3 片时优先于关键帧）
@property (nonatomic, readonly) double repairRttMs;            // 最近一次补片请求→收齐的耗时
@property (nonatomic, readonly) uint64_t repairRttSamples;
@property (nonatomic, readonly) double awaitingKeyframeMs;   // 处于等关键帧状态的总时长
// 最近一次「首个成功请求发出 → 后续关键帧完整重组到达」的耗时。
// 不含 VT 解码/上屏；0 表示本轮没有完成的采样。
@property (nonatomic, readonly) double keyframeRequestRttMs;
@property (nonatomic, readonly) uint64_t keyframeRequestRttSamples; // 已完成采样数
@property (nonatomic, readonly) double lastDecodeLatencyMs;
// VTDecompressionSessionCreate 的实际耗时（建一次记一次，末次值）。
// 预热生效后应落在几十 ms；首次且未预热时实测 260~1110ms。
@property (nonatomic, readonly) double decoderCreateMs;
// 进程级预热自身的耗时（0 表示本进程没做过预热）。
@property (nonatomic, readonly) double decoderPrewarmMs;
@end

@interface M1FrameReceiver : NSObject

// 进程级预热：VT 解码会话的首次初始化在进程内一次性发生，且与码流参数无关
// （用一个不含 SPS/PPS 的裸 formatDescription 就能把它做掉）。实测 260~1110ms，
// 正好压在首帧的关键路径上。在握手期间后台调一次即可。
//
// 幂等且线程安全；内部建的会话只用于预热，建完立刻销毁，绝不解码真实数据。
// 预热宽度/高度只是让 VT 走到同一分辨率分支，无需与真实码流一致。
+ (void)prewarmDecoder;

// onFrame 在调用 acceptDatagram 的线程上同步回调，pixelBuffer 仅回调期间有效。
// capturedAtUs 是主机采集 epoch 微秒（帧头 v3），0 表示旧版/未知。
- (instancetype)initWithOnFrame:(void (^)(CVPixelBufferRef pixelBuffer, uint32_t frameSeq,
                                          uint64_t capturedAtUs))onFrame
                  onNeedKeyframe:(void (^ _Nullable)(void))onNeedKeyframe;

// 交入一个完整 datagram（26B 帧头 + 载荷）。
// 返回 YES 表示该 datagram 被正确解析并吸收（不代表已出画面）。
- (BOOL)acceptDatagram:(NSData *)datagram error:(NSError * _Nullable * _Nullable)error;

// 客户端成功把 keyframe-request 送上控制通道时调用；限流/发送失败不要调用。
// 同一等待周期内只以首个成功请求作为 RTT 起点，重复请求不重置。
- (void)noteKeyframeRequestSent;

// 定向补片回调：某帧缺片停滞时先交出缺失片下标，由上层经控制通道请求 Host
// 只重发这几片。为 nil（或返回不处理）时，重组器在补片窗口后照旧判丢并请求关键帧。
// 回调在 acceptDatagram 的调用线程上，必须非阻塞。
@property (nonatomic, copy, nullable) void (^onNeedRepair)(uint32_t frameSeq, uint16_t fragCount,
                                                           NSIndexSet *missingIndices,
                                                           BOOL keyframe);

// 丢弃解码器与重组状态。分辨率变化或重连时调用。
- (void)reset;

@property (nonatomic, readonly) BOOL needsKeyframe;
// 接收端建议的码流尺寸（来自最近一次参数集）。未知时为 0。
@property (nonatomic, readonly) int32_t videoWidth;
@property (nonatomic, readonly) int32_t videoHeight;
@property (nonatomic, readonly) M1FrameReceiverStats *stats;

@end

NS_ASSUME_NONNULL_END

#endif /* M1FrameReceiver_h */
