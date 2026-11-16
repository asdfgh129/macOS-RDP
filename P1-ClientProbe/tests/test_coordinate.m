// P1Coordinate 单元测试：合成矩形，不触碰真实显示器/WindowServer。
#import <Foundation/Foundation.h>
#import "P1Coordinate.h"

static int gFail = 0;

static void ExpectRect(CGRect got, CGRect want, const char *name) {
    BOOL ok = fabs(got.origin.x - want.origin.x) < 1e-9 &&
              fabs(got.origin.y - want.origin.y) < 1e-9 &&
              fabs(got.size.width - want.size.width) < 1e-9 &&
              fabs(got.size.height - want.size.height) < 1e-9;
    if (!ok) {
        gFail++;
        printf("[FAIL] %s got={%g,%g,%g,%g} want={%g,%g,%g,%g}\n", name,
               got.origin.x, got.origin.y, got.size.width, got.size.height,
               want.origin.x, want.origin.y, want.size.width, want.size.height);
    } else {
        printf("[PASS] %s\n", name);
    }
}

static void ExpectPoint(CGPoint got, CGPoint want, const char *name) {
    BOOL ok = fabs(got.x - want.x) < 1e-9 && fabs(got.y - want.y) < 1e-9;
    if (!ok) {
        gFail++;
        printf("[FAIL] %s got={%g,%g} want={%g,%g}\n", name, got.x, got.y, want.x, want.y);
    } else {
        printf("[PASS] %s\n", name);
    }
}

int main(void) {
    @autoreleasepool {
        const CGFloat H = 1080;  // 主屏高度

        // 1. 主屏原点重合：NS 主屏 (0,0,1920,1080) ↔ Quartz (0,0,1920,1080)
        ExpectRect(P1QuartzRectFromNSRect(CGRectMake(0, 0, 1920, 1080), H),
                   CGRectMake(0, 0, 1920, 1080), "main-screen-origin");
        // 2. 主屏上方副屏：NS y=1080 → Quartz y=-1080（负坐标）
        ExpectRect(P1QuartzRectFromNSRect(CGRectMake(0, 1080, 1920, 1080), H),
                   CGRectMake(0, -1080, 1920, 1080), "above-main-negative-y");
        // 3. 左侧副屏：NS x=-1920 保持，y 翻转
        ExpectRect(P1QuartzRectFromNSRect(CGRectMake(-1920, 200, 1920, 1080), H),
                   CGRectMake(-1920, -200, 1920, 1080), "left-screen-negative-x");
        // 4. 往返一致性（含负坐标）
        CGRect ns = CGRectMake(-2560, -300, 2560, 1440);
        ExpectRect(P1NSRectFromQuartzRect(P1QuartzRectFromNSRect(ns, H), H),
                   ns, "roundtrip-negative");
        // 5. 非主屏高度基准（主屏 1692 points 的混合排列）
        ExpectRect(P1QuartzRectFromNSRect(CGRectMake(1920, 0, 2560, 1440), 1692),
                   CGRectMake(1920, 252, 2560, 1440), "main-height-1692");

        // 6. 窗口中心 → 虚拟屏中心（混合缩放：1440x900 points 窗口 → 1920x1080 虚拟屏）
        ExpectPoint(P1MapPoint(CGPointMake(720, 450),
                               CGRectMake(0, 0, 1440, 900),
                               CGRectMake(1920, -385, 1920, 1080)),
                    CGPointMake(2880, 155), "map-center-mixed-scale");
        // 7. 负坐标 fromRect：窗口在左侧副屏
        ExpectPoint(P1MapPoint(CGPointMake(-1920, 0),
                               CGRectMake(-1920, 0, 1920, 1080),
                               CGRectMake(0, 0, 2560, 1440)),
                    CGPointMake(0, 0), "map-negative-origin");
        // 8. 角点：右下 → 右下
        ExpectPoint(P1MapPoint(CGPointMake(1440, 900),
                               CGRectMake(0, 0, 1440, 900),
                               CGRectMake(1920, -385, 1920, 1080)),
                    CGPointMake(3840, 695), "map-corner");
        // 9. 矩形映射：尺寸按比例
        ExpectRect(P1MapRect(CGRectMake(360, 225, 720, 450),
                             CGRectMake(0, 0, 1440, 900),
                             CGRectMake(1920, -385, 1920, 1080)),
                   CGRectMake(2400, -115, 960, 540), "map-rect-scale");
        // 10. 空 fromRect 防御
        ExpectPoint(P1MapPoint(CGPointMake(5, 5), CGRectZero, CGRectMake(7, 9, 100, 100)),
                    CGPointMake(7, 9), "map-empty-from-rect");

        printf(gFail ? "\n%d FAILED\n" : "\nALL PASS\n", gFail);
    }
    return gFail ? 1 : 0;
}