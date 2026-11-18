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
@property (nonatomic, readonly) uint64_t framesCompleted;    // 重组收齐的帧
@property (nonatomic, readonly) uint64_t framesDecoded;      // 成功解出画面
@property (nonatomic, readonly) uint64_t framesDropped;      // 缺口/等关键帧而丢弃
@property (nonatomic, readonly) uint64_t decodeFailures;
@property (nonatomic, readonly) uint64_t keyframeRequests;
@property (nonatomic, readonly) double lastDecodeLatencyMs;
@end

@interface M1FrameReceiver : NSObject

// onFrame 在调用 acceptDatagram 的线程上同步回调，pixelBuffer 仅回调期间有效。
- (instancetype)initWithOnFrame:(void (^)(CVPixelBufferRef pixelBuffer, uint32_t frameSeq))onFrame
                  onNeedKeyframe:(void (^ _Nullable)(void))onNeedKeyframe;

// 交入一个完整 datagram（16B 帧头 + 载荷）。
// 返回 YES 表示该 datagram 被正确解析并吸收（不代表已出画面）。
- (BOOL)acceptDatagram:(NSData *)datagram error:(NSError * _Nullable * _Nullable)error;

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
