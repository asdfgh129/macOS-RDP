//
//  PipelineProbe.m
//  P0-TahoeProbe
//

#import "PipelineProbe.h"
#import "ProbeUtil.h"

#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <stdatomic.h>
#import <math.h>

// 解码回调在编码回调里被引用，先给前向声明。
static void P0DecompressionOutput(void *refCon, void *sourceFrameRefCon, OSStatus status,
                                  VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer,
                                  CMTime pts, CMTime duration);

#pragma mark - SCK enumeration

static SCShareableContent * _Nullable P0ShareableContent(NSError * _Nullable * _Nullable error) {
    __block SCShareableContent *result = nil;
    __block NSError *innerError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *err) {
        result = content;
        innerError = err;
        dispatch_semaphore_signal(sem);
    }];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
        innerError = [NSError errorWithDomain:@"P0" code:2
                                    userInfo:@{NSLocalizedDescriptionKey: @"SCShareableContent 枚举超时(5s)"}];
    }
    if (innerError && error) *error = innerError;
    return result;
}

#pragma mark - Encoder capability probe

static void P0CompressionCallbackNoop(void *refCon, void *sourceFrameRefCon, OSStatus status,
                                      VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer) {}

static NSDictionary *P0ProbeEncoder(CMVideoCodecType codec, NSString *label,
                                    CFStringRef profile, int width, int height) {
    VTCompressionSessionRef session = NULL;
    OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault, width, height, codec,
                                             NULL, NULL, NULL,
                                             P0CompressionCallbackNoop, NULL, &session);
    if (st != noErr || !session) {
        return @{ @"codec": label, @"raster": [NSString stringWithFormat:@"%dx%d", width, height],
                  @"supported": @NO, @"createStatus": @(st) };
    }
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    r[@"codec"] = label;
    r[@"raster"] = [NSString stringWithFormat:@"%dx%d", width, height];

    if (profile) VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, profile);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    NSNumber *one = @1;  // 必须保留强引用，否则 __bridge 出的 CFTypeRef 会在表达式结束时悬垂
    VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxFrameDelayCount,
                         (__bridge CFTypeRef)one);

    OSStatus prep = VTCompressionSessionPrepareToEncodeFrames(session);
    r[@"prepareStatus"] = @(prep);
    r[@"supported"] = @(prep == noErr);

    // VTSessionCopyProperty 的 out 参数是 CFTypeRef *，用 CFBooleanRef * 会触发
    // incompatible-pointer-types 警告；统一用 CFTypeRef 再显式 cast。
    CFTypeRef hw = NULL;
    OSStatus hwSt = VTSessionCopyProperty(session,
                        kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                        kCFAllocatorDefault, &hw);
    r[@"hardwareAccelerated"] = (hwSt == noErr && hw && CFGetTypeID(hw) == CFBooleanGetTypeID())
        ? @(CFBooleanGetValue((CFBooleanRef)hw)) : @NO;
    if (hw) CFRelease(hw);

    CFRelease(session);
    return r;
}

#pragma mark - Frame sink (SCStreamOutput + VideoToolbox loopback)

@interface P0FrameSink : NSObject <SCStreamOutput, SCStreamDelegate> {
    // 捕获回调（串行 queue）与 VT 编解码回调（VT 内部 queue）会并发写这些计数，
    // 必须用 C11 atomics；不放成 property，避免 ARC 为 _Atomic 类型合成访问器。
    atomic_int _frameCount;
    atomic_int _encodedCount;
    atomic_int _keyFrameCount;
    atomic_int _decodedCount;
    atomic_int _encodeErrors;
}
@property (nonatomic, assign) double firstFrameMs;
@property (nonatomic, assign) double captureStartMs;
@property (nonatomic, assign) double worstLumaMean;
@property (nonatomic, assign) double bestLumaVariance;
@property (nonatomic, assign) int blackFrames;
@property (nonatomic, assign) BOOL withEncoder;
@property (nonatomic, assign) VTCompressionSessionRef encoder;
@property (nonatomic, assign) VTDecompressionSessionRef decoder;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *encodeLatenciesMs;

