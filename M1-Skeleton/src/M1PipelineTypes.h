//
//  M1PipelineTypes.h
//  M1-Skeleton
//
//  帧管线共享类型：错误域/错误码 + 一帧编码结果。
//  故意不依赖 VideoToolbox / ScreenCaptureKit，保证纯逻辑模块可在任何机器上单测。
//

#ifndef M1PipelineTypes_h
#define M1PipelineTypes_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const M1PipelineErrorDomain;

typedef NS_ENUM(NSInteger, M1PipelineErrorCode) {
    M1PipelineErrorEmptyPayload = 1,       // 编码器给了空载荷
    M1PipelineErrorSinkFailed,             // datagram 投递失败（队列满/连接断）
    M1PipelineErrorFragmentationFailed,    // 分片失败（超 65535 片等）
    M1PipelineErrorNotStarted,             // 管线未 start 就请求编码
    M1PipelineErrorCaptureFailed,          // SCK 会话建立/启动失败
    M1PipelineErrorDegenerateMode,         // 退化 mode（1x1），按事故教训拒绝采集
    M1PipelineErrorEncoderFailed,          // VT 会话创建/编码失败
    M1PipelineErrorDecodeFailed,           // 重组后解码失败
};

// 一帧 H.264 编码结果。载荷为 AVCC（长度前缀 NALU），与 PROTOCOL.md §4 一致。
@interface M1EncodedFrame : NSObject

@property (nonatomic, copy) NSData *avccPayload;

// 关键帧（IDR）。接收端在关键帧到达前不产出画面。
@property (nonatomic, assign) BOOL isKeyframe;

// 本次载荷前部是否已含 SPS/PPS（关键帧时由编码器前置）。
// 发送器据此置 P1FrameFlagHasParamSets，接收端据此重建 formatDescription。
@property (nonatomic, assign) BOOL carriesParamSets;

// 编码完成时刻（wall clock ms），用于延迟打点。
@property (nonatomic, assign) double encodedAtMs;

// VT 入队到回调产出的耗时，用于编码器健康度观测。
@property (nonatomic, assign) double encodeLatencyMs;

@end

NS_ASSUME_NONNULL_END

#endif /* M1PipelineTypes_h */
