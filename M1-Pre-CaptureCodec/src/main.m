//
//  M1-Pre-CaptureCodec/main.m
//
//  验证 D-09 采集主路径的端到端可行性：
//    CGDisplayCreateImage(displayID) -> CVPixelBuffer(BGRA) -> VideoToolbox H.264
//    -> (可选环回) VTDecompressionSession
//
//  与 P0V-AltCapture 的区别：altprobe 只判断「抓到的 CGImage 是否有内容」，
//  本探针把每一帧真正送进编码器并统计帧率/耗时分位/CPU/黑帧/解码成功数，
//  用来在 M1 开工前决定 1080p60 采集编码参数，并核对 NFR-01/03/05。
//
//  安全：复用 VDManager 与 P0VDisplayControl 的快照/守护/死线/恢复；
//  先建虚拟屏再禁物理屏（C-09 + D-05 硬约束）；内置显示睡眠断言（D-08 前置）。
//

#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <ImageIO/ImageIO.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <stdatomic.h>
#import <math.h>
#import <unistd.h>
#import <sys/sysctl.h>

#import "P0VDisplayControl.h"
#import "VDManager.h"
#import "PipelineProbe.h"

#define M1_GRID 16

static NSUInteger optWidth = 1920;
static NSUInteger optHeight = 1080;
static int optDurationMs = 3000;
static int optTargetFps = 0;          // 0 = 尽力跑；>0 = 按目标帧率 pacing
static double optBitrateBPP = 0.12;   // bits per pixel per second
static NSString *optOut = @"/tmp/m1-pre-capture-codec.json";
static BOOL optNoDisable = NO;
static BOOL optSckControl = YES;
static BOOL optSckEncode = NO;
static BOOL optSckOnly = NO;
static NSString *optShotPath = nil;

static void M1Usage(void) {
    fprintf(stderr,
        "用法:\n"
        "  capturecodec [--spec WxH] [--duration-ms N] [--target-fps N]\n"
        "               [--bitrate-bpp D] [--out PATH] [--shot PATH]\n"
        "               [--no-disable] [--no-sck-control]\n"
        "  capturecodec --guardian <snapshot> --parent-pid <pid>\n");
}

static BOOL M1ParseUnsigned(const char *s, NSUInteger *out) {
    if (!s || !*s) return NO;
    char *end = NULL;
    unsigned long v = strtoul(s, &end, 0);
    if (end == s || *end != '\0') return NO;
    *out = (NSUInteger)v;
    return YES;
}

static double M1NowMs(void) { return [[NSDate date] timeIntervalSince1970] * 1000.0; }

static NSString *M1MachineModel(void) {
    char buf[128] = {0};
    size_t len = sizeof(buf);
    if (sysctlbyname("hw.model", buf, &len, NULL, 0) == 0) {
        return [NSString stringWithUTF8String:buf] ?: @"unknown";
    }
    return @"unknown";
}

#pragma mark - CPU 采样

typedef struct {
    uint64_t user;
    uint64_t system;
    uint64_t idle;
} M1CPUTicks;

static BOOL M1ReadCPUTicks(M1CPUTicks *out) {
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    kern_return_t kr = host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
                                       (host_info_t)&info, &count);
    if (kr != KERN_SUCCESS) return NO;
    out->user   = info.cpu_ticks[CPU_STATE_USER] + info.cpu_ticks[CPU_STATE_NICE];
    out->system = info.cpu_ticks[CPU_STATE_SYSTEM];
    out->idle   = info.cpu_ticks[CPU_STATE_IDLE];
    return YES;
}

