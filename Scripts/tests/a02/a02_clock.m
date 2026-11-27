//
//  a02_clock.m
//  A-02 玻璃到玻璃（无相机替代法）：主机侧「毫秒时钟 + 机器可读条码」内容源
//
//  目的：在没有高速相机的情况下，给 A-02 提供可判读的“屏幕上的时间”。
//
//  设计要点：
//   · 画面 = 大号毫秒时钟（给人看 / 截图存档）+ 一条 56 位的机器可读条码
//     （48 位 epoch 毫秒 + 8 位校验）。条码带洋红外框，客户端侧用「洋红包围盒」
//     反推格子尺寸，因此**缩放无关**：主机 3440×1440 采成 720p、客户端再放大到
//     1920×1080，条码仍能按比例解出来。
//   · 每 8ms 重绘一次（实际按显示器刷新合并成 60Hz），保证相邻采集帧的时间不同。
//   · 窗口是无边框、忽略鼠标、置顶、覆盖整块指定显示器，供 host 采集。
//
//  用法：
//    ./a02_clock --display <CGDisplayID> [--hold 30] [--no-text] [--no-barcode]
//    ./a02_clock --list          # 列出可用的显示器与 id
//
//  条码布局（格子边长 C）：
//    行 0：全白（同步行）   行 1：数据位 1=白 0=黑   行 2：全黑
//    洋红外框厚 C/2 ⇒ 包围盒 = 57C × 4C，用于反推 C。
//
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <time.h>

static uint64_t A02NowMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)(ts.tv_nsec / 1000000);
}

static void A02Fill(CGContextRef ctx, CGRect r, CGFloat cr, CGFloat cg, CGFloat cb) {
    CGContextSetRGBFillColor(ctx, cr, cg, cb, 1.0);
    CGContextFillRect(ctx, r);
}

@interface A02ClockView : NSView
@property (nonatomic, assign) BOOL drawText;
@property (nonatomic, assign) BOOL drawBarcode;
@property (nonatomic, assign) BOOL cyanFrame;   // 参考时钟用青色框，与主时钟的洋红框区分
@property (nonatomic, assign) double barcodeFraction;
@property (nonatomic, assign) long long skewMs;   // 自检用：给编码时间加一个已知偏差
@property (nonatomic, assign) uint64_t lastMs;
@property (nonatomic, assign) uint8_t lastChecksum;
@end

@implementation A02ClockView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    CGRect b = self.bounds;
    A02Fill(ctx, b, 0, 0, 0);

    uint64_t ms = (uint64_t)((long long)A02NowMs() + self.skewMs);
    self.lastMs = ms;

    uint8_t bytes[7];
    for (int i = 0; i < 6; i++) bytes[i] = (uint8_t)((ms >> (8 * (5 - i))) & 0xFF);
    uint8_t x = 0;
    for (int i = 0; i < 6; i++) x ^= bytes[i];
    bytes[6] = (uint8_t)((x ^ 0xA5) & 0xFF);
    self.lastChecksum = bytes[6];

    CGFloat W = b.size.width, H = b.size.height;

    if (self.drawBarcode) {
        CGFloat stripW = W * self.barcodeFraction;
        CGFloat C = stripW / 56.0;
        CGFloat x0 = (W - stripW) / 2.0;
        CGFloat y0 = self.drawText ? H * 0.05 : (H - 3.0 * C - C) / 2.0;
        // 外框：主时钟洋红、参考时钟青色。它不仅是视觉框，也是解码端唯一的定位依据。
        if (self.cyanFrame) A02Fill(ctx, CGRectMake(x0 - C / 2.0, y0 - C / 2.0,
                                                    stripW + C, 3.0 * C + C), 0, 1, 1);
        else               A02Fill(ctx, CGRectMake(x0 - C / 2.0, y0 - C / 2.0,
                                                   stripW + C, 3.0 * C + C), 1, 0, 1);
        // 行 0 全白、行 2 全黑，行 1 先铺白再按位盖黑块（0 位）。
        A02Fill(ctx, CGRectMake(x0, y0, stripW, C), 1, 1, 1);
        A02Fill(ctx, CGRectMake(x0, y0 + C, stripW, C), 1, 1, 1);
        A02Fill(ctx, CGRectMake(x0, y0 + 2.0 * C, stripW, C), 0, 0, 0);
        for (int i = 0; i < 56; i++) {
            BOOL bit = ((bytes[i / 8] >> (7 - (i % 8))) & 1) != 0;
            if (bit) continue;
            // 留 12% 白边，避免 0 位与行 2 的黑区在视频编码后连成一片。
            CGFloat inset = C * 0.12;
            A02Fill(ctx, CGRectMake(x0 + i * C + inset, y0 + C + inset,
                                    C - 2 * inset, C - 2 * inset), 0, 0, 0);
        }
    }

    if (self.drawText) {
        time_t secs = (time_t)(ms / 1000ull);
        struct tm tmv;
        localtime_r(&secs, &tmv);
        NSString *s = [NSString stringWithFormat:@"%02d:%02d:%02d.%03d",
                       tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(ms % 1000ull)];
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.alignment = NSTextAlignmentCenter;
        NSFont *f = [NSFont monospacedDigitSystemFontOfSize:H * 0.30 weight:NSFontWeightBold];
        NSDictionary *attrs = @{ NSFontAttributeName: f,
                                 NSForegroundColorAttributeName: [NSColor whiteColor],
                                 NSParagraphStyleAttributeName: ps };
        [s drawInRect:NSMakeRect(0, H * 0.32, W, H * 0.36) withAttributes:attrs];

        NSString *sub = [NSString stringWithFormat:@"A-02 CLOCK   epoch_ms=%llu   chk=%02x   %@",
                         ms, (unsigned)self.lastChecksum, @"VeilRD"];
        NSDictionary *subAttrs = @{ NSFontAttributeName:
                                        [NSFont monospacedDigitSystemFontOfSize:H * 0.045
                                                                        weight:NSFontWeightRegular],
                                    NSForegroundColorAttributeName:
                                        [NSColor colorWithCalibratedWhite:0.75 alpha:1.0],
                                    NSParagraphStyleAttributeName: ps };
        [sub drawInRect:NSMakeRect(0, H * 0.72, W, H * 0.08) withAttributes:subAttrs];
    }
}

