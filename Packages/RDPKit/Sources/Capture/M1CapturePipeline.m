//
//  M1CapturePipeline.m
//  M1-Skeleton
//

#import "M1CapturePipeline.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <string.h>
#include <math.h>

// CGSessionCopyCurrentDictionary 是公开 API；键名字符串在 13/26 通用。
// 用于在运行时识别锁屏态：CGDisplayStream 在锁屏态交付黑帧，而
// CGDisplayCreateImage 仍能看到登录界面（§5.28/§5.29）。
static BOOL M1ScreenIsLocked(void) {
    CFDictionaryRef d = CGSessionCopyCurrentDictionary();
    if (!d) return NO;
    BOOL locked = [((__bridge NSDictionary *)d)[@"CGSSessionScreenIsLocked"] boolValue];
    CFRelease(d);
    return locked;
}

static NSError *M1CaptureErr(M1PipelineErrorCode code, NSString *msg) {
    return [NSError errorWithDomain:M1PipelineErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static double M1WallMs(void) {
    return [[NSDate date] timeIntervalSince1970] * 1000.0;
}

// SCK 的 SCStreamFrameInfoDisplayTime 是 WindowServer 实际显示这一帧的
// mach 绝对时间。旧实现在回调里取 M1WallMs()，那是「交付时刻」，
// 积压时会比画面内容晚很多 ⇒ A-02 的 capturedAtUs 偏新、端到端被低估。
// 这里把它换算成 epoch 毫秒：先取一对同时刻的 mach/epoch，再按时间基差回推。
static double M1FrameDisplayEpochMs(CMSampleBufferRef sb) {
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (!atts || CFArrayGetCount(atts) == 0) return 0;
    CFDictionaryRef info = CFArrayGetValueAtIndex(atts, 0);
    CFTypeRef value = CFDictionaryGetValue(info, (CFStringRef)SCStreamFrameInfoDisplayTime);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) return 0;
    int64_t displayMach = 0;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &displayMach) ||
        displayMach <= 0) return 0;

    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    uint64_t nowMach = mach_absolute_time();
    if ((uint64_t)displayMach > nowMach) return 0;   // 未来时间：异常，回退到回调时刻
    uint64_t deltaNs = (uint64_t)(((double)(nowMach - (uint64_t)displayMach))
                                  * (double)tb.numer / (double)tb.denom);
    double epochMs = M1WallMs() - (double)deltaNs / 1e6;
    return epochMs > 0 ? epochMs : 0;
}

#pragma mark - 配置

@implementation M1CaptureConfig
- (instancetype)init {
    self = [super init];
    if (self) {
        _targetFps = 20;
        _showsCursor = NO;
        _capturesAudio = NO;
        _queueDepth = 4;
        _outputWidth = 0;
        _outputHeight = 0;
        _captureResolution = 0;
    }
    return self;
}
@end

#pragma mark - 统计

@interface M1CaptureStats ()
@property (nonatomic, assign) uint64_t framesDelivered;
@property (nonatomic, assign) uint64_t framesRejected;
@property (nonatomic, assign) double firstFrameLatencyMs;
@property (nonatomic, assign) double lastFrameIntervalMs;
@property (nonatomic, assign) uint64_t lastSecondDelivered;
@property (nonatomic, assign) uint64_t lastSecondIdle;
@end

@implementation M1CaptureStats
@end

static int M1FrameStatusOf(CMSampleBufferRef sb) {
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (!atts || CFArrayGetCount(atts) == 0) return -1;
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(atts, 0);
    NSNumber *st = info[(id)SCStreamFrameInfoStatus];
    return [st isKindOfClass:[NSNumber class]] ? st.intValue : -1;
}

static CGFloat M1FrameScaleOf(CMSampleBufferRef sb) {
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (!atts || CFArrayGetCount(atts) == 0) return 0;
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(atts, 0);
    NSNumber *sf = info[(id)SCStreamFrameInfoScaleFactor];
    return [sf isKindOfClass:[NSNumber class]] ? sf.doubleValue : 0;
}

#pragma mark - 输出代理

