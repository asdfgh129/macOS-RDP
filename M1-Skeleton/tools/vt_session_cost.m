//
//  vtwarm.m — 量化 VTDecompressionSessionCreate 的冷/热成本
//
//  目的：M1-A 第 5 步要判断首帧延迟里 800~1274ms 的解码会话创建，到底是
//  (a) VTDecoderXPCService 冷启动（可预热规避），还是
//  (b) H.264 硬件解码器在本次分辨率上的真实初始化（无法规避，只能挪走）。
//
//  做法：先用 VTCompressionSession 编一帧 1080p，拿到真实的 SPS/PPS，
//  再用它建解码会话两次，分别计时。最后单独测「裸 format desc（无参数集扩展）
//  能否建会话」，用于判断预热能否在不依赖真实码流的情况下完成。
//

#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>

static double NowMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static CMFormatDescriptionRef gFmt = NULL;
static BOOL gGotFrame = NO;
static NSData *gSPS = nil, *gPPS = nil;

static void EncodeCb(void *outRefCon, void *srcRefCon, OSStatus status,
                     VTEncodeInfoFlags infoFlags, CMSampleBufferRef sb) {
    if (status != noErr || !sb) {
        printf("  编码回调失败 status=%d\n", (int)status);
        return;
    }
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    if (!fd) return;
    gFmt = (CMFormatDescriptionRef)CFRetain(fd);

    size_t count = 0;
    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, 0, NULL, NULL, &count, NULL);
    for (size_t i = 0; i < count; i++) {
        const uint8_t *p = NULL; size_t n = 0;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, i, &p, &n, NULL, NULL) == noErr) {
            NSData *d = [NSData dataWithBytes:p length:n];
            uint8_t t = n ? (p[0] & 0x1F) : 0;
            if (t == 7 && !gSPS) gSPS = d;
            else if (t == 8 && !gPPS) gPPS = d;
            printf("  参数集 #%zu type=%u len=%zu\n", i, t, n);
        }
    }
    gGotFrame = YES;
}

// 建会话并计时；返回会话（调用方负责 invalidate/release），失败返回 NULL
static VTDecompressionSessionRef TimeCreate(CMFormatDescriptionRef fmt,
                                            const char *label,
                                            double *outMs) {
    double t0 = NowMs();
    VTDecompressionSessionRef s = NULL;
    OSStatus st = VTDecompressionSessionCreate(kCFAllocatorDefault, fmt, NULL, NULL, NULL, &s);
    double dt = NowMs() - t0;
    if (outMs) *outMs = dt;
    printf("  %-34s %8.1f ms   status=%d %s\n", label, dt, (int)st, s ? "OK" : "NULL");
    return s;
}

static void Destroy(VTDecompressionSessionRef s) {
    if (!s) return;
    VTDecompressionSessionWaitForAsynchronousFrames(s);
    VTDecompressionSessionInvalidate(s);
    CFRelease(s);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);

        BOOL bareOnly  = NO, warmOnly = NO;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--bare-only")) bareOnly = YES;
            if (!strcmp(argv[i], "--warm-only")) warmOnly = YES;
        }

        printf("== 阶段 0：裸 format desc（无参数集）能否建解码会话 ==\n");
        {
            CMFormatDescriptionRef bare = NULL;
            OSStatus cs = CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                                         kCMVideoCodecType_H264,
                                                         1920, 1080, NULL, &bare);
            printf("  CMVideoFormatDescriptionCreate status=%d\n", (int)cs);
            if (cs == noErr && bare) {
                double ms = 0;
                VTDecompressionSessionRef s = TimeCreate(bare, "VTDecompressionSessionCreate(裸)", &ms);
                Destroy(s);
                CFRelease(bare);
            }
        }
        if (bareOnly) return 0;

        printf("== 阶段 1：编码一帧拿到真实 SPS/PPS ==\n");
        double tEnc = NowMs();
        VTCompressionSessionRef enc = NULL;
        OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault, 1920, 1080,
                                                 kCMVideoCodecType_H264, NULL, NULL, NULL,
                                                 EncodeCb, NULL, &enc);
        printf("  VTCompressionSessionCreate status=%d  %.1f ms\n", (int)st, NowMs() - tEnc);
        if (st != noErr || !enc) return 1;
        VTSessionSetProperty(enc, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        VTSessionSetProperty(enc, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
        VTCompressionSessionPrepareToEncodeFrames(enc);

        CVPixelBufferRef pb = NULL;
        CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}},
                            &pb);
        for (int i = 0; i < 10 && !gGotFrame; i++) {
            double t0 = NowMs();
            VTCompressionSessionEncodeFrame(enc, pb, CMTimeMake(i, 20), kCMTimeInvalid,
                                            NULL, NULL, NULL);
            printf("  送第 %d 帧 %.1f ms%s\n", i + 1, NowMs() - t0, gGotFrame ? "（已出帧）" : "");
        }
        VTCompressionSessionCompleteFrames(enc, kCMTimeInvalid);
        CVPixelBufferRelease(pb);
        if (pb) CFRelease(pb);
        if (!gFmt) { printf("未拿到 format desc，退出\n"); return 1; }
        printf("  SPS=%zuB PPS=%zuB\n", gSPS.length, gPPS.length);

        if (!warmOnly) {
            printf("== 阶段 2：冷建解码会话（真实参数集）==\n");
            double ms1 = 0;
            VTDecompressionSessionRef s1 = TimeCreate(gFmt, "第 1 次（冷）", &ms1);
            printf("== 阶段 3：热建解码会话（同一进程第二次）==\n");
            double ms2 = 0;
            VTDecompressionSessionRef s2 = TimeCreate(gFmt, "第 2 次（热）", &ms2);
            printf("== 阶段 4：热建第三次 ==\n");
            double ms3 = 0;
            VTDecompressionSessionRef s3 = TimeCreate(gFmt, "第 3 次（热）", &ms3);
            Destroy(s1); Destroy(s2); Destroy(s3);
            printf("\n结论：冷 %.1fms → 热 %.1f/%.1fms，可预热节省 %.1fms\n",
                   ms1, ms2, ms3, MAX(0.0, ms1 - MIN(ms2, ms3)));
        }

        printf("== 阶段 5：第二次建编码会话（同进程，验证 VT 初始化是否 per-process 一次性）==\n");
        {
            VTCompressionSessionRef e2 = NULL;
            double t0 = NowMs();
            OSStatus s2 = VTCompressionSessionCreate(kCFAllocatorDefault, 1920, 1080,
                                                     kCMVideoCodecType_H264, NULL, NULL, NULL,
                                                     NULL, NULL, &e2);
            printf("  第 2 次建编码会话 %8.1f ms status=%d\n", NowMs() - t0, (int)s2);
            if (e2) { VTCompressionSessionInvalidate(e2); CFRelease(e2); }
        }
        printf("== 阶段 6：预热后用裸 fd 建解码会话（模拟预热生效后的真实建会话）==\n");
        {
            CMFormatDescriptionRef bare = NULL;
            CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_H264,
                                           1920, 1080, NULL, &bare);
            double ms = 0;
            VTDecompressionSessionRef s = TimeCreate(bare, "预热后裸 fd", &ms);
            Destroy(s);
            if (bare) CFRelease(bare);
        }

        VTCompressionSessionCompleteFrames(enc, kCMTimeInvalid);
        VTCompressionSessionInvalidate(enc);
        CFRelease(enc);
        if (gFmt) CFRelease(gFmt);
    }
    return 0;
}
