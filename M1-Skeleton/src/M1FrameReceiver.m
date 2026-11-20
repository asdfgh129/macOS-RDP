//
//  M1FrameReceiver.m
//  M1-Skeleton
//

#import "M1FrameReceiver.h"
#import "ProtocolCodec.h"
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>

static NSError *M1RxErr(M1PipelineErrorCode code, NSString *msg) {
    return [NSError errorWithDomain:M1PipelineErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static double M1RxNowMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

// AVCC 载荷拆解：参数集（SPS type7 / PPS type8）收集为裸 NAL，
// 其余（slice type1/5）保留 4 字节长度前缀写回 frameOut，供 VT 直接解码。
static BOOL M1SplitAVCC(NSData *payload,
                        NSMutableData *frameOut,
                        NSMutableArray<NSData *> *paramSets) {
    const uint8_t *p = payload.bytes;
    NSUInteger len = payload.length;
    NSUInteger off = 0;
    BOOL sawAny = NO;
    while (off + 4 <= len) {
        uint32_t n = ((uint32_t)p[off] << 24) | ((uint32_t)p[off + 1] << 16) |
                     ((uint32_t)p[off + 2] << 8) | (uint32_t)p[off + 3];
        off += 4;
        if (n == 0) return NO;                 // 零长度 NAL 视为损坏
        if (off + n > len) return NO;          // 声明长度越界
        uint8_t nalType = (uint8_t)(p[off] & 0x1F);
        if (nalType == 7 || nalType == 8) {
            [paramSets addObject:[NSData dataWithBytes:(p + off) length:n]];
        } else {
            uint8_t lenBE[4] = { (uint8_t)(n >> 24), (uint8_t)(n >> 16),
                                 (uint8_t)(n >> 8), (uint8_t)n };
            [frameOut appendBytes:lenBE length:4];
            [frameOut appendBytes:(p + off) length:n];
        }
        off += n;
        sawAny = YES;
    }
    // 尾部残留不足 4 字节 ⇒ 帧数据被截断，不能解。
    if (off != len) return NO;
    return sawAny;
}

@interface M1FrameReceiverStats ()
@property (nonatomic, assign) uint64_t datagramsReceived;
@property (nonatomic, assign) uint64_t malformedDatagrams;
@property (nonatomic, assign) uint64_t framesCompleted;
@property (nonatomic, assign) uint64_t framesDecoded;
@property (nonatomic, assign) uint64_t framesDropped;
@property (nonatomic, assign) uint64_t droppedKeyframes;
@property (nonatomic, assign) uint64_t droppedPFrames;
@property (nonatomic, copy) NSArray<NSString *> *recentDropDetails;
@property (nonatomic, assign) uint64_t fragmentsDiscarded;
@property (nonatomic, assign) uint64_t decodeFailures;
@property (nonatomic, assign) uint64_t keyframeRequests;
@property (nonatomic, assign) uint64_t repairRequests;
@property (nonatomic, assign) double repairRttMs;
@property (nonatomic, assign) uint64_t repairRttSamples;
@property (nonatomic, assign) double awaitingKeyframeMs;
@property (nonatomic, assign) double keyframeRequestRttMs;
@property (nonatomic, assign) uint64_t keyframeRequestRttSamples;
@property (nonatomic, assign) double lastDecodeLatencyMs;
@property (nonatomic, assign) double decoderCreateMs;
@property (nonatomic, assign) double decoderPrewarmMs;
@end

@implementation M1FrameReceiverStats
@end

@interface M1FrameReceiver () {
    void (^_onFrame)(CVPixelBufferRef, uint32_t);
    void (^_onNeedKeyframe)(void);
    P1FrameReassembler *_reassembler;
    VTDecompressionSessionRef _decoder;
    CMFormatDescriptionRef _formatDesc;
    int32_t _videoWidth;
    int32_t _videoHeight;
    BOOL _awaitingKeyframe;
    double _awaitingSinceMs;
    double _lastKeyframeRequestMs;
    // RTT 采样：只记本轮首个成功过线的请求；收到关键帧时结算。
    double _lastRequestSentMs;
    BOOL _rttAwaitingKeyframe;
    _Atomic double _keyframeRequestRttMs;
    atomic_uint_fast64_t _keyframeRequestRttSamples;
    atomic_uint_fast64_t _datagramsReceived;
    atomic_uint_fast64_t _malformed;
    atomic_uint_fast64_t _framesCompleted;
    atomic_uint_fast64_t _framesDecoded;
    atomic_uint_fast64_t _framesDropped;
    atomic_uint_fast64_t _droppedKeyframes;
    atomic_uint_fast64_t _droppedPFrames;
    NSArray<NSString *> *_recentDropDetails;   // @synchronized(self) 保护
    atomic_uint_fast64_t _fragmentsDiscarded;
    atomic_uint_fast64_t _decodeFailures;
    atomic_uint_fast64_t _keyframeRequests;
    atomic_uint_fast64_t _repairRequests;
    _Atomic double _repairRttMs;
    atomic_uint_fast64_t _repairRttSamples;
    _Atomic double _awaitingKeyframeMs;
    _Atomic double _lastDecodeLatencyMs;
    _Atomic double _decoderCreateMs;
}
- (void)handleDecodedImage:(CVImageBufferRef)image status:(OSStatus)status;
- (void)absorbReassembledFrame:(P1ReassembledFrame *)frame;
@end

#pragma mark - 解码回调

static void M1DecoderOutput(void *decompressionOutputRefCon,
                            void *sourceFrameRefCon,
                            OSStatus status,
                            VTDecodeInfoFlags infoFlags,
                            CVImageBufferRef imageBuffer,
                            CMTime presentationTimeStamp,
                            CMTime presentationDuration) {
    @autoreleasepool {
        M1FrameReceiver *rx = (__bridge M1FrameReceiver *)decompressionOutputRefCon;
        [rx handleDecodedImage:imageBuffer status:status];
    }
}

#pragma mark - 接收器

// 进程级预热结果（-1 表示本进程未预热）。dispatch_once 内只写一次，之后只读。
static double gPrewarmMs = -1;

@implementation M1FrameReceiver

+ (void)prewarmDecoder {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (getenv("M1_NO_PREWARM")) return;   // 诊断：关掉预热做 A/B 对照
        double t0 = M1RxNowMs();
        // 裸 formatDescription：不含 SPS/PPS。实测 VT 照样能建出会话，
        // 说明首次建会话的开销与码流参数无关，纯粹是 VT 解码侧的一次性初始化。
        CMFormatDescriptionRef bare = NULL;
        OSStatus cs = CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                                     kCMVideoCodecType_H264,
                                                     1920, 1080, NULL, &bare);
        OSStatus ds = -1;
        if (cs == noErr && bare) {
            VTDecompressionSessionRef spare = NULL;
            ds = VTDecompressionSessionCreate(kCFAllocatorDefault, bare,
                                             NULL, NULL, NULL, &spare);
            if (spare) {
                VTDecompressionSessionInvalidate(spare);
                CFRelease(spare);
            }
            CFRelease(bare);
        }
        gPrewarmMs = M1RxNowMs() - t0;
        fprintf(stderr, "[M1FrameReceiver] 解码器预热 %.0fms (fmt=%d ses=%d)\n",
                gPrewarmMs, (int)cs, (int)ds);
    });
}

