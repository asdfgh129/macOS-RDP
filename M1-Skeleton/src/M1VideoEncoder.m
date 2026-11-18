//
//  M1VideoEncoder.m
//  M1-Skeleton
//

#import "M1VideoEncoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>

static NSError *M1EncoderErr(M1PipelineErrorCode code, NSString *msg) {
    return [NSError errorWithDomain:M1PipelineErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static double M1EncNowMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

#pragma mark - 配置

@implementation M1EncoderConfig

+ (instancetype)configWithWidth:(int32_t)width height:(int32_t)height {
    M1EncoderConfig *c = [[M1EncoderConfig alloc] init];
    c.width = width;
    c.height = height;
    return c;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _targetFps = 20;            // D-10 下的默认档位
        _bitsPerPixel = 0.12;
        _maxBitrate = 0;
        _keyframeIntervalSec = 2.0;
    }
    return self;
}

- (int32_t)effectiveBitrate {
    if (_maxBitrate > 0) return _maxBitrate;
    double bps = (double)_width * (double)_height * (double)MAX(1, _targetFps) * _bitsPerPixel;
    if (bps < 200000) bps = 200000;          // 极小屏下限
    if (bps > 100000000) bps = 100000000;    // 4K/高帧率上限
    return (int32_t)bps;
}

@end

#pragma mark - 统计快照

@interface M1EncoderStats ()
@property (nonatomic, assign) uint64_t framesEncoded;
@property (nonatomic, assign) uint64_t keyframes;
@property (nonatomic, assign) uint64_t encodeFailures;
@property (nonatomic, assign) uint64_t bytesTotal;
@property (nonatomic, assign) double lastEncodeCallMs;
@property (nonatomic, assign) double maxEncodeCallMs;
@property (nonatomic, assign) double sessionCreateMs;
@end

@implementation M1EncoderStats
@end

#pragma mark - 编码器

@interface M1VideoEncoder () {
    VTCompressionSessionRef _session;
    M1EncoderConfig *_config;
    void (^_onEncoded)(M1EncodedFrame *);
    void (^_onError)(NSError *);
    atomic_uint_fast64_t _framesEncoded;
    atomic_uint_fast64_t _keyframes;
    atomic_uint_fast64_t _encodeFailures;
    atomic_uint_fast64_t _bytesTotal;
    _Atomic double _lastEncodeCallMs;
    _Atomic double _maxEncodeCallMs;
    _Atomic double _sessionCreateMs;
    BOOL _running;
    BOOL _forceNextKeyframe;   // 下一帧强制 IDR（帧级选项，用完即复位）
}
// C 回调转进来的入口，仅在 VT 内部队列执行。
- (void)handleStatus:(OSStatus)status sampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

// VT 编码完成回调。refCon 是 __bridge 的 encoder 指针——stop 已保证排空后才释放。
static void M1EncoderOutputCallback(void *refCon,
                                    void *sourceFrameRefCon,
                                    OSStatus status,
                                    VTEncodeInfoFlags infoFlags,
                                    CMSampleBufferRef sampleBuffer) {
    @autoreleasepool {
        M1VideoEncoder *enc = (__bridge M1VideoEncoder *)refCon;
        [enc handleStatus:status sampleBuffer:sampleBuffer];
    }
}

// 把 AVCC 参数集（SPS/PPS）以「4 字节大端长度 + NALU」追加到 payload 前部。
static BOOL M1AppendParameterSets(CMFormatDescriptionRef fmt, NSMutableData *out) {
    if (!fmt) return NO;
    size_t count = 0;
    if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, NULL, NULL, &count, NULL) != noErr) {
        return NO;
    }
    for (size_t i = 0; i < count; i++) {
        const uint8_t *ps = NULL;
        size_t psLen = 0;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &ps, &psLen, NULL, NULL) != noErr) {
            return NO;
        }
        if (!ps || psLen == 0 || psLen > UINT32_MAX) return NO;
        uint8_t lenBE[4] = { (uint8_t)(psLen >> 24), (uint8_t)(psLen >> 16),
                             (uint8_t)(psLen >> 8),  (uint8_t)psLen };
        [out appendBytes:lenBE length:4];
        [out appendBytes:ps length:psLen];
    }
    return count > 0;
}

@implementation M1VideoEncoder

+ (void)prewarm {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (getenv("M1_NO_PREWARM")) return;   // 诊断：关掉预热做 A/B 对照
        double t0 = M1EncNowMs();
        VTCompressionSessionRef spare = NULL;
        OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault, 1920, 1080,
                                                 kCMVideoCodecType_H264,
                                                 NULL, NULL, NULL,
                                                 NULL, NULL, &spare);
        if (spare) {
            VTCompressionSessionInvalidate(spare);
            CFRelease(spare);
        }
        fprintf(stderr, "[M1VideoEncoder] 编码器预热 %.0fms (status=%d)\n",
                M1EncNowMs() - t0, (int)st);
    });
}

