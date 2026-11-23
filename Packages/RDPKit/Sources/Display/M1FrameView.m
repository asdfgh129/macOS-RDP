//
//  M1FrameView.m
//  M1-Skeleton
//

#import "M1FrameView.h"
#import "M1InputLogic.h"
#import "M1WallClock.h"
#import "P1InputCodec.h"
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#include <stdatomic.h>

// 渲染转换队列允许的峰值深度。1080p 转换 p50 ~4.5ms，12 帧在极端突发下
// 最多引入 ~54ms；实测峰值 8 帧。限制过小（2）会把网络/解码突发误判成
// 「渲染跟不上」而丢弃本可正常转换的帧。
static const uint32_t kM1RenderBacklogLimit = 12;

static double M1ViewNowMs(void) {
    return CFAbsoluteTimeGetCurrent() * 1000.0;
}

// 1ms 直方图，256 桶；只增不减，进程内近似分位数足够定位积压来源。
static const uint32_t kM1RenderHistBuckets = 256;

// capture→render 的原始差值可能为负：帧头时刻是主机时钟，客户端时钟更快时
// raw 会小于 0。直方图从 -512ms 起算，报告端再加回时钟差（host-client）。
static const uint32_t kM1PresentHistBuckets = 2048;
static const int32_t  kM1PresentHistBaseMs = 512;

static void M1AtomicMaxU32(atomic_uint_fast32_t *slot, uint32_t v) {
    uint32_t old = atomic_load(slot);
    while (v > old && !atomic_compare_exchange_weak(slot, &old, v)) {}
}

static void M1AtomicMaxU64(atomic_uint_fast64_t *slot, uint64_t v) {
    uint64_t old = atomic_load(slot);
    while (v > old && !atomic_compare_exchange_weak(slot, &old, v)) {}
}

static double M1HistPercentile(atomic_uint_fast32_t *hist, uint32_t n, double p) {
    uint64_t total = 0;
    for (uint32_t i = 0; i < n; i++) total += atomic_load(&hist[i]);
    if (total == 0) return 0;
    uint64_t target = (uint64_t)(p * (double)total + 0.999); // 向上取整
    uint64_t seen = 0;
    for (uint32_t i = 0; i < n; i++) {
        seen += atomic_load(&hist[i]);
        if (seen >= target) return (double)i + 0.5;
    }
    return (double)n - 0.5;
}

// 色彩空间只建一次：createCGImage:...colorSpace: 不会接管所有权，
// 每帧新建就是每帧泄漏一个 CGColorSpace。
static CGColorSpaceRef M1ViewSRGBColorSpace(void) {
    static CGColorSpaceRef space;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    });
    return space;
}

// 只把可打印字符当 unicode 传：方向键/功能键在 AppKit 里是 0xF700 区私有码，
// 当成文本发过去会在 Host 侧打出乱码，这类键应当只靠 keyCode。
static NSString *M1PrintableCharacters(NSEvent *event) {
    NSString *s = event.characters;
    if (s.length == 0) return nil;
    unichar c = [s characterAtIndex:0];
    if (c < 0x20 || c == 0x7F) return nil;
    if (c >= 0xF700 && c <= 0xF8FF) return nil;
    return s;
}

@interface M1FrameView () {
    atomic_uint_fast64_t _framesRendered;
    atomic_uint_fast64_t _framesDropped;
    atomic_uint_fast64_t _renderDropped;
    atomic_uint_fast64_t _renderFailed;
    atomic_uint_fast64_t _inputEmitted;
    atomic_uint_fast64_t _skippedOccluded;
    atomic_uint_fast32_t _pendingRenders;
    atomic_uint_fast32_t _maxPendingRenders;
    atomic_uint_fast32_t _renderHist[kM1RenderHistBuckets];
    atomic_uint_fast32_t _presentLatHist[kM1PresentHistBuckets];
    atomic_uint_fast64_t _presentLatSamples;
    atomic_uint_fast64_t _maxQueueWaitUs;
    atomic_uint_fast64_t _maxMainWaitUs;
    _Atomic double _lastPresentLatencyMs;
    _Atomic double _maxPresentLatencyMs;
    CVPixelBufferRef _outBuffer;      // 复用的 BGRA 输出（IOSurface 承载），只在 renderQueue 上动
    CGSize _outSize;
}
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) dispatch_queue_t renderQueue;
@property (nonatomic, strong, nullable) NSTrackingArea *trackingArea;
@property (nonatomic, assign, readwrite) CGSize videoSize;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSNumber *> *lastFlags;
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, assign) BOOL rightDragging;
@property (nonatomic, assign) BOOL otherDragging;
@property (nonatomic, assign, readwrite) double lastRenderMs;
@property (nonatomic, assign, readwrite) double maxRenderMs;
@property (nonatomic, assign, readwrite) double warmUpMs;
// 同一份 NSEvent 的重复投递判据（见 mouseMoved:）
@property (nonatomic, assign) BOOL hasLastMouseEvent;
@property (nonatomic, assign) NSTimeInterval lastMouseEventTimestamp;
@property (nonatomic, assign) NSPoint lastMouseEventPoint;
@end