- (instancetype)initWithOnFrame:(void (^)(CVPixelBufferRef, uint32_t))onFrame
                  onNeedKeyframe:(void (^)(void))onNeedKeyframe {
    NSParameterAssert(onFrame);
    self = [super init];
    if (self) {
        _onFrame = [onFrame copy];
        _onNeedKeyframe = [onNeedKeyframe copy];
        _reassembler = [[P1FrameReassembler alloc] init];
        // 有定向补片后，停滞帧会占用在飞窗口一段时间；窗口太小时后来帧的分片
        // 会被整批拒绝，补完一帧反而在更后面留下无法补的缺口。12 帧在 15~20fps
        // 下约 0.6~0.8s，覆盖补片重问的最长等待，仍远小于重排序需求。
        _reassembler.maxFramesInFlight = 12;
        const char *winEnv = getenv("M1_FRAME_WINDOW");
        if (winEnv) _reassembler.maxFramesInFlight = (NSUInteger)MAX(1, atoi(winEnv));
        __weak M1FrameReceiver *weakSelf = self;
        _reassembler.onMissingFragments = ^(uint32_t frameSeq, uint16_t fragCount,
                                            NSIndexSet *missingIndices, BOOL keyframe) {
            M1FrameReceiver *strongSelf = weakSelf;
            if (!strongSelf) return;
            atomic_fetch_add(&strongSelf->_repairRequests, 1);
            void (^repair)(uint32_t, uint16_t, NSIndexSet *, BOOL) = strongSelf.onNeedRepair;
            if (repair) repair(frameSeq, fragCount, missingIndices, keyframe);
        };
        // 初始不在「等关键帧」状态：重组器本身只交付关键帧，这里从 NO 起步，
        // 第一个数据包就能触发一次 keyframe-request（客户端常在中途接入）。
        _awaitingKeyframe = NO;
        _awaitingSinceMs = 0;
        _lastKeyframeRequestMs = 0;
        _lastRequestSentMs = 0;
        _rttAwaitingKeyframe = NO;
        atomic_store(&_keyframeRequestRttMs, 0.0);
        atomic_init(&_keyframeRequestRttSamples, 0);
        atomic_init(&_datagramsReceived, 0);
        atomic_init(&_malformed, 0);
        atomic_init(&_framesCompleted, 0);
        atomic_init(&_framesDecoded, 0);
        atomic_init(&_framesDropped, 0);
        atomic_init(&_fragmentsDiscarded, 0);
        atomic_init(&_decodeFailures, 0);
        atomic_init(&_keyframeRequests, 0);
        atomic_init(&_repairRequests, 0);
        atomic_store(&_repairRttMs, 0.0);
        atomic_init(&_repairRttSamples, 0);
        atomic_init(&_awaitingKeyframeMs, 0.0);
        atomic_store(&_lastDecodeLatencyMs, 0.0);
        atomic_store(&_decoderCreateMs, 0.0);
    }
    return self;
}

