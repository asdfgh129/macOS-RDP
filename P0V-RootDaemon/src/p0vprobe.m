//
//  p0vprobe.m — P0-V Root Daemon Probe（V-04）
//
//  目的：验证「root 特权进程能否在锁屏 / 登录窗态下拿到画面并把键鼠送进 loginwindow」。
//  这是 D-08 Path A 的唯一判据，不再靠推断。
//
//  子命令：
//    probe                 打印环境（uid、会话、锁屏态、AX 信任、display 列表、SCK 枚举结果）
//    capture [--ms N]      捕获主屏若干帧，报告帧数 / 亮度 / 指纹
//    inject-test           指纹A → 向 loginwindow 定向输 "aa"+Return → 指纹B → 报告像素差
//    daemon-run            probe + capture + inject-test 一并落盘到 /tmp/p0v-root.json（供 launchd 调用）
//
//  编译产物是一个最小 .app bundle（TCC 按 bundle 身份记账，裸 CLI 在授权列表里不容易选中）。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <libproc.h>
#import <math.h>
#import <stdlib.h>

// CGSessionCopyCurrentDictionary 在 ApplicationServices 里没有稳定公开声明，自己补。
extern CFDictionaryRef CGSessionCopyCurrentDictionary(void);

// 前置声明：P0VEnv 会用到，定义在后面。
static NSArray<NSNumber *> *P0VShareableDisplayIDs(NSError **outError);

static NSString *const kOutPath = @"/tmp/p0v-root.json";

#pragma mark - 日志

static void P0VLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";
    });
    NSString *line = [NSString stringWithFormat:@"[p0v %@] %@\n", [df stringFromDate:[NSDate date]], s];
    fputs(line.UTF8String, stderr);
    // launchd 下 stderr 不一定被收集，同时追加到固定日志文件。
    FILE *f = fopen("/tmp/p0v-root.log", "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
}

static double P0VNowMs(void) { return [[NSDate date] timeIntervalSince1970] * 1000.0; }

#pragma mark - 进程查找（不依赖 shell）

static pid_t P0VFindPID(NSString *name) {
    int count = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (count <= 0) return -1;
    pid_t *pids = calloc((size_t)count, sizeof(pid_t));
    if (!pids) return -1;
    count = proc_listpids(PROC_ALL_PIDS, 0, pids, count * (int)sizeof(pid_t));
    pid_t found = -1;
    for (int i = 0; i < count / (int)sizeof(pid_t); i++) {
        pid_t p = pids[i];
        if (p <= 0) continue;
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(p, path, sizeof(path)) <= 0) continue;
        NSString *base = [[NSString stringWithUTF8String:path] lastPathComponent];
        if ([base isEqualToString:name]) { found = p; break; }
    }
    free(pids);
    return found;
}

#pragma mark - 会话 / 显示 / TCC 环境

static NSDictionary *P0VSessionInfo(void) {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    CFDictionaryRef dict = CGSessionCopyCurrentDictionary();
    if (!dict) {
        // root LaunchDaemon 不在任何 GUI 会话里，这里返回 NULL 是正常现象，
        // 恰恰说明"必须另想办法拿到会话信息"。
        r[@"available"] = @NO;
        r[@"note"] = @"CGSessionCopyCurrentDictionary 为 NULL（非 GUI 会话进程）";
        return r;
    }
    NSDictionary *d = (__bridge_transfer NSDictionary *)dict;
    r[@"available"] = @YES;
    r[@"onConsole"] = d[@"kCGSSessionOnConsoleKey"] ?: @NO;
    r[@"screenIsLocked"] = d[@"CGSSessionScreenIsLocked"] ?: @NO;
    r[@"loginDone"] = d[@"kCGSessionLoginDoneKey"] ?: @NO;
    r[@"userName"] = d[@"kCGSSessionUserNameKey"] ?: @"";
    r[@"auditID"] = d[@"kCGSSessionAuditIDKey"] ?: @0;
    return r;
}