@implementation M1FrameView

- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        _closesOnEscape = YES;
        _renderQueue = dispatch_queue_create("m1.display.render", DISPATCH_QUEUE_SERIAL);
        _ciContext = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO,
            kCIContextCacheIntermediates: @NO,
        }];
        atomic_init(&_framesRendered, 0);
        atomic_init(&_framesDropped, 0);
        atomic_init(&_renderDropped, 0);
        atomic_init(&_renderFailed, 0);
        atomic_init(&_inputEmitted, 0);
        atomic_init(&_skippedOccluded, 0);
        atomic_init(&_pendingRenders, 0);
        atomic_init(&_maxPendingRenders, 0);
        atomic_init(&_maxQueueWaitUs, 0);
        atomic_init(&_maxMainWaitUs, 0);
        atomic_init(&_presentLatSamples, 0);
        atomic_store(&_lastPresentLatencyMs, 0.0);
        atomic_store(&_maxPresentLatencyMs, -60000.0);
        for (uint32_t i = 0; i < kM1RenderHistBuckets; i++) atomic_init(&_renderHist[i], 0);
        for (uint32_t i = 0; i < kM1PresentHistBuckets; i++) atomic_init(&_presentLatHist[i], 0);
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor blackColor].CGColor;
        // 与 M1AspectFitRect 的几何一致：等比适配 + 居中，黑边由 layer 自己补。
        self.layer.contentsGravity = kCAGravityResizeAspect;
        self.layer.magnificationFilter = kCAFilterLinear;
        // CIContext 首次转换要编译 GPU 管线，实测 623ms（之后 3.3ms）。和 VT 会话一样，
        // 这是进程内一次性成本，提前到握手期间做掉，否则整段压在首帧上。
        dispatch_async(_renderQueue, ^{ [self warmUpRenderPath]; });
    }
    return self;
}

// 复用一块 BGRA + IOSurface 的输出缓冲；尺寸变化才重建。
// 必须在 renderQueue 上调用（唯一写入方）。
- (CVPixelBufferRef)ensureOutputBufferForSize:(CGSize)size {
    if (_outBuffer && CGSizeEqualToSize(_outSize, size)) return _outBuffer;
    if (_outBuffer) { CVPixelBufferRelease(_outBuffer); _outBuffer = NULL; }
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)size.width, (size_t)size.height,
                            kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) {
        return NULL;
    }
    _outBuffer = pb;
    _outSize = size;
    return _outBuffer;
}

- (CVPixelBufferRef)lastRenderedBuffer {
    return _outBuffer;   // 借出，仅自检用；下一次渲染可能被重用
}

// 用 16x16 的数据走完整条「CVPixelBuffer → CIImage → IOSurface」路径，结果直接丢弃。
- (void)warmUpRenderPath {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) {
        return;
    }
    double t0 = M1ViewNowMs();
    CIImage *image = [CIImage imageWithCVPixelBuffer:pb];
    CVPixelBufferRef out = image ? [self ensureOutputBufferForSize:image.extent.size] : NULL;
    if (image && out) {
        [self.ciContext render:image toCVPixelBuffer:out
                        bounds:image.extent colorSpace:M1ViewSRGBColorSpace()];
    }
    self.warmUpMs = M1ViewNowMs() - t0;
    CVPixelBufferRelease(pb);
}

- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }

#pragma mark - 上屏

- (void)presentPixelBuffer:(CVPixelBufferRef)pb {
    [self presentPixelBuffer:pb capturedAtUs:0];
}

