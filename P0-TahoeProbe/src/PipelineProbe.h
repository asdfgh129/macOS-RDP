//
//  PipelineProbe.h
//  P0-TahoeProbe
//
//  ScreenCaptureKit 可见性检查 / 逐屏捕获 / 黑屏判定 / VideoToolbox 能力探测与环回。
//

#ifndef PipelineProbe_h
#define PipelineProbe_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface PipelineProbe : NSObject

// SCShareableContent 当前枚举到的 displayID 列表。
// 失败时返回 nil 并填充 error —— 绝大多数情况是 Terminal 未获屏幕录制权限。
+ (NSArray<NSNumber *> * _Nullable)shareableDisplayIDsWithError:(NSError * _Nullable * _Nullable)error;

// 轮询直到 ids 全部出现在 SCShareableContent，或超时。
+ (BOOL)waitForDisplayIDs:(NSArray<NSNumber *> *)ids
                timeoutMs:(int)timeoutMs
                 lastSeen:(NSArray<NSNumber *> * _Nullable * _Nullable)lastSeen;

// 逐一试探 H.264 Baseline/Main/High 与 HEVC Main 在 1080p / 4K 下
// 能否创建会话并 PrepareToEncodeFrames，以及是否真的走硬件编码。
+ (NSDictionary *)encoderCapabilities;

// 对一块虚拟屏捕获 durationMs 毫秒，统计帧率 / 首帧延迟 / 亮度分布（判黑屏）。
// withEncoder=YES 时把帧同步送进 VideoToolbox H.264 硬编并用 VTDecompression 环回。
+ (NSDictionary *)captureDisplayID:(CGDirectDisplayID)displayID
                        durationMs:(int)durationMs
                       withEncoder:(BOOL)withEncoder;

@end

NS_ASSUME_NONNULL_END

#endif /* PipelineProbe_h */
