//
//  M1FramePipeline.h
//  M1-Skeleton
//
//  帧管线编排（D-10）：SCK 采集 → VT H.264 编码 → 协议分片 → datagram 投递。
//  这是 Host 侧帧通道的唯一对外入口，上层（M1SessionCoordinator / RDPApp）只跟它打交道。
//
//  启动顺序（有意为之）：
//    capture.start → 读实际像素尺寸 → encoder.start(该尺寸) → 开始转发
//  采集先于编码启动，是因为 HiDPI 屏的真实像素尺寸只有 SCK 告诉我们才准；
//  启动瞬间到达的帧因编码器尚未就绪会被丢弃，属预期行为并计入 stats。
//

#ifndef M1FramePipeline_h
#define M1FramePipeline_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "M1PipelineTypes.h"
#import "M1DatagramSink.h"
#import "M1CapturePipeline.h"
#import "M1VideoEncoder.h"
#import "M1FrameSender.h"

NS_ASSUME_NONNULL_BEGIN

@interface M1FramePipelineConfig : NSObject
@property (nonatomic, assign) int32_t targetFps;            // 默认 20
@property (nonatomic, assign) double bitsPerPixel;          // 默认 0.12
@property (nonatomic, assign) int32_t maxBitrate;           // 0 = 按 bpp 推导
@property (nonatomic, assign) double keyframeIntervalSec;   // 默认 2.0
@property (nonatomic, assign) BOOL showsCursor;             // 默认 NO
// >0 时降采样到该像素尺寸；0 = 屏幕原始尺寸。用于对齐 D-10 的 1080p 目标档。
@property (nonatomic, assign) int32_t outputWidth;
@property (nonatomic, assign) int32_t outputHeight;
@end

@interface M1FramePipelineStats : NSObject
@property (nonatomic, readonly) uint64_t framesCaptured;
@property (nonatomic, readonly) uint64_t framesEncoded;
@property (nonatomic, readonly) uint64_t framesSent;
@property (nonatomic, readonly) uint64_t framesDroppedBeforeEncoder;
@property (nonatomic, readonly) uint64_t encodeFailures;
@property (nonatomic, readonly) uint64_t sendFailures;
@property (nonatomic, readonly) uint64_t keyframes;
@property (nonatomic, readonly) uint64_t payloadBytesSent;
@property (nonatomic, readonly) uint64_t fragmentsSent;
@property (nonatomic, readonly) double firstFrameLatencyMs;
- (NSString *)summary;
@end

@interface M1FramePipeline : NSObject

- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID
                           config:(M1FramePipelineConfig *)config
                             sink:(id<M1DatagramSink>)sink
                          onError:(void (^ _Nullable)(NSError *error))onError;

- (BOOL)start:(NSError * _Nullable * _Nullable)error;
- (void)stop;

// 请求下一帧关键帧（接收端丢帧后调用）。
- (void)requestKeyframe;

@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) int32_t pixelWidth;
@property (nonatomic, readonly) int32_t pixelHeight;
@property (nonatomic, readonly) uint32_t nextFrameSeq;
@property (nonatomic, readonly) M1FramePipelineStats *stats;

@end

NS_ASSUME_NONNULL_END

#endif /* M1FramePipeline_h */