// SCStreamOutput + Delegate 需要一个独立对象：SCStream 对 delegate 是弱引用，
// 由 pipeline 强持有它，pipeline 生命周期内始终存活。
// CGDisplayStream 回退后端也复用这个对象做统计与帧分发（见 -deliverPixelBuffer:）。
@interface M1CaptureOutput : NSObject <SCStreamOutput, SCStreamDelegate> {
@public
    void (^_onFrame)(CVPixelBufferRef, double);
    void (^_onError)(NSError *);
    atomic_uint_fast64_t _framesDelivered;
    atomic_uint_fast64_t _framesRejected;
    atomic_uint_fast64_t _lastSecondDelivered;
    atomic_uint_fast64_t _lastSecondIdle;
    uint64_t _secDelivered;
    uint64_t _secRejected;
    uint64_t _secStatus[6];
    double _secStartMs;
    double _startMs;
    double _lastFrameMs;
    _Atomic double _firstFrameLatencyMs;
    _Atomic double _lastIntervalMs;
    _Atomic double _lastScale;
    BOOL _running;
}
- (void)deliverPixelBuffer:(CVPixelBufferRef)pb ptsMs:(double)ptsMs;
@end

@implementation M1CaptureOutput

- (void)stream:(SCStream *)stream
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) {
        atomic_fetch_add(&_framesRejected, 1);
        return;
    }
    if (!_running) return;

    int status = M1FrameStatusOf(sampleBuffer);
    if (status >= 0 && status < 6) _secStatus[status]++;
    CGFloat frameScale = M1FrameScaleOf(sampleBuffer);
    if (frameScale > 0) atomic_store(&_lastScale, (double)frameScale);

    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    // 用 WindowServer 的显示时刻而不是回调时刻：积压时两者差可达秒级，
    // 用后者会把 capturedAtUs 标成「新帧」，端到端延迟被系统性低估。
    double ptsMs = M1FrameDisplayEpochMs(sampleBuffer);
    if (ptsMs <= 0) ptsMs = M1WallMs();
    [self deliverPixelBuffer:pb ptsMs:ptsMs];
}

// SCK 与 CGDisplayStream 的公共帧出口：在这里统一做统计与时间戳，
// 下游（VT 编码 / 分片 / QUIC）完全看不到后端差异。
- (void)deliverPixelBuffer:(CVPixelBufferRef)pb ptsMs:(double)ptsMs {
    if (!_running) return;
    if (!pb) {
        atomic_fetch_add(&_framesRejected, 1);
        _secRejected++;
        [self tickSecondIfNeeded];
        return;
    }

    double now = ptsMs > 0 ? ptsMs : M1WallMs();
    if (atomic_load(&_firstFrameLatencyMs) <= 0 && _startMs > 0) {
        atomic_store(&_firstFrameLatencyMs, now - _startMs);
    }
    if (_lastFrameMs > 0) {
        atomic_store(&_lastIntervalMs, now - _lastFrameMs);
    }
    _lastFrameMs = now;

    atomic_fetch_add(&_framesDelivered, 1);
    _secDelivered++;
    [self tickSecondIfNeeded];
    if (_onFrame) _onFrame(pb, now);
}

// 每秒打印一次状态分布：区分「有画面但帧率低」与「系统判定无变化(idle)」。
- (void)tickSecondIfNeeded {
    double now = M1WallMs();
    if (_secStartMs <= 0) {
        _secStartMs = now;
        return;
    }
    if (now - _secStartMs < 1000.0) return;
    printf("[capture] +%.0fs: delivered=%llu rejected=%llu "
           "[complete=%llu idle=%llu blank=%llu suspended=%llu started=%llu stopped=%llu] "
           "lastInterval=%.0fms scale=%.2f\n",
           (now - _startMs) / 1000.0,
           (unsigned long long)_secDelivered,
           (unsigned long long)_secRejected,
           (unsigned long long)_secStatus[0],
           (unsigned long long)_secStatus[1],
           (unsigned long long)_secStatus[2],
           (unsigned long long)_secStatus[3],
           (unsigned long long)_secStatus[4],
           (unsigned long long)_secStatus[5],
           atomic_load(&_lastIntervalMs),
           (double)_lastScale);
    fflush(stdout);
    atomic_store(&_lastSecondDelivered, _secDelivered);
    atomic_store(&_lastSecondIdle, _secStatus[1]);
    _secDelivered = 0;
    _secRejected = 0;
    memset(_secStatus, 0, sizeof(_secStatus));
    _secStartMs = now;
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if (_onError) {
        _onError(M1CaptureErr(M1PipelineErrorCaptureFailed,
            [NSString stringWithFormat:@"SCStream 意外停止: %@",
             error.localizedDescription ?: @"unknown"]));
    }
}

@end

#pragma mark - CGDisplayStream 回退后端