// C 回调不能直接访问受保护的 ivar，统一走方法，避免跨编译单元的 ivar 可见性问题。
- (void)handleEncodedSampleBuffer:(CMSampleBufferRef)sampleBuffer status:(OSStatus)status;
- (void)handleDecodeStatus:(OSStatus)status hasImage:(BOOL)hasImage;
- (int)framesValue;
- (int)encodedValue;
- (int)keyFramesValue;
- (int)decodedValue;
- (int)encodeErrorsValue;
@end

static double P0NowMs(void) { return [[NSDate date] timeIntervalSince1970] * 1000.0; }

static void P0CompressionOutput(void *refCon, void *sourceFrameRefCon, OSStatus status,
                                VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer) {
    P0FrameSink *sink = (__bridge P0FrameSink *)refCon;
    [sink handleEncodedSampleBuffer:sampleBuffer status:status];
}

static void P0DecompressionOutput(void *refCon, void *sourceFrameRefCon, OSStatus status,
                                  VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer,
                                  CMTime pts, CMTime duration) {
    P0FrameSink *sink = (__bridge P0FrameSink *)refCon;
    [sink handleDecodeStatus:status hasImage:(imageBuffer != NULL)];
}

// 从 Y plane 做 8x8 网格采样，返回亮度均值与方差。
// 全黑判定只作提示：Tahoe 的深色壁纸本来就偏暗，务必结合帧数与肉眼截图一起看。
//
// 注意色彩范围：捕获配置用的是 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange，
// 视频范围下 Y ∈ [16,235]，纯黑是 16 而不是 0。早期实现按「Y<8」判黑，
// 在任何视频范围的帧上都不可能命中，等于关掉了 MOSTLY_BLACK 判据、
// 会让真黑屏被误判为 HAS_CONTENT（假通过）。这里按 16 + 容差取阈值。
static const double kP0VideoRangeBlackY = 16.0;
static const double kP0BlackMeanTolerance = 4.0;   // 16 + 4，容忍少量抖动/压缩噪声
static const double kP0BlackVarianceMax = 4.0;     // 近无空间变化
static NSDictionary *P0LumaStats(CVPixelBufferRef pb) {
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return @{ @"mean": @(-1), @"variance": @(-1) };
    }
    uint8_t *base = NULL;
    size_t stride = 0, w = 0, h = 0;
    if (CVPixelBufferGetPlaneCount(pb) > 0) {
        base = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
        stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
        w = CVPixelBufferGetWidthOfPlane(pb, 0);
        h = CVPixelBufferGetHeightOfPlane(pb, 0);
    } else {
        base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
        stride = CVPixelBufferGetBytesPerRow(pb);
        w = CVPixelBufferGetWidth(pb);
        h = CVPixelBufferGetHeight(pb);
    }
    double sum = 0, sumSq = 0; int n = 0;
    if (base && w > 8 && h > 8) {
        for (int iy = 0; iy < 8; iy++) {
            for (int ix = 0; ix < 8; ix++) {
                size_t x = (size_t)((ix + 0.5) * w / 8.0);
                size_t y = (size_t)((iy + 0.5) * h / 8.0);
                double v = base[y * stride + x];
                sum += v; sumSq += v * v; n++;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (n == 0) return @{ @"mean": @(-1), @"variance": @(-1) };
    double mean = sum / n;
    double var = sumSq / n - mean * mean;
    return @{ @"mean": @((int)mean), @"variance": @((int)(var < 0 ? 0 : var)), @"samples": @(n) };
}

// 内部方法显式声明，避免 clang 对「同一 @implementation 内后定义的方法」给出
// "no visible @interface declares the selector" 诊断（不同 SDK 的 clang 行为不一致）。
@interface P0FrameSink ()
- (void)encodePixelBuffer:(CVPixelBufferRef)pb pts:(CMTime)pts;
// 必须在 captureDisplayID: 返回前调用：停掉会话并等异步回调排空。
// VT 回调的 refCon 是非 retained 的 __bridge 指针，sink 提前释放会变成野指针。
- (void)shutdown;
@end

@implementation P0FrameSink

- (instancetype)init {
    self = [super init];
    if (self) {
        atomic_init(&_frameCount, 0);
        atomic_init(&_encodedCount, 0);
        atomic_init(&_keyFrameCount, 0);
        atomic_init(&_decodedCount, 0);
        atomic_init(&_encodeErrors, 0);
        _encodeLatenciesMs = [NSMutableArray array];
        _worstLumaMean = 999;
        _bestLumaVariance = -1;
    }
    return self;
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) return;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb) return;

    int n = atomic_fetch_add(&_frameCount, 1) + 1;
    if (n == 1) _firstFrameMs = P0NowMs() - _captureStartMs;

    NSDictionary *luma = P0LumaStats(pb);
    double mean = [luma[@"mean"] doubleValue];
    double var  = [luma[@"variance"] doubleValue];
    if (mean >= 0 && mean < _worstLumaMean) _worstLumaMean = mean;
    if (var > _bestLumaVariance) _bestLumaVariance = var;
    // 「全黑帧」= 亮度贴近视频范围黑电平 16 且几乎无空间变化
    if (mean >= 0 && mean < kP0VideoRangeBlackY + kP0BlackMeanTolerance && var < kP0BlackVarianceMax) _blackFrames++;

    if (_withEncoder) [self encodePixelBuffer:pb pts:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
}

- (void)encodePixelBuffer:(CVPixelBufferRef)pb pts:(CMTime)pts {
    if (!_encoder) {
        int w = (int)CVPixelBufferGetWidth(pb);
        int h = (int)CVPixelBufferGetHeight(pb);
        OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault, w, h,
                          kCMVideoCodecType_H264, NULL, NULL, NULL,
                          P0CompressionOutput, (__bridge void *)self, &_encoder);
        if (st != noErr || !_encoder) {
            P0Error(@"VTCompressionSessionCreate 失败: %d", (int)st);
            return;
        }
        VTSessionSetProperty(_encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        VTSessionSetProperty(_encoder, kVTCompressionPropertyKey_ProfileLevel,
                             kVTProfileLevel_H264_Main_AutoLevel);
        VTSessionSetProperty(_encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
        NSNumber *one = @1;
        VTSessionSetProperty(_encoder, kVTCompressionPropertyKey_MaxFrameDelayCount,
                             (__bridge CFTypeRef)one);
        int bitrate = (int)(w * h * 60 * 0.12);  // 粗略 0.12 bpp @60fps
        NSNumber *bitrateNum = @(bitrate);
        VTSessionSetProperty(_encoder, kVTCompressionPropertyKey_AverageBitRate,
                             (__bridge CFTypeRef)bitrateNum);
        VTCompressionSessionPrepareToEncodeFrames(_encoder);
        P0Log(@"H.264 编码会话建立: %dx%d, target %d bps", w, h, bitrate);
    }
    double t0 = P0NowMs();
    OSStatus st = VTCompressionSessionEncodeFrame(_encoder, pb, pts, kCMTimeInvalid,
                                                  NULL, NULL, NULL);
    if (st == noErr) [_encodeLatenciesMs addObject:@(P0NowMs() - t0)];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    P0Error(@"SCStream 意外停止: %@", error.localizedDescription);
}

- (void)handleEncodedSampleBuffer:(CMSampleBufferRef)sampleBuffer status:(OSStatus)status {
    if (status != noErr || !sampleBuffer) {
        atomic_fetch_add(&_encodeErrors, 1);
        return;
    }
    atomic_fetch_add(&_encodedCount, 1);

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    BOOL isSync = YES;
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef a = CFArrayGetValueAtIndex(attachments, 0);
        isSync = !CFDictionaryGetValue(a, kCMSampleAttachmentKey_NotSync);
    }
    if (isSync) atomic_fetch_add(&_keyFrameCount, 1);

    // 环回解码：复用编码器输出的 formatDescription，省去手工解析 SPS/PPS。
    if (!_decoder) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (fmt) {
            VTDecompressionOutputCallbackRecord cb = { P0DecompressionOutput, (__bridge void *)self };
            VTDecompressionSessionCreate(kCFAllocatorDefault, fmt, NULL, NULL, &cb, &_decoder);
        }
    }
    if (_decoder) {
        VTDecompressionSessionDecodeFrame(_decoder, sampleBuffer,
                                          kVTDecodeFrame_EnableAsynchronousDecompression,
                                          NULL, NULL);
    }
}