- (BOOL)needsKeyframe { return _awaitingKeyframe || _reassembler.needsKeyframe; }
- (int32_t)videoWidth { return _videoWidth; }
- (int32_t)videoHeight { return _videoHeight; }

- (BOOL)acceptDatagram:(NSData *)datagram error:(NSError **)error {
    if (error) *error = nil;
    atomic_fetch_add(&_datagramsReceived, 1);

    if (datagram.length < P1FrameHeaderSize) {
        atomic_fetch_add(&_malformed, 1);
        if (error) *error = M1RxErr(M1PipelineErrorDecodeFailed, @"datagram 短于 18B 帧头");
        return NO;
    }

    P1FrameHeader h = {0};
    NSError *hdrErr = nil;
    if (!P1UnpackFrameHeader([datagram subdataWithRange:NSMakeRange(0, P1FrameHeaderSize)],
                             &h, &hdrErr)) {
        atomic_fetch_add(&_malformed, 1);
        if (error) *error = M1RxErr(M1PipelineErrorDecodeFailed,
                                     hdrErr.localizedDescription ?: @"帧头解析失败");
        return NO;
    }
    if (h.payloadLen == 0 || P1FrameHeaderSize + h.payloadLen > datagram.length) {
        atomic_fetch_add(&_malformed, 1);
        if (error) *error = M1RxErr(M1PipelineErrorDecodeFailed, @"载荷长度与 datagram 不符");
        return NO;
    }

    NSData *body = [datagram subdataWithRange:NSMakeRange(P1FrameHeaderSize, h.payloadLen)];
    NSArray<P1ReassembledFrame *> *frames = [_reassembler acceptHeader:h payload:body error:NULL];
    atomic_store(&_framesDropped, (uint64_t)_reassembler.droppedFrames);
    atomic_store(&_droppedKeyframes, (uint64_t)_reassembler.droppedKeyframes);
    atomic_store(&_droppedPFrames, (uint64_t)_reassembler.droppedPFrames);
    atomic_store(&_fragmentsDiscarded, (uint64_t)_reassembler.fragmentsDiscarded);
    atomic_store(&_repairRttMs, _reassembler.lastRepairRttMs);
    atomic_store(&_repairRttSamples, (uint64_t)_reassembler.repairRttSamples);
    NSArray<NSString *> *drops = _reassembler.recentDropDetails;
    if (drops.count > 0) {
        @synchronized (self) { _recentDropDetails = [drops copy]; }
    }

    // 等待关键帧期间按 1s 重试：WAN 上 IDR 有几百个分片、传输本身就要
    // 一两秒，重试过快只会不断打断在途 IDR。
    if (_reassembler.needsKeyframe) {
        double now = M1RxNowMs();
        BOOL first = !_awaitingKeyframe;
        if (first) {
            _awaitingKeyframe = YES;
            _awaitingSinceMs = now;
        }
        // 在途 IDR 只要还在增长就不请求新的：大 IDR 在窄带链路上要传一两秒，
        // 1s 重试会在它传完之前再塞一个 IDR 进来，两个都收不齐（实测互相打断）。
        BOOL activeKeyframe = [_reassembler hasActiveKeyframeAtMs:now withinMs:500.0];
        if (!activeKeyframe && (first || now - _lastKeyframeRequestMs > 1000.0)) {
            _lastKeyframeRequestMs = now;
            atomic_fetch_add(&_keyframeRequests, 1);
            if (_onNeedKeyframe) _onNeedKeyframe();
        }
    }

    for (P1ReassembledFrame *frame in frames) {
        [self absorbReassembledFrame:frame];
    }
    return YES;
}

