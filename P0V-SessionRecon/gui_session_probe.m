// gui_session_probe — 真 loginwindow 补测的只读前置探针
// =============================================================================
// 用途：在【登出后停登录框】态、被 SSH 以 root 调起时，先回答一个问题：
//   「当前这个 root 进程，到底在不在 GUI 图形会话里、能不能抓到真实画面？」
//
// 为什么必须先问：DESIGN A-09 记录过 Sequoia 实测结论 —— root daemon 路径被
// TCC 路径条目 + 无 GUI 会话挡住。SSH 起的 root 进程通常不在 Aqua session，
// 此时 CGDisplayCreateImage 多半返回全黑，跑完整补测脚本只会得到空结果。
// 先探这一步，可避免在借测机上白跑一轮（禁屏有风险、恢复也耗时间）。
//
// 严格只读：不建虚拟屏、不禁物理屏、不改任何显示配置、不注入事件。
// 仅：读 CGSession 字典 + 枚举 active display + 对每块屏抓 1 帧算 luma。
//
// 用法：
//   cc -O2 -fobjc-arc -framework Foundation -framework CoreGraphics \
//      -framework ApplicationServices gui_session_probe.c -o gui_session_probe
//   ./gui_session_probe [--frames N]
//
// 退出码：0 = 在 GUI 会话且抓到非黑画面（可继续跑补测）
//         10 = 不在 GUI 会话（需 launchctl bsexec 进入）
//         11 = 在 GUI 会话但抓到全黑（TCC 屏幕录制未授权或合成异常）
//         2  = 参数/环境错误
// =============================================================================
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

static double NowMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

// 单帧平均亮度（0-255）+ 采样点方差，用于判黑帧。
// 与 P0V 探针的判据保持一致：mean < 8 视为黑帧候选。
static BOOL SampleLuma(CGImageRef img, double *meanOut, double *varOut) {
    if (!img) return NO;
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    if (w == 0 || h == 0) return NO;

    // 缩到 64x64 采样，避免整图拷贝开销。
    size_t sw = 64, sh = 64;
    uint8_t *buf = calloc(sw * sh * 4, 1);
    if (!buf) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, sw, sh, 8, sw * 4, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return NO; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, sw, sh), img);
    CGContextRelease(ctx);

    double sum = 0, sumSq = 0;
    size_t n = sw * sh;
    for (size_t i = 0; i < n; i++) {
        uint8_t *p = buf + i * 4;      // BGRA
        double luma = 0.114 * p[0] + 0.587 * p[1] + 0.299 * p[2];
        sum += luma;
        sumSq += luma * luma;
    }
    free(buf);
    double mean = sum / n;
    double var = sumSq / n - mean * mean;
    if (meanOut) *meanOut = mean;
    if (varOut) *varOut = var > 0 ? var : 0;
    return YES;
}