- (void)handleDecodeStatus:(OSStatus)status hasImage:(BOOL)hasImage {
    if (status == noErr && hasImage) atomic_fetch_add(&_decodedCount, 1);
}

- (int)framesValue     { return atomic_load(&_frameCount); }
- (int)encodedValue    { return atomic_load(&_encodedCount); }
- (int)keyFramesValue  { return atomic_load(&_keyFrameCount); }
- (int)decodedValue    { return atomic_load(&_decodedCount); }
- (int)encodeErrorsValue { return atomic_load(&_encodeErrors); }

- (void)shutdown {
    if (_encoder) {
        VTCompressionSessionCompleteFrames(_encoder, kCMTimeInvalid);
        VTCompressionSessionInvalidate(_encoder);
        CFRelease(_encoder);
        _encoder = NULL;
    }
    if (_decoder) {
        // 等异步解码帧全部回调完，再 invalidate，确保 P0DecompressionOutput 期间 sink 仍存活。
        VTDecompressionSessionWaitForAsynchronousFrames(_decoder);
        VTDecompressionSessionInvalidate(_decoder);
        CFRelease(_decoder);
        _decoder = NULL;
    }
    P0SleepMs(50);
}

- (void)dealloc {
    if (_encoder) { VTCompressionSessionCompleteFrames(_encoder, kCMTimeInvalid);
                    VTCompressionSessionInvalidate(_encoder); CFRelease(_encoder); }
    if (_decoder) { VTDecompressionSessionInvalidate(_decoder); CFRelease(_decoder); }
}