static NSDictionary *P0VDisplays(void) {
    uint32_t count = 0;
    if (CGGetActiveDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) {
        return @{ @"count": @0, @"list": @[] };
    }
    CGDirectDisplayID ids[16];
    if (count > 16) count = 16;
    CGGetActiveDisplayList(count, ids, &count);
    NSMutableArray *list = [NSMutableArray array];
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID d = ids[i];
        CGRect b = CGDisplayBounds(d);
        [list addObject:@{
            @"id": @(d),
            @"bounds": [NSString stringWithFormat:@"%.0fx%.0f+%.0f+%.0f",
                        b.size.width, b.size.height, b.origin.x, b.origin.y],
            @"online": @(CGDisplayIsOnline(d) != 0),
            @"active": @(CGDisplayIsActive(d) != 0),
            @"main": @(CGDisplayIsMain(d) != 0),
            @"asleep": @(CGDisplayIsAsleep(d) != 0),
            @"vendor": @(CGDisplayVendorNumber(d)),
            @"model": @(CGDisplayModelNumber(d)),
        }];
    }
    return @{ @"count": @(count), @"list": list };
}

static NSDictionary *P0VEnv(void) {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    r[@"ts"] = [[NSDate date] description];
    r[@"uid"] = @(getuid());
    r[@"euid"] = @(geteuid());
    r[@"isRoot"] = @(geteuid() == 0);
    r[@"executable"] = [[NSBundle mainBundle] executablePath] ?: @"";
    r[@"bundleID"] = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    r[@"axTrusted"] = @(AXIsProcessTrusted());
    r[@"session"] = P0VSessionInfo();
    r[@"displays"] = P0VDisplays();

    pid_t lw = P0VFindPID(@"loginwindow");
    pid_t ws = P0VFindPID(@"WindowServer");
    r[@"loginwindowPID"] = @(lw);
    r[@"windowServerPID"] = @(ws);

    NSError *e = nil;
    NSArray *ids = [P0VShareableDisplayIDs(&e) copy];
    r[@"sckDisplayIDs"] = ids ?: @[];
    r[@"sckError"] = e ? [NSString stringWithFormat:@"%@ (domain=%@ code=%ld)",
                          e.localizedDescription, e.domain, (long)e.code] : [NSNull null];
    return r;
}

#pragma mark - SCK 枚举

static NSArray<NSNumber *> *P0VShareableDisplayIDs(NSError **outError) {
    __block SCShareableContent *content = nil;
    __block NSError *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *c, NSError *e) {
        content = c; err = e; dispatch_semaphore_signal(sem);
    }];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC)) != 0) {
        if (outError) *outError = [NSError errorWithDomain:@"P0V" code:2
                                                     userInfo:@{NSLocalizedDescriptionKey: @"SCShareableContent 6s 超时"}];
        return nil;
    }
    if (err) { if (outError) *outError = err; return nil; }
    NSMutableArray *ids = [NSMutableArray array];
    for (SCDisplay *d in content.displays) [ids addObject:@(d.displayID)];
    return ids;
}

#pragma mark - 帧指纹采集

static const double kP0VBlackY = 16.0;   // 420YpCbCr8BiPlanarVideoRange 的纯黑是 16，不是 0

#define P0V_GRID 16

@interface P0VSink : NSObject <SCStreamOutput, SCStreamDelegate> {
@public
    // 16x16 亮度网格指纹：用于「注入前后画面是否变化」的判据。
    // 不能用 property —— ObjC 属性不支持数组类型。
    int _grid[P0V_GRID * P0V_GRID];
}
@property (nonatomic, assign) int frames;
@property (nonatomic, assign) double startMs;
@property (nonatomic, assign) double firstFrameMs;
@property (nonatomic, assign) double worstMean;
@property (nonatomic, assign) double bestVariance;
@property (nonatomic, assign) int blackFrames;
@property (nonatomic, assign) BOOL hasGrid;
@end

@implementation P0VSink
- (instancetype)init {
    self = [super init];
    if (self) { _worstMean = 999; _bestVariance = -1; }
    return self;
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb
         ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sb)) return;
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    if (self.frames == 0) self.firstFrameMs = P0VNowMs() - self.startMs;
    self.frames++;

    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;
    uint8_t *base = NULL;
    size_t stride = 0, w = 0, h = 0;
    if (CVPixelBufferGetPlaneCount(pb) > 0) {
        base = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
        stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
        w = CVPixelBufferGetWidthOfPlane(pb, 0);
        h = CVPixelBufferGetHeightOfPlane(pb, 0);
    } else {
        base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
        stride = CVPixelBufferGetBytesPerRow(pb);
        w = CVPixelBufferGetWidth(pb);
        h = CVPixelBufferGetHeight(pb);
    }
    if (base && w > P0V_GRID && h > P0V_GRID) {
        double sum = 0, sumSq = 0;
        for (int iy = 0; iy < P0V_GRID; iy++) {
            for (int ix = 0; ix < P0V_GRID; ix++) {
                size_t x = (size_t)((ix + 0.5) * w / P0V_GRID);
                size_t y = (size_t)((iy + 0.5) * h / P0V_GRID);
                int v = base[y * stride + x];
                self->_grid[iy * P0V_GRID + ix] = v;
                sum += v; sumSq += (double)v * v;
            }
        }
        int n = P0V_GRID * P0V_GRID;
        double mean = sum / n;
        double var = sumSq / n - mean * mean;
        if (var < 0) var = 0;
        if (mean < self.worstMean) self.worstMean = mean;
        if (var > self.bestVariance) self.bestVariance = var;
        if (mean < kP0VBlackY + 4 && var < 4) self.blackFrames++;
        self.hasGrid = YES;
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}
@end

