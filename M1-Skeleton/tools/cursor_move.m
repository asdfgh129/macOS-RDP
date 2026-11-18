//
//  cursor_move.m
//  M1-Skeleton/tools
//
//  M1-B 端到端验证用的光标工具：只移动光标、不发点击。
//
//  之所以不用真点击：单机环回时 Host 和 Client 是同一个桌面，
//  点下去会点到窗口背后的东西，验证反而有副作用。
//
//  用法：
//    ./cursor_move info            打印主屏尺寸与当前光标位置
//    ./cursor_move move X Y        把光标移到全局坐标 (X, Y) 并发一个 mouseMoved
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        // 锁屏时 SCK 拿不到 display、窗口收不到输入，验证前必须先排除。
        if (argc >= 2 && !strcmp(argv[1], "locked")) {
            // 拿不到会话字典时按「锁定」处理（fail-safe）：
            // CGSessionCopyCurrentDictionary 在会话切换瞬间会返回 NULL，
            // 之前把这种情况当成「已解锁」，导致脚本误判后立刻又失败。
            BOOL locked = YES;
            CFDictionaryRef d = CGSessionCopyCurrentDictionary();
            if (d) {
                NSDictionary *dict = (__bridge NSDictionary *)d;
                locked = [dict[@"CGSSessionScreenIsLocked"] boolValue];
                CFRelease(d);
            }
            printf("%s\n", locked ? "locked" : "unlocked");
            return locked ? 1 : 0;
        }
        if (argc >= 2 && !strcmp(argv[1], "info")) {
            CGRect b = CGDisplayBounds(CGMainDisplayID());
            printf("%.0f %.0f\n", b.size.width, b.size.height);
            CGEventRef ev = CGEventCreate(NULL);
            if (ev) {
                CGPoint p = CGEventGetLocation(ev);
                CFRelease(ev);
                printf("%.0f %.0f\n", p.x, p.y);
            }
            return 0;
        }
        if (argc >= 4 && !strcmp(argv[1], "move")) {
            double x = atof(argv[2]), y = atof(argv[3]);
            // 先 warp（改光标硬件位置），再补一个 moved 事件：
            // 只 warp 不保证 AppKit 收到 mouseMoved，只发事件又不移动可见光标。
            CGWarpMouseCursorPosition(CGPointMake(x, y));
            CGAssociateMouseAndMouseCursorPosition(true);
            CGEventRef ev = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
                                                    CGPointMake(x, y),
                                                    kCGMouseButtonLeft);
            if (ev) {
                CGEventPost(kCGHIDEventTap, ev);
                CFRelease(ev);
            }
            printf("moved %.0f,%.0f\n", x, y);
            return 0;
        }
        fprintf(stderr, "用法: %s locked | info | move X Y\n", argv[0]);
        return 1;
    }
}