@end

#pragma mark - PipelineProbe

@implementation PipelineProbe

+ (NSArray<NSNumber *> * _Nullable)shareableDisplayIDsWithError:(NSError * _Nullable * _Nullable)error {
    SCShareableContent *content = P0ShareableContent(error);
    if (!content) return nil;
    NSMutableArray *ids = [NSMutableArray array];
    for (SCDisplay *d in content.displays) [ids addObject:@(d.displayID)];
    return ids;
}

+ (BOOL)waitForDisplayIDs:(NSArray<NSNumber *> *)ids
                timeoutMs:(int)timeoutMs
                 lastSeen:(NSArray<NSNumber *> * _Nullable * _Nullable)lastSeen {
    NSSet *want = [NSSet setWithArray:ids];
    int elapsed = 0;
    NSArray *seen = @[];
    while (elapsed <= timeoutMs) {
        NSError *err = nil;
        NSArray *now = [self shareableDisplayIDsWithError:&err];
        seen = now ?: @[];
        if (err) P0Error(@"SCShareableContent: %@", err.localizedDescription);
        if ([want isSubsetOfSet:[NSSet setWithArray:seen]]) {
            if (lastSeen) *lastSeen = seen;
            return YES;
        }
        P0SleepMs(200);
        elapsed += 200;
    }
    if (lastSeen) *lastSeen = seen;
    return NO;
}