- (void)presentPixelBuffer:(CVPixelBufferRef)pb capturedAtUs:(uint64_t)capturedAtUs {
    if (!pb) return;

    // 积压保护只约束转换队列：主线程贴层慢不应被算成「渲染跟不上解码」。
    if (atomic_load(&_pendingRenders) >= kM1RenderBacklogLimit) {
        atomic_fetch_add(&_framesDropped, 1);
        atomic_fetch_add(&_renderDropped, 1);
        return;
    }
    double tPresent = M1ViewNowMs();
    uint32_t pending = (uint32_t)atomic_fetch_add(&_pendingRenders, 1) + 1;
    M1AtomicMaxU32(&_maxPendingRenders, pending);

    CVPixelBufferRef held = CVPixelBufferRetain(pb);
    CGSize size = CGSizeMake((CGFloat)CVPixelBufferGetWidth(pb),
                             (CGFloat)CVPixelBufferGetHeight(pb));

    dispatch_async(self.renderQueue, ^{
        double t0 = M1ViewNowMs();
        M1AtomicMaxU64(&self->_maxQueueWaitUs, (uint64_t)((t0 - tPresent) * 1000.0));
        CIImage *image = [CIImage imageWithCVPixelBuffer:held];
        CVPixelBufferRef out = image ? [self ensureOutputBufferForSize:image.extent.size] : NULL;
        if (image && out) {
            // 渲染到 IOSurface 承载的 BGRA 缓冲：全程 GPU，没有 createCGImage 的
            // GPU→CPU 回读。3440×1440 下每帧 20 MB，回读实测 0.5~0.9 s/帧。
            [self.ciContext render:image
                     toCVPixelBuffer:out
                              bounds:image.extent
                          colorSpace:M1ViewSRGBColorSpace()];
        }
        double costMs = M1ViewNowMs() - t0;
        uint32_t bucket = costMs >= (double)kM1RenderHistBuckets
                        ? kM1RenderHistBuckets - 1 : (uint32_t)costMs;
        atomic_fetch_add(&self->_renderHist[bucket], 1);
        CVPixelBufferRelease(held);

        IOSurfaceRef surface = out ? CVPixelBufferGetIOSurface(out) : NULL;
        if (!surface) {
            atomic_fetch_sub(&self->_pendingRenders, 1);
            atomic_fetch_add(&self->_framesDropped, 1);
            atomic_fetch_add(&self->_renderFailed, 1);
            return;
        }
        // 转换已完成，先释放转换槽位；主线程贴层单独计量等待。
        atomic_fetch_sub(&self->_pendingRenders, 1);
        double tDone = M1ViewNowMs();
        // 主线程赋值期间缓冲可能因尺寸变化被换掉，先把 surface 自己留住。
        CFRetain(surface);
        dispatch_async(dispatch_get_main_queue(), ^{
            M1AtomicMaxU64(&self->_maxMainWaitUs,
                           (uint64_t)((M1ViewNowMs() - tDone) * 1000.0));
            // 窗口不可见时不要贴帧：CALayer 的 contents 赋值会等合成器提交，
            // 窗口被遮住/锁屏时实测阻塞到 0.3~3 s，把整条渲染队列堵死。
            NSWindow *win = self.window;
            if (win && (win.occlusionState & NSWindowOcclusionStateVisible) == 0) {
                CFRelease(surface);
                atomic_fetch_add(&self->_skippedOccluded, 1);
                return;
            }
            if (self.videoSize.width != size.width || self.videoSize.height != size.height) {
                self.videoSize = size;
                [self setNeedsLayout:YES];
            }
            // CALayer 支持直接把 IOSurface 当 contents（零拷贝上屏）。
            self.layer.contents = (__bridge id)surface;
            CFRelease(surface);
            self.lastRenderMs = costMs;
            if (costMs > self.maxRenderMs) self.maxRenderMs = costMs;
            atomic_fetch_add(&self->_framesRendered, 1);

            // A-02：贴层完成即结算。这里不含显示器扫描，也不含相机，
            // 得到的是 capture→render，而不是严格 glass-to-glass。
            if (capturedAtUs > 0) {
                double rawMs = ((double)M1WallClockUs() - (double)capturedAtUs) / 1000.0;
                double idx = rawMs + (double)kM1PresentHistBaseMs;
                if (idx >= 0 && idx < (double)kM1PresentHistBuckets) {
                    uint32_t bucket = (uint32_t)idx;
                    atomic_fetch_add(&self->_presentLatHist[bucket], 1);
                    atomic_fetch_add(&self->_presentLatSamples, 1);
                    atomic_store(&self->_lastPresentLatencyMs, rawMs);
                    double prevMax = atomic_load(&self->_maxPresentLatencyMs);
                    while (rawMs > prevMax &&
                           !atomic_compare_exchange_weak(&self->_maxPresentLatencyMs,
                                                         &prevMax, rawMs)) {
                        // 重试直到写入更大的值
                    }
                }
            }
        });
    });
}

- (void)dealloc {
    if (_outBuffer) CVPixelBufferRelease(_outBuffer);
}

- (CGRect)videoRect {
    return M1AspectFitRect(self.videoSize, self.bounds);
}