- (instancetype)initWithConfig:(M1EncoderConfig *)config
                     onEncoded:(void (^)(M1EncodedFrame *))onEncoded
                       onError:(void (^)(NSError *))onError {
    NSParameterAssert(config);
    NSParameterAssert(onEncoded);
    self = [super init];
    if (self) {
        _config = config;
        _onEncoded = [onEncoded copy];
        _onError = [onError copy];
        atomic_init(&_framesEncoded, 0);
        atomic_init(&_keyframes, 0);
        atomic_init(&_encodeFailures, 0);
        atomic_init(&_bytesTotal, 0);
        atomic_store(&_lastEncodeCallMs, 0.0);
        atomic_store(&_maxEncodeCallMs, 0.0);
        atomic_store(&_sessionCreateMs, 0.0);
        _running = NO;
    }
    return self;
}

- (BOOL)isRunning { return _running; }

- (BOOL)start:(NSError **)error {
    if (error) *error = nil;
    if (_session) return YES;
    if (_config.width < 2 || _config.height < 2) {
        if (error) *error = M1EncoderErr(M1PipelineErrorEncoderFailed,
            [NSString stringWithFormat:@"非法尺寸 %dx%d", _config.width, _config.height]);
        return NO;
    }

    double createT0 = M1EncNowMs();
    OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault,
                                             _config.width, _config.height,
                                             kCMVideoCodecType_H264,
                                             NULL, NULL, NULL,
                                             M1EncoderOutputCallback,
                                             (__bridge void *)self,
                                             &_session);
    if (st != noErr || !_session) {
        if (error) *error = M1EncoderErr(M1PipelineErrorEncoderFailed,
            [NSString stringWithFormat:@"VTCompressionSessionCreate 失败: %d", (int)st]);
        return NO;
    }

    // 实时流三件套：无重排、低延迟、实时优先级。
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_Main_AutoLevel);
    int32_t delay = 1;
    CFNumberRef delayNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &delay);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxFrameDelayCount, delayNum);
    CFRelease(delayNum);

    // 关键帧间隔按时间换算成帧数；取整后至少 1 帧。
    int32_t kfFrames = (int32_t)llround(_config.keyframeIntervalSec * MAX(1, _config.targetFps));
    if (kfFrames < 1) kfFrames = 1;
    CFNumberRef kfNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &kfFrames);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameInterval, kfNum);
    CFRelease(kfNum);

    int32_t bitrate = [_config effectiveBitrate];
    CFNumberRef brNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bitrate);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate, brNum);
    CFRelease(brNum);

    st = VTCompressionSessionPrepareToEncodeFrames(_session);
    if (st != noErr) {
        if (error) *error = M1EncoderErr(M1PipelineErrorEncoderFailed,
            [NSString stringWithFormat:@"PrepareToEncodeFrames 失败: %d", (int)st]);
        VTCompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
        return NO;
    }

    atomic_store(&_sessionCreateMs, M1EncNowMs() - createT0);
    _running = YES;
    return YES;
}

- (BOOL)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
                    ptsMs:(double)ptsMs
                    error:(NSError **)error {
    if (error) *error = nil;
    if (!_session || !_running) {
        if (error) *error = M1EncoderErr(M1PipelineErrorNotStarted, @"编码器未启动");
        return NO;
    }
    if (!pixelBuffer) {
        if (error) *error = M1EncoderErr(M1PipelineErrorEncoderFailed, @"空 pixel buffer");
        return NO;
    }

    // 尺寸不一致直接拒绝：VT 会话绑定固定分辨率，中途换尺寸必须重建会话。
    size_t w = CVPixelBufferGetWidth(pixelBuffer);
    size_t h = CVPixelBufferGetHeight(pixelBuffer);
    if ((int32_t)w != _config.width || (int32_t)h != _config.height) {
        if (error) *error = M1EncoderErr(M1PipelineErrorEncoderFailed,
            [NSString stringWithFormat:@"帧尺寸 %zux%zu 与编码器 %dx%d 不符",
             w, h, _config.width, _config.height]);
        return NO;
    }

    CMTime pts = CMTimeMakeWithSeconds(ptsMs / 1000.0, 1000);

    // 关键帧请求是「帧级选项」，不是会话属性：只在本次 EncodeFrame 生效。
    CFDictionaryRef frameProps = NULL;
    if (_forceNextKeyframe) {
        const void *keys[] = { kVTEncodeFrameOptionKey_ForceKeyFrame };
        const void *vals[] = { kCFBooleanTrue };
        frameProps = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 1,
                                        &kCFTypeDictionaryKeyCallBacks,
                                        &kCFTypeDictionaryValueCallBacks);
    }

    CFTimeInterval t0 = CACurrentMediaTime();
    OSStatus st = VTCompressionSessionEncodeFrame(_session, pixelBuffer, pts,
                                                 kCMTimeInvalid, frameProps, NULL, NULL);
    if (frameProps) CFRelease(frameProps);
    if (_forceNextKeyframe) _forceNextKeyframe = NO;

    double callMs = (CACurrentMediaTime() - t0) * 1000.0;
    atomic_store(&_lastEncodeCallMs, callMs);
    double prevMax = atomic_load(&_maxEncodeCallMs);
    while (callMs > prevMax &&
           !atomic_compare_exchange_weak(&_maxEncodeCallMs, &prevMax, callMs)) {
        // 重试直到写入更大的值
    }

    if (st != noErr) {
        atomic_fetch_add(&_encodeFailures, 1);
        if (error) *error = M1EncoderErr(M1PipelineErrorEncoderFailed,
            [NSString stringWithFormat:@"EncodeFrame 失败: %d", (int)st]);
        return NO;
    }
    return YES;
}

