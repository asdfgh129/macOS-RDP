//
//  render_selftest.m
//  M1-Skeleton
//
//  M1FrameView 的离屏自检：不需要可见窗口，也不需要解锁屏幕。
//
//  做法：造一张「左红右蓝」的 CVPixelBuffer 喂给 view，等渲染队列把 IOSurface 贴上，
//  再从输出缓冲读回像素采样。每档分辨率都钉住四件容易出错的事：
//    · CIContext 是否能转换该像素格式（转不出来 → 输出缓冲拿不到）；
//    · 尺寸是否与源一致（错位/裁切会立刻看出）；
//    · 通道顺序与色彩空间是否对（R/B 互换是最常见的坑）；
//    · letterbox 几何是否等于独立算出的 aspect-fit + 居中矩形。
//
//  另附单帧渲染耗时作为**回归基线**（离屏量的是纯转换成本，不含窗口合成），
//  不是上屏性能结论——真实帧率要看跨机联调的 client lastRenderMs。
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

// 用档位名拼出唯一的检查名，便于在多档位输出里定位失败。
static void CheckCase(BOOL cond, const char *label, const char *suffix) {
    char nm[128];
    snprintf(nm, sizeof(nm), "%s-%s", label, suffix);
    Check(cond, nm);
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

// 单档位用例：送一帧 → 等上屏 → 校验尺寸/通道/letterbox → 记耗时。
// budgetMs 是宽松的回归护栏（离屏纯转换），不是性能门禁。
static void RunCase(M1FrameView *view, size_t W, size_t H,
                    const char *label, double budgetMs) {
    printf("\n--- %s (%zux%zu) ---\n", label, W, H);
    unsigned long before = view.framesRendered;

    CVPixelBufferRef pb = MakeTwoToneBuffer(W, H);
    CheckCase(pb != NULL, label, "buffer-created");
    if (!pb) return;

    [view presentPixelBuffer:pb];
    BOOL ok = WaitUntil(^BOOL { return view.framesRendered > before; }, 10.0);
    CheckCase(ok, label, "frame-rendered");

    CheckCase(view.layer.contents != NULL, label, "layer-contents-set");
    CVPixelBufferRef outBuf = [view lastRenderedBuffer];
    CheckCase(outBuf != NULL, label, "output-buffer-exists");
    if (outBuf) {
        CheckCase(CVPixelBufferGetWidth(outBuf) == W && CVPixelBufferGetHeight(outBuf) == H,
                  label, "output-size-matches-source");
        CheckCase(CVPixelBufferGetIOSurface(outBuf) != NULL, label, "output-is-iosurface-backed");

        uint8_t left[4] = {0}, right[4] = {0};
        BOOL a = SamplePixelBuffer(outBuf, 0.25, 0.5, left);
        BOOL b = SamplePixelBuffer(outBuf, 0.75, 0.5, right);
        CheckCase(a && b, label, "sample-both-ok");
        printf("  左半像素 BGRA = %u,%u,%u,%u\n", left[0], left[1], left[2], left[3]);
        printf("  右半像素 BGRA = %u,%u,%u,%u\n", right[0], right[1], right[2], right[3]);
        // BGRA 布局：红=(0,0,255)，蓝=(255,0,0)。R/B 互换会在这里暴露。
        CheckCase(IsDark(left[0]) && IsDark(left[1]) && IsBright(left[2]),
                  label, "left-is-red");
        CheckCase(IsBright(right[0]) && IsDark(right[1]) && IsDark(right[2]),
                  label, "right-is-blue");
    }

    // letterbox 几何：独立按 aspect-fit 算期望矩形，不去调 M1AspectFitRect
    // （否则变成拿被测函数验证自己）。宽/高受限两种情况都要覆盖：
    // 16:9 档在 900x506 视图里高度顶满；3440x1440（≈2.39:1）宽度顶满。
    CGSize vs = view.videoSize;
    CheckCase(vs.width == (CGFloat)W && vs.height == (CGFloat)H, label, "video-size-tracked");
    CGRect vr = view.videoRect;
    CGRect vb = view.bounds;
    double scale = MIN(vb.size.width / (double)W, vb.size.height / (double)H);
    double ew = (double)W * scale, eh = (double)H * scale;
    double ex = (vb.size.width - ew) / 2.0, ey = (vb.size.height - eh) / 2.0;
    printf("  videoRect = (%.2f, %.2f, %.2f, %.2f)  期望 = (%.2f, %.2f, %.2f, %.2f)\n",
           vr.origin.x, vr.origin.y, vr.size.width, vr.size.height, ex, ey, ew, eh);
    CheckCase(fabs(vr.size.width - ew) < 1.5 && fabs(vr.size.height - eh) < 1.5,
              label, "letterbox-size");
    CheckCase(fabs(vr.origin.x - ex) < 1.5 && fabs(vr.origin.y - ey) < 1.5,
              label, "letterbox-centered");

    printf("  %s 单帧渲染 %.1f ms（回归护栏 < %.0f ms）\n", label, view.lastRenderMs, budgetMs);
    CheckCase(view.lastRenderMs > 0 && view.lastRenderMs < budgetMs, label, "render-budget");
    CVPixelBufferRelease(pb);
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];   // 不上屏，但 AppKit 需要初始化

        const NSRect viewFrame = NSMakeRect(0, 0, 900, 506);
        M1FrameView *view = [[M1FrameView alloc] initWithFrame:viewFrame];
        view.displayID = 1000;

        printf("=== M1FrameView 离屏自检（视图 900x506，多档位）===\n");
        // 构造时已排队预热，等它把 CIContext 冷启动吃掉
        WaitUntil(^BOOL { return view.warmUpMs > 0; }, 10.0);
        printf("  CIContext 预热 %.1f ms\n", view.warmUpMs);
        Check(view.warmUpMs > 0, "warmup-ran");

        // 640x360（16:9）与 900x506（≈16:9.01）：高度顶满、宽度差 0.4px，
        // 非整数倍正好检验换算精度。
        RunCase(view, 640, 360, "vga", 25.0);
        // 720p / 1080p：P2.3 要求补的档位基线。
        RunCase(view, 1280, 720, "720p", 45.0);
        RunCase(view, 1920, 1080, "1080p", 60.0);
        // 3440x1440（≈2.39:1）：宽度顶满，覆盖另一种 letterbox 受限方向。
        // 窗口不可见时 CA 提交会阻塞，离屏量的才是纯转换成本。
        RunCase(view, 3440, 1440, "ultrawide", 100.0);

        // 覆盖验证：第二帧必须替换第一帧（不能只贴一次），且尺寸跟随变化。
        {
            unsigned long before = view.framesRendered;
            CVPixelBufferRef pb = MakeTwoToneBuffer(320, 180);
            Check(pb != NULL, "cover-buffer-created");
            if (pb) {
                [view presentPixelBuffer:pb];
                BOOL ok = WaitUntil(^BOOL { return view.framesRendered > before; }, 5.0);
                Check(ok, "second-frame-rendered");
                CVPixelBufferRef out2 = [view lastRenderedBuffer];
                Check(out2 != NULL && CVPixelBufferGetWidth(out2) == 320,
                      "second-frame-applied");
                CVPixelBufferRelease(pb);
            }
        }

        // 输出侧统计必须可读（verify_m1b.sh 依赖它判断是否上屏）
        printf("\n  framesRendered=%lu framesDropped=%lu lastRenderMs=%.1f maxRenderMs=%.1f\n",
               (unsigned long)view.framesRendered, (unsigned long)view.framesDropped,
               view.lastRenderMs, view.maxRenderMs);
        Check(view.framesDropped == 0, "no-drop-across-cases");
        Check(view.maxRenderMs > 0, "render-cost-measured");
        // 预热生效的判据：真实帧不再承担冷启动成本（预热前首帧 623ms）
        Check(view.maxRenderMs < 100.0, "warmup-keeps-first-frame-cheap");

        printf("\n=== %s ===\n", gFail == 0 ? "ALL PASS" : "FAILURES");
        return gFail == 0 ? 0 : 1;
    }
}
