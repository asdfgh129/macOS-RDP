//
//  M1FramePipeline.m
//  M1-Skeleton
//

#import "M1FramePipeline.h"
#import "M1WallClock.h"
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>

static double NowMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

// 连续多少帧因超分片上限失败后，升级为一次明确告警（而不是每帧刷同一条错误）。
static const NSUInteger kM1FragFailureAlertThreshold = 3;

#pragma mark - 配置

@implementation M1FramePipelineConfig
- (instancetype)init {
    self = [super init];
    if (self) {
        _targetFps = 20;
        _bitsPerPixel = 0.12;
        _maxBitrate = 0;
        _keyframeIntervalSec = 2.0;
        _showsCursor = NO;
        // auto 在高分辨率物理屏降采样时把缩放压给 host，采集会跌到 ~5fps；
        // best 让 SCK 直接出目标尺寸（§5.24）。macOS 13 编译期/运行期均忽略。
        _captureResolution = 1;
    }
    return self;
}
@end

#pragma mark - 统计

@interface M1FramePipelineStats ()
@property (nonatomic, assign) uint64_t framesCaptured;
@property (nonatomic, assign) uint64_t framesEncoded;
@property (nonatomic, assign) uint64_t framesSent;
@property (nonatomic, assign) uint64_t framesDroppedBeforeEncoder;
@property (nonatomic, assign) uint64_t encodeFailures;
@property (nonatomic, assign) uint64_t sendFailures;
@property (nonatomic, assign) uint64_t keyframes;
@property (nonatomic, assign) uint64_t payloadBytesSent;
@property (nonatomic, assign) uint64_t fragmentsSent;
@property (nonatomic, assign) double firstFrameLatencyMs;
@property (nonatomic, assign) double encoderSessionCreateMs;
@end

@implementation M1FramePipelineStats

- (NSString *)summary {
    return [NSString stringWithFormat:
            @"captured=%llu encoded=%llu sent=%llu dropPreEnc=%llu "
            @"encFail=%llu sendFail=%llu key=%llu frags=%llu payload=%lluB "
            @"firstFrame=%.0fms encInit=%.0fms",
            self.framesCaptured, self.framesEncoded, self.framesSent,
            self.framesDroppedBeforeEncoder, self.encodeFailures, self.sendFailures,
            self.keyframes, self.fragmentsSent, self.payloadBytesSent,
            self.firstFrameLatencyMs, self.encoderSessionCreateMs];
}

@end

#pragma mark - 管线

@interface M1FramePipeline () {
    CGDirectDisplayID _displayID;
    M1FramePipelineConfig *_config;
    id<M1DatagramSink> _sink;
    void (^_onError)(NSError *);
    M1CapturePipeline *_capture;
    M1VideoEncoder *_encoder;
    M1FrameSender *_sender;
    M1FramePipelineStats *_finalSnapshot;   // stop 后 capture/encoder 已释放，统计需固化
    int32_t _stoppedWidth, _stoppedHeight;  // 同上，尺寸也要固化（否则报告 0x0）
    atomic_uint_fast64_t _framesCaptured;
    atomic_uint_fast64_t _droppedBeforeEncoder;
    atomic_uint_fast64_t _encodeFailures;
    atomic_uint_fast64_t _sendFailures;
    NSUInteger _consecutiveFragFailures;   // 仅在编码回调线程访问
    BOOL _running;
}
@end

@implementation M1FramePipeline

- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID
                           config:(M1FramePipelineConfig *)config
                             sink:(id<M1DatagramSink>)sink
                          onError:(void (^)(NSError *))onError {
    NSParameterAssert(config);
    NSParameterAssert(sink);
    self = [super init];
    if (self) {
        _displayID = displayID;
        _config = config;
        _sink = sink;
        _onError = [onError copy];
        atomic_init(&_framesCaptured, 0);
        atomic_init(&_droppedBeforeEncoder, 0);
        atomic_init(&_encodeFailures, 0);
        atomic_init(&_sendFailures, 0);
        _sender = [[M1FrameSender alloc] initWithSink:sink];
    }
    return self;
}

- (BOOL)isRunning { return _running; }
// stop 之后 _capture 已释放，尺寸必须回落到停止前固化的值，否则统计里是 0x0。
- (int32_t)pixelWidth { return _capture ? _capture.pixelWidth : _stoppedWidth; }
- (int32_t)pixelHeight { return _capture ? _capture.pixelHeight : _stoppedHeight; }
- (uint32_t)nextFrameSeq { return _sender.nextFrameSeq; }
- (M1FrameSender *)sender { return _sender; }