// 只在 macOS 13 或 SCK 建流失败时启用。CGDisplayStream 自 14 deprecated、
// 15 obsoleted；这里用部署目标 13 + 编译警告抑制保留这条兼容路径。
// 注意：回调给的是 IOSurface，等价于 SCK 的 CMSampleBuffer 里的像素缓冲，
// 用 CVPixelBufferCreateWithIOSurface 包一层即可复用现有编码器。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface M1CGDisplaySource : NSObject {
@public
    CGDisplayStreamRef _stream;
    dispatch_queue_t _queue;
    M1CaptureOutput *_sink;
}
- (BOOL)startWithDisplay:(CGDirectDisplayID)displayID
                   width:(size_t)width
                  height:(size_t)height
                     fps:(int)fps
              showCursor:(BOOL)showCursor
                    sink:(M1CaptureOutput *)sink
                   error:(NSError **)error;
- (void)stop;
@end

@implementation M1CGDisplaySource

- (BOOL)startWithDisplay:(CGDirectDisplayID)displayID
                   width:(size_t)width
                  height:(size_t)height
                     fps:(int)fps
              showCursor:(BOOL)showCursor
                    sink:(M1CaptureOutput *)sink
                   error:(NSError **)error {
    NSMutableDictionary *props = [NSMutableDictionary dictionary];
    // CGDisplayStream 只在内容变化时出帧；设定最小间隔避免空闲屏刷到 60fps。
    props[(id)kCGDisplayStreamMinimumFrameTime] = @(1.0 / (double)MAX(1, fps));
    props[(id)kCGDisplayStreamShowCursor] = @(showCursor ? YES : NO);

    dispatch_queue_t q = dispatch_queue_create("m1.capture.cgdisplay", DISPATCH_QUEUE_SERIAL);
    __weak typeof(self) weakSelf = self;
    CGDisplayStreamRef s = CGDisplayStreamCreateWithDispatchQueue(
        displayID, width, height, (int32_t)kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)props, q,
        ^(CGDisplayStreamFrameStatus status, uint64_t displayTime,
          IOSurfaceRef surface, CGDisplayStreamUpdateRef updateRef) {
        @autoreleasepool {
            M1CGDisplaySource *strong = weakSelf;
            if (!strong) return;
            M1CaptureOutput *sink = strong->_sink;
            if (!sink || !sink->_running) return;
            if (status != kCGDisplayStreamFrameStatusFrameComplete || !surface) return;

            CVPixelBufferRef pb = NULL;
            CVReturn cr = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault,
                                                           surface, NULL, &pb);
            if (cr != kCVReturnSuccess || !pb) {
                atomic_fetch_add(&sink->_framesRejected, 1);
                return;
            }
            [sink deliverPixelBuffer:pb ptsMs:M1WallMs()];
            CVPixelBufferRelease(pb);
        }
    });
    if (!s) {
        if (error) *error = M1CaptureErr(M1PipelineErrorCaptureFailed,
            @"CGDisplayStreamCreateWithDispatchQueue 返回空 stream");
        return NO;
    }

    // 先挂 sink/queue 再 start：回调可能在 start 内立即触发。
    _sink = sink;
    _queue = q;
    CGError rc = CGDisplayStreamStart(s);
    if (rc != kCGErrorSuccess) {
        CFRelease(s);
        _sink = nil;
        _queue = nil;
        if (error) *error = M1CaptureErr(M1PipelineErrorCaptureFailed,
            [NSString stringWithFormat:@"CGDisplayStreamStart 失败: %d", (int)rc]);
        return NO;
    }
    _stream = s;
    printf("[capture] backend=CGDisplayStream display=%u out=%zux%zu fps=%d "
           "cursor=%d (iOSurface→CVPixelBuffer)\n",
           displayID, width, height, fps, showCursor ? 1 : 0);
    fflush(stdout);
    return YES;
}

- (void)stop {
    if (_stream) {
        CGDisplayStreamStop(_stream);
        CFRelease(_stream);
        _stream = NULL;
    }
    _queue = nil;
    _sink = nil;
}

@end

#pragma clang diagnostic pop

#pragma mark - CGDisplayCreateImage 轮询后端（锁屏态专用）

// CGDisplayStream 在锁屏态仍以低频出帧，但帧内容是纯黑（§5.28）。
// 同一 TCC 状态下 CGDisplayCreateImage 能拿到完整登录界面（§5.29），
// 因此锁屏态改用同步快照轮询。该 API 自 14 deprecated，仅在锁屏态启用。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface M1CGImageSource : NSObject {
@public
    CGDirectDisplayID _displayID;
    size_t _width;
    size_t _height;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    M1CaptureOutput *_sink;
    int _nullCount;
}
- (BOOL)startWithDisplay:(CGDirectDisplayID)displayID
                   width:(size_t)width
                  height:(size_t)height
                     fps:(int)fps
                    sink:(M1CaptureOutput *)sink
                   error:(NSError **)error;