static NSDictionary *P0VCapture(CGDirectDisplayID displayID, int durationMs, BOOL showCursor) {
    NSError *contentError = nil;
    NSArray<NSNumber *> *ids = P0VShareableDisplayIDs(&contentError);
    if (!ids) {
        return @{ @"ok": @NO,
                  @"error": [NSString stringWithFormat:@"SCShareableContent 失败：%@",
                             contentError.localizedDescription ?: @"unknown"] };
    }
    if (![ids containsObject:@(displayID)]) {
        return @{ @"ok": @NO,
                  @"error": @"目标 displayID 不在 SCShareableContent 中",
                  @"visibleIDs": ids };
    }

    // 重新取一次（SCShareableContent 每个实例的 lifetime 与 SCDisplay 绑定，不能跨调用复用）
    __block SCShareableContent *content = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *c, NSError *e) {
        (void)e;
        content = c; dispatch_semaphore_signal(sem);
    }];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC)) != 0 || !content) {
        return @{ @"ok": @NO, @"error": @"二次枚举 SCShareableContent 超时" };
    }
    SCDisplay *target = nil;
    for (SCDisplay *d in content.displays) if (d.displayID == displayID) { target = d; break; }
    if (!target) return @{ @"ok": @NO, @"error": @"SCDisplay 查找失败" };

    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:target excludingWindows:@[]];
    SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
    CGFloat scale = 1.0;
    if (@available(macOS 14.0, *)) { if (filter.pointPixelScale > 0) scale = filter.pointPixelScale; }
    size_t outW = (size_t)llround(target.width * scale);
    size_t outH = (size_t)llround(target.height * scale);
    outW -= outW % 2; outH -= outH % 2;
    cfg.width = outW;
    cfg.height = outH;
    cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    cfg.minimumFrameInterval = CMTimeMake(1, 30);
    cfg.queueDepth = 4;
    cfg.showsCursor = showCursor;
    cfg.capturesAudio = NO;

    __attribute__((objc_precise_lifetime)) P0VSink *sink = [[P0VSink alloc] init];
    sink.startMs = P0VNowMs();

    NSError *streamError = nil;
    SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:sink];
    dispatch_queue_t q = dispatch_queue_create("p0v.sck", DISPATCH_QUEUE_SERIAL);
    if (![stream addStreamOutput:sink type:SCStreamOutputTypeScreen
              sampleHandlerQueue:q error:&streamError]) {
        return @{ @"ok": @NO, @"error": [NSString stringWithFormat:@"addStreamOutput: %@",
                                         streamError.localizedDescription] };
    }

    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    __block NSError *startErr = nil;
    [stream startCaptureWithCompletionHandler:^(NSError *e) { startErr = e; dispatch_semaphore_signal(started); }];
    BOOL timedOut = dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC)) != 0;
    if (startErr || timedOut) {
        dispatch_semaphore_t stopSem = dispatch_semaphore_create(0);
        [stream stopCaptureWithCompletionHandler:^(NSError *e) { (void)e; dispatch_semaphore_signal(stopSem); }];
        dispatch_semaphore_wait(stopSem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        return @{ @"ok": @NO,
                  @"error": startErr ? [NSString stringWithFormat:@"startCapture: %@", startErr.localizedDescription]
                                     : @"startCapture 6s 未回调，已中止" };
    }

    [NSThread sleepForTimeInterval:durationMs / 1000.0];

    dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
    [stream stopCaptureWithCompletionHandler:^(NSError *e) { (void)e; dispatch_semaphore_signal(stopped); }];
    dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    [NSThread sleepForTimeInterval:0.1];

    NSMutableArray *grid = [NSMutableArray arrayWithCapacity:P0V_GRID * P0V_GRID];
    for (int i = 0; i < P0V_GRID * P0V_GRID; i++) [grid addObject:@(sink->_grid[i])];

    NSString *verdict = sink.frames == 0 ? @"NO_FRAMES"
                      : (sink.blackFrames > sink.frames * 0.8 ? @"MOSTLY_BLACK" : @"HAS_CONTENT");
    return @{
        @"ok": @(sink.frames > 0),
        @"displayID": @(displayID),
        @"raster": [NSString stringWithFormat:@"%zux%zu", outW, outH],
        @"frames": @(sink.frames),
        @"firstFrameMs": @((int)sink.firstFrameMs),
        @"minMean": @((int)(sink.worstMean == 999 ? -1 : sink.worstMean)),
        @"maxVariance": @((int)sink.bestVariance),
        @"suspectedBlackFrames": @(sink.blackFrames),
        @"verdict": verdict,
        @"grid": grid,
        @"hasGrid": @(sink.hasGrid),
    };
}

