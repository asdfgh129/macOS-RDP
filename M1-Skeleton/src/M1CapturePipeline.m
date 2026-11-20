//
//  M1CapturePipeline.m
//  M1-Skeleton
//

#import "M1CapturePipeline.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#include <stdatomic.h>
#include <string.h>
#include <math.h>

static NSError *M1CaptureErr(M1PipelineErrorCode code, NSString *msg) {
    return [NSError errorWithDomain:M1PipelineErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static double M1WallMs(void) {
    return [[NSDate date] timeIntervalSince1970] * 1000.0;
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
    if (!pb) {
        atomic_fetch_add(&_framesRejected, 1);
        _secRejected++;
        [self tickSecondIfNeeded];
        return;
    }

    double now = M1WallMs();
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
    double ptsMs = now;
    if (_onFrame) _onFrame(pb, ptsMs);
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

#pragma mark - 采集管线

@interface M1CapturePipeline () {
    CGDirectDisplayID _displayID;
    M1CaptureConfig *_config;
    void (^_onFrame)(CVPixelBufferRef, double);
    void (^_onError)(NSError *);
    SCStream *_stream;
    M1CaptureOutput *_output;
    dispatch_queue_t _queue;
    int32_t _pixelWidth;
    int32_t _pixelHeight;
    BOOL _running;
}
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
    if (_stream) return YES;

    // 安全阀 1：退化 mode 拒绝采集。
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(_displayID);
    size_t mw = mode ? CGDisplayModeGetWidth(mode) : 0;
    size_t mh = mode ? CGDisplayModeGetHeight(mode) : 0;
    if (mode) CGDisplayModeRelease(mode);
    if (mw < 2 || mh < 2) {
        if (error) *error = M1CaptureErr(M1PipelineErrorDegenerateMode,
            [NSString stringWithFormat:@"退化 mode %zux%zu（未提交），拒绝采集", mw, mh]);
        return NO;
    }

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
    CGFloat scale = 1.0;
    if (@available(macOS 14.0, *)) {
        if (filter.pointPixelScale > 0) scale = filter.pointPixelScale;
    }
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
    if (@available(macOS 14.0, *)) {
        cfg.preservesAspectRatio = YES;
        if (_config.captureResolution == 1) cfg.captureResolution = SCCaptureResolutionBest;
        else if (_config.captureResolution == 2) cfg.captureResolution = SCCaptureResolutionNominal;
    }
    {
        CGDisplayModeRef dm = CGDisplayCopyDisplayMode(_displayID);
        size_t dw = dm ? CGDisplayModeGetWidth(dm) : 0;
        size_t dh = dm ? CGDisplayModeGetHeight(dm) : 0;
        double hz = dm ? CGDisplayModeGetRefreshRate(dm) : 0;
        if (dm) CGDisplayModeRelease(dm);
        const char *resName = _config.captureResolution == 1 ? "best"
                            : _config.captureResolution == 2 ? "nominal" : "auto";
        printf("[capture] display=%u mode=%zux%zu@%.1fHz sck=%zux%zu scale=%.2f "
               "out=%zux%zu fps=%d qDepth=%d res=%s\n",
               _displayID, dw, dh, hz, (size_t)target.width, (size_t)target.height,
               (double)scale, outW, outH, fps, _config.queueDepth, resName);
        fflush(stdout);
    }

    M1CaptureOutput *output = [[M1CaptureOutput alloc] init];
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
    output->_running = YES;

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
        [stream removeStreamOutput:output type:SCStreamOutputTypeScreen error:NULL];
        return NO;
    }

    _stream = stream;
    _output = output;
    _pixelWidth = (int32_t)outW;
    _pixelHeight = (int32_t)outH;
    _running = YES;
    return YES;
}

- (void)stop {
    _running = NO;
    if (_output) _output->_running = NO;
    if (!_stream) {
        _output = nil;
        return;
    }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [_stream stopCaptureWithCompletionHandler:^(NSError *e) {
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    [_stream removeStreamOutput:_output type:SCStreamOutputTypeScreen error:NULL];
    _stream = nil;
    _output = nil;
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