- (void)stop;
@end

@implementation M1CGImageSource

- (BOOL)startWithDisplay:(CGDirectDisplayID)displayID
                   width:(size_t)width
                  height:(size_t)height
                     fps:(int)fps
                    sink:(M1CaptureOutput *)sink
                   error:(NSError **)error {
    CGImageRef first = CGDisplayCreateImage(displayID);
    if (!first) {
        if (error) *error = M1CaptureErr(M1PipelineErrorCaptureFailed,
            @"CGDisplayCreateImage 首帧为 NULL（TCC 未授权或显示器已睡眠）");
        return NO;
    }
    CGImageRelease(first);

    _displayID = displayID;
    _width = width;
    _height = height;
    _sink = sink;
    _nullCount = 0;
    _queue = dispatch_queue_create("m1.capture.cgimage", DISPATCH_QUEUE_SERIAL);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    uint64_t interval = (uint64_t)(1e9 / (double)MAX(1, fps));
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              interval, interval / 4);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        @autoreleasepool {
            M1CGImageSource *strong = weakSelf;
            if (!strong) return;
            M1CaptureOutput *sinkRef = strong->_sink;
            if (!sinkRef || !sinkRef->_running) return;

            CGImageRef img = CGDisplayCreateImage(strong->_displayID);
            if (!img) {
                strong->_nullCount++;
                if (strong->_nullCount == 1 || strong->_nullCount % 30 == 0) {
                    printf("[capture] CGDisplayCreateImage 返回 NULL (%d 次): "
                           "显示器可能已睡眠，需 caffeinate -d\n", strong->_nullCount);
                    fflush(stdout);
                }
                atomic_fetch_add(&sinkRef->_framesRejected, 1);
                return;
            }
            strong->_nullCount = 0;

            size_t w = strong->_width, h = strong->_height;
            CVPixelBufferRef pb = NULL;
            NSDictionary *attrs = @{ (__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
            CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                              kCVPixelFormatType_32BGRA,
                                              (__bridge CFDictionaryRef)attrs, &pb);
            if (cr != kCVReturnSuccess || !pb) {
                CGImageRelease(img);
                atomic_fetch_add(&sinkRef->_framesRejected, 1);
                return;
            }
            BOOL ok = NO;
            if (CVPixelBufferLockBaseAddress(pb, 0) == kCVReturnSuccess) {
                void *base = CVPixelBufferGetBaseAddress(pb);
                size_t rowBytes = CVPixelBufferGetBytesPerRow(pb);
                CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, rowBytes, cs,
                    kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
                CGColorSpaceRelease(cs);
                if (ctx) {
                    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
                    CGContextRelease(ctx);
                    ok = YES;
                }
                CVPixelBufferUnlockBaseAddress(pb, 0);
            }
            CGImageRelease(img);
            if (!ok) {
                CVPixelBufferRelease(pb);
                atomic_fetch_add(&sinkRef->_framesRejected, 1);
                return;
            }
            [sinkRef deliverPixelBuffer:pb ptsMs:M1WallMs()];
            CVPixelBufferRelease(pb);
        }
    });
    dispatch_resume(_timer);
    printf("[capture] backend=CGDisplayCreateImage display=%u out=%zux%zu fps=%d "
           "(锁屏态快照轮询)\n", displayID, width, height, fps);
    fflush(stdout);
    return YES;
}

- (void)stop {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = NULL;
    }
    _queue = nil;
    _sink = nil;
}

@end

#pragma clang diagnostic pop

#pragma mark - 采集管线

@interface M1CapturePipeline () {
    CGDirectDisplayID _displayID;
    M1CaptureConfig *_config;
    void (^_onFrame)(CVPixelBufferRef, double);
    void (^_onError)(NSError *);
    SCStream *_stream;
    M1CaptureOutput *_output;
    M1CGDisplaySource *_cgSource;
    M1CGImageSource *_cgImageSource;
    dispatch_queue_t _queue;
    dispatch_queue_t _monitorQueue;
    dispatch_source_t _monitorTimer;
    int _preferredBackend;   // 0=SCK, 1=CGDisplayStream
    BOOL _lastLocked;
    size_t _outWidth;
    size_t _outHeight;
    int32_t _pixelWidth;
    int32_t _pixelHeight;
    BOOL _running;
}
- (BOOL)startSCKWithError:(NSError **)error;
- (BOOL)startCGWithError:(NSError **)error;
- (BOOL)startCGImageWithError:(NSError **)error;
- (void)stopBackendSourcesKeepingOutput;
- (void)startLockMonitor;
- (void)setupOutput:(M1CaptureOutput *)output;
@end