#pragma mark - 定向注入

static void P0VPostKeyToPid(pid_t pid, CGKeyCode code, BOOL down) {
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, code, down);
    if (!e) return;
    CGEventPostToPid(pid, e);
    CFRelease(e);
}

// 用 Unicode 事件注入，避免维护键码表；keycode 传 0（'a'）只是占位，
// 真正的字符由 CGEventKeyboardSetUnicodeString 决定。
static void P0VTypeToPid(pid_t pid, NSString *ascii) {
    for (NSUInteger i = 0; i < ascii.length; i++) {
        UniChar u = [ascii characterAtIndex:i];
        CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0, true);
        CGEventRef up   = CGEventCreateKeyboardEvent(NULL, 0, false);
        if (!down || !up) { if (down) CFRelease(down); if (up) CFRelease(up); continue; }
        CGEventKeyboardSetUnicodeString(down, 1, &u);
        CGEventKeyboardSetUnicodeString(up, 1, &u);
        CGEventPostToPid(pid, down);
        CGEventPostToPid(pid, up);
        CFRelease(down);
        CFRelease(up);
    }
}

static NSDictionary *P0VDiffGrid(NSArray *a, NSArray *b) {
    if (!a || !b || a.count != b.count || a.count == 0) {
        return @{ @"comparable": @NO };
    }
    int maxDiff = 0, changed = 0, total = (int)a.count;
    for (NSUInteger i = 0; i < a.count; i++) {
        int d = abs([a[i] intValue] - [b[i] intValue]);
        if (d > maxDiff) maxDiff = d;
        if (d > 8) changed++;
    }
    return @{ @"comparable": @YES, @"maxCellDiff": @(maxDiff),
              @"changedCells": @(changed), @"totalCells": @(total),
              @"changedRatio": @((double)changed / total) };
}

#pragma mark - 子命令

static int P0VCmdProbe(void) {
    NSDictionary *env = P0VEnv();
    NSData *json = [NSJSONSerialization dataWithJSONObject:env
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:NULL];
    printf("%s\n", json ? [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] UTF8String] : "{}");
    return 0;
}

static int P0VCmdCapture(int ms) {
    NSDictionary *env = P0VEnv();
    NSArray *list = env[@"displays"][@"list"];
    if (list.count == 0) { printf("{\"ok\":false,\"error\":\"no active display\"}\n"); return 2; }
    NSNumber *did = list[0][@"id"];
    NSDictionary *cap = P0VCapture((CGDirectDisplayID)did.unsignedIntValue, ms, NO);
    NSMutableDictionary *r = [cap mutableCopy];
    r[@"session"] = env[@"session"];
    r[@"axTrusted"] = env[@"axTrusted"];
    NSData *json = [NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    printf("%s\n", json ? [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] UTF8String] : "{}");
    return 0;
}