static double M1ProcessCPUSeconds(void) {
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) != 0) return -1;
    return (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1e6
         + (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1e6;
}

static NSDictionary *M1CPUReport(double cpuStart, double wallSec,
                                 M1CPUTicks t0, M1CPUTicks t1, BOOL hostOK) {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    r[@"wallSeconds"] = @(wallSec);
    if (cpuStart >= 0) {
        double proc = M1ProcessCPUSeconds();
        r[@"processCpuSeconds"] = @(MAX(0.0, proc - cpuStart));
        r[@"processCpuCores"] = @((proc - cpuStart) / MAX(wallSec, 1e-6));
    }
    if (hostOK) {
        uint64_t busy0 = t0.user + t0.system, busy1 = t1.user + t1.system;
        uint64_t total0 = busy0 + t0.idle, total1 = busy1 + t1.idle;
        uint64_t dBusy = (busy1 > busy0) ? (busy1 - busy0) : 0;
        uint64_t dTotal = (total1 > total0) ? (total1 - total0) : 1;
        r[@"machineBusyPercent"] = @((double)busy1 * 0 + 100.0 * (double)dBusy / (double)dTotal);
    }
    return r;
}

#pragma mark - 图像统计与落盘

// 从已 conversions 完成的 BGRA CVPixelBuffer 采样 16x16 网格判黑。
// BGRA 为 full range，纯黑接近 0（不同于 SCK 的 video range Y=16）。
static NSDictionary *M1LumaStats(CVPixelBufferRef pb) {
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return @{ @"mean": @(-1), @"variance": @(-1), @"black": @NO };
    }
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t rowBytes = CVPixelBufferGetBytesPerRow(pb);
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    double sum = 0, sumSq = 0; int n = 0;
    if (base && w >= M1_GRID && h >= M1_GRID) {
        for (int iy = 0; iy < M1_GRID; iy++) {
            for (int ix = 0; ix < M1_GRID; ix++) {
                size_t x = (size_t)((ix + 0.5) * w / M1_GRID);
                size_t y = (size_t)((iy + 0.5) * h / M1_GRID);
                uint8_t b = base[y * rowBytes + x * 4 + 0];
                uint8_t g = base[y * rowBytes + x * 4 + 1];
                uint8_t r = base[y * rowBytes + x * 4 + 2];
                double lum = (r + g + b) / 3.0;
                sum += lum; sumSq += lum * lum; n++;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (n == 0) return @{ @"mean": @(-1), @"variance": @(-1), @"black": @NO };
    double mean = sum / n;
    double var = fmax(0.0, sumSq / n - mean * mean);
    return @{ @"mean": @((int)lround(mean)),
              @"variance": @((int)lround(var)),
              @"black": @(mean < 8.0 && var < 4.0) };
}

static BOOL M1SaveCGImage(CGImageRef img, NSString *path) {
    if (!img || !path) return NO;
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    if (!dest) return NO;
    CGImageDestinationAddImage(dest, img, NULL);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok;
}

static NSDictionary *M1Percentiles(NSArray<NSNumber *> *values) {
    NSArray *sorted = [values sortedArrayUsingSelector:@selector(compare:)];
    if (sorted.count == 0) {
        return @{ @"count": @0, @"p50": @(-1), @"p95": @(-1), @"max": @(-1) };
    }
    return @{
        @"count": @(sorted.count),
        @"p50": sorted[sorted.count / 2],
        @"p95": sorted[MIN(sorted.count - 1, (NSUInteger)(sorted.count * 0.95))],
        @"max": sorted.lastObject,
        @"avg": @([sorted.lastObject doubleValue] * 0 +
                  [[sorted valueForKeyPath:@"@avg.doubleValue"] doubleValue]),
    };
}

#pragma mark - 编码环回 sink

static void M1DecompressionOutput(void *refCon, void *src, OSStatus status,
                                  VTDecodeInfoFlags flags, CVImageBufferRef image,
                                  CMTime pts, CMTime duration);

@interface M1EncodeSink : NSObject {
    atomic_int _captureFrames;
    atomic_int _blackFrames;
    atomic_int _convertFailures;
    atomic_int _encodedFrames;
    atomic_int _keyFrames;
    atomic_int _encodeErrors;
    atomic_int _decodedFrames;
    atomic_long _encodedBytes;
}
@property (nonatomic, assign) double minLumaMean;
@property (nonatomic, assign) double maxLumaVariance;
@property (nonatomic, assign) VTCompressionSessionRef encoder;
@property (nonatomic, assign) VTDecompressionSessionRef decoder;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *captureMs;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *convertMs;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *enqueueMs;
- (void)noteCaptureFrameBlack:(BOOL)black mean:(double)mean var:(double)var;
- (void)noteConvertFailure;
- (void)noteCaptureMs:(double)ms convertMs:(double)cms enqueueMs:(double)ems;
- (void)handleEncoded:(CMSampleBufferRef)sb status:(OSStatus)status;
- (void)handleDecoded:(OSStatus)status hasImage:(BOOL)hasImage;
- (NSDictionary *)counters;
- (void)shutdown;
@end

static void M1CompressionOutput(void *refCon, void *src, OSStatus status,
                                VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    [(__bridge M1EncodeSink *)refCon handleEncoded:sb status:status];
}

static void M1DecompressionOutput(void *refCon, void *src, OSStatus status,
                                  VTDecodeInfoFlags flags, CVImageBufferRef image,
                                  CMTime pts, CMTime duration) {
    [(__bridge M1EncodeSink *)refCon handleDecoded:status hasImage:(image != NULL)];
}

@implementation M1EncodeSink

- (instancetype)init {
    self = [super init];
    if (self) {
        atomic_init(&_captureFrames, 0);
        atomic_init(&_blackFrames, 0);
        atomic_init(&_convertFailures, 0);
        atomic_init(&_encodedFrames, 0);
        atomic_init(&_keyFrames, 0);
        atomic_init(&_encodeErrors, 0);
        atomic_init(&_decodedFrames, 0);
        atomic_init(&_encodedBytes, 0);
        _minLumaMean = 999;
        _maxLumaVariance = -1;
        _captureMs = [NSMutableArray array];
        _convertMs = [NSMutableArray array];
        _enqueueMs = [NSMutableArray array];
    }
    return self;
}

- (void)noteCaptureFrameBlack:(BOOL)black mean:(double)mean var:(double)var {
    atomic_fetch_add(&_captureFrames, 1);
    if (black) atomic_fetch_add(&_blackFrames, 1);
    if (mean >= 0 && mean < _minLumaMean) _minLumaMean = mean;
    if (var > _maxLumaVariance) _maxLumaVariance = var;
}

- (void)noteConvertFailure { atomic_fetch_add(&_convertFailures, 1); }
- (void)noteEnqueueError { atomic_fetch_add(&_encodeErrors, 1); }

- (void)noteCaptureMs:(double)ms convertMs:(double)cms enqueueMs:(double)ems {
    [_captureMs addObject:@(ms)];
    [_convertMs addObject:@(cms)];
    [_enqueueMs addObject:@(ems)];
}

- (void)handleEncoded:(CMSampleBufferRef)sb status:(OSStatus)status {
    if (status != noErr || !sb) {
        atomic_fetch_add(&_encodeErrors, 1);
        return;
    }
    atomic_fetch_add(&_encodedFrames, 1);
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    if (bb) atomic_fetch_add(&_encodedBytes, (long)CMBlockBufferGetDataLength(bb));

    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (atts && CFArrayGetCount(atts) > 0) {
        CFDictionaryRef a = CFArrayGetValueAtIndex(atts, 0);
        if (!CFDictionaryGetValue(a, kCMSampleAttachmentKey_NotSync)) {
            atomic_fetch_add(&_keyFrames, 1);
        }
    }
    if (!_decoder) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
        if (fmt) {
            VTDecompressionOutputCallbackRecord cb = { M1DecompressionOutput,
                                                        (__bridge void *)self };
            if (VTDecompressionSessionCreate(kCFAllocatorDefault, fmt, NULL, NULL,
                                             &cb, &_decoder) != noErr) {
                _decoder = NULL;
            }
        }
    }
    if (_decoder) {
        VTDecompressionSessionDecodeFrame(_decoder, sb,
                                          kVTDecodeFrame_EnableAsynchronousDecompression,
                                          NULL, NULL);
    }
}

- (void)handleDecoded:(OSStatus)status hasImage:(BOOL)hasImage {
    if (status == noErr && hasImage) atomic_fetch_add(&_decodedFrames, 1);
}

- (NSDictionary *)counters {
    return @{
        @"captureFrames": @(atomic_load(&_captureFrames)),
        @"blackFrames": @(atomic_load(&_blackFrames)),
        @"convertFailures": @(atomic_load(&_convertFailures)),
        @"encodedFrames": @(atomic_load(&_encodedFrames)),
        @"keyFrames": @(atomic_load(&_keyFrames)),
        @"encodeErrors": @(atomic_load(&_encodeErrors)),
        @"decodedFrames": @(atomic_load(&_decodedFrames)),
        @"encodedBytes": @(atomic_load(&_encodedBytes)),
        @"minLumaMean": @((int)(_minLumaMean == 999 ? -1 : _minLumaMean)),
        @"maxLumaVariance": @((int)MAX(0, _maxLumaVariance)),
        @"captureMs": M1Percentiles(_captureMs),
        @"convertMs": M1Percentiles(_convertMs),
        @"enqueueMs": M1Percentiles(_enqueueMs),
    };
}

- (void)shutdown {
    if (_encoder) {
        VTCompressionSessionCompleteFrames(_encoder, kCMTimeInvalid);
        VTCompressionSessionInvalidate(_encoder);
        CFRelease(_encoder);
        _encoder = NULL;
    }
    if (_decoder) {
        VTDecompressionSessionWaitForAsynchronousFrames(_decoder);
        VTDecompressionSessionInvalidate(_decoder);
        CFRelease(_decoder);
        _decoder = NULL;
    }
    [NSThread sleepForTimeInterval:0.05];
}

- (void)dealloc {
    if (_encoder) { VTCompressionSessionCompleteFrames(_encoder, kCMTimeInvalid);
                    VTCompressionSessionInvalidate(_encoder); CFRelease(_encoder); }
    if (_decoder) { VTDecompressionSessionInvalidate(_decoder); CFRelease(_decoder); }
}

@end

#pragma mark - CGImage -> CVPixelBuffer

// CGDisplayCreateImage 返回 CGImage；VT 只吃 CVPixelBuffer，故经 CGBitmapContext
// 画进 BGRA pixel buffer。D-09 已明确这里不是零拷贝，性能以本次实测为准。
static CVPixelBufferRef M1CreatePixelBuffer(size_t w, size_t h) {
    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{ (__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_32BGRA,
                                     (__bridge CFDictionaryRef)attrs, &pb);
    return (r == kCVReturnSuccess) ? pb : NULL;
}

static BOOL M1DrawImageInto(CGImageRef img, CVPixelBufferRef pb) {
    if (CVPixelBufferLockBaseAddress(pb, 0) != kCVReturnSuccess) return NO;
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t rowBytes = CVPixelBufferGetBytesPerRow(pb);
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, rowBytes, cs,
                        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (!ctx) { CVPixelBufferUnlockBaseAddress(pb, 0); return NO; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return YES;
}

#pragma mark - 主采集循环

static NSDictionary *M1RunCapture(CGDirectDisplayID displayID, __attribute__((objc_precise_lifetime)) M1EncodeSink *sink) {
    // 用第一帧的实际尺寸建编码会话，避免 spec 与 mode 不一致时喂错分辨率。
    CGImageRef first = CGDisplayCreateImage(displayID);
    if (!first) {
        return @{ @"ok": @NO, @"error": @"CGDisplayCreateImage 首帧返回 NULL（TCC 或屏睡）" };
    }
    size_t w = CGImageGetWidth(first), h = CGImageGetHeight(first);
    BOOL shotSaved = M1SaveCGImage(first, optShotPath);
    CGImageRelease(first);
    if (w < 2 || h < 2) {
        return @{ @"ok": @NO, @"error": [NSString stringWithFormat:@"退化尺寸 %zux%zu", w, h] };
    }

    VTCompressionSessionRef enc = NULL;
    OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault, (int)w, (int)h,
                        kCMVideoCodecType_H264, NULL, NULL, NULL,
                        M1CompressionOutput, (__bridge void *)sink, &enc);
    if (st != noErr || !enc) {
        return @{ @"ok": @NO, @"error": [NSString stringWithFormat:@"VTCompressionSessionCreate 失败 %d", (int)st] };
    }
    VTSessionSetProperty(enc, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(enc, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_Main_AutoLevel);
    VTSessionSetProperty(enc, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    NSNumber *one = @1;
    VTSessionSetProperty(enc, kVTCompressionPropertyKey_MaxFrameDelayCount,
                         (__bridge CFTypeRef)one);
    int bitrate = (int)(w * h * (optTargetFps > 0 ? optTargetFps : 60) * optBitrateBPP);
    NSNumber *br = @(bitrate);
    VTSessionSetProperty(enc, kVTCompressionPropertyKey_AverageBitRate,
                         (__bridge CFTypeRef)br);
    VTCompressionSessionPrepareToEncodeFrames(enc);
    sink.encoder = enc;

    M1CPUTicks t0 = {0}, t1 = {0};
    BOOL hostOK = M1ReadCPUTicks(&t0);
    double cpuStart = M1ProcessCPUSeconds();
    double wallStart = M1NowMs();
    int tick = 0;
    CVPixelBufferRef sharedPB = NULL;
    size_t sharedW = 0, sharedH = 0;

    while (M1NowMs() - wallStart < optDurationMs) {
        if (optTargetFps > 0) {
            double due = wallStart + (1000.0 * tick) / optTargetFps;
            double now = M1NowMs();
            if (now < due) [NSThread sleepForTimeInterval:(due - now) / 1000.0];
        }
        double c0 = M1NowMs();
        CGImageRef img = CGDisplayCreateImage(displayID);
        double c1 = M1NowMs();
        if (!img) { [sink noteConvertFailure]; tick++; continue; }

        // 复用一个 pixel buffer，避免每帧 alloc 引入噪音；尺寸来自首帧，后续帧应一致。
        if (!sharedPB || sharedW != w || sharedH != h) {
            if (sharedPB) CVPixelBufferRelease(sharedPB);
            sharedPB = M1CreatePixelBuffer(w, h);
            sharedW = w; sharedH = h;
        }
        double v0 = M1NowMs();
        BOOL converted = sharedPB && M1DrawImageInto(img, sharedPB);
        double v1 = M1NowMs();
        CGImageRelease(img);
        if (!converted) { [sink noteConvertFailure]; tick++; continue; }

        NSDictionary *luma = M1LumaStats(sharedPB);
        [sink noteCaptureFrameBlack:[luma[@"black"] boolValue]
                               mean:[luma[@"mean"] doubleValue]
                                var:[luma[@"variance"] doubleValue]];

        double e0 = M1NowMs();
        CMTime pts = CMTimeMake(tick++, 60);
        OSStatus enq = VTCompressionSessionEncodeFrame(enc, sharedPB, pts,
                            kCMTimeInvalid, NULL, NULL, NULL);
        double e1 = M1NowMs();
        [sink noteCaptureMs:c1 - c0 convertMs:v1 - v0 enqueueMs:e1 - e0];
        if (enq != noErr) [sink noteEnqueueError];
    }
    if (sharedPB) { CVPixelBufferRelease(sharedPB); sharedPB = NULL; }

    double wallEnd = M1NowMs();
    hostOK = hostOK && M1ReadCPUTicks(&t1);
    [sink shutdown];  // 排空回调后再读计数

    double wallSec = (wallEnd - wallStart) / 1000.0;
    NSDictionary *counters = [sink counters];
    int frames = [counters[@"captureFrames"] intValue];
    int black = [counters[@"blackFrames"] intValue];
    int encoded = [counters[@"encodedFrames"] intValue];
    int decoded = [counters[@"decodedFrames"] intValue];
    int errs = [counters[@"encodeErrors"] intValue];
    int convFail = [counters[@"convertFailures"] intValue];

    NSString *verdict = @"FAIL";
    if (frames > 0 && black <= frames * 0.1 && convFail == 0 &&
        encoded >= frames * 0.8 && decoded >= encoded * 0.5 && errs == 0) {
        verdict = @"PASS";
    }

    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    r[@"ok"] = @([verdict isEqualToString:@"PASS"]);
    r[@"verdict"] = verdict;
    r[@"raster"] = [NSString stringWithFormat:@"%zux%zu", w, h];
    r[@"durationMs"] = @(optDurationMs);
    r[@"targetFps"] = @(optTargetFps);
    r[@"bitrateBpp"] = @(optBitrateBPP);
    r[@"targetBitrate"] = @(bitrate);
    r[@"actualFps"] = @((int)(frames / MAX(wallSec, 1e-6)));
    r[@"shotSaved"] = @(shotSaved);
    [r addEntriesFromDictionary:counters];
    r[@"cpu"] = M1CPUReport(cpuStart, wallSec, t0, t1, hostOK);
    return r;
}

#pragma mark - 主流程

static int M1Run(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"stage"] = @"start";
    out[@"ts"] = [[NSDate date] description];
    out[@"osVersion"] = [NSProcessInfo processInfo].operatingSystemVersionString;
    out[@"machineModel"] = M1MachineModel();
    out[@"mode"] = optNoDisable ? @"no-disable" : @"disable-all";

    // D-08 前置：常驻防显示睡眠断言，避免锁屏 2–3s 后屏睡导致抓屏为空。
    IOPMAssertionID displayAssertion = 0, systemAssertion = 0;
    IOReturn ar1 = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionLevelOn,
        CFSTR("M1-Pre capture codec"), &displayAssertion);
    IOReturn ar2 = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionLevelOn,
        CFSTR("M1-Pre capture codec"), &systemAssertion);
    out[@"powerAssertions"] = @{ @"display": @(ar1 == kIOReturnSuccess),
                                 @"system": @(ar2 == kIOReturnSuccess) };

    NSString *snapPath = [NSString stringWithFormat:@"/tmp/m1-pre-snapshot-%d.json", getpid()];
    P0VDisplaySnapshot *snap = nil;
    if (!optNoDisable) {
        snap = [P0VDisplaySnapshot captureActive];
        NSError *snapErr = nil;
        if (![snap writeToFile:snapPath error:&snapErr]) {
            out[@"error"] = [NSString stringWithFormat:@"snapshot failed: %@", snapErr.localizedDescription];
            [out writeToFile:optOut atomically:YES];
            return 2;
        }
        out[@"snapshotPath"] = snapPath;
        NSError *guardErr = nil;
        out[@"guardian"] = P0VStartGuardian(snapPath, getpid(), &guardErr)
            ? @{ @"started": @YES } : @{ @"started": @NO,
                                         @"error": guardErr.localizedDescription ?: @"unknown" };
    } else {
        out[@"guardian"] = @{ @"started": @NO, @"reason": @"no-disable mode" };
    }

    out[@"stage"] = @"create-virtual";
    VDManager *vd = [[VDManager alloc] initWithConfigs:@[
        @{ @"width": @(optWidth), @"height": @(optHeight), @"hiDPI": @NO,
           @"refreshRate": @60, @"name": @"M1-Pre" }
    ] identityOffset:[VDManager savedIdentityOffset] conservativeFirst:YES];
    BOOL created = [vd createAll];
    if (!created || ![vd waitUntilUsableTimeoutMs:8000]) {
        out[@"error"] = @"create virtual display failed";
        [out writeToFile:optOut atomically:YES];
        return 2;
    }
    [vd waitUntilModeMatchesTimeoutMs:10000 conservative:YES];
    [vd promoteToTarget];
    [vd waitUntilModeMatchesTimeoutMs:10000 conservative:NO];
    uint32_t displayID = [vd.displayIDs.firstObject unsignedIntValue];
    out[@"virtualDisplayID"] = @(displayID);
    out[@"virtualLiveness"] = vd.liveness;
    printf("虚拟屏就绪: %u (%lux%lu)\n", displayID,
           (unsigned long)optWidth, (unsigned long)optHeight);
    fflush(stdout);

    if (!optNoDisable) {
        out[@"stage"] = @"disable-physical";
        NSArray<NSNumber *> *active = P0VActiveDisplayIDs();
        NSMutableArray *physical = [NSMutableArray array];
        for (NSNumber *n in active) if (n.unsignedIntValue != displayID) [physical addObject:n];
        NSDictionary *detail = nil; NSError *derr = nil;
        BOOL disabled = P0VApplyDisplayEnabledChanges(physical, @[], P0VCommitScopeSession,
                                                      20, &detail, &derr);
        out[@"disable"] = @{
            @"ok": @(disabled), @"targets": physical,
            @"detail": detail ?: [NSNull null],
            @"error": derr.localizedDescription ?: [NSNull null],
            @"activeAfter": P0VActiveDisplayIDs(),
        };
        if (!disabled) {
            [vd destroyAll];
            [out writeToFile:optOut atomically:YES];
            return 1;
        }
        [NSThread sleepForTimeInterval:1.0];
    }

    out[@"stage"] = @"capture-encode";
    if (!optSckOnly) {
        __attribute__((objc_precise_lifetime)) M1EncodeSink *sink = [[M1EncodeSink alloc] init];
        out[@"captureEncode"] = M1RunCapture(displayID, sink);
    } else {
        out[@"captureEncode"] = @{ @"skipped": @"sck-only mode" };
    }

    if (optSckControl) {
        out[@"stage"] = @"sck-control";
        out[@"sckControl"] = [PipelineProbe captureDisplayID:displayID
                                                  durationMs:MIN(4000, optDurationMs)
                                                 withEncoder:optSckEncode];
    }

    out[@"stage"] = @"restore";
    if (!optNoDisable) {
        NSDictionary *rd = nil; NSError *rerr = nil;
        BOOL restored = P0VRestoreSnapshot(snap, P0VCommitScopeSession, 20, &rd, &rerr);
        out[@"restore"] = @{
            @"ok": @(restored), @"detail": rd ?: [NSNull null],
            @"error": rerr.localizedDescription ?: [NSNull null],
            @"activeAfter": P0VActiveDisplayIDs(),
        };
        NSString *done = [NSString stringWithFormat:@"%@.done", snapPath];
        [@"ok" writeToFile:done atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else {
        out[@"restore"] = @{ @"ok": @YES, @"skipped": @"no-disable mode" };
    }
    [vd destroyAll];

    if (displayAssertion) IOPMAssertionRelease(displayAssertion);
    if (systemAssertion) IOPMAssertionRelease(systemAssertion);

    out[@"stage"] = @"done";
    NSError *werr = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:out
                                                  options:NSJSONWritingPrettyPrinted
                                                    error:&werr];
    if (!json || ![json writeToFile:optOut atomically:YES]) {
        fprintf(stderr, "结果写入失败: %s\n", optOut.UTF8String);
    }

    NSDictionary *ce = out[@"captureEncode"];
    printf("=== M1-Pre 采编链路 ===\n");
    if (optSckOnly) {
        printf("  (CGDisplayCreateImage 主链路已跳过，仅跑 SCK 对照)\n");
    } else {
        printf("  verdict=%s  actualFps=%s  frames=%s  black=%s\n",
               [ce[@"verdict"] UTF8String], [ce[@"actualFps"] description].UTF8String,
               [ce[@"captureFrames"] description].UTF8String,
               [ce[@"blackFrames"] description].UTF8String);
        printf("  encoded=%s  decoded=%s  encodeErrors=%s  convertFail=%s\n",
               [ce[@"encodedFrames"] description].UTF8String,
               [ce[@"decodedFrames"] description].UTF8String,
               [ce[@"encodeErrors"] description].UTF8String,
               [ce[@"convertFailures"] description].UTF8String);
        printf("  captureMs p95=%s  convertMs p95=%s  machineBusy=%s%%\n",
               [ce[@"captureMs"][@"p95"] description].UTF8String,
               [ce[@"convertMs"][@"p95"] description].UTF8String,
               [ce[@"cpu"][@"machineBusyPercent"] description].UTF8String);
    }
    printf("restore=%s\n", [out[@"restore"][@"ok"] boolValue] ? "OK" : "FAILED");
    BOOL chainOK = optSckOnly ? YES : [ce[@"ok"] boolValue];
    return chainOK && [out[@"restore"][@"ok"] boolValue] ? 0 : 2;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--guardian") == 0) {
            NSString *snap = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : nil;
            pid_t parent = 0;
            for (int i = 3; i + 1 < argc; i++) {
                if (strcmp(argv[i], "--parent-pid") == 0) parent = atoi(argv[i + 1]);
            }
            if (!snap || parent <= 0) return 3;
            return P0VRunGuardian(snap, parent);
        }
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--spec") == 0 && i + 1 < argc) {
                NSUInteger w = 0, h = 0;
                NSString *spec = [NSString stringWithUTF8String:argv[++i]];
                NSArray *p = [spec componentsSeparatedByString:@"x"];
                if (p.count != 2 || !M1ParseUnsigned([p[0] UTF8String], &w) ||
                    !M1ParseUnsigned([p[1] UTF8String], &h)) { M1Usage(); return 3; }
                optWidth = w; optHeight = h;
            } else if (strcmp(argv[i], "--duration-ms") == 0 && i + 1 < argc) {
                optDurationMs = atoi(argv[++i]);
            } else if (strcmp(argv[i], "--target-fps") == 0 && i + 1 < argc) {
                optTargetFps = atoi(argv[++i]);
            } else if (strcmp(argv[i], "--bitrate-bpp") == 0 && i + 1 < argc) {
                optBitrateBPP = atof(argv[++i]);
            } else if (strcmp(argv[i], "--out") == 0 && i + 1 < argc) {
                optOut = [NSString stringWithUTF8String:argv[++i]];
            } else if (strcmp(argv[i], "--shot") == 0 && i + 1 < argc) {
                optShotPath = [NSString stringWithUTF8String:argv[++i]];
            } else if (strcmp(argv[i], "--no-disable") == 0) {
                optNoDisable = YES;
            } else if (strcmp(argv[i], "--no-sck-control") == 0) {
                optSckControl = NO;
            } else if (strcmp(argv[i], "--sck-encode") == 0) {
                optSckEncode = YES;
            } else if (strcmp(argv[i], "--sck-only") == 0) {
                optSckOnly = YES; optSckEncode = YES;
            } else {
                M1Usage(); return 3;
            }
        }
        return M1Run();
    }
}