@implementation M1CapturePipeline

- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID
                           config:(M1CaptureConfig *)config
                          onFrame:(void (^)(CVPixelBufferRef, double))onFrame
                          onError:(void (^)(NSError *))onError {
    NSParameterAssert(config);
    NSParameterAssert(onFrame);
    self = [super init];
    if (self) {
        _displayID = displayID;
        _config = config;
        _onFrame = [onFrame copy];
        _onError = [onError copy];
        _pixelWidth = 0;
        _pixelHeight = 0;
        _running = NO;
    }
    return self;
}

- (BOOL)isRunning { return _running; }
- (int32_t)pixelWidth { return _pixelWidth; }
- (int32_t)pixelHeight { return _pixelHeight; }

- (BOOL)start:(NSError **)error {
    if (error) *error = nil;
    if (_running) return YES;

    // 安全阀 1：退化 mode 拒绝采集。此检查与后端无关，必须先做。
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(_displayID);
    size_t mw = mode ? CGDisplayModeGetWidth(mode) : 0;
    size_t mh = mode ? CGDisplayModeGetHeight(mode) : 0;
    if (mode) CGDisplayModeRelease(mode);
    if (mw < 2 || mh < 2) {
        if (error) *error = M1CaptureErr(M1PipelineErrorDegenerateMode,
            [NSString stringWithFormat:@"退化 mode %zux%zu（未提交），拒绝采集", mw, mh]);
        return NO;
    }

    // 版本门控：13 直接走 CGDisplayStream（实测 SCK/SkyLight 在本机 13.6.7
    // 无法建流）；14+ 优先 SCK，失败时同样回退 CGDisplayStream。
    BOOL useSCK = NO;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 140000
    if (@available(macOS 14.0, *)) useSCK = YES;
#endif
    const char *forcedBackend = getenv("M1_CAPTURE_BACKEND");
    BOOL forceCGImage = NO;
    if (forcedBackend && !strcasecmp(forcedBackend, "cg")) useSCK = NO;
    if (forcedBackend && !strcasecmp(forcedBackend, "sck")) useSCK = YES;
    if (forcedBackend && !strcasecmp(forcedBackend, "cgimage")) forceCGImage = YES;
    _preferredBackend = useSCK ? 0 : 1;

    NSError *sckErr = nil;
    NSError *cgErr = nil;

    // 锁屏态：CGDisplayStream 只交付黑帧，必须改用 CGDisplayCreateImage 快照轮询。
    // 显示器睡眠时该 API 返回 NULL，需要 p2.sh 已有的 caffeinate -d 断言先唤醒。
    if (forceCGImage || M1ScreenIsLocked()) {
        NSError *imgErr = nil;
        if ([self startCGImageWithError:&imgErr]) {
            [self startLockMonitor];
            return YES;
        }
        printf("[capture] CGDisplayCreateImage 后端不可用: %s%s\n",
               imgErr.localizedDescription.UTF8String ?: "unknown",
               forceCGImage ? "（强制模式，不回退）" : "（回退常规后端）");
        fflush(stdout);
        if (forceCGImage) {
            if (error) *error = imgErr;
            return NO;
        }
    }

    if (useSCK && [self startSCKWithError:&sckErr]) {
        [self startLockMonitor];
        return YES;
    }
    if (useSCK) {
        printf("[capture] SCK 后端失败，回退 CGDisplayStream: %s\n",
               sckErr.localizedDescription.UTF8String ?: "unknown");
        fflush(stdout);
        // 不要在 startCapture 失败的 stream 上 removeStreamOutput：
        // macOS 13 的 SCStream 从未 start 成功时底层 CG stream 为空，
        // removeStreamOutput 会 EXC_BAD_ACCESS（§5.25）。这里只摘引用，
        // 由 ARC 释放局部对象。
        _stream = nil;
        _output = nil;
        _queue = nil;
    }

    if (![self startCGWithError:&cgErr]) {
        if (error) {
            if (sckErr) {
                *error = M1CaptureErr(M1PipelineErrorCaptureFailed,
                    [NSString stringWithFormat:@"SCK: %@; CGDisplayStream: %@",
                     sckErr.localizedDescription ?: @"unknown",
                     cgErr.localizedDescription ?: @"unknown"]);
            } else {
                *error = cgErr;
            }
        }
        return NO;
    }
    [self startLockMonitor];
    return YES;
}