+ (NSDictionary *)encoderCapabilities {
    NSMutableArray *rows = [NSMutableArray array];
    // ARC 下 C 结构体不能放强引用 ObjC 对象，名字用 const char * 再转。
    struct { CFStringRef profile; const char *name; CMVideoCodecType codec; } cases[] = {
        { kVTProfileLevel_H264_Baseline_AutoLevel, "H264-Baseline", kCMVideoCodecType_H264 },
        { kVTProfileLevel_H264_Main_AutoLevel,     "H264-Main",     kCMVideoCodecType_H264 },
        { kVTProfileLevel_H264_High_AutoLevel,     "H264-High",     kCMVideoCodecType_H264 },
        { kVTProfileLevel_HEVC_Main_AutoLevel,     "HEVC-Main",     kCMVideoCodecType_HEVC },
    };
    int rasters[][2] = { {1920, 1080}, {2560, 1440}, {3840, 2160} };
    for (int c = 0; c < 4; c++) {
        for (int i = 0; i < 3; i++) {
            NSString *label = [NSString stringWithUTF8String:cases[c].name];
            [rows addObject:P0ProbeEncoder(cases[c].codec, label,
                                           cases[c].profile, rasters[i][0], rasters[i][1])];
        }
    }

    // OpenDisplay PR #288：H.264 High@L5.2 有吞吐上限，直接请求 5K 会让
    // VideoToolbox 返回成功回调却不产出 buffer（表现为黑屏）。这里给出建议工作点。
    return @{
        @"rows": rows,
        @"note": @"Intel 上以 H264-Main/Baseline 4:2:0 为基线；HEVC-Main 仅在 supported && hardwareAccelerated 时启用",
        @"safeH264OperatingPoint": @"4096x2304@55 (H264 High@L5.2 吞吐上限内的安全点，来自 PR #288 实测)",
    };
}