- (void)noteKeyframeRequestSent {
    // 同一个缺口 episode 的重复请求不重置起点：只有从「最早一次成功请求」
    // 算到关键帧到达，才代表用户真实经历的恢复时延。
    if (_rttAwaitingKeyframe) return;
    _lastRequestSentMs = M1RxNowMs();
    _rttAwaitingKeyframe = YES;
}

- (void)absorbReassembledFrame:(P1ReassembledFrame *)frame {
    atomic_fetch_add(&_framesCompleted, 1);

    // 拆 AVCC：参数集建 formatDescription，slice 留待解码。
    NSMutableData *frameData = [NSMutableData data];
    NSMutableArray<NSData *> *paramSets = [NSMutableArray array];
    if (!M1SplitAVCC(frame.payload, frameData, paramSets)) {
        atomic_fetch_add(&_malformed, 1);
        atomic_fetch_add(&_framesDropped, 1);
        return;
    }

    if (paramSets.count >= 2) {
        [self rebuildFormatDescriptionWithParamSets:paramSets];
    }

    if (!_formatDesc) {
        // 还没有参数集（非关键帧先到），等下一个关键帧。
        atomic_fetch_add(&_framesDropped, 1);
        return;
    }

    if (frame.keyframe) {
        if (_rttAwaitingKeyframe) {
            double rtt = M1RxNowMs() - _lastRequestSentMs;
            if (rtt > 0) {
                atomic_store(&_keyframeRequestRttMs, rtt);
                atomic_fetch_add(&_keyframeRequestRttSamples, 1);
            }
            _rttAwaitingKeyframe = NO;
            _lastRequestSentMs = 0;
        }
        if (_awaitingKeyframe) {
            _awaitingKeyframe = NO;
            atomic_store(&_awaitingKeyframeMs,
                         atomic_load(&_awaitingKeyframeMs) + (M1RxNowMs() - _awaitingSinceMs));
        }
    } else if (_awaitingKeyframe) {
        atomic_fetch_add(&_framesDropped, 1);
        return;
    }

    [self decodeFrameData:frameData frameSeq:frame.frameSeq];
}