- (void)setupOutput:(M1CaptureOutput *)output {
    output->_onFrame = [_onFrame copy];
    output->_onError = [_onError copy];
    atomic_init(&output->_framesDelivered, 0);
    atomic_init(&output->_framesRejected, 0);
    atomic_init(&output->_lastSecondDelivered, 0);
    atomic_init(&output->_lastSecondIdle, 0);
    atomic_store(&output->_firstFrameLatencyMs, 0.0);
    atomic_store(&output->_lastIntervalMs, 0.0);
    atomic_store(&output->_lastScale, 0.0);
    output->_startMs = M1WallMs();
    output->_secStartMs = output->_startMs;
    output->_lastFrameMs = 0;
    memset(output->_secStatus, 0, sizeof(output->_secStatus));
    output->_secDelivered = 0;
    output->_secRejected = 0;
    output->_running = YES;
}

- (BOOL)startSCKWithError:(NSError **)error {
    NSError *contentErr = nil;
    SCShareableContent *content = [self syncShareableContentWithError:&contentErr];
    if (!content) {
        if (error) *error = contentErr ?: M1CaptureErr(M1PipelineErrorCaptureFailed,
                                                        @"SCShareableContent 失败");
        return NO;
    }

    SCDisplay *target = nil;
    for (SCDisplay *d in content.displays) {
        if (d.displayID == _displayID) { target = d; break; }
    }
    if (!target) {
        if (error) *error = M1CaptureErr(M1PipelineErrorCaptureFailed,
            @"该 displayID 不在 SCShareableContent.displays 中（stale display 的典型症状）");
        return NO;
    }

    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:target
                                                      excludingWindows:@[]];
    SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];

    // 安全阀 2：HiDPI 乘 pointPixelScale（macOS 14+ 才有该属性）。
    // 编译期也要守卫：macOS 13 SDK 的 ScreenCaptureKit 头没有该属性声明，
    // 只有 @available 运行时判断仍会报 property not found。
    CGFloat scale = 1.0;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 140000
    if (@available(macOS 14.0, *)) {
        if (filter.pointPixelScale > 0) scale = filter.pointPixelScale;
    }
#endif
    // 目标输出尺寸：显式指定优先（降采样验证目标档），否则用屏幕原始像素。
    size_t outW, outH;
    if (_config.outputWidth > 0 && _config.outputHeight > 0) {
        outW = (size_t)_config.outputWidth;
        outH = (size_t)_config.outputHeight;
    } else {
        outW = (size_t)llround((double)target.width * (double)scale);
        outH = (size_t)llround((double)target.height * (double)scale);
    }
    // 安全阀 3：宽高取偶数，H.264 要求。
    outW -= outW % 2;
    outH -= outH % 2;
    if (outW < 2 || outH < 2) {
        if (error) *error = M1CaptureErr(M1PipelineErrorDegenerateMode,
            [NSString stringWithFormat:@"换算后尺寸 %zux%zu 非法", outW, outH]);
        return NO;
    }

    cfg.width = outW;
    cfg.height = outH;
    cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    int32_t fps = MAX(1, _config.targetFps);
    cfg.minimumFrameInterval = CMTimeMake(1, fps);
    cfg.queueDepth = (size_t)MAX(1, _config.queueDepth);
    cfg.showsCursor = _config.showsCursor;
    cfg.capturesAudio = _config.capturesAudio;
    cfg.scalesToFit = YES;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 140000
    if (@available(macOS 14.0, *)) {
        cfg.preservesAspectRatio = YES;
        if (_config.captureResolution == 1) cfg.captureResolution = SCCaptureResolutionBest;
        else if (_config.captureResolution == 2) cfg.captureResolution = SCCaptureResolutionNominal;
    }
