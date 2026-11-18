//
//  recover_v5.m — 消除显示布局空洞
//
//  背景：虚拟屏被禁用后，显示布局里留下 1920px 的空洞
//  （主屏 0..3440，竖屏在 5360，中间 3440..5360 无屏）。
//  WindowServer 在这种带空洞的布局下可能出现合成异常，表现为「屏 enabled 但全黑」。
//
//  做法：按 x 升序把所有屏紧排，消除空洞，然后强制重配置。
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

static void Dump(NSString *tag) {
    printf("[%s]\n", tag.UTF8String);
    for (NSNumber *n in P0VActiveDisplayIDs()) {
        CGDirectDisplayID did = (CGDirectDisplayID)n.unsignedIntValue;
        CGRect r = CGDisplayBounds(did);
        printf("  %u  x=%d y=%d %dx%d  luma=%.0f\n", did,
               (int)r.origin.x, (int)r.origin.y,
               (int)r.size.width, (int)r.size.height, Luma(did));
    }
}

int main(void) {
    @autoreleasepool {
        Dump(@"当前布局");

        NSArray<NSNumber *> *ids = P0VActiveDisplayIDs();
        if (ids.count == 0) return 2;

        // 按当前 x 排序，保持用户原本的左右顺序。
        NSArray<NSNumber *> *sorted = [ids sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            CGRect ra = CGDisplayBounds((CGDirectDisplayID)a.unsignedIntValue);
            CGRect rb = CGDisplayBounds((CGDirectDisplayID)b.unsignedIntValue);
            if (ra.origin.x < rb.origin.x) return NSOrderedAscending;
            if (ra.origin.x > rb.origin.x) return NSOrderedDescending;
            return NSOrderedSame;
        }];

        CGDisplayConfigRef cfg = NULL;
        if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess || !cfg) {
            printf("CGBeginDisplayConfiguration 失败\n");
            return 2;
        }

        double cursorX = 0;
        BOOL anyMove = NO;
        for (NSNumber *n in sorted) {
            CGDirectDisplayID did = (CGDirectDisplayID)n.unsignedIntValue;
            CGRect r = CGDisplayBounds(did);
            if ((double)r.origin.x != cursorX) {
                CGError e = CGConfigureDisplayOrigin(cfg, did, (int32_t)cursorX, 0);
                printf("  移动 %u 到 x=%d -> %d\n", did, (int)cursorX, (int)e);
                anyMove = YES;
            }
            cursorX += r.size.width;
        }

        if (!anyMove) {
            printf("  布局已是紧凑排列，无需移动\n");
            CGCancelDisplayConfiguration(cfg);
        } else {
            CGError e = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
            printf("  commit -> %d\n", (int)e);
        }

        usleep(1200000);
        Dump(@"收紧后");

        int black = 0;
        for (NSNumber *n in P0VActiveDisplayIDs()) {
            if (Luma((CGDirectDisplayID)n.unsignedIntValue) < 8.0) black++;
        }
        printf("\nblack=%d\n", black);
        return black > 0 ? 3 : 0;
    }
}
