//
//  M1InputInjector.h
//  M1-Skeleton
//
//  把 M1InjectionPlan 变成真实 CGEvent，并维护修饰键状态。
//    - 事件下沉走 id<M1EventSink>，测试可用 mock 记录注入计划；
//    - M1CGEventSink 用 CGEventPost(kCGHIDEventTap, ...) 注入到当前 GUI 会话；
//    - 凭据/解锁走定向 pid（复用 V-04 的 CGEventPostToPid 路径）。
//
//  现场接管手势（Shift≥3s）由 M1TakeoverDetector 判定；本类提供
//  -installTakeoverTapWithDetector: 在本机键盘事件上喂 shiftDown/shiftUp，
//  fail-safe（热插拔/睡眠/锁屏）由宿主调用 detector 的对应方法。
//  CGEventTap 需要辅助功能授权；未授权时返回 NO 并由调用方降级为纯远程判定。
//

#import <Foundation/Foundation.h>
#import "M1InputLogic.h"
#import "M1Takeover.h"

NS_ASSUME_NONNULL_BEGIN

@class M1TakeoverDetector;

// 事件下沉 seam：注入计划 → 副作用。mock 记录而不真注入。
@protocol M1EventSink <NSObject>
- (BOOL)postPlan:(NSDictionary<NSString *, id> *)plan error:(NSError **)error;
@end

// 真实 CGEvent 下沉。注意 CGEventPost 影响当前 GUI 会话全部 app（独占会话语义，D-04）。
@interface M1CGEventSink : NSObject <M1EventSink>
// 目标 pid >0 时用 CGEventPostToPid 定向（凭据注入）；0 用 kCGHIDEventTap 全局注入。
@property (nonatomic, assign) pid_t targetPID;
@end

@interface M1InputInjector : NSObject

// 目标显示坐标：注入时把归一化坐标映射到该 rect。禁屏后通常是唯一 active 虚拟屏。
@property (nonatomic, assign) CGRect targetDisplayRect;

- (instancetype)initWithSink:(id<M1EventSink>)sink;

// 注入一个已归一化的控制协议事件（kind/displayID/x/y/...）。
- (BOOL)injectEvent:(NSDictionary *)event error:(NSError **)error;

// 全量同步修饰键（flags 事件或随事件带入），返回当前 flags 掩码。
- (uint64_t)currentFlags;

// 安装本机 Shift 手势 tap，喂给 detector。需要辅助功能授权。
- (BOOL)installTakeoverTapWithDetector:(M1TakeoverDetector *)detector error:(NSError **)error;
- (void)removeTakeoverTap;

@end

NS_ASSUME_NONNULL_END
