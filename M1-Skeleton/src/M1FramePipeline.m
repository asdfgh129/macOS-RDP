//
//  M1FramePipeline.m
//  M1-Skeleton
//

#import "M1FramePipeline.h"
#include <stdatomic.h>

// 连续多少帧因超 255 片失败后，升级为一次明确告警（而不是每帧刷同一条错误）。
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
@end

@implementation M1FramePipelineStats

- (NSString *)summary {
    return [NSString stringWithFormat:
            @"captured=%llu encoded=%llu sent=%llu dropPreEnc=%llu "
            @"encFail=%llu sendFail=%llu key=%llu frags=%llu payload=%lluB "
            @"firstFrame=%.0fms",
            self.framesCaptured, self.framesEncoded, self.framesSent,
            self.framesDroppedBeforeEncoder, self.encodeFailures, self.sendFailures,
            self.keyframes, self.fragmentsSent, self.payloadBytesSent,
            self.firstFrameLatencyMs];
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

- (BOOL)start:(NSError **)error {
    if (error) *error = nil;
    if (_running) return YES;

    __weak typeof(self) weakSelf = self;

    M1CaptureConfig *cc = [[M1CaptureConfig alloc] init];
    cc.targetFps = _config.targetFps;
    cc.showsCursor = _config.showsCursor;
    cc.outputWidth = _config.outputWidth;
    cc.outputHeight = _config.outputHeight;

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
    _running = NO;
    // 先停采集（不再来新帧），再排空编码器（不再有回调）。
    [_capture stop];
    [_encoder stop];
    // capture/encoder 的统计随对象消失，释放前必须先固化，否则 stop 后读到全 0。
    _stoppedWidth = _capture.pixelWidth;
    _stoppedHeight = _capture.pixelHeight;
    _finalSnapshot = [self liveStats];
    _capture = nil;
    _encoder = nil;
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
    if (![enc encodePixelBuffer:pb ptsMs:ptsMs error:&err]) {
        atomic_fetch_add(&_encodeFailures, 1);
    }
}

- (void)handleEncodedFrame:(M1EncodedFrame *)frame {
    if (!_running) return;
    NSError *err = nil;
    if (![_sender sendFrame:frame displayID:(uint32_t)_displayID error:&err]) {
        atomic_fetch_add(&_sendFailures, 1);

        // 单帧超 255 片（1150B×255 ≈ 293KB）是协议硬上限，重试同一路径永远失败。
        // 这里累计连续失败次数并在超阈值时上报告警，避免上层以为「只是丢了一帧」。
        if (err.code == M1PipelineErrorFragmentationFailed) {
            _consecutiveFragFailures += 1;
            if (_consecutiveFragFailures == kM1FragFailureAlertThreshold && _onError) {
                _onError([NSError errorWithDomain:M1PipelineErrorDomain
                                             code:M1PipelineErrorFragmentationFailed
                                         userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:
                     @"连续 %d 帧超过 255 片上限（单帧 >~293KB）。"
                     @"当前 %dx%d 码率过高或分辨率超出协议 v1 支持范围；"
                     @"请降分辨率/码率，或按 PROTOCOL 记录扩展 fragCount。",
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
    M1FramePipelineStats *s = [[M1FramePipelineStats alloc] init];
    s.framesCaptured = atomic_load(&_framesCaptured);
    s.framesDroppedBeforeEncoder = atomic_load(&_droppedBeforeEncoder);
    s.encodeFailures = atomic_load(&_encodeFailures);
    s.sendFailures = atomic_load(&_sendFailures);
    s.firstFrameLatencyMs = _capture ? _capture.stats.firstFrameLatencyMs : 0;

    M1EncoderStats *es = _encoder ? _encoder.stats : nil;
    s.framesEncoded = es ? es.framesEncoded : 0;
    s.keyframes = es ? es.keyframes : 0;

    M1FrameSenderStats *ss = _sender.stats;
    s.framesSent = ss.framesSent;
    s.payloadBytesSent = ss.payloadBytesSent;
    s.fragmentsSent = ss.fragmentsSent;

    return s;
}

@end
