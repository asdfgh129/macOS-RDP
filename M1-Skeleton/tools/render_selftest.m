//
//  render_selftest.m
//  M1-Skeleton/tools
//
//  M1FrameView 的离屏自检：不需要可见窗口，也不需要解锁屏幕。
//
//  做法：造一张「左红右蓝」的 CVPixelBuffer 喂给 view，等渲染队列把 CGImage 贴上，
//  再从 layer.contents 读回来采样像素。这能钉住三件容易出错的事：
//    · CIContext 是否能转换该像素格式（转不出来 → cg == NULL）；
//    · 尺寸是否与源一致（错位/裁切会立刻看出）；
//    · 通道顺序与色彩空间是否对（R/B 互换是最常见的坑）。
//
//  注意：它验证不了「窗口真的显示在屏幕上」，那需要解锁后的 verify_m1b.sh。
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import "M1FrameView.h"

static int gFail = 0;

static void Check(BOOL cond, const char *name) {
    printf("[%s] %s\n", cond ? "PASS" : "FAIL", name);
    if (!cond) gFail++;
}

// 左半红、右半蓝的 BGRA 图。
static CVPixelBufferRef MakeTwoToneBuffer(size_t w, size_t h) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) {
        return NULL;
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t stride = CVPixelBufferGetBytesPerRow(pb);
    for (size_t y = 0; y < h; y++) {
        uint8_t *row = base + y * stride;
        for (size_t x = 0; x < w; x++) {
            uint8_t *p = row + x * 4;      // BGRA
            if (x < w / 2) { p[0] = 0;   p[1] = 0;   p[2] = 255; p[3] = 255; }  // 红
            else           { p[0] = 255; p[1] = 0;   p[2] = 0;   p[3] = 255; }  // 蓝
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

// 直接从 BGRA 输出缓冲里采样某点（fx/fy 为 0..1 的相对位置，原点左上）。
static BOOL SamplePixelBuffer(CVPixelBufferRef pb, double fx, double fy, uint8_t out[4]) {
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    if (w == 0 || h == 0) return NO;
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return NO;
    }
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t stride = CVPixelBufferGetBytesPerRow(pb);
    size_t x = (size_t)(fx * (double)(w - 1));
    size_t y = (size_t)(fy * (double)(h - 1));
    memcpy(out, base + y * stride + x * 4, 4);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return YES;
}

// 跑主线程 run loop 直到条件成立或超时。
static BOOL WaitUntil(BOOL (^cond)(void), double timeoutSec) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSec];
    while (!cond() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    return cond();
}

// 把一个 8 位通道判成「亮」或「暗」，容忍色彩管理带来的偏差。
static BOOL IsBright(uint8_t v) { return v > 160; }
static BOOL IsDark(uint8_t v)   { return v < 95; }

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];   // 不上屏，但 AppKit 需要初始化

        const size_t W = 640, H = 360;
        M1FrameView *view = [[M1FrameView alloc] initWithFrame:NSMakeRect(0, 0, 900, 506)];
        view.displayID = 1000;

        printf("=== M1FrameView 离屏自检（%zux%zu → 900x506 视图）===\n", W, H);
        // 构造时已排队预热，等它把 CIContext 冷启动吃掉
        WaitUntil(^BOOL { return view.warmUpMs > 0; }, 10.0);
        printf("  CIContext 预热 %.1f ms\n", view.warmUpMs);

        CVPixelBufferRef pb = MakeTwoToneBuffer(W, H);
        Check(pb != NULL, "pixel-buffer-created");
        if (!pb) return 1;

        [view presentPixelBuffer:pb];
        BOOL ok = WaitUntil(^BOOL { return view.framesRendered >= 1; }, 5.0);
        Check(ok, "frame-rendered");
        Check(view.framesDropped == 0, "no-drop");

        // layer.contents 现在是 IOSurface（零拷贝上屏），不再是 CGImage。
        Check(view.layer.contents != NULL, "layer-contents-set");
        CVPixelBufferRef outBuf = [view lastRenderedBuffer];
        Check(outBuf != NULL, "output-buffer-exists");
        if (outBuf) {
            Check(CVPixelBufferGetWidth(outBuf) == W && CVPixelBufferGetHeight(outBuf) == H,
                  "output-size-matches-source");
            Check(CVPixelBufferGetIOSurface(outBuf) != NULL, "output-is-iosurface-backed");

            uint8_t left[4] = {0}, right[4] = {0};
            BOOL a = SamplePixelBuffer(outBuf, 0.25, 0.5, left);
            BOOL b = SamplePixelBuffer(outBuf, 0.75, 0.5, right);
            Check(a && b, "sample-both-ok");
            printf("  左半像素 BGRA = %u,%u,%u,%u\n", left[0], left[1], left[2], left[3]);
            printf("  右半像素 BGRA = %u,%u,%u,%u\n", right[0], right[1], right[2], right[3]);
            // BGRA 布局：红=(0,0,255)，蓝=(255,0,0)。R/B 互换会在这里暴露。
            Check(IsDark(left[0]) && IsDark(left[1]) && IsBright(left[2]), "left-is-red");
            Check(IsBright(right[0]) && IsDark(right[1]) && IsDark(right[2]), "right-is-blue");
        }

        // letterbox 几何：640x360（16:9）放进 900x506（≈16:9.01）的视图，
        // 高度先顶满，宽度差一点点（左右各 0.2px），不是精确整数倍，正好能检验换算。
        CGSize vs = view.videoSize;
        Check(vs.width == W && vs.height == H, "video-size-tracked");
        CGRect vr = view.videoRect;
        printf("  videoRect = (%.2f, %.2f, %.2f, %.2f) in view (900x506)\n",
               vr.origin.x, vr.origin.y, vr.size.width, vr.size.height);
        double scale = 506.0 / 360.0;
        Check(fabs(vr.size.height - 506.0) < 1.5, "letterbox-height-full");
        Check(fabs(vr.size.width - 640.0 * scale) < 1.5, "letterbox-width-scaled");
        Check(fabs(vr.origin.y) < 1.5, "letterbox-vertically-flush");
        Check(fabs(vr.origin.x - (900.0 - 640.0 * scale) / 2.0) < 1.5, "letterbox-centered");

        // 第二帧必须覆盖第一帧（验证更新而不是只贴一次）
        CVPixelBufferRelease(pb);
        CVPixelBufferRef pb2 = MakeTwoToneBuffer(320, 180);
        [view presentPixelBuffer:pb2];
        WaitUntil(^BOOL { return view.framesRendered >= 2; }, 5.0);
        Check(view.framesRendered >= 2, "second-frame-rendered");
        CVPixelBufferRef out2 = [view lastRenderedBuffer];
        Check(out2 != NULL && CVPixelBufferGetWidth(out2) == 320, "second-frame-applied");
        CVPixelBufferRelease(pb2);

        // ---- 全分辨率：3440x1440（这台机器的原生尺寸）----
        // 窗口不可见时 CA 提交会被阻塞，量出来的耗时会虚高到 2.8 s；
        // 离屏量的是纯转换成本，才是渲染路径本身的值。
        {
            CVPixelBufferRef big = MakeTwoToneBuffer(3440, 1440);
            Check(big != NULL, "full-res-buffer-created");
            if (big) {
                double t0 = [[NSDate date] timeIntervalSince1970] * 1000.0;
                [view presentPixelBuffer:big];
                WaitUntil(^BOOL { return view.framesRendered >= 3; }, 10.0);
                double cost = view.lastRenderMs;
                printf("  3440x1440 单帧渲染 %.1f ms（累计上屏 %lu 帧）\n",
                       cost, (unsigned long)view.framesRendered);
                Check(cost < 100.0, "full-res-render-under-100ms");
                CVPixelBufferRelease(big);
            }
        }

        // 输出侧统计必须可读（verify_m1b.sh 依赖它判断是否上屏）
        printf("  framesRendered=%lu framesDropped=%lu lastRenderMs=%.1f maxRenderMs=%.1f\n",
               (unsigned long)view.framesRendered, (unsigned long)view.framesDropped,
               view.lastRenderMs, view.maxRenderMs);
        Check(view.maxRenderMs > 0, "render-cost-measured");
        // 预热生效的判据：真实帧不再承担冷启动成本（预热前首帧 623ms）
        Check(view.maxRenderMs < 100.0, "warmup-keeps-first-frame-cheap");

        printf("\n=== %s ===\n", gFail == 0 ? "ALL PASS" : "FAILURES");
        return gFail == 0 ? 0 : 1;
    }
}
