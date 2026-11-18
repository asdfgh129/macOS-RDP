//
//  recover_v2.m — 诊断 + 定向恢复
//
//  1) 打印每块 display 的 vendor/model/是否虚拟/几何，先确认「黑屏的是谁」；
//  2) 若发现「尺寸与已知虚拟屏一致且位置孤立」的残留槽位，定向禁用它；
//  3) 对剩余屏重设 mode 触发重配置；
//  4) 逐屏 luma 复核。
//
//  只做最小必要动作，不启用 stale 槽位（那会触发 illegal argument）。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "P0VDisplayControl.h"

static double DisplayLuma(CGDirectDisplayID did) {
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

int main(int argc, char **argv) {
    @autoreleasepool {
        // --disable-victim：定向禁用「疑似虚拟残留」
        BOOL disableVictim = NO;
        CGDirectDisplayID victimArg = 0;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--disable") == 0 && i + 1 < argc) {
                disableVictim = YES;
                victimArg = (CGDirectDisplayID)strtoul(argv[++i], NULL, 10);
            }
        }

        NSArray<NSNumber *> *active = P0VActiveDisplayIDs();
        NSArray<NSDictionary *> *dicts = P0VDisplayDictionaries(active);

        printf("=== 当前 active display ===\n");
        for (NSDictionary *d in dicts) {
            CGDirectDisplayID did = (CGDirectDisplayID)[d[@"displayID"] unsignedIntValue];
            printf("  id=%u vendor=%s model=%s virtual=%s bounds=%s luma=%.1f\n",
                   did,
                   [d[@"vendorID"] description].UTF8String ?: "-",
                   [d[@"modelID"] description].UTF8String ?: "-",
                   [d[@"isP0Virtual"] description].UTF8String ?: "-",
                   [d[@"bounds"] description].UTF8String ?: "-",
                   DisplayLuma(did));
        }

        if (victimArg != 0) {
            printf("\n=== 定向禁用 %u ===\n", victimArg);
            NSDictionary *detail = nil;
            NSError *err = nil;
            BOOL ok = P0VApplyDisplayEnabledChanges(@[ @(victimArg) ], @[],
                                                    P0VCommitScopeSession,
                                                    20, &detail, &err);
            printf("  disable: %s\n", ok ? "OK" : "FAILED");
            if (err) printf("  error: %s\n", err.localizedDescription.UTF8String);
            usleep(600000);
        }

        // 对剩余 active 屏重设 mode，强制重配置。
        NSArray<NSNumber *> *now = P0VActiveDisplayIDs();
        printf("\n=== 重设 mode（%lu 块）===\n", (unsigned long)now.count);
        for (NSNumber *n in now) {
            CGDirectDisplayID did = (CGDirectDisplayID)n.unsignedIntValue;
            CGDisplayModeRef m = CGDisplayCopyDisplayMode(did);
            if (!m) continue;
            CGError e = CGDisplaySetDisplayMode(did, m, NULL);
            printf("  %u %zux%zu -> %s\n", did,
                   CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m),
                   e == kCGErrorSuccess ? "OK" : "FAILED");
            CGDisplayModeRelease(m);
        }
        usleep(800000);

        printf("\n=== 复核 ===\n");
        NSArray<NSNumber *> *fin = P0VActiveDisplayIDs();
        int black = 0;
        for (NSNumber *n in fin) {
            CGDirectDisplayID did = (CGDirectDisplayID)n.unsignedIntValue;
            double luma = DisplayLuma(did);
            BOOL isBlack = (luma >= 0 && luma < 8.0);
            if (isBlack) black++;
            printf("  %u luma=%.1f %s\n", did, luma, isBlack ? "ALL_BLACK" : "OK");
        }
        printf("  active=%lu black=%d\n", (unsigned long)fin.count, black);
        return black > 0 ? 3 : 0;
    }
}
