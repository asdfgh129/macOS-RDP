//
//  M1Takeover.h
//  M1-Skeleton
//
//  D-06 §3 现场取回控制权（local console wins）的纯逻辑层：
//    - 一级（可协商）：Shift 按住 ≥3s → localTakeover，客户端 10s 缓冲，
//      可延后一次最多 60s，缓冲结束强制断开。
//    - 二级（fail-safe）：热插拔 / 睡眠唤醒 / 锁屏事件 → 立即断开，无缓冲。
//    - 三级：断电（本层不处理）。
//  时间由调用方注入（now 秒），便于确定性单测；不依赖 AppKit 事件源。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, M1TakeoverSignal) {
    M1TakeoverSignalShiftDown = 0,   // 现场用户按下 Shift（手势开始）
    M1TakeoverSignalShiftUp,         // 松开 Shift（手势取消，除非已触发）
    M1TakeoverSignalHotplug,         // 显示器热插拔（二级，立即）
    M1TakeoverSignalSleepWake,       // 系统睡眠/唤醒（二级，立即）
    M1TakeoverSignalScreenLock,      // 锁屏事件（二级，立即）
};

typedef NS_ENUM(NSInteger, M1TakeoverVerdict) {
    M1TakeoverVerdictNone = 0,       // 无动作
    M1TakeoverVerdictGestureStarted, // Shift 手势已识别，进入 10s 缓冲
    M1TakeoverVerdictDeferAccepted,  // 客户端延后请求被接受
    M1TakeoverVerdictDeferRejected,  // 超出延后上限，拒绝
    M1TakeoverVerdictForceDisconnect,// 缓冲结束 / fail-safe，立即断开
};

@interface M1TakeoverDetector : NSObject

@property (nonatomic, readonly) BOOL shiftHeld;
@property (nonatomic, readonly) BOOL pendingDisconnect;  // 处于 10s 缓冲中
@property (nonatomic, readonly) NSUInteger deferCount;

// 可调阈值（测试用；生产默认 shiftHold=3s, grace=10s, maxDefer=60s）。
@property (nonatomic, assign) NSTimeInterval shiftHoldSeconds;
@property (nonatomic, assign) NSTimeInterval graceSeconds;
@property (nonatomic, assign) NSTimeInterval maxDeferSeconds;

// 输入一个信号，返回应触发的动作。now 为当前绝对时间（秒）。
- (M1TakeoverVerdict)handleSignal:(M1TakeoverSignal)signal atTime:(double)now
    NS_SWIFT_NAME(handle(signal:atTime:));

// 每帧/每秒 tick，检查 Shift 按住时长与缓冲到期。now 为当前绝对时间。
- (M1TakeoverVerdict)tickAtTime:(double)now;

// 客户端请求延后（一次最多 graceSeconds，累计不超过 maxDeferSeconds）。
- (M1TakeoverVerdict)requestDeferAtTime:(double)now;

// 会话断开后复位全部状态。
- (void)reset;

@end

NS_ASSUME_NONNULL_END