- (NSUInteger)framesRendered { return (NSUInteger)atomic_load(&_framesRendered); }
- (NSUInteger)framesDropped  { return (NSUInteger)atomic_load(&_framesDropped); }
- (NSUInteger)renderDropped  { return (NSUInteger)atomic_load(&_renderDropped); }
- (NSUInteger)renderFailed   { return (NSUInteger)atomic_load(&_renderFailed); }
- (NSUInteger)maxPendingRenders { return (NSUInteger)atomic_load(&_maxPendingRenders); }
- (double)renderP50Ms { return M1HistPercentile(_renderHist, kM1RenderHistBuckets, 0.50); }
- (double)renderP95Ms { return M1HistPercentile(_renderHist, kM1RenderHistBuckets, 0.95); }
- (double)maxQueueWaitMs { return (double)atomic_load(&_maxQueueWaitUs) / 1000.0; }
- (double)maxMainWaitMs  { return (double)atomic_load(&_maxMainWaitUs) / 1000.0; }
- (NSUInteger)presentLatencySamples { return (NSUInteger)atomic_load(&_presentLatSamples); }
- (double)presentLatencyP50Ms {
    return M1HistPercentile(_presentLatHist, kM1PresentHistBuckets, 0.50)
         - (double)kM1PresentHistBaseMs;
}
- (double)presentLatencyP95Ms {
    return M1HistPercentile(_presentLatHist, kM1PresentHistBuckets, 0.95)
         - (double)kM1PresentHistBaseMs;
}
- (double)lastPresentLatencyMs { return atomic_load(&_lastPresentLatencyMs); }
- (double)maxPresentLatencyMs  { return atomic_load(&_maxPresentLatencyMs); }
- (NSUInteger)inputEventsEmitted { return (NSUInteger)atomic_load(&_inputEmitted); }
- (NSUInteger)framesSkippedOccluded { return (NSUInteger)atomic_load(&_skippedOccluded); }

#pragma mark - 输入：坐标与修饰键

- (NSDictionary<NSString *, NSNumber *> *)currentFlagsDict {
    NSEventModifierFlags f = [NSEvent modifierFlags];
    return @{
        @"cmd":   @((f & NSEventModifierFlagCommand) != 0),
        @"shift": @((f & NSEventModifierFlagShift) != 0),
        @"opt":   @((f & NSEventModifierFlagOption) != 0),
        @"ctrl":  @((f & NSEventModifierFlagControl) != 0),
        @"caps":  @((f & NSEventModifierFlagCapsLock) != 0),
    };
}

// 修饰键走「状态同步」而不是逐事件转发（PROTOCOL §3.1）：
// 只在状态变化时发一条全量 flags，省掉每个事件都带 flags 的冗余。
- (NSDictionary<NSString *, NSNumber *> *)syncModifierStateIfNeeded {
    NSDictionary<NSString *, NSNumber *> *now = [self currentFlagsDict];
    if (self.lastFlags && [self.lastFlags isEqualToDictionary:now]) return now;
    self.lastFlags = now;
    [self emitInputEvent:P1MakeFlagsEvent(now)];
    return now;
}

- (void)resetModifierState {
    self.lastFlags = nil;
    [self syncModifierStateIfNeeded];
}

- (void)emitInputEvent:(NSDictionary *)event {
    atomic_fetch_add(&_inputEmitted, 1);
    if (self.onInputEvent) self.onInputEvent(event);
}

// 事件坐标 → 归一化。落在黑边上返回 NO（不产生输入）：
// 黑边不属于目标屏内容，点它映射到边缘会造成「点不到但会点中角落」的错觉。
- (BOOL)normalizedPointForEvent:(NSEvent *)event out:(CGPoint *)out {
    CGRect rect = self.videoRect;
    if (rect.size.width <= 0 || rect.size.height <= 0) return NO;
    CGPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (!CGRectContainsPoint(rect, p)) return NO;
    if (out) *out = M1NormalizedPointFromViewPoint(p, rect);
    return YES;
}

- (void)emitMouse:(NSEvent *)event button:(NSString *)button action:(NSString *)action {
    CGPoint p;
    if (![self normalizedPointForEvent:event out:&p]) return;
    NSDictionary *flags = [self syncModifierStateIfNeeded];
    [self emitInputEvent:P1MakeMouseEvent(self.displayID, p.x, p.y, button, action, flags)];
}

#pragma mark - 输入：鼠标

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.trackingArea) [self removeTrackingArea:self.trackingArea];
    // 用 NSTrackingActiveAlways 而不是 ...InKeyWindow：命令行起的 App 常常拿不到
    // key window（实测 inputEmitted 一直是 0），用 key window 限定就一个事件都收不到。
    NSTrackingAreaOptions opts = NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                 NSTrackingActiveAlways | NSTrackingInVisibleRect;
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                     options:opts
                                                       owner:self
                                                    userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

