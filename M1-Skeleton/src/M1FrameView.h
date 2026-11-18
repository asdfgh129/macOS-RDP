//
//  M1FrameView.h
//  M1-Skeleton
//
//  M1-B 客户端上屏：解码后的 CVPixelBuffer 贴到 layer，并把鼠标/键盘/滚轮
//  归一化成 PROTOCOL §3.1 的 input 事件。
//
//  职责边界：
//    · 只做「显示 + 采集 + 归一化」，不发送、不碰会话——事件交回宿主，
//      由它补 seq/type 后走 M1ControlSession sendInputEvent:。
//    · 坐标换算用 M1InputLogic 的纯函数（M1AspectFitRect / M1NormalizedPointFromViewPoint），
//      与「画面实际画在哪」共用同一份几何，避免看到的和点到的错位。
//
//  线程约定：
//    · presentPixelBuffer: 可从任意线程调用（解码回调线程），内部转到渲染队列 +
//      主线程；积压超过 2 帧直接丢旧帧，不让延迟滚雪球。
//    · onInputEvent / onCloseRequest 都在主线程回调。
//

#import <Cocoa/Cocoa.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface M1FrameView : NSView

// 输入事件里携带的目标屏 ID（Host 据此选目标 rect）。
@property (nonatomic, assign) uint32_t displayID;

// 归一化输入事件（无 type/seq）；宿主负责补全并发送。
@property (nonatomic, copy, nullable) void (^onInputEvent)(NSDictionary *event);

// Esc 请求结束会话；宿主决定收尾方式（默认开启）。
@property (nonatomic, copy, nullable) void (^onCloseRequest)(void);
@property (nonatomic, assign) BOOL closesOnEscape;

// 把一帧贴到屏幕上。
- (void)presentPixelBuffer:(CVPixelBufferRef)pb;

// 强制同步一次修饰键状态（重连后必须复位，PROTOCOL §3.1）。
- (void)resetModifierState;

@property (nonatomic, readonly) CGSize videoSize;       // 最近一帧的像素尺寸
@property (nonatomic, readonly) CGRect videoRect;        // letterbox 后的画面矩形（视图坐标）
@property (nonatomic, readonly) NSUInteger framesRendered;
@property (nonatomic, readonly) NSUInteger framesDropped; // 渲染积压丢掉的帧
// 窗口不可见（被遮住/锁屏）而没贴的帧。这个数不为 0 说明画面根本没上屏，
// 此时 framesRendered 会偏低且渲染耗时统计不可信。
@property (nonatomic, readonly) NSUInteger framesSkippedOccluded;
@property (nonatomic, readonly) NSUInteger inputEventsEmitted;
@property (nonatomic, readonly) double lastRenderMs;
@property (nonatomic, readonly) double maxRenderMs;
// CIContext 首次转换的冷启动耗时（实测 600ms 级，之后 3ms）。构造时已在后台预热，
// 这里只用于观测；预热是否生效看 maxRenderMs 是否落回个位数。
@property (nonatomic, readonly) double warmUpMs;

// 最近一次渲染的输出缓冲（IOSurface 承载，返回借出的引用，下一次渲染可能重用）。
// 仅供离屏自检采样；运行时不必读。
- (CVPixelBufferRef)lastRenderedBuffer;

@end

NS_ASSUME_NONNULL_END