@end

static NSScreen *A02ScreenWithID(uint32_t displayID) {
    for (NSScreen *s in [NSScreen screens]) {
        NSNumber *n = s.deviceDescription[@"NSScreenNumber"];
        if (n && n.unsignedIntValue == displayID) return s;
    }
    return nil;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        uint32_t displayID = CGMainDisplayID();
        double holdSec = 0;
        BOOL drawText = YES, drawBarcode = YES, cyan = NO;
        NSString *sizeArg = nil, *anchor = @"tl";
        double barcodeFraction = 0.92;
        long long skewMs = 0;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--display") && i + 1 < argc) {
                displayID = (uint32_t)strtoul(argv[++i], NULL, 10);
            } else if (!strcmp(argv[i], "--hold") && i + 1 < argc) {
                holdSec = atof(argv[++i]);
            } else if (!strcmp(argv[i], "--size") && i + 1 < argc) {
                sizeArg = [NSString stringWithUTF8String:argv[++i]];
            } else if (!strcmp(argv[i], "--anchor") && i + 1 < argc) {
                anchor = [NSString stringWithUTF8String:argv[++i]];
            } else if (!strcmp(argv[i], "--barcode-fraction") && i + 1 < argc) {
                barcodeFraction = atof(argv[++i]);
            } else if (!strcmp(argv[i], "--skew-ms") && i + 1 < argc) {
                skewMs = atoll(argv[++i]);
            } else if (!strcmp(argv[i], "--list-screens")) {
                int idx = 0;
                for (NSScreen *s in [NSScreen screens]) {
                    NSNumber *n = s.deviceDescription[@"NSScreenNumber"];
                    NSRect f = s.frame;
                    printf("screen index=%d id=%u frame=%.0fx%.0f+%.0f+%.0f\n",
                           idx++, n.unsignedIntValue,
                           f.size.width, f.size.height, f.origin.x, f.origin.y);
                }
                return 0;
            } else if (!strcmp(argv[i], "--cyan")) {
                cyan = YES;
            } else if (!strcmp(argv[i], "--no-text")) {
                drawText = NO;
            } else if (!strcmp(argv[i], "--no-barcode")) {
                drawBarcode = NO;
            } else if (!strcmp(argv[i], "--list")) {
                uint32_t ids[16]; uint32_t n = 0;
                if (CGGetActiveDisplayList(16, ids, &n) == kCGErrorSuccess) {
                    for (uint32_t k = 0; k < n; k++) {
                        CGRect r = CGDisplayBounds(ids[k]);
                        printf("display id=%u bounds=%.0fx%.0f+%.0f+%.0f main=%d vendor=0x%x\n",
                               ids[k], r.size.width, r.size.height, r.origin.x, r.origin.y,
                               (int)(ids[k] == CGMainDisplayID()),
                               (unsigned)CGDisplayVendorNumber(ids[k]));
                    }
                }
                return 0;
            } else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
                printf("用法: a02_clock [--display ID] [--hold SEC] [--no-text] [--no-barcode] [--list]\n");
                return 0;
            }
        }

        NSApplication *app = [NSApplication sharedApplication];
        // 参考钟（小窗）要用 regular + 激活：accessory 应用在副屏（独立 Space）上
        // orderFrontRegardless 也拿不到合成，实测副屏始终只有壁纸。
        [app setActivationPolicy:sizeArg ? NSApplicationActivationPolicyRegular
                                         : NSApplicationActivationPolicyAccessory];

        NSScreen *screen = A02ScreenWithID(displayID);
        if (!screen) {
            fprintf(stderr, "✗ 找不到显示器 %u（用 --list 看可用 id）\n", displayID);
            return 2;
        }
        // initWithContentRect:...screen: 会把 rect 的 origin **再加一次该屏 origin**
        // （副屏实测 3440,-154 → 6880,-308，窗口直接跑到屏幕外），因此这里一律用
        // 「相对该屏」的局部坐标，屏幕定位交给 screen: 参数。
        NSRect frame = NSMakeRect(0, 0, screen.frame.size.width, screen.frame.size.height);
        if (sizeArg) {
            // 参考时钟：小窗口贴在目标屏一角。--size WxH + --anchor tl|tr|bl|br
            NSArray *wh = [sizeArg componentsSeparatedByString:@"x"];
            if (wh.count != 2) { fprintf(stderr, "✗ --size 需 WxH\n"); return 2; }
            CGFloat w = [wh[0] doubleValue], h = [wh[1] doubleValue];
            CGFloat m = 24, sx = frame.size.width, sy = frame.size.height;
            CGFloat x = m, y = m;
            if ([anchor isEqualToString:@"br"]) { x = sx - w - m; y = m; }
            if ([anchor isEqualToString:@"tr"]) { x = sx - w - m; y = sy - h - m; }
            if ([anchor isEqualToString:@"tl"]) { x = m; y = sy - h - m; }
            frame = NSMakeRect(x, y, w, h);
        }
        // 不用 initWithContentRect:...screen:（它会把 origin 再叠加一次屏 origin），
        // 先建在 (0,0)，再用全局坐标 setFrame 落到目标屏——这是把窗口放到副屏的标准做法。
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, frame.size.width,
                                                                        frame.size.height)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
        NSRect globalFrame = frame;
        globalFrame.origin.x += screen.frame.origin.x;
        globalFrame.origin.y += screen.frame.origin.y;
        win.backgroundColor = [NSColor blackColor];
        win.opaque = YES;
        win.hasShadow = NO;
        // 参考钟要压在客户端的沉浸窗口之上（沉浸窗口是普通层级），用 screenSaver 层级。
        // 全屏时钟用普通层级：客户端窗口要压在它上面（同层后创建者在上，更可靠的是
        // 客户端窗口自己抬层级）。参考钟小窗仍用最高层级。
        win.level = sizeArg ? NSScreenSaverWindowLevel : NSNormalWindowLevel;
        // 副屏若启用「显示器各自拥有独立 Space」，窗口默认只在它被创建时所属的 Space 出现；
        // canJoinAllSpaces 是让它落到任意显示器/Space 的必要条件（stationary 会把它钉在
        // 创建时那一屏，反而挡住跨屏，实测副屏上完全不出现）。
        win.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
        win.ignoresMouseEvents = YES;

        A02ClockView *view = [[A02ClockView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width,
                                                                           frame.size.height)];
        view.drawText = drawText;
        view.drawBarcode = drawBarcode;
        view.cyanFrame = cyan;
        view.barcodeFraction = barcodeFraction;
        view.skewMs = skewMs;
        win.contentView = view;
        [win setFrame:globalFrame display:NO];

        NSTimer *timer = [NSTimer timerWithTimeInterval:0.008 repeats:YES block:^(NSTimer *t) {
            (void)t;
            [view setNeedsDisplay:YES];
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];

        printf("A02_CLOCK ready display=%u %.0fx%.0f+%.0f+%.0f text=%d barcode=%d\n",
               displayID, frame.size.width, frame.size.height,
               frame.origin.x, frame.origin.y, (int)drawText, (int)drawBarcode);
        printf("A02_CLOCK win frame=%.0f,%.0f %.0fx%.0f visible=%d screens=%lu level=%.0f onscreen=%d\n",
               win.frame.origin.x, win.frame.origin.y, win.frame.size.width, win.frame.size.height,
               (int)win.isVisible, (unsigned long)[NSScreen screens].count,
               (double)win.level, (int)win.isOnActiveSpace);
        fflush(stdout);

        // 不要激活本应用：客户端窗口要压在时钟之上，一旦时钟把应用激活就会抢到前面，
        // 客户端窗口被判为被遮挡后整帧不上屏（实测 framesRendered=0）。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [win setFrame:globalFrame display:YES];
            [win orderFrontRegardless];
        });

        if (holdSec > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(holdSec * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [app stop:nil]; });
        }
        [app run];
        printf("A02_CLOCK exit\n");
    }
    return 0;
}
