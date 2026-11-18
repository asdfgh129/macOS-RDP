//
//  P0V-AltCapture/main.m
//
//  验证 Tahoe「零 active 物理屏」状态下，SCK 之外的采集路径是否还能拿到内容。
//  对照路径：
//    1) SCK（PipelineProbe，已知在 Tahoe 该状态送黑帧）
//    2) CGDisplayCreateImage(displayID)   —— 抓整块虚拟屏
//    3) CGWindowListCreateImage(region)   —— 抓虚拟屏区域内的 on-screen 窗口
//
//  安全：复用 P0VDisplayControl 的快照/守护进程/死线；禁用全部物理屏前先落盘快照。
//

#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <unistd.h>
#import <math.h>

#import "P0VDisplayControl.h"
#import "ProbeUtil.h"
#import "VDManager.h"
#import "PipelineProbe.h"

#define ALT_GRID 16

static NSUInteger optWidth = 1280;
static NSUInteger optHeight = 720;
static int optCaptureMs = 1200;
static NSString *optOut = @"/tmp/p0v-alt-capture.json";
static BOOL optNoDisable = NO;

static void AltUsage(void) {
    fprintf(stderr,
        "用法:\n"
        "  altprobe [--spec WxH] [--capture-ms N] [--out PATH] [--yes]\n"
        "  altprobe --guardian <snapshot> --parent-pid <pid>\n");
}

static BOOL AltParseUnsigned(const char *s, NSUInteger *out) {
    if (!s || !*s) return NO;
    char *end = NULL;
    unsigned long v = strtoul(s, &end, 0);
    if (end == s || *end != '\0') return NO;
    *out = (NSUInteger)v;
    return YES;
}

#pragma mark - CGImage 分析

// 把 CGImage 降到 16x16 网格，按 RGB 平均亮度统计；纯黑判据 mean<8 && var<4。
static NSDictionary *AltAnalyzeImage(CGImageRef image) {
    if (!image) return @{ @"ok": @NO, @"error": @"CGImageRef is NULL" };
    size_t w = CGImageGetWidth(image);
    size_t h = CGImageGetHeight(image);
    if (w == 0 || h == 0) return @{ @"ok": @NO, @"error": @"empty image" };

    size_t bytesPerRow = w * 4;
    uint8_t *buf = calloc(h * bytesPerRow, 1);
    if (!buf) return @{ @"ok": @NO, @"error": @"calloc failed" };
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, bytesPerRow, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return @{ @"ok": @NO, @"error": @"CGBitmapContextCreate failed" }; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    CGContextRelease(ctx);

    double sum = 0, sumSq = 0;
    int cells = 0;
    for (int iy = 0; iy < ALT_GRID; iy++) {
        for (int ix = 0; ix < ALT_GRID; ix++) {
            size_t x = (size_t)((ix + 0.5) * w / ALT_GRID);
            size_t y = (size_t)((iy + 0.5) * h / ALT_GRID);
            if (x >= w) x = w - 1;
            if (y >= h) y = h - 1;
            // kCGBitmapByteOrder32Little + AlphaFirst ⇒ BGRA
            uint8_t b = buf[y * bytesPerRow + x * 4 + 0];
            uint8_t g = buf[y * bytesPerRow + x * 4 + 1];
            uint8_t r = buf[y * bytesPerRow + x * 4 + 2];
            double lum = (r + g + b) / 3.0;
            sum += lum; sumSq += lum * lum; cells++;
        }
    }
    free(buf);
    double mean = sum / cells;
    double var = fmax(0.0, sumSq / cells - mean * mean);
    BOOL black = (mean < 8.0 && var < 4.0);
    return @{
        @"ok": @YES,
        @"raster": [NSString stringWithFormat:@"%zux%zu", w, h],
        @"mean": @((int)lround(mean)),
        @"variance": @((int)lround(var)),
        @"black": @(black),
    };
}

