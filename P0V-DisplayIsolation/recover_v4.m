//
//  recover_v4.m — 强制重建显示输出链路
//
//  背景：禁屏事务 commit 失败后，display 处于「enabled 但输出链路断开」状态。
//  CGDisplaySetDisplayMode 只能让缓存帧短暂可见，无法真正重建链路。
//
//  策略（由弱到强，逐个尝试，任一奏效即停）：
//    1. origin 抖动：把屏移 1px 再移回，强制 WindowServer 重排布局；
//    2. mirror 往返：把副屏 mirror 到主屏再解除，强制重建输出链路。
//
//  只用公开 CG API，不做 enable/disable，不改 mode 尺寸。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "P0VDisplayControl.h"

static double Luma(CGDirectDisplayID did) {
    CGImageRef img = CGDisplayCreateImage(did);
    if (!img) return -1;
    size_t sw = 32, sh = 32;
    uint8_t *buf = calloc(sw * sh * 4, 1);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf, sw, sh, 8, sw * 4, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    double mean = -1;
    if (c) {
        CGContextDrawImage(c, CGRectMake(0, 0, sw, sh), img);
        CGContextRelease(c);
        double sum = 0;
        for (size_t i = 0; i < sw * sh; i++) {
            uint8_t *p = buf + i * 4;
            sum += 0.114 * p[0] + 0.587 * p[1] + 0.299 * p[2];
        }
        mean = sum / (sw * sh);
    }
    free(buf);
    CGImageRelease(img);
    return mean;
}

static void Report(NSString *tag) {
    NSArray<NSNumber *> *ids = P0VActiveDisplayIDs();
    printf("  [%s] active=%lu:", tag.UTF8String, (unsigned long)ids.count);
    for (NSNumber *n in ids) {
        CGDirectDisplayID did = (CGDirectDisplayID)n.unsignedIntValue;
        printf(" %u=%.0f", did, Luma(did));
    }
    printf("\n");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        Report(@"初始");

        NSArray<NSNumber *> *ids = P0VActiveDisplayIDs();
        if (ids.count < 2) {
            printf("  只有 %lu 块屏，无法做布局操作\n", (unsigned long)ids.count);
            return 2;
        }
        CGDirectDisplayID a = (CGDirectDisplayID)ids[0].unsignedIntValue;
        CGDirectDisplayID b = (CGDirectDisplayID)ids[1].unsignedIntValue;
        CGRect ra = CGDisplayBounds(a);
        CGRect rb = CGDisplayBounds(b);

        // 策略 1：origin 抖动（先移开再移回）
        printf("\n=== 策略 1：origin 抖动 ===\n");
        for (int pass = 0; pass < 2; pass++) {
            CGDisplayConfigRef cfg = NULL;
            if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess || !cfg) {
                printf("  CGBeginDisplayConfiguration 失败\n");
                break;
            }
            CGError e1 = kCGErrorSuccess;
            if (pass == 0) {
                e1 = CGConfigureDisplayOrigin(cfg, b, (int32_t)(rb.origin.x + 1), 0);
            } else {
                e1 = CGConfigureDisplayOrigin(cfg, b, (int32_t)rb.origin.x, 0);
            }
            CGError e2 = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
            printf("  pass%d configure=%d commit=%d\n", pass, (int)e1, (int)e2);
        }
        usleep(800000);
        Report(@"origin 抖动后");

        BOOL stillBlack = NO;
        for (NSNumber *n in P0VActiveDisplayIDs()) {
            if (Luma((CGDirectDisplayID)n.unsignedIntValue) < 8.0) stillBlack = YES;
        }
        if (!stillBlack) { printf("\n  已恢复。\n"); return 0; }

        // 策略 2：mirror 往返——把 b 镜像到 a，再解除
        printf("\n=== 策略 2：mirror 往返 ===\n");
        {
            CGDisplayConfigRef cfg = NULL;
            if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess && cfg) {
                CGError e1 = CGConfigureDisplayMirrorOfDisplay(cfg, b, a);
                CGError e2 = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
                printf("  mirror b->a configure=%d commit=%d\n", (int)e1, (int)e2);
            }
        }
        usleep(1000000);
        Report(@"mirror 设置后");

        {
            CGDisplayConfigRef cfg = NULL;
            if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess && cfg) {
                CGError e1 = CGConfigureDisplayMirrorOfDisplay(cfg, b, kCGNullDirectDisplay);
                CGError e2 = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
                printf("  解除 mirror configure=%d commit=%d\n", (int)e1, (int)e2);
            }
        }
        usleep(1000000);
        Report(@"解除 mirror 后");

        stillBlack = NO;
        for (NSNumber *n in P0VActiveDisplayIDs()) {
            if (Luma((CGDirectDisplayID)n.unsignedIntValue) < 8.0) stillBlack = YES;
        }
        if (!stillBlack) { printf("\n  已恢复。\n"); return 0; }

        printf("\n  ⚠ 公开 CG API 无法恢复输出链路。\n");
        printf("     需要重启 WindowServer（sudo killall -HUP WindowServer）或整机重启。\n");
        return 3;
    }
}