// 调试用：M1_INPUT_DEBUG=1 时把每个到达视图的鼠标事件打出来。
// 「驱动了真光标但主机一条都没收到」时，先看这一层有没有事件，能立刻把
// 「系统没派发」和「派发了但被后半段丢掉」分开。
- (void)mouseEntered:(NSEvent *)event {
    if (getenv("M1_INPUT_DEBUG")) {
        printf("[view] mouseEntered win=(%.0f,%.0f)\n", event.locationInWindow.x, event.locationInWindow.y);
    }
    [self.window makeFirstResponder:self];
    [self emitMouse:event button:@"left" action:@"move"];
}

- (void)mouseMoved:(NSEvent *)event {
    if (getenv("M1_INPUT_DEBUG")) {
        printf("[view] mouseMoved win=(%.0f,%.0f) ts=%.3f dragging=%d\n",
               event.locationInWindow.x, event.locationInWindow.y,
               event.timestamp, (int)self.dragging);
    }
    if (self.dragging) return;   // 拖动由 mouseDragged 负责，避免重复事件
    // 同一份 NSEvent 会被投两次：一次按 hit-test 命中视图，一次按 tracking area
    // 派给 owner（本视图既是命中视图又是 owner，且开了 NSTrackingMouseMoved）。
    // 实测每次移动都变成 2 条上行事件，白占一倍带宽；物理鼠标同样如此。
    // 同一事件的时间戳与窗口内坐标必然相同，按此去重，不影响真实连续移动。
    if (self.hasLastMouseEvent &&
        event.timestamp == self.lastMouseEventTimestamp &&
        NSEqualPoints(event.locationInWindow, self.lastMouseEventPoint)) {
        return;
    }
    self.hasLastMouseEvent = YES;
    self.lastMouseEventTimestamp = event.timestamp;
    self.lastMouseEventPoint = event.locationInWindow;
    [self emitMouse:event button:@"left" action:@"move"];
}

- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    self.dragging = YES;
    [self emitMouse:event button:@"left" action:@"down"];
}

- (void)mouseDragged:(NSEvent *)event {
    [self emitMouse:event button:@"left" action:@"drag"];
}

- (void)mouseUp:(NSEvent *)event {
    self.dragging = NO;
    [self emitMouse:event button:@"left" action:@"up"];
}

- (void)rightMouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    self.rightDragging = YES;
    [self emitMouse:event button:@"right" action:@"down"];
}

- (void)rightMouseDragged:(NSEvent *)event {
    [self emitMouse:event button:@"right" action:@"drag"];
}

- (void)rightMouseUp:(NSEvent *)event {
    self.rightDragging = NO;
    [self emitMouse:event button:@"right" action:@"up"];
}

- (void)otherMouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    self.otherDragging = YES;
    [self emitMouse:event button:@"other" action:@"down"];
}

- (void)otherMouseDragged:(NSEvent *)event {
    [self emitMouse:event button:@"other" action:@"drag"];
}

- (void)otherMouseUp:(NSEvent *)event {
    self.otherDragging = NO;
    [self emitMouse:event button:@"other" action:@"up"];
}

- (void)scrollWheel:(NSEvent *)event {
    NSDictionary *flags = [self syncModifierStateIfNeeded];
    // 方向与 NSEvent 的 scrollingDelta 同向；Host 侧直接进 CGEventCreateScrollWheelEvent。
    [self emitInputEvent:P1MakeScrollEvent(self.displayID,
                                           event.scrollingDeltaX,
                                           event.scrollingDeltaY,
                                           flags)];
}

#pragma mark - 输入：键盘

- (void)keyDown:(NSEvent *)event {
    if (self.closesOnEscape && event.keyCode == 53) {
        if (self.onCloseRequest) self.onCloseRequest();
        return;
    }
    NSDictionary *flags = [self syncModifierStateIfNeeded];
    [self emitInputEvent:P1MakeKeyEvent(self.displayID, event.keyCode,
                                        M1PrintableCharacters(event), flags)];
}

- (void)keyUp:(NSEvent *)event {
    // 协议里 key 不带 down/up 位（Host 侧成对注入），这里只在 keyDown 发一次，
    // 避免同一按键被注入两遍。重复键（长按）由 keyDown 的 repeat 自然覆盖。
}

- (void)flagsChanged:(NSEvent *)event {
    [self syncModifierStateIfNeeded];
}

@end