static void EmitJSON(NSDictionary *d) {
    NSData *j = [NSJSONSerialization dataWithJSONObject:d
                                                options:NSJSONWritingPrettyPrinted
                                                  error:NULL];
    if (j) {
        fwrite(j.bytes, 1, j.length, stdout);
        fputc('\n', stdout);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int frames = 3;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--frames") == 0 && i + 1 < argc) {
                frames = atoi(argv[++i]);
                if (frames < 1) frames = 1;
                if (frames > 10) frames = 10;
            } else {
                fprintf(stderr, "用法: gui_session_probe [--frames N(1-10)]\n");
                return 2;
            }
        }

        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"uid"] = @(getuid());
        out[@"pid"] = @(getpid());

        // 1) GUI 会话判定：CGSessionCopyCurrentDictionary 为 NULL 即不在 Aqua session。
        //    这是 SSH/launchd 上下文里最可靠的自检信号。
        CFDictionaryRef sess = CGSessionCopyCurrentDictionary();
        BOOL inGUI = (sess != NULL);
        out[@"inGUISession"] = @(inGUI);
        if (inGUI) {
            NSDictionary *s = (__bridge_transfer NSDictionary *)sess;
            out[@"sessionLoginDone"] = s[@"kCGSSessionLoginDoneKey"] ?: [NSNull null];
            out[@"sessionOnConsole"] = s[@"kCGSSessionOnConsoleKey"] ?: [NSNull null];
            out[@"sessionUserName"] = s[@"kCGSSessionUserNameKey"] ?: [NSNull null];
            out[@"sessionAuditID"] = s[@"kCGSSessionAuditIDKey"] ?: [NSNull null];
        }

        // 2) 枚举 active 显示（只读，不改）。
        uint32_t cnt = 0;
        CGGetActiveDisplayList(0, NULL, &cnt);
        CGDirectDisplayID ids[16];
        if (cnt > 16) cnt = 16;
        CGGetActiveDisplayList(cnt, ids, &cnt);
        out[@"activeDisplayCount"] = @(cnt);

        NSMutableArray *displays = [NSMutableArray array];
        NSMutableArray *verdicts = [NSMutableArray array];

        for (uint32_t i = 0; i < cnt; i++) {
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            d[@"displayID"] = @(ids[i]);
            d[@"bounds"] = NSStringFromRect(CGDisplayBounds(ids[i]));
            d[@"isMain"] = @(CGDisplayIsMain(ids[i]) != 0);

            // 3) 每屏抓 N 帧算 luma，判是否黑屏。
            double bestMean = -1, bestVar = 0, worstMs = 0;
            int blackFrames = 0;
            for (int f = 0; f < frames; f++) {
                double t0 = NowMs();
                CGImageRef img = CGDisplayCreateImage(ids[i]);
                double ms = NowMs() - t0;
                if (ms > worstMs) worstMs = ms;

                double mean = 0, var = 0;
                if (SampleLuma(img, &mean, &var)) {
                    if (mean > bestMean) { bestMean = mean; bestVar = var; }
                    if (mean < 8.0) blackFrames++;
                } else {
                    blackFrames++;
                }
                if (img) CGImageRelease(img);
                if (f + 1 < frames) usleep(60000);  // 60ms 间隔
            }

            d[@"captureMsMax"] = @(worstMs);
            d[@"lumaMeanBest"] = bestMean >= 0 ? @(bestMean) : [NSNull null];
            d[@"lumaVarAtBest"] = @(bestVar);
            d[@"blackFrames"] = @(blackFrames);
            d[@"frames"] = @(frames);

            NSString *verdict = @"UNKNOWN";
            if (bestMean < 0) {
                verdict = @"CAPTURE_FAILED";
            } else if (blackFrames == frames) {
                verdict = @"ALL_BLACK";
            } else if (bestMean < 8.0) {
                verdict = @"NEAR_BLACK";
            } else {
                verdict = @"HAS_CONTENT";
            }
            d[@"verdict"] = verdict;
            [verdicts addObject:verdict];
            [displays addObject:d];
        }
        out[@"displays"] = displays;

        // 4) 总结论：这是补测脚本用来 decide「跑不跑」的依据。
        NSString *summary = @"UNKNOWN";
        int exitCode = 0;
        BOOL anyContent = NO;
        for (NSString *v in verdicts) {
            if ([v isEqualToString:@"HAS_CONTENT"]) { anyContent = YES; break; }
        }

        if (!inGUI) {
            summary = @"NOT_IN_GUI_SESSION";
            exitCode = 10;
        } else if (cnt == 0) {
            summary = @"NO_ACTIVE_DISPLAY";
            exitCode = 11;
        } else if (!anyContent) {
            summary = @"GUI_BUT_NO_CONTENT";
            exitCode = 11;
        } else {
            summary = @"READY_FOR_LOGINWINDOW_PROBE";
            exitCode = 0;
        }
        out[@"summary"] = summary;
        out[@"osVersion"] = [[NSProcessInfo processInfo] operatingSystemVersionString];

        EmitJSON(out);

        // 人读摘要（写进日志更直观）
        fprintf(stderr, "\n=== gui_session_probe ===\n");
        fprintf(stderr, "  inGUISession=%s  activeDisplays=%u\n",
                inGUI ? "YES" : "NO", cnt);
        for (NSDictionary *d in displays) {
            fprintf(stderr, "  display %s  %s  luma=%.1f  black=%s/%s\n",
                    [[d[@"displayID"] description] UTF8String],
                    [d[@"verdict"] UTF8String],
                    [d[@"lumaMeanBest"] isKindOfClass:[NSNumber class]]
                        ? [d[@"lumaMeanBest"] doubleValue] : -1.0,
                    [[d[@"blackFrames"] description] UTF8String],
                    [[d[@"frames"] description] UTF8String]);
        }
        fprintf(stderr, "  summary=%s\n", [summary UTF8String]);
        if (!inGUI) {
            fprintf(stderr,
                "  ↳ 不在 GUI 会话：需用 launchctl bsexec <loginwindow_pid> 进入图形会话后重试\n");
        } else if (!anyContent) {
            fprintf(stderr,
                "  ↳ 在 GUI 会话但抓不到内容：检查「屏幕录制」TCC 授权与该二进制的签名/路径\n");
        }
        return exitCode;
    }
}
