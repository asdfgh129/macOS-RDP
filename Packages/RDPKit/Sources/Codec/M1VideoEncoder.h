//
//  M1VideoEncoder.h
//  M1-Skeleton
//
//  VideoToolbox H.264 硬件编码封装（D-10：SCK 主路径的编码段）。
//
//  设计约束（来自 P0 实测与 PR #288 类陷阱）：
//    - RealTime=true、AllowFrameReordering=false（无 B 帧）、MaxFrameDelayCount=1
//      —— 实时流不能有重排缓冲，否则延迟不可控。
//    - 关键帧按时间间隔自动插入，并支持外部强制请求（接收端丢帧后需要）。
//    - 关键帧载荷前置 SPS/PPS（AVCC 长度前缀格式），使接收端可在中途加入/重建解码器。
//    - stop 必须等 VT 内部队列排空，否则回调 refCon 变野指针（P0 踩过）。
//

#ifndef M1VideoEncoder_h
#define M1VideoEncoder_h

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "M1PipelineTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface M1EncoderConfig : NSObject

@property (nonatomic, assign) int32_t width;              // 必须是偶数
@property (nonatomic, assign) int32_t height;             // 必须是偶数
@property (nonatomic, assign) int32_t targetFps;          // 默认 20（D-10 档位）
@property (nonatomic, assign) double bitsPerPixel;        // 默认 0.12，码率 = w*h*fps*bpp
@property (nonatomic, assign) int32_t maxBitrate;         // >0 时覆盖 bpp 推导值
@property (nonatomic, assign) double keyframeIntervalSec; // 默认 2.0

+ (instancetype)configWithWidth:(int32_t)width height:(int32_t)height;

// 由 bpp/帧率推导出的目标码率（bps）。maxBitrate>0 时返回 maxBitrate。
- (int32_t)effectiveBitrate;

@end

@interface M1EncoderStats : NSObject
@property (nonatomic, readonly) uint64_t framesEncoded;
@property (nonatomic, readonly) uint64_t keyframes;
@property (nonatomic, readonly) uint64_t encodeFailures;
@property (nonatomic, readonly) uint64_t bytesTotal;
@property (nonatomic, readonly) double lastEncodeCallMs;   // 入队调用耗时（与 P0 探针同口径）
@property (nonatomic, readonly) double maxEncodeCallMs;
// VTCompressionSessionCreate + PrepareToEncodeFrames 的实际耗时。
// 预热生效后应在百毫秒级；未预热时实测 340~1650ms（直接压首帧）。
@property (nonatomic, readonly) double sessionCreateMs;
@end

@interface M1VideoEncoder : NSObject

// 进程级预热：VT 的会话初始化在进程内是一次性的——首次 VTCompressionSessionCreate
// 实测 340~1380ms（框架冷加载 + VTEncoderXPCService 握手），之后同进程只要 100ms 级。
// 推流时这 1s 直接压在首帧延迟上（而且发生在采集已启动之后，期间的采集帧全被丢弃）。
// 在握手 / 等待客户端接入期间后台调一次，把这次性开销挪出关键路径。
//
// 幂等且线程安全：可重复调用，只有第一次真正执行；在任何队列上调都安全。
// 不依赖分辨率——空转会话建完立即销毁，从不接收真实像素。
+ (void)prewarm;

// onEncoded / onError 在 VT 内部队列回调，不在调用方线程——上层需自行切回目标队列。
- (instancetype)initWithConfig:(M1EncoderConfig *)config
                     onEncoded:(void (^)(M1EncodedFrame *frame))onEncoded
                       onError:(void (^ _Nullable)(NSError *error))onError;

- (BOOL)start:(NSError * _Nullable * _Nullable)error;

// 送一帧。pixelBuffer 由调用方持有，本方法同步入队后即返回（VT 内部异步编码）。
// capturedAtUs 为采集 epoch 微秒，随编码结果回传并写入帧头（A-02 打点）。
- (BOOL)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
                    ptsMs:(double)ptsMs
             capturedAtUs:(uint64_t)capturedAtUs
                    error:(NSError * _Nullable * _Nullable)error;

// 请求下一帧编码为关键帧（接收端丢帧/新客户端加入时调用）。
- (void)requestKeyframe;

// 停止并排空：返回后不再有任何回调，可安全释放。
- (void)stop;

@property (nonatomic, readonly) M1EncoderStats *stats;
@property (nonatomic, readonly, getter=isRunning) BOOL running;

@end

NS_ASSUME_NONNULL_END

#endif /* M1VideoEncoder_h */