#endif
    {
        CGDisplayModeRef dm = CGDisplayCopyDisplayMode(_displayID);
        size_t dw = dm ? CGDisplayModeGetWidth(dm) : 0;
        size_t dh = dm ? CGDisplayModeGetHeight(dm) : 0;
        double hz = dm ? CGDisplayModeGetRefreshRate(dm) : 0;
        if (dm) CGDisplayModeRelease(dm);
        const char *resName = _config.captureResolution == 1 ? "best"
                            : _config.captureResolution == 2 ? "nominal" : "auto";
        printf("[capture] backend=ScreenCaptureKit display=%u mode=%zux%zu@%.1fHz "
               "sck=%zux%zu scale=%.2f out=%zux%zu fps=%d qDepth=%d res=%s\n",
               _displayID, dw, dh, hz, (size_t)target.width, (size_t)target.height,
               (double)scale, outW, outH, fps, _config.queueDepth, resName);
        fflush(stdout);
    }

    M1CaptureOutput *output = [[M1CaptureOutput alloc] init];
    [self setupOutput:output];

    NSError *streamErr = nil;
    SCStream *stream = [[SCStream alloc] initWithFilter:filter
                                          configuration:cfg
                                               delegate:output];
    _queue = dispatch_queue_create("m1.capture.sample", DISPATCH_QUEUE_SERIAL);
    if (![stream addStreamOutput:output
                            type:SCStreamOutputTypeScreen
              sampleHandlerQueue:_queue
                           error:&streamErr]) {
        if (error) *error = M1CaptureErr(M1PipelineErrorCaptureFailed,
            [NSString stringWithFormat:@"addStreamOutput 失败: %@",
             streamErr.localizedDescription ?: @"unknown"]);
        return NO;
    }

    // 同步等待 startCapture 完成，避免「start 返回了但还没真正开始」的竞态。
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSError *startErr = nil;
    [stream startCaptureWithCompletionHandler:^(NSError *e) {
        startErr = e;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (startErr) {
        if (error) *error = M1CaptureErr(M1PipelineErrorCaptureFailed,
            [NSString stringWithFormat:@"startCapture 失败: %@",
             startErr.localizedDescription ?: @"unknown"]);
        return NO;
    }

    _stream = stream;
    _output = output;
    _pixelWidth = (int32_t)outW;
    _pixelHeight = (int32_t)outH;
    _running = YES;
    return YES;
}

- (BOOL)startCGWithError:(NSError **)error {
    // CGDisplayStream 的输出尺寸是像素（不是 point）；13 上没有 pointPixelScale，
    // 直接用 CGDisplayPixelsWide/High。显式 outputWidth/Height 仍优先。
    size_t outW = (size_t)CGDisplayPixelsWide(_displayID);
    size_t outH = (size_t)CGDisplayPixelsHigh(_displayID);
    if (_config.outputWidth > 0 && _config.outputHeight > 0) {
        outW = (size_t)_config.outputWidth;
        outH = (size_t)_config.outputHeight;
    }
    outW -= outW % 2;
    outH -= outH % 2;
    if (outW < 2 || outH < 2) {
        if (error) *error = M1CaptureErr(M1PipelineErrorDegenerateMode,
            [NSString stringWithFormat:@"CG 换算后尺寸 %zux%zu 非法", outW, outH]);
        return NO;
    }

    M1CaptureOutput *output = [[M1CaptureOutput alloc] init];
    [self setupOutput:output];

    M1CGDisplaySource *source = [[M1CGDisplaySource alloc] init];
    NSError *cgErr = nil;
    if (![source startWithDisplay:_displayID
                            width:outW
                           height:outH
                              fps:MAX(1, _config.targetFps)
                       showCursor:_config.showsCursor
                             sink:output
                            error:&cgErr]) {
        output->_running = NO;
        if (error) *error = cgErr;
        return NO;
    }

    _cgSource = source;
    _output = output;
    _pixelWidth = (int32_t)outW;
    _pixelHeight = (int32_t)outH;
    _running = YES;
    return YES;
}

- (BOOL)startCGImageWithError:(NSError **)error {
    size_t outW = (size_t)CGDisplayPixelsWide(_displayID);
    size_t outH = (size_t)CGDisplayPixelsHigh(_displayID);
    if (_config.outputWidth > 0 && _config.outputHeight > 0) {
        outW = (size_t)_config.outputWidth;
        outH = (size_t)_config.outputHeight;
    }
    outW -= outW % 2;
    outH -= outH % 2;
    if (outW < 2 || outH < 2) {
        if (error) *error = M1CaptureErr(M1PipelineErrorDegenerateMode,
            [NSString stringWithFormat:@"CGImage 换算后尺寸 %zux%zu 非法", outW, outH]);
        return NO;
    }

    // 锁屏切换时复用同一个 output（统计与下游 block 不中断）。
    M1CaptureOutput *output = _output;
    if (!output) {
        output = [[M1CaptureOutput alloc] init];
        [self setupOutput:output];
        _output = output;
    }

    M1CGImageSource *source = [[M1CGImageSource alloc] init];
    NSError *imgErr = nil;
    if (![source startWithDisplay:_displayID
                            width:outW
                           height:outH
                              fps:MAX(1, _config.targetFps)
                             sink:output
                            error:&imgErr]) {
        if (error) *error = imgErr;
        return NO;
    }
    _cgImageSource = source;
    _outWidth = outW;
    _outHeight = outH;
    _pixelWidth = (int32_t)outW;
    _pixelHeight = (int32_t)outH;
    _running = YES;
    return YES;
}

- (void)stopBackendSourcesKeepingOutput {
    if (_stream) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [_stream stopCaptureWithCompletionHandler:^(NSError *e) {
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        [_stream removeStreamOutput:_output type:SCStreamOutputTypeScreen error:NULL];
        _stream = nil;
    }
    if (_cgSource) {
        [_cgSource stop];
        _cgSource = nil;
    }
    // 不碰 _output->_running / _queue：锁屏切换期间下游不能中断。
}

- (void)startLockMonitor {
    if (_monitorTimer) return;
    _lastLocked = M1ScreenIsLocked();
    if (_outWidth == 0) {
        _outWidth = (size_t)_pixelWidth;
        _outHeight = (size_t)_pixelHeight;
    }
    _monitorQueue = dispatch_queue_create("m1.capture.lockwatch", DISPATCH_QUEUE_SERIAL);
    _monitorTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _monitorQueue);
    dispatch_source_set_timer(_monitorTimer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                              1 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_monitorTimer, ^{
        M1CapturePipeline *strong = weakSelf;
        if (!strong || !strong->_running) return;
        BOOL locked = M1ScreenIsLocked();
        if (locked == strong->_lastLocked) return;
        printf("[capture] 锁屏状态变化 locked=%d，切换采集后端\n", locked ? 1 : 0);
        fflush(stdout);
        strong->_lastLocked = locked;
        if (locked) {
            [strong stopBackendSourcesKeepingOutput];
            NSError *imgErr = nil;
            if (![strong startCGImageWithError:&imgErr]) {
                printf("[capture] 锁屏快照后端启动失败: %s，退回常规后端\n",
                       imgErr.localizedDescription.UTF8String ?: "unknown");
                fflush(stdout);
                NSError *e = nil;
                if (strong->_preferredBackend == 0) {
                    if (![strong startSCKWithError:&e]) [strong startCGWithError:NULL];
                } else {
                    [strong startCGWithError:NULL];
                }
                strong->_lastLocked = NO;
            }
        } else {
            if (strong->_cgImageSource) {
                [strong->_cgImageSource stop];
                strong->_cgImageSource = nil;
            }
            if (strong->_output) strong->_output->_running = NO;
            NSError *e = nil;
            if (strong->_preferredBackend == 0) {
                if (![strong startSCKWithError:&e]) [strong startCGWithError:NULL];
            } else {
                [strong startCGWithError:NULL];
            }
        }
    });
    dispatch_resume(_monitorTimer);
}

- (void)stop {
    _running = NO;
    if (_output) _output->_running = NO;

    if (_monitorTimer) {
        dispatch_source_cancel(_monitorTimer);
        _monitorTimer = NULL;
        _monitorQueue = nil;
    }
    if (_cgImageSource) {
        [_cgImageSource stop];
        _cgImageSource = nil;
    }

    if (_stream) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [_stream stopCaptureWithCompletionHandler:^(NSError *e) {
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        [_stream removeStreamOutput:_output type:SCStreamOutputTypeScreen error:NULL];
    }
    if (_cgSource) {
        [_cgSource stop];
        _cgSource = nil;
    }
    _stream = nil;
    _output = nil;
    _queue = nil;
}

- (M1CaptureStats *)stats {
    M1CaptureStats *s = [[M1CaptureStats alloc] init];
    if (_output) {
        s.framesDelivered = atomic_load(&_output->_framesDelivered);
        s.framesRejected = atomic_load(&_output->_framesRejected);
        s.firstFrameLatencyMs = atomic_load(&_output->_firstFrameLatencyMs);
        s.lastFrameIntervalMs = atomic_load(&_output->_lastIntervalMs);
        s.lastSecondDelivered = atomic_load(&_output->_lastSecondDelivered);
        s.lastSecondIdle = atomic_load(&_output->_lastSecondIdle);
    }
    return s;
}

// SCShareableContent 的同步获取：用信号量包住异步 API。
- (SCShareableContent * _Nullable)syncShareableContentWithError:(NSError **)error {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block SCShareableContent *result = nil;
    __block NSError *innerErr = nil;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                              onScreenWindowsOnly:YES
                                                completionHandler:^(SCShareableContent *c, NSError *e) {
        result = c;
        innerErr = e;
        dispatch_semaphore_signal(sem);
    }];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
        if (error) *error = M1CaptureErr(M1PipelineErrorCaptureFailed,
                                          @"SCShareableContent 超时（5s）");
        return nil;
    }
    if (!result) {
        if (error) *error = M1CaptureErr(M1PipelineErrorCaptureFailed,
            [NSString stringWithFormat:@"SCShareableContent: %@",
             innerErr.localizedDescription ?: @"unknown"]);
    }
    return result;
}

@end