- (void)requestKeyframe {
    if (!_session) return;
    // 标记下一帧为 IDR；实际通过 EncodeFrame 的 frameProperties 传递。
    _forceNextKeyframe = YES;
}

- (void)stop {
    // 必须可重入、可并发：对端 bye 触发的管线停止跑在控制收包队列上，主线程
    // 收尾时还会再调一次；两者并发进到这里时，旧实现会对 _session 二次 CFRelease，
    // 直接 SIGILL（EXC_BAD_INSTRUCTION，CFRelease 的 over-release 陷阱）。
    // 先把 _session 摘走再释放，保证同一会话只会被释放一次。
    VTCompressionSessionRef draining = NULL;
    @synchronized (self) {
        _running = NO;
        draining = _session;
        _session = NULL;
    }
    if (!draining) return;
    VTCompressionSessionCompleteFrames(draining, kCMTimeInvalid);
    VTCompressionSessionInvalidate(draining);
    CFRelease(draining);
}

- (void)dealloc {
    // 兜底：正常路径应显式 stop。
    if (_session) {
        VTCompressionSessionCompleteFrames(_session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(_session);
        CFRelease(_session);
    }
}

#pragma mark - VT 回调（内部队列）

- (void)handleStatus:(OSStatus)status sampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (status != noErr || !sampleBuffer) {
        atomic_fetch_add(&_encodeFailures, 1);
        if (_onError) {
            _onError(M1EncoderErr(M1PipelineErrorEncoderFailed,
                [NSString stringWithFormat:@"VT 编码回调 status=%d", (int)status]));
        }
        return;
    }
    if (!_running) return;   // stop 之后到达的帧直接丢弃

    // 参数字典：NotSync 缺失即关键帧。
    BOOL isKey = YES;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (atts && CFArrayGetCount(atts) > 0) {
        CFDictionaryRef a = (CFDictionaryRef)CFArrayGetValueAtIndex(atts, 0);
        isKey = (CFDictionaryGetValue(a, kCMSampleAttachmentKey_NotSync) == NULL);
    }

    // 取 AVCC 帧数据。
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!bb) {
        atomic_fetch_add(&_encodeFailures, 1);
        return;
    }
    size_t len = CMBlockBufferGetDataLength(bb);
    if (len == 0) {
        atomic_fetch_add(&_encodeFailures, 1);
        return;
    }
    NSMutableData *payload = [NSMutableData dataWithLength:len];
    if (CMBlockBufferCopyDataBytes(bb, 0, len, payload.mutableBytes) != kCMBlockBufferNoErr) {
        atomic_fetch_add(&_encodeFailures, 1);
        return;
    }

    // 关键帧前置 SPS/PPS，使接收端可在任意时刻加入或重建解码器（PROTOCOL.md §4 bit2）。
    BOOL hasPS = NO;
    if (isKey) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
        NSMutableData *withPS = [NSMutableData dataWithCapacity:payload.length + 128];
        hasPS = M1AppendParameterSets(fmt, withPS);
        [withPS appendData:payload];
        payload = withPS;
    }

    M1EncodedFrame *frame = [[M1EncodedFrame alloc] init];
    frame.avccPayload = payload;
    frame.isKeyframe = isKey;
    frame.carriesParamSets = hasPS;
    frame.encodedAtMs = CACurrentMediaTime() * 1000.0;
    frame.encodeLatencyMs = atomic_load(&_lastEncodeCallMs);

    atomic_fetch_add(&_framesEncoded, 1);
    if (isKey) atomic_fetch_add(&_keyframes, 1);
    atomic_fetch_add(&_bytesTotal, (uint64_t)payload.length);

    if (_onEncoded) _onEncoded(frame);
}

#pragma mark - 统计

- (M1EncoderStats *)stats {
    M1EncoderStats *s = [[M1EncoderStats alloc] init];
    s.framesEncoded = atomic_load(&_framesEncoded);
    s.keyframes = atomic_load(&_keyframes);
    s.encodeFailures = atomic_load(&_encodeFailures);
    s.bytesTotal = atomic_load(&_bytesTotal);
    s.lastEncodeCallMs = atomic_load(&_lastEncodeCallMs);
    s.maxEncodeCallMs = atomic_load(&_maxEncodeCallMs);
    s.sessionCreateMs = atomic_load(&_sessionCreateMs);
    return s;
}

@end
