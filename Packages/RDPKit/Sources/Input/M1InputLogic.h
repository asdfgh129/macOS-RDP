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

// 等比适配（letterbox）：把 videoSize 按原比例放进 bounds 并居中，返回画面矩形。
// 客户端上屏与坐标映射必须用同一个结果，否则「看到的」和「点到的」会错位。
CGRect M1AspectFitRect(CGSize videoSize, CGRect bounds)
    NS_SWIFT_NAME(aspectFitRect(videoSize:bounds:));

// 视图坐标 → 协议归一化坐标。
//   · 视图用 AppKit 默认的左下原点，协议 y=0 是画面顶边，这里负责翻 y；
//   · videoRect 是 M1AspectFitRect 的结果（不是整个视图，否则黑边会被算进画面）；
//   · 落在画面外会被 clamp 到 [0,1]——调用方通常先用 scale 判断是否在画面内。
CGPoint M1NormalizedPointFromViewPoint(CGPoint viewPoint, CGRect videoRect)
    NS_SWIFT_NAME(normalizedPoint(fromViewPoint:videoRect:));

// 输入事件 → 注入计划字典。计划是可序列化的描述，真实注入由 M1CGEventSink 执行。
// 返回 nil 表示不支持/非法事件。
// 计划形状：@{@"kind":..., @"displayID":..., ...}
//   mouse: @{@"x":全局px, @"y":全局py, @"button":..., @"action":..., @"flags":掩码}
//   key:   @{@"keyCode":..., @"unicode":..., @"flags":掩码}
//   text:  @{@"text":成串文本, @"flags":掩码}（IME 提交串，按 unicode 注入）
//   scroll:@{@"dx":..., @"dy":..., @"flags":掩码}
//   flags: @{@"flags":掩码}
NSDictionary<NSString *, id> * _Nullable M1InjectionPlan(NSDictionary *event,
                                                          CGRect targetDisplayRect,
                                                          NSError * _Nullable * _Nullable error)
    NS_SWIFT_NAME(injectionPlan(event:targetRect:));

// 旧掩码 → 新掩码的修饰键增量：按「先抬起后按下」逐键产出
// @{@"keyCode":@(HID 键码), @"down":@(BOOL), @"flags":@(该步之后的掩码)}。
// Host 只收到全量状态时用它合成 flagsChanged：只改掩码而不带键码的
// flagsChanged 在部分 App 里会被忽略。
NSArray<NSDictionary<NSString *, id> *> *M1ModifierFlagTransitions(uint64_t oldFlags,
                                                                   uint64_t newFlags);

extern NSString * const M1InputLogicErrorDomain;

NS_ASSUME_NONNULL_END