static NSDictionary *AltSampleCGDisplay(CGDirectDisplayID displayID, int samples) {
    NSMutableArray *rows = [NSMutableArray array];
    int blackCount = 0, maxVar = 0, minMean = 999;
    for (int i = 0; i < samples; i++) {
        CGImageRef img = CGDisplayCreateImage(displayID);
        NSDictionary *row = AltAnalyzeImage(img);
        if (img) CGImageRelease(img);
        [rows addObject:row];
        if ([row[@"ok"] boolValue]) {
            if ([row[@"black"] boolValue]) blackCount++;
            maxVar = MAX(maxVar, [row[@"variance"] intValue]);
            minMean = MIN(minMean, [row[@"mean"] intValue]);
        }
        if (i + 1 < samples) [NSThread sleepForTimeInterval:0.25];
    }
    NSString *verdict = blackCount == samples ? @"MOSTLY_BLACK"
                      : (blackCount == 0 ? @"HAS_CONTENT" : @"PARTIAL");
    return @{
        @"path": @"CGDisplayCreateImage",
        @"samples": @(samples),
        @"blackSamples": @(blackCount),
        @"minMean": (minMean == 999 ? @(-1) : @(minMean)),
        @"maxVariance": @(maxVar),
        @"verdict": verdict,
        @"rows": rows,
    };
}

static NSDictionary *AltSampleWindows(CGRect region, int samples) {
    NSMutableArray *rows = [NSMutableArray array];
    int blackCount = 0, maxVar = 0, minMean = 999;
    for (int i = 0; i < samples; i++) {
        CGImageRef img = CGWindowListCreateImage(region, kCGWindowListOptionOnScreenOnly,
                                                 kCGNullWindowID, kCGWindowImageDefault);
        NSDictionary *row = AltAnalyzeImage(img);
        if (img) CGImageRelease(img);
        [rows addObject:row];
        if ([row[@"ok"] boolValue]) {
            if ([row[@"black"] boolValue]) blackCount++;
            maxVar = MAX(maxVar, [row[@"variance"] intValue]);
            minMean = MIN(minMean, [row[@"mean"] intValue]);
        }
        if (i + 1 < samples) [NSThread sleepForTimeInterval:0.25];
    }
    NSString *verdict = blackCount == samples ? @"MOSTLY_BLACK"
                      : (blackCount == 0 ? @"HAS_CONTENT" : @"PARTIAL");
    return @{
        @"path": @"CGWindowListCreateImage",
        @"samples": @(samples),
        @"blackSamples": @(blackCount),
        @"minMean": (minMean == 999 ? @(-1) : @(minMean)),
        @"maxVariance": @(maxVar),
        @"verdict": verdict,
        @"rows": rows,
    };
}

#pragma mark - 主流程

static int AltGuardian(NSString *snapshotPath, pid_t parentPID) {
    return P0VRunGuardian(snapshotPath, parentPID);
}

