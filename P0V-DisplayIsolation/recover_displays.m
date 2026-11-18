//
//  recover_displays.m — 紧急恢复：把所有显示重新启用
//
//  用途：禁屏流程异常中断（守护未兜底 / 事务提交失败）后，物理屏停留在
//  「active 但全黑」状态时，强制对所有 SkyLight 注册的 display 重新 enable。
//
//  只做启用，不禁用、不建屏、不改 mode/origin，风险最低。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "P0VDisplayControl.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        printf("=== 显示恢复 ===\n");

        // 之前的事务失败可能置了 hung 标记，先清掉，否则后续配置请求会被拒。
        P0VResetWindowServerHung();

        NSArray<NSNumber *> *all = P0VAllDisplayIDsFromSkyLight();
        NSArray<NSNumber *> *active = P0VActiveDisplayIDs();
        printf("  SkyLight 注册: %lu 块\n", (unsigned long)all.count);
        printf("  当前 active  : %lu 块 %s\n", (unsigned long)active.count,
               [active.description UTF8String] ?: "");

        if (all.count == 0) {
            printf("  SkyLight 未返回任何 display，放弃（避免误操作）\n");
            return 2;
        }

        NSDictionary *detail = nil;
        NSError *err = nil;
        BOOL ok = P0VApplyDisplayEnabledChanges(@[], all, P0VCommitScopeSession,
                                                20, &detail, &err);
        printf("  enable all: %s\n", ok ? "OK" : "FAILED");
        if (detail) printf("  detail: %s\n", detail.description.UTF8String);
        if (err) printf("  error : %s\n", err.localizedDescription.UTF8String);

        NSArray<NSNumber *> *after = P0VActiveDisplayIDs();
        printf("  恢复后 active: %lu 块\n", (unsigned long)after.count);

        // enable 只改了「启用位」，事务提交失败时 WindowServer 不会真正点亮。
        // 对每块屏重设当前 mode，强制走一次完整的显示重配置（相当于拔插的效果）。
        printf("  --- 重设各屏 mode 以触发重配置 ---\n");
        for (NSNumber *n in after) {
            CGDirectDisplayID did = (CGDirectDisplayID)n.unsignedIntValue;
            CGDisplayModeRef mode = CGDisplayCopyDisplayMode(did);
            if (!mode) {
                printf("    display %-12u 无可用 mode\n", did);
                continue;
            }
            CGError e = CGDisplaySetDisplayMode(did, mode, NULL);
            printf("    display %-12u set mode %zux%zu -> %s\n", did,
                   CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode),
                   e == kCGErrorSuccess ? "OK" : "FAILED");
            CGDisplayModeRelease(mode);
        }
        usleep(400000);   // 给 WindowServer 一点时间完成重配置

        after = P0VActiveDisplayIDs();
        printf("  重配置后 active: %lu 块\n", (unsigned long)after.count);

        // 逐屏 luma 检查：全黑说明还没真正恢复。
        int black = 0;
        for (NSNumber *n in after) {
            CGDirectDisplayID did = (CGDirectDisplayID)n.unsignedIntValue;
            CGImageRef img = CGDisplayCreateImage(did);
            double mean = -1;
            if (img) {
                size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
                if (w && h) {
                    size_t sw = 32, sh = 32;
                    uint8_t *buf = calloc(sw * sh * 4, 1);
                    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                    CGContextRef c = CGBitmapContextCreate(buf, sw, sh, 8, sw * 4, cs,
                        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
                    CGColorSpaceRelease(cs);
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
                }
                CGImageRelease(img);
            }
            BOOL isBlack = (mean >= 0 && mean < 8.0);
            if (isBlack) black++;
            printf("    display %-12u luma=%.1f %s\n", did, mean,
                   isBlack ? "ALL_BLACK" : "OK");
        }

        if (black > 0) {
            printf("\n  仍有 %d 块屏全黑。若背光/信号未恢复，可能需要拔插显示器或重启。\n", black);
            return 3;
        }
        printf("\n  全部显示已恢复。\n");
        return 0;
    }
}