- (void)rebuildFormatDescriptionWithParamSets:(NSArray<NSData *> *)paramSets {
    // 只要 SPS + PPS 两个（type7/type8），多余的忽略。
    NSData *sps = nil, *pps = nil;
    for (NSData *ps in paramSets) {
        if (ps.length == 0) continue;
        uint8_t t = ((const uint8_t *)ps.bytes)[0] & 0x1F;
        if (t == 7 && !sps) sps = ps;
        else if (t == 8 && !pps) pps = ps;
    }
    if (!sps || !pps) return;

    const uint8_t *ptrs[2] = { sps.bytes, pps.bytes };
    size_t sizes[2] = { sps.length, pps.length };
    CMFormatDescriptionRef fmt = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                     2, ptrs, sizes,
                                                                     4, &fmt);
    if (st != noErr || !fmt) {
        atomic_fetch_add(&_decodeFailures, 1);
        return;
    }

    int32_t w = (int32_t)CMVideoFormatDescriptionGetDimensions(fmt).width;
    int32_t h = (int32_t)CMVideoFormatDescriptionGetDimensions(fmt).height;
    BOOL changed = (_formatDesc == NULL || w != _videoWidth || h != _videoHeight);

    if (changed) {
        // 分辨率变了或首次建：重建解码会话。
        if (_decoder) {
            VTDecompressionSessionWaitForAsynchronousFrames(_decoder);
            VTDecompressionSessionInvalidate(_decoder);
            CFRelease(_decoder);
            _decoder = NULL;
        }
        _videoWidth = w;
        _videoHeight = h;
    }

    if (_formatDesc) CFRelease(_formatDesc);
    _formatDesc = (CMFormatDescriptionRef)CFRetain(fmt);

    if (!_decoder) {
        VTDecompressionOutputCallbackRecord cb = { M1DecoderOutput, (__bridge void *)self };
        double t0 = M1RxNowMs();
        OSStatus ds = VTDecompressionSessionCreate(kCFAllocatorDefault, fmt,
                                                   NULL, NULL, &cb, &_decoder);
        atomic_store(&_decoderCreateMs, M1RxNowMs() - t0);
        if (ds != noErr || !_decoder) {
            _decoder = NULL;
            atomic_fetch_add(&_decodeFailures, 1);
        }
    }
    CFRelease(fmt);
}

- (void)decodeFrameData:(NSData *)frameData frameSeq:(uint32_t)frameSeq {
    if (!_decoder || frameData.length == 0) {
        atomic_fetch_add(&_framesDropped, 1);
        return;
    }

    CMBlockBufferRef bb = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, frameData.length,
                                           kCFAllocatorDefault, NULL, 0, frameData.length,
                                           0, &bb) != kCMBlockBufferNoErr || !bb) {
        atomic_fetch_add(&_decodeFailures, 1);
        return;
    }
    if (CMBlockBufferReplaceDataBytes(frameData.bytes, bb, 0, frameData.length)
            != kCMBlockBufferNoErr) {
        CFRelease(bb);
        atomic_fetch_add(&_decodeFailures, 1);
        return;
    }

    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMakeWithSeconds(
            [[NSDate date] timeIntervalSince1970], 1000),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    size_t sizes[1] = { frameData.length };
    CMSampleBufferRef sb = NULL;
    OSStatus st = CMSampleBufferCreateReady(kCFAllocatorDefault, bb, _formatDesc,
                                            1, 1, &timing, 1, sizes, &sb);
    CFRelease(bb);
    if (st != noErr || !sb) {
        atomic_fetch_add(&_decodeFailures, 1);
        return;
    }

    double t0 = [[NSDate date] timeIntervalSince1970] * 1000.0;
    st = VTDecompressionSessionDecodeFrame(_decoder, sb,
                                           kVTDecodeFrame_EnableAsynchronousDecompression,
                                           NULL, NULL);
    double dt = [[NSDate date] timeIntervalSince1970] * 1000.0 - t0;
    atomic_store(&_lastDecodeLatencyMs, dt);
    CFRelease(sb);

    if (st != noErr) atomic_fetch_add(&_decodeFailures, 1);
    (void)frameSeq;
}

