//
//  M1FrameReceiver.m
//  M1-Skeleton
//

#import "M1FrameReceiver.h"
#import "ProtocolCodec.h"
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#include <stdatomic.h>

static NSError *M1RxErr(M1PipelineErrorCode code, NSString *msg) {
    return [NSError errorWithDomain:M1PipelineErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
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
@property (nonatomic, assign) uint64_t decodeFailures;
@property (nonatomic, assign) uint64_t keyframeRequests;
@property (nonatomic, assign) double lastDecodeLatencyMs;
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
    atomic_uint_fast64_t _datagramsReceived;
    atomic_uint_fast64_t _malformed;
    atomic_uint_fast64_t _framesCompleted;
    atomic_uint_fast64_t _framesDecoded;
    atomic_uint_fast64_t _framesDropped;
    atomic_uint_fast64_t _decodeFailures;
    atomic_uint_fast64_t _keyframeRequests;
    _Atomic double _lastDecodeLatencyMs;
}
- (void)handleDecodedImage:(CVImageBufferRef)image status:(OSStatus)status;
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

@implementation M1FrameReceiver

- (instancetype)initWithOnFrame:(void (^)(CVPixelBufferRef, uint32_t))onFrame
                  onNeedKeyframe:(void (^)(void))onNeedKeyframe {
    NSParameterAssert(onFrame);
    self = [super init];
    if (self) {
        _onFrame = [onFrame copy];
        _onNeedKeyframe = [onNeedKeyframe copy];
        _reassembler = [[P1FrameReassembler alloc] init];
        _awaitingKeyframe = YES;    // 首个关键帧之前不解码
        atomic_init(&_datagramsReceived, 0);
        atomic_init(&_malformed, 0);
        atomic_init(&_framesCompleted, 0);
        atomic_init(&_framesDecoded, 0);
        atomic_init(&_framesDropped, 0);
        atomic_init(&_decodeFailures, 0);
        atomic_init(&_keyframeRequests, 0);
        atomic_store(&_lastDecodeLatencyMs, 0.0);
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
        if (error) *error = M1RxErr(M1PipelineErrorDecodeFailed, @"datagram 短于 16B 帧头");
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
    NSData *full = [_reassembler acceptHeader:h payload:body error:NULL];

    // 缺口出现：丢帧并请求关键帧。
    if (_reassembler.needsKeyframe) {
        if (!_awaitingKeyframe) {
            _awaitingKeyframe = YES;
            atomic_fetch_add(&_keyframeRequests, 1);
            if (_onNeedKeyframe) _onNeedKeyframe();
        }
        if (!full) {
            atomic_fetch_add(&_framesDropped, 1);
            return YES;
        }
    }

    if (!full) return YES;   // 中间分片，等后续

    atomic_fetch_add(&_framesCompleted, 1);

    // 拆 AVCC：参数集建 formatDescription，slice 留待解码。
    NSMutableData *frameData = [NSMutableData data];
    NSMutableArray<NSData *> *paramSets = [NSMutableArray array];
    if (!M1SplitAVCC(full, frameData, paramSets)) {
        atomic_fetch_add(&_malformed, 1);
        if (error) *error = M1RxErr(M1PipelineErrorDecodeFailed, @"AVCC 拆解失败");
        return NO;
    }

    if (paramSets.count >= 2) {
        [self rebuildFormatDescriptionWithParamSets:paramSets];
    }

    if (!_formatDesc) {
        // 还没有参数集（非关键帧先到），等下一个关键帧。
        atomic_fetch_add(&_framesDropped, 1);
        return YES;
    }

    BOOL isKey = (h.flags & P1FrameFlagKeyframe) != 0;
    if (_awaitingKeyframe && !isKey) {
        atomic_fetch_add(&_framesDropped, 1);
        return YES;
    }
    if (isKey) _awaitingKeyframe = NO;

    [self decodeFrameData:frameData frameSeq:h.frameSeq];
    return YES;
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
        OSStatus ds = VTDecompressionSessionCreate(kCFAllocatorDefault, fmt,
                                                   NULL, NULL, &cb, &_decoder);
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
    _awaitingKeyframe = YES;
    _videoWidth = 0;
    _videoHeight = 0;
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
    s.decodeFailures = atomic_load(&_decodeFailures);
    s.keyframeRequests = atomic_load(&_keyframeRequests);
    s.lastDecodeLatencyMs = atomic_load(&_lastDecodeLatencyMs);
    return s;
}

@end