+ (NSDictionary *)captureDisplayID:(CGDirectDisplayID)displayID
                        durationMs:(int)durationMs
                       withEncoder:(BOOL)withEncoder {
    NSError *contentError = nil;
    SCShareableContent *content = P0ShareableContent(&contentError);
    if (!content) {
        return @{ @"displayID": @(displayID), @"ok": @NO,
                  @"error": [NSString stringWithFormat:@"SCShareableContent: %@",
                             contentError.localizedDescription ?: @"unknown"] };
    }
    SCDisplay *target = nil;
    for (SCDisplay *d in content.displays) {
        if (d.displayID == displayID) { target = d; break; }
    }
    if (!target) {
        return @{ @"displayID": @(displayID), @"ok": @NO,
                  @"error": @"该 displayID 不在 SCShareableContent.displays 中（Tahoe stale display 的典型症状）",
                  @"visibleIDs": [self shareableDisplayIDsWithError:NULL] ?: @[] };
    }

    // 拒绝退化 mode：对 1x1 虚拟屏启动 SCK 捕获是 2026-11-14 WindowServer
    // 挂起事故的疑似触发点之一。mode 未提交时宁可失败，绝不尝试捕获。
    CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(displayID);
    size_t mw = curMode ? CGDisplayModeGetWidth(curMode) : 0;
    size_t mh = curMode ? CGDisplayModeGetHeight(curMode) : 0;
    if (curMode) CGDisplayModeRelease(curMode);
    if (mw < 2 || mh < 2) {
        return @{ @"displayID": @(displayID), @"ok": @NO,
                  @"error": [NSString stringWithFormat:@"退化 mode %zux%zu（未提交），拒绝捕获", mw, mh] };
    }

    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:target excludingWindows:@[]];
    SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
    // SCStreamConfiguration.width/height 的单位是【像素】，而 SCDisplay.width/height 是【点】。
    // 1x 虚拟屏两者相等；HiDPI(2x) 屏若不乘 pointPixelScale，就会把 2x 画面降采样成 1x 再编码，
    // 使 HiDPI 验证（A-05）测到的其实是半分辨率流。宽高另按 H.264 要求取偶数。
    // pointPixelScale 从 macOS 14 起才有；Ventura 13 上退回 1.0（13 上暂无 HiDPI 需求）。
    CGFloat scale = 1.0;
    if (@available(macOS 14.0, *)) {
        if (filter.pointPixelScale > 0) scale = filter.pointPixelScale;
    }
    size_t outW = (size_t)llround(target.width * scale);
    size_t outH = (size_t)llround(target.height * scale);
    outW -= outW % 2;
    outH -= outH % 2;
    cfg.width = outW;
    cfg.height = outH;
    cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    cfg.minimumFrameInterval = CMTimeMake(1, 60);
    cfg.queueDepth = 4;
    cfg.showsCursor = NO;
    cfg.capturesAudio = NO;

    // precise_lifetime：禁止 ARC 在最后一次使用后提前释放 sink，
    // VT 的内部队列可能仍持着它的 __bridge refCon。
    __attribute__((objc_precise_lifetime)) P0FrameSink *sink = [[P0FrameSink alloc] init];
    sink.withEncoder = withEncoder;
    sink.captureStartMs = P0NowMs();

    NSError *streamError = nil;
    SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:sink];
    dispatch_queue_t q = dispatch_queue_create("p0.sck.sample", DISPATCH_QUEUE_SERIAL);
    if (![stream addStreamOutput:sink type:SCStreamOutputTypeScreen
              sampleHandlerQueue:q error:&streamError]) {
        return @{ @"displayID": @(displayID), @"ok": @NO,
                  @"error": [NSString stringWithFormat:@"addStreamOutput: %@", streamError.localizedDescription] };
    }

    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    __block NSError *startErr = nil;
    [stream startCaptureWithCompletionHandler:^(NSError *err) {
        startErr = err; dispatch_semaphore_signal(started);
    }];
    BOOL startTimedOut = dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0;
    if (startErr || startTimedOut) {
        // 失败路径也必须收尾：半启动的 SCStream 若直接释放，其异步 teardown
        // 会与调用方随后的虚拟屏销毁竞争。best-effort stop 后再返回。
        dispatch_semaphore_t stopSem = dispatch_semaphore_create(0);
        [stream stopCaptureWithCompletionHandler:^(NSError *e) { dispatch_semaphore_signal(stopSem); }];
        dispatch_semaphore_wait(stopSem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        return @{ @"displayID": @(displayID), @"ok": @NO,
                  @"error": startErr
                      ? [NSString stringWithFormat:@"startCapture: %@", startErr.localizedDescription]
                      : @"startCapture 5s 未回调（WindowServer 疑似异常），已中止捕获" };
    }

    P0Log(@"开始捕获 display %u (%zux%zu px, scale %.0f)，持续 %d ms", displayID,
          outW, outH, (double)scale, durationMs);
    P0SleepMs(durationMs);

    dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
    [stream stopCaptureWithCompletionHandler:^(NSError *err) {
        if (err) P0Error(@"stopCapture: %@", err.localizedDescription);
        dispatch_semaphore_signal(stopped);
    }];
    dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    // 停编解码会话 + 等异步帧排空，之后读到的计数才是终值。
    [sink shutdown];
    P0SleepMs(100);

    int frames = [sink framesValue];
    int encoded = [sink encodedValue];
    int decoded = [sink decodedValue];
    double seconds = durationMs / 1000.0;

    NSArray *sorted = [sink.encodeLatenciesMs sortedArrayUsingSelector:@selector(compare:)];
    NSNumber *p50 = sorted.count ? sorted[sorted.count / 2] : @(-1);
    NSNumber *p95 = sorted.count ? sorted[MIN(sorted.count - 1, sorted.count * 95 / 100)] : @(-1);

    return @{
        @"displayID": @(displayID),
        @"ok": @(frames > 0),
        @"raster": [NSString stringWithFormat:@"%zux%zu", outW, outH],
        @"rasterScale": @((double)scale),
        @"durationMs": @(durationMs),
        @"frames": @(frames),
        @"fps": @((int)(frames / seconds)),
        @"firstFrameLatencyMs": @((int)sink.firstFrameMs),
        @"minLumaMean": @((int)(sink.worstLumaMean == 999 ? -1 : sink.worstLumaMean)),
        @"maxLumaVariance": @((int)sink.bestLumaVariance),
        @"suspectedBlackFrames": @(sink.blackFrames),
        @"encodedFrames": @(encoded),
        @"keyFrames": @([sink keyFramesValue]),
        @"encodeErrors": @([sink encodeErrorsValue]),
        @"decodedFrames": @(decoded),
        @"encodeEnqueueP50Ms": p50,
        @"encodeEnqueueP95Ms": p95,
        @"verdict": frames == 0 ? @"NO_FRAMES_TCC_OR_STALE"
                   : (sink.blackFrames > frames * 0.8 ? @"MOSTLY_BLACK" : @"HAS_CONTENT"),
    };
}

@end