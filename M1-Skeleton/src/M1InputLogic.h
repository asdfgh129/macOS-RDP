//
//  M1InputLogic.h
//  M1-Skeleton
//
//  输入注入的纯逻辑（Foundation-only，不碰 CGEvent / WindowServer）：
//    - 归一化坐标 (0..1) → 目标虚拟屏 Quartz 全局坐标
//    - 控制协议 flags (cmd/shift/opt/ctrl/caps) → CGEventFlags 位掩码
//    - 输入事件 → 注入计划（供真实 sink 消费，便于单测与重放）
//
//  坐标约定：PROTOCOL 的 x/y ∈ [0,1] 是相对「客户端窗口内容区」；
//  服务端按目标 display 的 Quartz bounds 映射。y 轴在 Quartz 下原点左上，
//  客户端若用左下原点需先在客户端翻转（P1QuartzRectFromNSRect）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// flags 字典 → CGEventFlags 数值（unsigned long long，便于不 import ApplicationServices）。
// 位值与 CGEventFlags 一致：shift=1<<17, ctrl=1<<18, opt=1<<19, cmd=1<<20, caps=1<<16。
uint64_t M1EventFlagsFromDict(NSDictionary<NSString *, NSNumber *> * _Nullable flags)
    NS_SWIFT_NAME(eventFlags(fromDict:));

// 归一化点 (x,y) ∈ [0,1] → 目标 Quartz rect 内的全局点。
// x/y 越界会被 clamp 到 [0,1]（防御，正常由 P1NormalizeInputEvent 校验）。
CGPoint M1PointInDisplayRect(double nx, double ny, CGRect displayRect)
    NS_SWIFT_NAME(pointInDisplayRect(nx:ny:rect:));

// 输入事件 → 注入计划字典。计划是可序列化的描述，真实注入由 M1CGEventSink 执行。
// 返回 nil 表示不支持/非法事件。
// 计划形状：@{@"kind":..., @"displayID":..., ...}
//   mouse: @{@"x":全局px, @"y":全局py, @"button":..., @"action":..., @"flags":掩码}
//   key:   @{@"keyCode":..., @"unicode":..., @"flags":掩码}
//   scroll:@{@"dx":..., @"dy":..., @"flags":掩码}
//   flags: @{@"flags":掩码}
NSDictionary<NSString *, id> * _Nullable M1InjectionPlan(NSDictionary *event,
                                                          CGRect targetDisplayRect,
                                                          NSError * _Nullable * _Nullable error)
    NS_SWIFT_NAME(injectionPlan(event:targetRect:));

extern NSString * const M1InputLogicErrorDomain;

NS_ASSUME_NONNULL_END