static int AltRun(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"stage"] = @"start";
    out[@"osVersion"] = [NSProcessInfo processInfo].operatingSystemVersionString;
    out[@"ts"] = [[NSDate date] description];

    NSString *snapPath = [NSString stringWithFormat:@"/tmp/p0v-alt-snapshot-%d.json", getpid()];
    P0VDisplaySnapshot *snap = nil;
    out[@"mode"] = optNoDisable ? @"no-disable" : @"disable-all";
    if (!optNoDisable) {
        snap = [P0VDisplaySnapshot captureActive];
        NSError *snapErr = nil;
        if (![snap writeToFile:snapPath error:&snapErr]) {
            out[@"error"] = [NSString stringWithFormat:@"snapshot failed: %@", snapErr.localizedDescription];
            [out writeToFile:optOut atomically:YES];
            return 2;
        }
        out[@"snapshotPath"] = snapPath;
        if (!P0VStartGuardian(snapPath, getpid(), &snapErr)) {
            out[@"guardian"] = @{ @"started": @NO,
                                  @"error": snapErr.localizedDescription ?: @"unknown" };
        } else {
            out[@"guardian"] = @{ @"started": @YES };
        }
    } else {
        out[@"guardian"] = @{ @"started": @NO, @"reason": @"no-disable mode" };
    }

    out[@"stage"] = @"create-virtual";
    VDManager *vd = [[VDManager alloc] initWithConfigs:@[
        @{ @"width": @(optWidth), @"height": @(optHeight), @"hiDPI": @NO,
           @"refreshRate": @60, @"name": @"P0V-Alt" }
    ] identityOffset:[VDManager savedIdentityOffset] conservativeFirst:YES];
    if (![vd createAll] || ![vd waitUntilUsableTimeoutMs:8000]) {
        out[@"error"] = @"create virtual display failed";
        [out writeToFile:optOut atomically:YES];
        return 2;
    }
    [vd waitUntilModeMatchesTimeoutMs:10000 conservative:YES];
    [vd promoteToTarget];
    [vd waitUntilModeMatchesTimeoutMs:10000 conservative:NO];
    uint32_t displayID = [vd.displayIDs.firstObject unsignedIntValue];
    out[@"virtualDisplayID"] = @(displayID);
    out[@"virtualLiveness"] = vd.liveness;
    printf("虚拟屏就绪: %u\n", displayID);
    fflush(stdout);

    NSError *sckErr = nil;
    [PipelineProbe waitForDisplayIDs:@[@(displayID)] timeoutMs:8000 lastSeen:NULL];
    out[@"sckVisible"] = @([[PipelineProbe shareableDisplayIDsWithError:&sckErr] containsObject:@(displayID)]);
    out[@"sckError"] = sckErr.localizedDescription ?: [NSNull null];

    CGRect bounds = CGDisplayBounds(displayID);
    int samples = MAX(2, optCaptureMs / 300);
    out[@"stage"] = @"baseline";
    out[@"baseline"] = @{
        @"sck": [PipelineProbe captureDisplayID:displayID durationMs:optCaptureMs withEncoder:NO],
        @"cgDisplay": AltSampleCGDisplay(displayID, samples),
        @"windows": AltSampleWindows(bounds, samples),
    };

    if (optNoDisable) {
        out[@"stage"] = @"done";
        NSError *we = nil;
        NSData *j = [NSJSONSerialization dataWithJSONObject:out
                                                   options:NSJSONWritingPrettyPrinted error:&we];
        if (!j || ![j writeToFile:optOut atomically:YES]) {
            fprintf(stderr, "结果写入失败: %s\n", optOut.UTF8String);
        }
        printf("=== 锁屏态建屏对照（未禁物理屏）===\n");
        for (NSString *path in @[@"sck", @"cgDisplay", @"windows"]) {
            NSDictionary *r = out[@"baseline"][path];
            printf("  %-10s verdict=%s\n", path.UTF8String, [r[@"verdict"] UTF8String]);
        }
        [vd destroyAll];
        return 0;
    }

    out[@"stage"] = @"disable-physical";
    NSArray<NSNumber *> *active = P0VActiveDisplayIDs();
    NSMutableArray *physical = [NSMutableArray array];
    for (NSNumber *n in active) if (n.unsignedIntValue != displayID) [physical addObject:n];
    NSDictionary *detail = nil;
    NSError *disableErr = nil;
    BOOL disabled = P0VApplyDisplayEnabledChanges(physical, @[], P0VCommitScopeSession,
                                                  20, &detail, &disableErr);
    out[@"disable"] = @{
        @"ok": @(disabled),
        @"targets": physical,
        @"detail": detail ?: [NSNull null],
        @"error": disableErr.localizedDescription ?: [NSNull null],
        @"activeAfter": P0VActiveDisplayIDs(),
    };
    if (!disabled) {
        [vd destroyAll];
        [out writeToFile:optOut atomically:YES];
        return 1;
    }

    [NSThread sleepForTimeInterval:1.0];
    out[@"stage"] = @"disabled-capture";
    // 禁用物理屏后 WindowServer 会重排原点（Tahoe 实测：x=4520 → x=0），
    // 必须用新的 bounds 抓窗口，否则窗口路径会因区域错位得到假黑帧。
    CGRect disabledBounds = CGDisplayBounds(displayID);
    out[@"disabledBounds"] = NSStringFromRect(disabledBounds);
    out[@"disabled"] = @{
        @"sck": [PipelineProbe captureDisplayID:displayID durationMs:optCaptureMs withEncoder:NO],
        @"cgDisplay": AltSampleCGDisplay(displayID, samples),
        @"windows": AltSampleWindows(disabledBounds, samples),
    };

    out[@"stage"] = @"restore";
    NSDictionary *restoreDetail = nil;
    NSError *restoreErr = nil;
    BOOL restored = P0VRestoreSnapshot(snap, P0VCommitScopeSession, 20,
                                       &restoreDetail, &restoreErr);
    out[@"restore"] = @{
        @"ok": @(restored),
        @"detail": restoreDetail ?: [NSNull null],
        @"error": restoreErr.localizedDescription ?: [NSNull null],
        @"activeAfter": P0VActiveDisplayIDs(),
    };
    [vd destroyAll];

    // 告诉守护进程父进程已正常恢复
    NSString *done = [NSString stringWithFormat:@"%@.done", snapPath];
    [@"ok" writeToFile:done atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    out[@"stage"] = @"done";
    NSError *writeErr = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:out
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&writeErr];
    if (!json || ![json writeToFile:optOut atomically:YES]) {
        fprintf(stderr, "结果写入失败: %s (%s)\n", optOut.UTF8String,
                writeErr.localizedDescription.UTF8String ?: "write error");
    }

    printf("=== 替代采集路径对照 ===\n");
    for (NSString *phase in @[@"baseline", @"disabled"]) {
        printf("%s:\n", phase.UTF8String);
        for (NSString *path in @[@"sck", @"cgDisplay", @"windows"]) {
            NSDictionary *r = out[phase][path];
            printf("  %-10s verdict=%-14s minMean=%s maxVar=%s\n",
                   path.UTF8String, [r[@"verdict"] UTF8String],
                   [r[@"minMean"] description].UTF8String,
                   [r[@"maxVariance"] description].UTF8String);
        }
    }
    printf("restore=%s\n", restored ? "OK" : "FAILED");
    return restored ? 0 : 2;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // 守护进程模式
        if (argc > 1 && strcmp(argv[1], "--guardian") == 0) {
            NSString *snap = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : nil;
            pid_t parent = 0;
            for (int i = 3; i + 1 < argc; i++) {
                if (strcmp(argv[i], "--parent-pid") == 0) parent = atoi(argv[i + 1]);
            }
            if (!snap || parent <= 0) return 3;
            return AltGuardian(snap, parent);
        }
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--spec") == 0 && i + 1 < argc) {
                NSUInteger w = 0, h = 0;
                NSString *spec = [NSString stringWithUTF8String:argv[++i]];
                NSArray *p = [spec componentsSeparatedByString:@"x"];
                if (p.count != 2 || !AltParseUnsigned([p[0] UTF8String], &w) ||
                    !AltParseUnsigned([p[1] UTF8String], &h)) { AltUsage(); return 3; }
                optWidth = w; optHeight = h;
            } else if (strcmp(argv[i], "--capture-ms") == 0 && i + 1 < argc) {
                optCaptureMs = atoi(argv[++i]);
            } else if (strcmp(argv[i], "--out") == 0 && i + 1 < argc) {
                optOut = [NSString stringWithUTF8String:argv[++i]];
            } else if (strcmp(argv[i], "--yes") == 0) {
                // 兼容 v01probe 习惯；本探针默认无需交互
            } else if (strcmp(argv[i], "--no-disable") == 0) {
                optNoDisable = YES;
            } else {
                AltUsage(); return 3;
            }
        }
        return AltRun();
    }
}