- (BOOL)start:(NSError **)error {
    if (error) *error = nil;
    if (_running) return YES;

    __weak typeof(self) weakSelf = self;

    M1CaptureConfig *cc = [[M1CaptureConfig alloc] init];
    cc.targetFps = _config.targetFps;
    cc.showsCursor = _config.showsCursor;
    cc.outputWidth = _config.outputWidth;
    cc.outputHeight = _config.outputHeight;
    cc.captureResolution = _config.captureResolution;

    M1CapturePipeline *capture =
        [[M1CapturePipeline alloc] initWithDisplayID:_displayID
                                              config:cc
                                             onFrame:^(CVPixelBufferRef pb, double ptsMs) {
        [weakSelf handleCapturedPixelBuffer:pb ptsMs:ptsMs];
    } onError:^(NSError *e) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf->_onError) strongSelf->_onError(e);
    }];

    NSError *capErr = nil;
    if (![capture start:&capErr]) {
        if (error) *error = capErr;
        return NO;
    }

    // 采集先起来，才能拿到 HiDPI 换算后的真实像素尺寸。
    int32_t w = capture.pixelWidth;
    int32_t h = capture.pixelHeight;
    if (w < 2 || h < 2) {
        [capture stop];
        if (error) *error = [NSError errorWithDomain:M1PipelineErrorDomain
                                                code:M1PipelineErrorDegenerateMode
                                            userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"采集尺寸非法 %dx%d", w, h]}];
        return NO;
    }

    M1EncoderConfig *ec = [M1EncoderConfig configWithWidth:w height:h];
    ec.targetFps = _config.targetFps;
    ec.bitsPerPixel = _config.bitsPerPixel;
    ec.maxBitrate = _config.maxBitrate;
    ec.keyframeIntervalSec = _config.keyframeIntervalSec;

    M1VideoEncoder *encoder =
        [[M1VideoEncoder alloc] initWithConfig:ec
                                     onEncoded:^(M1EncodedFrame *frame) {
        [weakSelf handleEncodedFrame:frame];
    } onError:^(NSError *e) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        atomic_fetch_add(&strongSelf->_encodeFailures, 1);
        if (strongSelf->_onError) strongSelf->_onError(e);
    }];

    NSError *encErr = nil;
    if (![encoder start:&encErr]) {
        [capture stop];
        if (error) *error = encErr;
        return NO;
    }

    _capture = capture;
    _encoder = encoder;
    _running = YES;
    return YES;
}

- (void)stop {
    // 并发双停防护：onSessionClosed 里停一次（控制收包队列），主线程收尾再停一次。
    // 不串行化的话两边会同时进 _capture/_encoder 的 stop，触发二次释放而崩溃。
    // 先摘快照再释放，锁外做真正耗时的排空。
    M1CapturePipeline *cap = nil;
    M1VideoEncoder *enc = nil;
    @synchronized (self) {
        if (!_running && !_capture && !_encoder) return;   // 已停过，幂等返回
        _running = NO;
        cap = _capture;
        enc = _encoder;
        // 尺寸必须在摘掉 _capture 之前固化，否则并发的 pixelWidth 会读到 0。
        _stoppedWidth = _capture ? _capture.pixelWidth : _stoppedWidth;
        _stoppedHeight = _capture ? _capture.pixelHeight : _stoppedHeight;
        // 先停采集（不再来新帧），再排空编码器（不再有回调）。
        _capture = nil;
        _encoder = nil;
    }
    // 快照必须在真正停之前取：stop 里的 CompleteFrames/SCK 停止可能长时间阻塞，
    // 一旦阻塞在这条线程上（对端 bye 触发的路径就在控制收包队列），后面的赋值永远到不了。
    _finalSnapshot = [self liveStatsFromCapture:cap encoder:enc];

    double t0 = NowMs();
    [cap stop];
    double tCap = NowMs() - t0;
    t0 = NowMs();
    [enc stop];
    double tEnc = NowMs() - t0;
    // 已知隐患：stop 偶尔会在这条线程上长时间阻塞（对端 bye 触发的路径就在控制
    // 收包队列上）。默认不打印，需要定位时用 M1_STOP_TIMING=1 打开。
    if (getenv("M1_STOP_TIMING")) {
        fprintf(stderr, "[M1FramePipeline] stop cost: capture=%.0fms encoder=%.0fms\n",
                tCap, tEnc);
    }
}