static NSDictionary *P0VInjectTest(void) {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    pid_t lw = P0VFindPID(@"loginwindow");
    r[@"loginwindowPID"] = @(lw);
    if (lw <= 0) { r[@"ok"] = @NO; r[@"error"] = @"找不到 loginwindow"; return r; }

    NSDictionary *env = P0VEnv();
    NSArray *list = env[@"displays"][@"list"];
    if (list.count == 0) { r[@"ok"] = @NO; r[@"error"] = @"无 active display"; return r; }
    CGDirectDisplayID did = (CGDirectDisplayID)[list[0][@"id"] unsignedIntValue];

    NSDictionary *a = P0VCapture(did, 350, NO);
    r[@"before"] = a[@"verdict"] ?: @"?";
    r[@"beforeFrames"] = a[@"frames"] ?: @0;

    P0VTypeToPid(lw, @"aa");
    P0VPostKeyToPid(lw, 36, true);   // Return
    P0VPostKeyToPid(lw, 36, false);
    [NSThread sleepForTimeInterval:1.2];

    NSDictionary *b = P0VCapture(did, 350, NO);
    r[@"after"] = b[@"verdict"] ?: @"?";
    r[@"afterFrames"] = b[@"frames"] ?: @0;
    r[@"diff"] = P0VDiffGrid(a[@"grid"], b[@"grid"]);

    NSDictionary *post = P0VSessionInfo();
    r[@"sessionAfter"] = post;
    BOOL unlocked = [post[@"screenIsLocked"] isEqual:@NO] && [post[@"available"] isEqual:@YES];
    r[@"mayHaveUnlocked"] = @(unlocked);

    NSDictionary *d = r[@"diff"];
    BOOL changed = [d[@"comparable"] boolValue] && [d[@"changedCells"] intValue] > 0;
    r[@"ok"] = @(changed || unlocked);
    r[@"verdict"] = unlocked ? @"INJECTION_ACCEPTED_AND_UNLOCKED"
                  : changed ? @"INJECTION_ACCEPTED_UI_CHANGED"
                            : @"INJECTION_NO_VISIBLE_EFFECT";
    return r;
}

static int P0VCmdInject(void) {
    NSDictionary *r = P0VInjectTest();
    NSData *json = [NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    printf("%s\n", json ? [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] UTF8String] : "{}");
    return 0;
}

static int P0VCmdDaemonRun(void) {
    P0VLog(@"daemon-run 开始（euid=%d）", geteuid());
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"stage"] = @"env";
    out[@"env"] = P0VEnv();
    P0VLog(@"env: session=%@ axTrusted=%@ displays=%d",
           out[@"env"][@"session"][@"available"],
           out[@"env"][@"axTrusted"],
           [out[@"env"][@"displays"][@"count"] intValue]);

    out[@"stage"] = @"capture";
    NSArray *list = out[@"env"][@"displays"][@"list"];
    if (list.count > 0) {
        CGDirectDisplayID did = (CGDirectDisplayID)[list[0][@"id"] unsignedIntValue];
        NSDictionary *cap = P0VCapture(did, 600, NO);
        NSMutableDictionary *c = [cap mutableCopy];
        [c removeObjectForKey:@"grid"];
        out[@"capture"] = c;
        P0VLog(@"capture: %@ frames=%@ mean=%@", c[@"verdict"], c[@"frames"], c[@"minMean"]);
    } else {
        out[@"capture"] = @{ @"ok": @NO, @"error": @"无 active display" };
    }

    out[@"stage"] = @"inject";
    if ([[out[@"env"][@"session"][@"available"] description] isEqualToString:@"1"]) {
        out[@"inject"] = @{ @"skipped": @"进程在 GUI 会话内，说明未锁屏，注入测试无意义" };
    } else {
        out[@"inject"] = P0VInjectTest();
    }

    out[@"stage"] = @"done";
    NSData *json = [NSJSONSerialization dataWithJSONObject:out
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:NULL];
    [json writeToFile:kOutPath atomically:YES];
    P0VLog(@"已写入 %@（%lu bytes）", kOutPath, (unsigned long)json.length);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *cmd = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"probe";
        int ms = 600;
        for (int i = 2; i < argc; i++) {
            if (strcmp(argv[i], "--ms") == 0 && i + 1 < argc) ms = atoi(argv[++i]);
        }
        if ([cmd isEqualToString:@"probe"])        return P0VCmdProbe();
        if ([cmd isEqualToString:@"capture"])      return P0VCmdCapture(ms);
        if ([cmd isEqualToString:@"inject-test"])  return P0VCmdInject();
        if ([cmd isEqualToString:@"daemon-run"])   return P0VCmdDaemonRun();
        fprintf(stderr, "用法: p0vprobe {probe|capture|inject-test|daemon-run} [--ms N]\n");
        return 1;
    }
}