- (void)handleDecodedImage:(CVImageBufferRef)image status:(OSStatus)status {
    if (status != noErr || !image) {
        atomic_fetch_add(&_decodeFailures, 1);
        return;
    }
    atomic_fetch_add(&_framesDecoded, 1);
    if (_onFrame) _onFrame((CVPixelBufferRef)image, _reassembler.lastCompletedSeq);
}

- (void)reset {
    if (_decoder) {
        VTDecompressionSessionWaitForAsynchronousFrames(_decoder);
        VTDecompressionSessionInvalidate(_decoder);
        CFRelease(_decoder);
        _decoder = NULL;
    }
    if (_formatDesc) {
        CFRelease(_formatDesc);
        _formatDesc = NULL;
    }
    [_reassembler reset];
    atomic_store(&_droppedKeyframes, 0);
    atomic_store(&_droppedPFrames, 0);
    @synchronized (self) { _recentDropDetails = @[]; }
    _awaitingKeyframe = NO;
    _awaitingSinceMs = 0;
    _lastKeyframeRequestMs = 0;
    _lastRequestSentMs = 0;
    _rttAwaitingKeyframe = NO;
    atomic_store(&_keyframeRequestRttMs, 0.0);
    atomic_store(&_keyframeRequestRttSamples, 0);
    _videoWidth = 0;
    _videoHeight = 0;
    atomic_store(&_framesDropped, 0);
    atomic_store(&_fragmentsDiscarded, 0);
    atomic_store(&_keyframeRequests, 0);
    atomic_store(&_repairRequests, 0);
    atomic_store(&_repairRttMs, 0.0);
    atomic_store(&_repairRttSamples, 0);
    atomic_store(&_awaitingKeyframeMs, 0.0);
}

- (void)dealloc {
    if (_decoder) {
        VTDecompressionSessionWaitForAsynchronousFrames(_decoder);
        VTDecompressionSessionInvalidate(_decoder);
        CFRelease(_decoder);
    }
    if (_formatDesc) CFRelease(_formatDesc);
}

- (M1FrameReceiverStats *)stats {
    M1FrameReceiverStats *s = [[M1FrameReceiverStats alloc] init];
    s.datagramsReceived = atomic_load(&_datagramsReceived);
    s.malformedDatagrams = atomic_load(&_malformed);
    s.framesCompleted = atomic_load(&_framesCompleted);
    s.framesDecoded = atomic_load(&_framesDecoded);
    s.framesDropped = atomic_load(&_framesDropped);
    s.droppedKeyframes = atomic_load(&_droppedKeyframes);
    s.droppedPFrames = atomic_load(&_droppedPFrames);
    @synchronized (self) {
        s.recentDropDetails = _recentDropDetails ?: @[];
    }
    s.fragmentsDiscarded = atomic_load(&_fragmentsDiscarded);
    s.decodeFailures = atomic_load(&_decodeFailures);
    s.keyframeRequests = atomic_load(&_keyframeRequests);
    s.repairRequests = atomic_load(&_repairRequests);
    s.repairRttMs = atomic_load(&_repairRttMs);
    s.repairRttSamples = atomic_load(&_repairRttSamples);
    double awaiting = atomic_load(&_awaitingKeyframeMs);
    if (_awaitingKeyframe) awaiting += M1RxNowMs() - _awaitingSinceMs;
    s.awaitingKeyframeMs = awaiting;
    s.keyframeRequestRttMs = atomic_load(&_keyframeRequestRttMs);
    s.keyframeRequestRttSamples = atomic_load(&_keyframeRequestRttSamples);
    s.lastDecodeLatencyMs = atomic_load(&_lastDecodeLatencyMs);
    s.decoderCreateMs = atomic_load(&_decoderCreateMs);
    s.decoderPrewarmMs = (gPrewarmMs > 0) ? gPrewarmMs : 0;
    return s;
}

@end