- (void)requestKeyframe {
    [_encoder requestKeyframe];
}

#pragma mark - 内部流转

- (void)handleCapturedPixelBuffer:(CVPixelBufferRef)pb ptsMs:(double)ptsMs {
    if (!_running) return;
    atomic_fetch_add(&_framesCaptured, 1);

    M1VideoEncoder *enc = _encoder;
    if (!enc) {
        // 启动瞬间：采集已开始但编码器尚未就绪。
        atomic_fetch_add(&_droppedBeforeEncoder, 1);
        return;
    }
    NSError *err = nil;
    // 优先用采集后端给的内容显示时刻（SCK 的 DisplayTime，换算成 epoch ms），
    // 而不是「回调被调用」的时刻：后者在积压时会晚到秒级，A-02 会把延迟低估。
    // CGDisplayStream/快照后端没有该信息，ptsMs 就是回调时刻，行为不变。
    uint64_t capturedAtUs = ptsMs > 0 ? (uint64_t)(ptsMs * 1000.0) : M1WallClockUs();
    if (![enc encodePixelBuffer:pb ptsMs:ptsMs capturedAtUs:capturedAtUs error:&err]) {
        atomic_fetch_add(&_encodeFailures, 1);
    }
}

- (void)handleEncodedFrame:(M1EncodedFrame *)frame {
    if (!_running) return;
    NSError *err = nil;
    if (![_sender sendFrame:frame displayID:(uint32_t)_displayID error:&err]) {
        atomic_fetch_add(&_sendFailures, 1);

        // 单帧超 65535 片（1150B×65535 ≈ 75MB）是协议硬上限，重试同一路径永远失败。
        // v2 之前这里是 255 片/286KB，3440×1440 的关键帧就会打穿（见 RESULTS-BY-OS §5.8）。
        // 这里累计连续失败次数并在超阈值时上报告警，避免上层以为「只是丢了一帧」。
        if (err.code == M1PipelineErrorFragmentationFailed) {
            _consecutiveFragFailures += 1;
            if (_consecutiveFragFailures == kM1FragFailureAlertThreshold && _onError) {
                _onError([NSError errorWithDomain:M1PipelineErrorDomain
                                             code:M1PipelineErrorFragmentationFailed
                                         userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:
                     @"连续 %d 帧超过 65535 片上限（单帧 >~75MB）。"
                     @"当前 %dx%d 码率异常，更可能是编码器输出了损坏的超大帧；"
                     @"请检查采集/编码侧，而不是链路。",
                     (int)_consecutiveFragFailures,
                     self.pixelWidth, self.pixelHeight]}]);
            }
        }
        if (_onError && _consecutiveFragFailures < kM1FragFailureAlertThreshold) {
            _onError(err);
        }
        return;
    }
    _consecutiveFragFailures = 0;
}

#pragma mark - 统计

- (M1FramePipelineStats *)stats {
    if (_finalSnapshot && !_running) return _finalSnapshot;
    return [self liveStats];
}

// 从当前存活对象读取统计（运行期与 stop 瞬间都用它）。
- (M1FramePipelineStats *)liveStats {
    return [self liveStatsFromCapture:_capture encoder:_encoder];
}

// stop 会把 _capture/_encoder 摘成 nil，所以统计必须在释放前用快照算出来。
- (M1FramePipelineStats *)liveStatsFromCapture:(M1CapturePipeline *)capture
                                       encoder:(M1VideoEncoder *)encoder {
    M1FramePipelineStats *s = [[M1FramePipelineStats alloc] init];
    s.framesCaptured = atomic_load(&_framesCaptured);
    s.framesDroppedBeforeEncoder = atomic_load(&_droppedBeforeEncoder);
    s.encodeFailures = atomic_load(&_encodeFailures);
    s.sendFailures = atomic_load(&_sendFailures);
    s.firstFrameLatencyMs = capture ? capture.stats.firstFrameLatencyMs : 0;

    M1EncoderStats *es = encoder ? encoder.stats : nil;
    s.framesEncoded = es ? es.framesEncoded : 0;
    s.keyframes = es ? es.keyframes : 0;
    s.encoderSessionCreateMs = es ? es.sessionCreateMs : 0;

    M1FrameSenderStats *ss = _sender.stats;
    s.framesSent = ss.framesSent;
    s.payloadBytesSent = ss.payloadBytesSent;
    s.fragmentsSent = ss.fragmentsSent;

    return s;
}

@end
