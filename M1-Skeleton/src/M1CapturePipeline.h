//
//  M1CapturePipeline.h
//  M1-Skeleton
//
//  ScreenCaptureKit 逐屏采集（D-10 主路径的采集段）。
//
//  刻意保留 P0 阶段的三个安全阀，它们都是踩出来的：
//    1. 退化 mode（<2×2）拒绝采集 —— 2026-11-14 WindowServer 挂起事故的疑似触发点。
//    2. HiDPI 必须乘 pointPixelScale —— 否则 2x 屏被降采样成半分辨率流，HiDPI 验证失真。
//    3. 输出宽高取偶数 —— H.264 要求。
//
//  与编码器的边界：本类只产出 CVPixelBuffer，不做任何编码。回调里的 pixelBuffer
//  仅在回调期间有效；需要异步持有必须自行 CVPixelBufferRetain/Release。
//

#ifndef M1CapturePipeline_h
#define M1CapturePipeline_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import "M1PipelineTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface M1CaptureConfig : NSObject
@property (nonatomic, assign) int32_t targetFps;    // 默认 20（D-10 档位）
@property (nonatomic, assign) BOOL showsCursor;     // 默认 NO，光标走独立通道（FR-10）
@property (nonatomic, assign) BOOL capturesAudio;   // 默认 NO，音频为 M4
@property (nonatomic, assign) int32_t queueDepth;   // 默认 4
// >0 时把采集输出降采样到该像素尺寸（取偶数）；0 = 用屏幕原始尺寸 × pointPixelScale。
// 用途：在 3440×1440 这类物理屏上验证 1080p 目标档，避免测的永远不是目标分辨率。
@property (nonatomic, assign) int32_t outputWidth;
@property (nonatomic, assign) int32_t outputHeight;
@end

@interface M1CaptureStats : NSObject
@property (nonatomic, readonly) uint64_t framesDelivered;
@property (nonatomic, readonly) uint64_t framesRejected;      // 非屏幕输出/无像素缓冲
@property (nonatomic, readonly) double firstFrameLatencyMs;   // start 返回到首帧的耗时
@property (nonatomic, readonly) double lastFrameIntervalMs;   // 相邻两帧间隔（判卡顿）
@end

@interface M1CapturePipeline : NSObject

// onFrame 在内部串行队列回调，不在调用方线程。
- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID
                           config:(M1CaptureConfig *)config
                          onFrame:(void (^)(CVPixelBufferRef pixelBuffer, double ptsMs))onFrame
                          onError:(void (^ _Nullable)(NSError *error))onError;

- (BOOL)start:(NSError * _Nullable * _Nullable)error;
- (void)stop;

// 实际输出像素尺寸（已按 pointPixelScale 换算并取偶数）。start 成功后有效。
@property (nonatomic, readonly) int32_t pixelWidth;
@property (nonatomic, readonly) int32_t pixelHeight;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) M1CaptureStats *stats;

@end

NS_ASSUME_NONNULL_END

#endif /* M1CapturePipeline_h */
