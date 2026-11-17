//
//  main.m
//  P0V-DisplayIsolation
//
//  V-01：禁用一块物理屏后，虚拟屏仍可捕获，且唤醒事件不会把它重新 enable。
//  V-03：禁用全部物理屏（只剩虚拟屏）后，系统仍可建屏 / 捕获 / 注入输入。
//
//  设计原则：
//    - 任何显示变更前先落盘快照，再起守护进程；探针异常退出时守护进程恢复物理屏。
//    - 所有显示事务带死线；WindowServer 超时后不重试、不再发任何显示配置请求。
//    - 结论只写实测结果，不替用户推断；disable 无效时明确报 DISABLE_NO_EFFECT。
//

#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <signal.h>
#import <ApplicationServices/ApplicationServices.h>
#import <unistd.h>
#import <math.h>

#import "P0VDisplayControl.h"
#import "ProbeUtil.h"
#import "VDManager.h"
#import "PipelineProbe.h"

static volatile sig_atomic_t gCancelRequested = 0;

static void P0VSignalHandler(int sig) {
    if (gCancelRequested) _exit(128 + sig);  // 第二次 Ctrl+C：立刻退出，守护进程兜底
    gCancelRequested = 1;
    const char msg[] = "\n[取消] 收到信号，将在当前步骤结束后恢复显示；再按一次强制退出（守护进程会恢复）\n";
    (void)write(STDERR_FILENO, msg, sizeof(msg) - 1);
}

#pragma mark - 选项

@interface P0VOptions : NSObject
@property (nonatomic, copy) NSString *mode;          // one | all
@property (nonatomic, strong, nullable) NSNumber *target;
@property (nonatomic, assign) NSUInteger width;
@property (nonatomic, assign) NSUInteger height;
@property (nonatomic, assign) BOOL hiDPI;
@property (nonatomic, assign) NSUInteger count;
@property (nonatomic, assign) int watchSecs;
@property (nonatomic, assign) int commitTimeoutSec;
@property (nonatomic, assign) int captureMs;
@property (nonatomic, assign) P0VCommitScope scope;
@property (nonatomic, assign) BOOL useGuardian;
@property (nonatomic, assign) BOOL yes;
@property (nonatomic, assign) BOOL reassert;
@property (nonatomic, assign) BOOL rebuildTest;
@property (nonatomic, assign) BOOL allowStaleSlots;
@property (nonatomic, assign) BOOL dryRun;
@property (nonatomic, copy) NSString *outPath;
@end

@implementation P0VOptions
- (instancetype)init {
    self = [super init];
    if (self) {
        _mode = @"one";
        _width = 1920;
        _height = 1080;
        _hiDPI = NO;
        _count = 1;
        _watchSecs = 20;
        _commitTimeoutSec = 20;
        _captureMs = 1500;
        _scope = P0VCommitScopeSession;
        _useGuardian = YES;
        _yes = NO;
        _reassert = NO;
        _rebuildTest = YES;
        _allowStaleSlots = NO;
        _dryRun = NO;
        _outPath = @"/tmp/p0v-display-isolation.json";
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        @"mode": self.mode,
        @"target": self.target ?: @"(auto)",
        @"spec": [NSString stringWithFormat:@"%lux%lu", (unsigned long)self.width, (unsigned long)self.height],
        @"hiDPI": @(self.hiDPI),
        @"count": @(self.count),
        @"watchSecs": @(self.watchSecs),
        @"commitTimeoutSec": @(self.commitTimeoutSec),
        @"captureMs": @(self.captureMs),
        @"commit": self.scope == P0VCommitScopePermanent ? @"permanent" : @"session",
        @"guardian": @(self.useGuardian),
        @"reassert": @(self.reassert),
        @"rebuildTest": @(self.rebuildTest),
        @"allowStaleSlots": @(self.allowStaleSlots),
        @"dryRun": @(self.dryRun),
        @"outPath": self.outPath,
    };
}
@end

#pragma mark - 工具

static void P0VUsage(void) {
    fprintf(stderr,
        "用法:\n"
        "  v01probe probe                         只读侦察：显示拓扑 / SCK 可见性 / 私有符号\n"
        "  v01probe snapshot [--out PATH]         落盘当前 active display 快照\n"
        "  v01probe run [选项]                    执行 V-01/V-03（会临时关闭物理屏）\n"
        "  v01probe restore --snapshot PATH       用快照手动恢复显示\n"
        "\n"
        "run 选项:\n"
        "  --mode one|all         one=V-01 禁用一块（默认），all=V-03 禁用全部\n"
        "  --target ID            指定要禁用的物理屏（默认优先非主屏）\n"
        "  --spec WxH             虚拟屏点尺寸（默认 1920x1080）\n"
        "  --hidpi                虚拟屏 2x\n"
        "  --count N              虚拟屏块数（默认 1）\n"
        "  --watch-secs N         禁用后观察物理屏是否被唤醒事件重新 enable（默认 20，0=跳过）\n"
        "  --commit-timeout N     显示事务死线秒数（默认 20）\n"
        "  --capture-ms N         单次 SCK 捕获时长（默认 1500）\n"
        "  --commit session|permanent\n"
        "  --reassert             观察到物理屏重新出现后再次禁用（默认只记录）\n"
        "  --dry-run              只建虚拟屏并捕获基线，不禁用物理屏（验证 TCC / 虚拟屏链路）\n"
        "  --no-rebuild-test      V-03 下跳过「零物理屏下再建一块」子项（有停放槽位时会自动跳过）\n"
        "  --allow-stale-slots    有停放槽位时仍允许多建虚拟屏（风险：可能触发 WindowServer 断言）\n"
        "  --no-guardian          不起守护进程（不推荐）\n"
        "  --yes                  跳过交互确认（非交互环境必须显式给出）\n"
        "  --out PATH             结果 JSON 路径（默认 /tmp/p0v-display-isolation.json）\n");
}

static BOOL P0VParseUnsigned(const char *s, NSUInteger *out) {
    if (!s || !*s) return NO;
    char *end = NULL;
    unsigned long v = strtoul(s, &end, 0);
    if (end == s || *end != '\0') return NO;
    *out = (NSUInteger)v;
    return YES;
}

static BOOL P0VParseInt(const char *s, int *out) {
    if (!s || !*s) return NO;
    char *end = NULL;
    long v = strtol(s, &end, 0);
    if (end == s || *end != '\0') return NO;
    *out = (int)v;
    return YES;
}

static BOOL P0VParseSpec(NSString *spec, NSUInteger *w, NSUInteger *h) {
    NSArray<NSString *> *parts = [spec componentsSeparatedByString:@"x"];
    if (parts.count != 2) return NO;
    NSUInteger a = 0, b = 0;
    if (!P0VParseUnsigned(parts[0].UTF8String, &a)) return NO;
    if (!P0VParseUnsigned(parts[1].UTF8String, &b)) return NO;
    if (a < 320 || b < 240 || a > 7680 || b > 4320) return NO;
    *w = a;
    *h = b;
    return YES;
}

static BOOL P0VWaitUntil(int timeoutMs, BOOL (^predicate)(void), NSArray<NSNumber *> **lastIDs) {
    int elapsed = 0;
    NSArray *last = nil;
    while (elapsed <= timeoutMs) {
        if (gCancelRequested) break;
        if (predicate()) {
            if (lastIDs) *lastIDs = last ?: P0VActiveDisplayIDs();
            return YES;
        }
        last = P0VActiveDisplayIDs();
        P0SleepMs(200);
        elapsed += 200;
    }
    if (lastIDs) *lastIDs = last ?: P0VActiveDisplayIDs();
    return NO;
}

static CGRect P0VUnionBounds(NSArray<NSNumber *> *displayIDs) {
    CGRect u = CGRectNull;
    for (NSNumber *num in displayIDs) u = CGRectUnion(u, CGDisplayBounds(num.unsignedIntValue));
    return u;
}

static CGPoint P0VCursorLocation(void) {
    CGEventRef event = CGEventCreate(NULL);
    CGPoint p = event ? CGEventGetLocation(event) : CGPointZero;
    if (event) CFRelease(event);
    return p;
}

static NSDictionary *P0VCaptureDisplays(NSArray<NSNumber *> *displayIDs, int durationMs) {
    NSMutableArray *rows = [NSMutableArray array];
    BOOL allContent = displayIDs.count > 0;
    for (NSNumber *num in displayIDs) {
        if (gCancelRequested) break;
        NSDictionary *capture = [PipelineProbe captureDisplayID:num.unsignedIntValue
                                                    durationMs:durationMs
                                                   withEncoder:NO];
        [rows addObject:capture];
        if (![capture[@"verdict"] isEqualToString:@"HAS_CONTENT"]) allContent = NO;
    }
    return @{ @"rows": rows, @"allHasContent": @(allContent) };
}

#pragma mark - 指针 / 输入

static BOOL P0VPointInAnyDisplay(CGPoint p, NSArray<NSNumber *> *ids) {
    for (NSNumber *n in ids) {
        if (CGRectContainsPoint(CGDisplayBounds(n.unsignedIntValue), p)) return YES;
    }
    return NO;
}

// 逐块 active 屏采样，而不是取多屏并集的外接矩形四角。并集四角在 L 形/错位布局里
// 可能是没有显示的空白区，系统会把指针钳制到最近的有效屏，造成“偏差”假阳性
// （2026-11-17 V-01：并集左上角 {1,-384} 在主屏上方，被钳到 {1,0}）。
// 真正要断言的是：落点始终在当前屏内，且绝不落进任何被禁用屏的矩形。
static NSDictionary *P0VPointerCheck(NSArray<NSNumber *> *disabledIDs) {
    NSArray<NSNumber *> *active = P0VActiveDisplayIDs();
    if (active.count == 0) {
        return @{ @"ok": @NO, @"error": @"没有 active display" };
    }
    CGRect u = P0VUnionBounds(active);

    NSMutableArray *rows = [NSMutableArray array];
    NSMutableArray *activeBounds = [NSMutableArray array];
    for (NSNumber *n in active) {
        [activeBounds addObject:@{ @"displayID": n, @"bounds": P0RectString(CGDisplayBounds(n.unsignedIntValue)) }];
    }
    NSMutableArray *disabledBounds = [NSMutableArray array];
    for (NSNumber *n in disabledIDs) {
        [disabledBounds addObject:@{ @"displayID": n, @"bounds": P0RectString(CGDisplayBounds(n.unsignedIntValue)) }];
    }

    BOOL allOK = YES;
    BOOL landedOnDisabled = NO;
    double maxDeviation = 0;
    for (NSNumber *num in active) {
        if (gCancelRequested) break;
        CGDirectDisplayID did = num.unsignedIntValue;
        CGRect r = CGDisplayBounds(did);
        if (CGRectIsEmpty(r)) continue;
        CGFloat minX = CGRectGetMinX(r), minY = CGRectGetMinY(r);
        CGFloat maxX = CGRectGetMaxX(r), maxY = CGRectGetMaxY(r);
        if (maxX - minX < 2 || maxY - minY < 2) continue;
        CGPoint points[5] = {
            { minX + 1, minY + 1 },
            { maxX - 1, minY + 1 },
            { minX + 1, maxY - 1 },
            { maxX - 1, maxY - 1 },
            { CGRectGetMidX(r), CGRectGetMidY(r) },
        };
        for (int i = 0; i < 5; i++) {
            if (gCancelRequested) break;
            CGPoint target = points[i];
            CGWarpMouseCursorPosition(target);
            P0SleepMs(120);
            CGPoint landed = P0VCursorLocation();
            double dev = hypot(landed.x - target.x, landed.y - target.y);
            BOOL onSame = CGRectContainsPoint(r, landed);
            BOOL onDisabled = P0VPointInAnyDisplay(landed, disabledIDs);
            if (!onSame || dev > 1.0) allOK = NO;
            if (onDisabled) { allOK = NO; landedOnDisabled = YES; }
            if (dev > maxDeviation) maxDeviation = dev;
            [rows addObject:@{
                @"displayID": @(did),
                @"target": [NSString stringWithFormat:@"%.1f,%.1f", target.x, target.y],
                @"landed": [NSString stringWithFormat:@"%.1f,%.1f", landed.x, landed.y],
                @"deviation": @(dev),
                @"onSameDisplay": @(onSame),
                @"onDisabledDisplay": @(onDisabled),
            }];
        }
    }

    return @{
        @"ok": @(allOK),
        @"maxDeviation": @(maxDeviation),
        @"landedOnDisabledDisplay": @(landedOnDisabled),
        @"union": P0RectString(u),
        @"activeBounds": activeBounds,
        @"disabledBounds": disabledBounds,
        @"points": rows,
    };
}

static NSDictionary *P0VInputCheck(NSArray<NSNumber *> *disabledIDs) {
    NSArray<NSNumber *> *active = P0VActiveDisplayIDs();
    CGRect u = P0VUnionBounds(active);
    if (CGRectIsNull(u) || CGRectIsEmpty(u)) {
        return @{ @"ok": @NO, @"error": @"没有 active display 的并集" };
    }

    CGPoint start = CGPointMake(CGRectGetMinX(u) + 2, CGRectGetMinY(u) + 2);
    CGWarpMouseCursorPosition(start);
    P0SleepMs(100);

    CGPoint target = CGPointMake(CGRectGetMidX(u) + 20, CGRectGetMidY(u) + 20);
    CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, target, kCGMouseButtonLeft);
    if (!move) return @{ @"ok": @NO, @"error": @"CGEventCreateMouseEvent 返回 NULL" };
    CGEventPost(kCGHIDEventTap, move);
    CFRelease(move);
    P0SleepMs(200);

    CGPoint landed = P0VCursorLocation();
    double dev = hypot(landed.x - target.x, landed.y - target.y);
    double moved = hypot(landed.x - start.x, landed.y - start.y);
    BOOL contained = P0VPointInAnyDisplay(landed, active);
    BOOL onDisabled = P0VPointInAnyDisplay(landed, disabledIDs);
    return @{
        @"ok": @(contained && !onDisabled && moved > 1.0),
        @"target": [NSString stringWithFormat:@"%.1f,%.1f", target.x, target.y],
        @"landed": [NSString stringWithFormat:@"%.1f,%.1f", landed.x, landed.y],
        @"deviation": @(dev),
        @"movedDistance": @(moved),
        @"contained": @(contained),
        @"onDisabledDisplay": @(onDisabled),
        @"axTrusted": @(AXIsProcessTrusted()),
        @"note": @"若 movedDistance≈0，先检查 Terminal/iTerm 是否已获「辅助功能」授权",
    };
}

#pragma mark - 虚拟屏

static NSArray<NSDictionary *> *P0VVirtualConfigs(P0VOptions *opt) {
    NSMutableArray *configs = [NSMutableArray array];
    for (NSUInteger i = 0; i < opt.count; i++) {
        [configs addObject:@{
            @"width": @(opt.width),
            @"height": @(opt.height),
            @"hiDPI": @(opt.hiDPI ? 1 : 0),
            @"refreshRate": @60,
            @"name": [NSString stringWithFormat:@"P0V-V-01-%lu", (unsigned long)i + 1],
        }];
    }
    return configs;
}

static VDManager *P0VCreateVirtualDisplays(NSArray<NSDictionary *> *configs,
                                           uint32_t identityOffset,
                                           NSError **error) {
    NSDictionary *policy = P0OSPolicy();
    BOOL conservative = [policy[@"conservativeFirst"] boolValue];
    int modeWaitMs = [policy[@"modeWaitMs"] intValue];

    VDManager *mgr = [[VDManager alloc] initWithConfigs:configs
                                         identityOffset:identityOffset
                                      conservativeFirst:conservative];
    if (![mgr createAll]) {
        if (mgr.windowServerHung) P0VMarkWindowServerHung();
        if (error) *error = [NSError errorWithDomain:@"P0V" code:30
            userInfo:@{NSLocalizedDescriptionKey: @"虚拟屏 createAll 失败"}];
        return nil;
    }
    if (![mgr waitUntilUsableTimeoutMs:10000]) {
        if (mgr.windowServerHung) P0VMarkWindowServerHung();
        if (error) *error = [NSError errorWithDomain:@"P0V" code:31
            userInfo:@{NSLocalizedDescriptionKey: @"虚拟屏 10s 内未 usable"}];
        [mgr destroyAll];
        return nil;
    }
    if (![mgr waitUntilModeMatchesTimeoutMs:modeWaitMs conservative:conservative]) {
        if (mgr.windowServerHung) P0VMarkWindowServerHung();
        if (error) *error = [NSError errorWithDomain:@"P0V" code:32
            userInfo:@{NSLocalizedDescriptionKey: @"虚拟屏 mode 未在死线内提交"}];
        [mgr destroyAll];
        return nil;
    }
    if (conservative && ![mgr promoteToTarget]) {
        if (mgr.windowServerHung) P0VMarkWindowServerHung();
        if (error) *error = [NSError errorWithDomain:@"P0V" code:33
            userInfo:@{NSLocalizedDescriptionKey: @"虚拟屏 promote 到目标分辨率失败"}];
        [mgr destroyAll];
        return nil;
    }
    if (conservative && ![mgr waitUntilModeMatchesTimeoutMs:modeWaitMs conservative:NO]) {
        if (mgr.windowServerHung) P0VMarkWindowServerHung();
        if (error) *error = [NSError errorWithDomain:@"P0V" code:34
            userInfo:@{NSLocalizedDescriptionKey: @"虚拟屏 promote 后 mode 未落地"}];
        [mgr destroyAll];
        return nil;
    }

    NSArray *seen = nil;
    if (![PipelineProbe waitForDisplayIDs:mgr.displayIDs timeoutMs:10000 lastSeen:&seen]) {
        if (mgr.windowServerHung) P0VMarkWindowServerHung();
        if (error) *error = [NSError errorWithDomain:@"P0V" code:35
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"虚拟屏未出现在 SCShareableContent（lastSeen=%@）", seen]}];
        [mgr destroyAll];
        return nil;
    }
    return mgr;
}

#pragma mark - 守护观察

static NSDictionary *P0VWatch(NSArray<NSNumber *> *targets,
                              NSArray<NSNumber *> *virtualIDs,
                              int seconds,
                              BOOL reassert,
                              P0VCommitScope scope,
                              int timeoutSec) {
    if (seconds <= 0) {
        return @{ @"seconds": @0, @"skipped": @YES,
                  @"reenableEvents": @[], @"virtualLost": @[] };
    }

    P0Log(@"观察 %d 秒：请现在按键盘、滑触控板、按 Touch ID，验证系统会不会把物理屏重新 enable", seconds);
    NSMutableArray *reenableEvents = [NSMutableArray array];
    NSMutableArray *virtualLost = [NSMutableArray array];
    NSMutableArray *reasserts = [NSMutableArray array];
    NSSet *last = [NSSet setWithArray:P0VActiveDisplayIDs()];
    double started = [[NSDate date] timeIntervalSince1970];
    double deadline = started + seconds;
    int lastNotice = 0;

    while ([[NSDate date] timeIntervalSince1970] < deadline) {
        if (gCancelRequested) break;
        NSArray *active = P0VActiveDisplayIDs();
        NSSet *cur = [NSSet setWithArray:active];

        NSMutableArray *newlyVisible = [NSMutableArray array];
        for (NSNumber *t in targets) {
            if (![last containsObject:t] && [cur containsObject:t]) {
                [newlyVisible addObject:t];
                CGRect b = CGDisplayBounds(t.unsignedIntValue);
                [reenableEvents addObject:@{
                    @"atSec": @([[NSDate date] timeIntervalSince1970] - started),
                    @"displayID": t,
                    @"bounds": P0RectString(b),
                    @"main": @(CGDisplayIsMain(t.unsignedIntValue)),
                }];
                P0Error(@"物理屏 %@ 在观察期内重新出现在 active list", t);
            }
        }
        for (NSNumber *vd in virtualIDs) {
            if (![cur containsObject:vd]) {
                BOOL known = NO;
                for (NSNumber *existing in virtualLost) if ([existing isEqual:vd]) known = YES;
                if (!known) {
                    [virtualLost addObject:vd];
                    P0Error(@"虚拟屏 %@ 在观察期内从 active list 消失", vd);
                }
            }
        }

        if (reassert && newlyVisible.count > 0) {
            NSDictionary *detail = nil;
            NSError *err = nil;
            BOOL ok = P0VApplyDisplayEnabledChanges(newlyVisible, @[], scope, timeoutSec, &detail, &err);
            [reasserts addObject:@{ @"displayIDs": newlyVisible, @"ok": @(ok),
                                    @"error": err.localizedDescription ?: @"",
                                    @"detail": detail ?: @{} }];
            if (P0VWindowServerHung()) break;
        }

        int elapsed = (int)([[NSDate date] timeIntervalSince1970] - started);
        if (elapsed / 5 > lastNotice) {
            lastNotice = elapsed / 5;
            P0Log(@"观察中 %d/%ds（重新出现 %lu 次，虚拟屏缺失 %lu 块）",
                  elapsed, seconds,
                  (unsigned long)reenableEvents.count, (unsigned long)virtualLost.count);
        }

        last = cur;
        P0SleepMs(300);
    }

    return @{
        @"seconds": @(seconds),
        @"skipped": @NO,
        @"cancelled": @(gCancelRequested ? YES : NO),
        @"reenableEvents": reenableEvents,
        @"virtualLost": virtualLost,
        @"reasserts": reasserts,
    };
}

#pragma mark - 重建测试（V-03）

static NSDictionary *P0VRebuildTest(void) {
    NSDictionary *config = @{
        @"width": @1280, @"height": @720, @"hiDPI": @0,
        @"refreshRate": @60, @"name": @"P0V-V-03-rebuild",
    };
    // 换一段 identity，避免与主虚拟屏的 vendor/product/serial 撞车。
    uint32_t offset = [VDManager savedIdentityOffset] + 1000;
    NSError *err = nil;
    VDManager *mgr = P0VCreateVirtualDisplays(@[config], offset, &err);
    if (!mgr) {
        return @{ @"ok": @NO, @"error": err.localizedDescription ?: @"create failed" };
    }
    NSArray *ids = mgr.displayIDs;
    NSDictionary *captures = P0VCaptureDisplays(ids, 1000);
    BOOL ok = [captures[@"allHasContent"] boolValue];
    [mgr destroyAll];
    return @{
        @"ok": @(ok),
        @"displayIDs": ids,
        @"captures": captures,
    };
}

#pragma mark - 恢复

static BOOL P0VBoundsMatch(CGRect a, CGRect b, double tolerance) {
    return fabs(a.origin.x - b.origin.x) <= tolerance &&
           fabs(a.origin.y - b.origin.y) <= tolerance &&
           fabs(a.size.width - b.size.width) <= tolerance &&
           fabs(a.size.height - b.size.height) <= tolerance;
}

static NSDictionary *P0VRestoreAndVerify(P0VDisplaySnapshot *snapshot,
                                         VDManager *mgr,
                                         P0VCommitScope scope,
                                         int timeoutSec) {
    if (P0VWindowServerHung()) {
        return @{ @"ok": @NO, @"skipped": @"windowServerHung",
                  @"note": @"事务已判定挂起，探针不再发显示配置请求；守护进程会尝试恢复" };
    }

    NSDictionary *firstDetail = nil;
    NSError *firstError = nil;
    BOOL firstOK = P0VRestoreSnapshot(snapshot, scope, timeoutSec, &firstDetail, &firstError);

    NSArray *ids = [snapshot displayIDs];
    BOOL appeared = P0VWaitUntil(10000, ^BOOL{
        NSSet *active = [NSSet setWithArray:P0VActiveDisplayIDs()];
        for (NSNumber *n in ids) if (![active containsObject:n]) return NO;
        return YES;
    }, NULL);

    // 物理屏回来后再销毁虚拟屏：反过来做会短暂出现「零块可见屏」，
    // WindowServer 在那种状态下会自行重排，恢复结果更不可控。
    if (mgr) [mgr destroyAll];

    NSDictionary *finalDetail = nil;
    NSError *finalError = nil;
    BOOL finalOK = NO;
    if (!P0VWindowServerHung()) {
        finalOK = P0VRestoreSnapshot(snapshot, scope, timeoutSec, &finalDetail, &finalError);
    }

    BOOL finalAppeared = P0VWaitUntil(10000, ^BOOL{
        NSSet *active = [NSSet setWithArray:P0VActiveDisplayIDs()];
        for (NSNumber *n in ids) if (![active containsObject:n]) return NO;
        return YES;
    }, NULL);

    NSSet *activeSet = [NSSet setWithArray:P0VActiveDisplayIDs()];
    NSMutableArray *mismatches = [NSMutableArray array];
    BOOL boundsOK = YES;
    BOOL mainOK = YES;
    for (P0VDisplayRecord *r in snapshot.displays) {
        if (![activeSet containsObject:@(r.displayID)]) {
            boundsOK = NO;
            [mismatches addObject:@{ @"displayID": @(r.displayID), @"issue": @"not-active" }];
            continue;
        }
        CGRect now = CGDisplayBounds(r.displayID);
        if (!P0VBoundsMatch(now, r.bounds, 1.0)) {
            boundsOK = NO;
            [mismatches addObject:@{
                @"displayID": @(r.displayID),
                @"issue": @"bounds-differ",
                @"expected": P0RectString(r.bounds),
                @"actual": P0RectString(now),
            }];
        }
        if (r.isMain && !CGDisplayIsMain(r.displayID)) {
            mainOK = NO;
            [mismatches addObject:@{ @"displayID": @(r.displayID), @"issue": @"lost-main" }];
        }
    }

    BOOL ok = firstOK && finalOK && appeared && finalAppeared && boundsOK && mainOK;
    return @{
        @"ok": @(ok),
        @"firstCommitOK": @(firstOK),
        @"finalCommitOK": @(finalOK),
        @"allIDsActive": @(appeared && finalAppeared),
        @"boundsMatch": @(boundsOK),
        @"mainMatch": @(mainOK),
        @"mismatches": mismatches,
        @"firstError": firstError.localizedDescription ?: @"",
        @"finalError": finalError.localizedDescription ?: @"",
        @"firstDetail": firstDetail ?: @{},
        @"finalDetail": finalDetail ?: @{},
        @"activeIDs": P0VActiveDisplayIDs(),
        @"snapshotIDs": ids,
    };
}

#pragma mark - probe

// CGEventPost 到 HID 需要「辅助功能」授权；命令行工具的 TCC 归属是父进程。
// 不把这个字段放进结果里，输入失败时无法区分「权限缺失」和「注入路径错误」。
static NSDictionary *P0VSystemInfo(void) {
    NSMutableDictionary *d = [P0SystemInfo() mutableCopy];
    d[@"axTrusted"] = @(AXIsProcessTrusted());
    return d;
}

static int P0VCommandProbe(void) {
    NSDictionary *sys = P0VSystemInfo();
    NSArray *active = P0VActiveDisplayIDs();
    NSArray *online = P0VOnlineDisplayIDs();
    NSArray *sls = P0VAllDisplayIDsFromSkyLight();
    P0VDisplaySnapshot *snap = [P0VDisplaySnapshot captureActive];
    NSError *sckError = nil;
    NSArray *sck = [PipelineProbe shareableDisplayIDsWithError:&sckError];

    printf("=== 环境 ===\n");
    printf("  %s %s / %s / %s\n",
           [sys[@"osVersion"] UTF8String], [sys[@"arch"] UTF8String],
           [sys[@"model"] UTF8String], [sys[@"cpuBrand"] UTF8String]);
    printf("  uid=%s parent=%s GUI=%s AX=%s\n",
           [sys[@"uid"] description].UTF8String,
           [sys[@"parentApp"] UTF8String],
           [sys[@"isLoggedInGUI"] boolValue] ? "yes" : "no",
           [sys[@"axTrusted"] boolValue] ? "yes" : "no");
    printf("  私有 SLSConfigureDisplayEnabled: %s\n",
           P0VPrivateDisplayControlAvailable() ? "可解析" : "缺失");
    printf("  虚拟屏 vendor: 0x%x\n", 0x5030);

    printf("\n=== Active displays ===\n");
    for (NSDictionary *d in P0VDisplayDictionaries(active)) {
        printf("  id=%-12s bounds=%-22s main=%s points=%-10s pixels=%-10s vendor=0x%x\n",
               [d[@"displayID"] description].UTF8String,
               [d[@"bounds"] UTF8String],
               [d[@"main"] boolValue] ? "Y" : "N",
               [d[@"points"] UTF8String], [d[@"pixels"] UTF8String],
               [d[@"vendorID"] unsignedIntValue]);
    }
    printf("\n=== Online displays ===\n  %s\n",
           [[online componentsJoinedByString:@", "] UTF8String]);
    printf("=== SLSGetDisplayList（含被禁用项）===\n  %s\n",
           sls ? [[sls componentsJoinedByString:@", "] UTF8String] : "(symbol unavailable)");
    NSArray *staleSlots = P0VStaleVirtualSlotIDs();
    printf("=== 残留虚拟屏槽位 ===\n  %s\n",
           staleSlots.count ? [[staleSlots componentsJoinedByString:@", "] UTF8String] : "无");
    printf("=== SCShareableContent ===\n");
    if (sck) printf("  %s\n", [[sck componentsJoinedByString:@", "] UTF8String]);
    else printf("  失败: %s\n", [sckError.localizedDescription UTF8String]);

    NSMutableArray *snapRows = [NSMutableArray array];
    for (P0VDisplayRecord *r in snap.displays) [snapRows addObject:[r dictionaryRepresentation]];
    P0Emit(@"probe", @{
        @"os": sys,
        @"privateSymbols": @{ @"SLSConfigureDisplayEnabled": @(P0VPrivateDisplayControlAvailable()) },
        @"activeIDs": active,
        @"onlineIDs": online,
        @"slsIDs": sls ?: @[],
        @"staleSlotIDs": staleSlots,
        @"sckIDs": sck ?: @[],
        @"sckError": sckError.localizedDescription ?: @"",
        @"snapshot": snapRows,
    });
    return 0;
}

#pragma mark - snapshot

static int P0VCommandSnapshot(NSString *outPath) {
    P0VDisplaySnapshot *snap = [P0VDisplaySnapshot captureActive];
    NSError *err = nil;
    if (![snap writeToFile:outPath error:&err]) {
        P0Error(@"写快照失败: %@", err.localizedDescription);
        return 3;
    }
    printf("快照: %s\n", outPath.UTF8String);
    for (P0VDisplayRecord *r in snap.displays) {
        printf("  id=%-12u bounds=%-22s main=%s vendor=0x%x points=%zux%zu mirrorOf=%u\n",
               r.displayID, P0RectString(r.bounds).UTF8String, r.isMain ? "Y" : "N",
               r.vendorID, r.pointWidth, r.pointHeight, r.mirrorOf);
    }
    return 0;
}

#pragma mark - restore

static int P0VCommandRestore(NSString *snapshotPath, P0VCommitScope scope, int timeoutSec) {
    P0VDisplaySnapshot *snap = [P0VDisplaySnapshot loadFromFile:snapshotPath];
    if (!snap) {
        P0Error(@"无法读取快照: %@", snapshotPath);
        return 3;
    }
    printf("从快照恢复 %lu 块屏: %s\n", (unsigned long)snap.displays.count, snapshotPath.UTF8String);

    NSDictionary *detail = nil;
    NSError *err = nil;
    BOOL ok = P0VRestoreSnapshot(snap, scope, timeoutSec, &detail, &err);
    if (!ok) P0Error(@"恢复失败: %@", err.localizedDescription);

    BOOL allActive = P0VWaitUntil(10000, ^BOOL{
        NSSet *active = [NSSet setWithArray:P0VActiveDisplayIDs()];
        for (NSNumber *n in [snap displayIDs]) if (![active containsObject:n]) return NO;
        return YES;
    }, NULL);

    printf("恢复事务: %s；active: %s\n", ok ? "OK" : "FAIL", allActive ? "OK" : "MISSING");
    printf("  当前 active: %s\n", [[P0VActiveDisplayIDs() componentsJoinedByString:@", "] UTF8String]);
    printf("  快照 active: %s\n", [[[snap displayIDs] componentsJoinedByString:@", "] UTF8String]);
    return (ok && allActive) ? 0 : 2;
}

#pragma mark - run

static NSDictionary *P0VRunScenario(P0VOptions *opt, int *exitCode) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"command"] = @"run";
    result[@"version"] = @1;
    result[@"os"] = P0VSystemInfo();
    result[@"options"] = [opt dictionaryRepresentation];

    P0VDisplaySnapshot *snapshot = nil;
    NSString *snapshotPath = nil;
    VDManager *mgr = nil;
    BOOL displayedDisabled = NO;
    BOOL restored = NO;

    NSArray<NSNumber *> *virtualIDs = @[];
    NSArray<NSNumber *> *targets = @[];
    NSDictionary *verdict = @{ @"pass": @NO, @"label": @"ABORTED", @"reasons": @[@"未执行"] };

    do {
        if (gCancelRequested) { verdict = @{ @"pass": @NO, @"label": @"CANCELLED" }; break; }

        // 1. 前置检查
        if (!P0VPrivateDisplayControlAvailable()) {
            verdict = @{ @"pass": @NO, @"label": @"ABORTED",
                         @"reasons": @[@"SLSConfigureDisplayEnabled 不可用"] };
            break;
        }

        NSArray *active0 = P0VActiveDisplayIDs();
        NSMutableArray *physical = [NSMutableArray array];
        NSMutableArray *leftoverVirtual = [NSMutableArray array];
        for (NSNumber *num in active0) {
            CGDirectDisplayID did = num.unsignedIntValue;
            if (CGDisplayVendorNumber(did) == 0x5030) [leftoverVirtual addObject:num];
            else [physical addObject:num];
        }
        NSArray *staleSlots = P0VStaleVirtualSlotIDs();
        BOOL plannedRebuild = ([opt.mode isEqualToString:@"all"] && opt.rebuildTest && !opt.dryRun);
        BOOL rebuildSkippedForSlots = NO;
        if (staleSlots.count > 0) {
            P0Error(@"检测到 %lu 个 WindowServer 停放槽位: %@（vendor=0xFFFFFFFF / offline / 1x1）",
                    (unsigned long)staleSlots.count,
                    [staleSlots componentsJoinedByString:@", "]);
            P0Error(@"停放槽位由 WindowServer 持有，用户态没有按 displayID 注销的接口；"
                    @"CDVirtualDisplayDestroy 只接受创建进程内的 client，休眠/唤醒也不会回收离线槽位。"
                    @"它们不影响单块建屏，核心流程不需要为此重启。");
            // 2026-11-17 22:03 实测（Sequoia 15.5）：5 个停放槽位 + 全部物理屏已禁用时再建第 2 块
            // 虚拟屏，WindowServer 在 DisplaySet::create 的 canonical_mirror_master 断言处 SIGABRT。
            // 唯一不安全的就是这个「零物理屏下再建一块」子项；跳过它，V-03 核心可继续。
            if (plannedRebuild) {
                opt.rebuildTest = NO;
                rebuildSkippedForSlots = YES;
                P0Error(@"已跳过“零物理屏下再建一块”子项（该组合与停放槽位同时存在时会崩溃）；V-03 核心继续");
            }
            if (opt.count > 1 && !opt.allowStaleSlots) {
                NSString *staleText = [staleSlots componentsJoinedByString:@", "];
                verdict = @{ @"pass": @NO, @"label": @"ABORTED",
                             @"reasons": @[[NSString stringWithFormat:
                    @"停放槽位 %@：本次请求 %lu 块虚拟屏。多屏建屏与该状态组合尚未验证，可能触发 WindowServer 断言。"
                    @"可改为 --count 1 跑核心 V-03（不需要清槽位），或加 --allow-stale-slots 承担风险。",
                    staleText, (unsigned long)opt.count]] };
                break;
            }
        }
        result[@"preflight"] = @{
            @"activeIDs": active0,
            @"onlineIDs": P0VOnlineDisplayIDs(),
            @"slsIDs": P0VAllDisplayIDsFromSkyLight() ?: @[],
            @"physicalIDs": physical,
            @"leftoverP0VirtualIDs": leftoverVirtual,
            @"staleVirtualSlotIDs": staleSlots,
            @"rebuildSkippedForSlots": @(rebuildSkippedForSlots),
        };
        if (rebuildSkippedForSlots) {
            result[@"rebuildTest"] = @{
                @"ok": @YES,
                @"skipped": @"staleVirtualSlots",
                @"note": @"停放槽位存在时，零物理屏下再建一块虚拟屏会触发 WindowServer 断言；应改为在禁用物理屏之前建齐全部虚拟屏",
            };
        }
        if (physical.count == 0) {
            verdict = @{ @"pass": @NO, @"label": @"ABORTED",
                         @"reasons": @[@"没有可禁用的物理屏"] };
            break;
        }
        if (![P0SystemInfo()[@"isLoggedInGUI"] boolValue]) {
            P0Error(@"当前进程不在 GUI 会话内；显示配置很可能失败。请在已登录桌面的 Terminal 中运行");
        }

        // 2. 目标选择
        if (opt.target) {
            NSUInteger wanted = opt.target.unsignedIntegerValue;
            BOOL found = NO;
            for (NSNumber *n in physical) if (n.unsignedIntegerValue == wanted) found = YES;
            if (!found) {
                verdict = @{ @"pass": @NO, @"label": @"ABORTED",
                             @"reasons": @[[NSString stringWithFormat:@"--target %lu 不是 active 物理屏", (unsigned long)wanted]] };
                break;
            }
            targets = @[@(wanted)];
        } else if ([opt.mode isEqualToString:@"all"]) {
            targets = physical;
        } else {
            NSNumber *nonMain = nil;
            for (NSNumber *n in physical) {
                if (!CGDisplayIsMain(n.unsignedIntValue)) { nonMain = n; break; }
            }
            NSNumber *chosen = nonMain ?: physical.firstObject;
            targets = @[chosen];
            if (!nonMain) {
                P0Error(@"只有一块物理屏，禁用它就是 V-03 的极限情形；建议改用 --mode all 并接受黑屏风险");
            }
        }
        result[@"targets"] = targets;

        // 3. 交互确认
        if (!opt.yes) {
            if (!isatty(STDIN_FILENO)) {
                verdict = @{ @"pass": @NO, @"label": @"ABORTED",
                             @"reasons": @[@"非交互环境必须显式 --yes"] };
                break;
            }
            printf("\n=== V-01/V-03 显示隔离测试 ===\n");
            printf("  物理屏: %s\n", [[physical componentsJoinedByString:@", "] UTF8String]);
            printf("  将禁用: %s\n", [[targets componentsJoinedByString:@", "] UTF8String]);
            printf("  虚拟屏: %lu x %lux%lu%s\n",
                   (unsigned long)opt.count, (unsigned long)opt.width, (unsigned long)opt.height,
                   opt.hiDPI ? " (2x)" : "");
            printf("  commit: %s，事务死线: %ds，观察: %ds\n",
                   opt.scope == P0VCommitScopePermanent ? "permanent" : "session",
                   opt.commitTimeoutSec, opt.watchSecs);
            printf("  注意：会话期间的窗口重排不会自动还原（M1 工作项），请先保存工作。\n");
            printf("输入 YES 继续（其它任何输入=取消）: ");
            fflush(stdout);
            char buf[16] = {0};
            if (!fgets(buf, sizeof(buf), stdin)) {
                verdict = @{ @"pass": @NO, @"label": @"CANCELLED" };
                break;
            }
            NSString *answer = [[NSString stringWithUTF8String:buf]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (![answer isEqualToString:@"YES"]) {
                verdict = @{ @"pass": @NO, @"label": @"CANCELLED" };
                break;
            }
        }

        // 4. 快照 + 守护进程
        snapshot = [P0VDisplaySnapshot captureActive];
        snapshotPath = [NSString stringWithFormat:@"/tmp/p0v-display-snapshot-%d.json", getpid()];
        NSError *writeError = nil;
        if (![snapshot writeToFile:snapshotPath error:&writeError]) {
            verdict = @{ @"pass": @NO, @"label": @"ABORTED",
                         @"reasons": @[[NSString stringWithFormat:@"写快照失败: %@", writeError.localizedDescription]] };
            break;
        }
        [[NSFileManager defaultManager] removeItemAtPath:[snapshotPath stringByAppendingString:@".done"] error:NULL];
        result[@"snapshotPath"] = snapshotPath;
        NSMutableArray *snapRows = [NSMutableArray array];
        for (P0VDisplayRecord *r in snapshot.displays) [snapRows addObject:[r dictionaryRepresentation]];
        result[@"snapshot"] = snapRows;

        if (opt.useGuardian) {
            NSError *guardError = nil;
            BOOL guardOK = P0VStartGuardian(snapshotPath, getpid(), &guardError);
            result[@"guardian"] = @{ @"started": @(guardOK),
                                     @"error": guardError.localizedDescription ?: @"" };
            if (!guardOK) {
                P0Error(@"守护进程启动失败: %@。仍继续，但异常退出时无人兜底", guardError.localizedDescription);
            }
        } else {
            result[@"guardian"] = @{ @"started": @NO, @"note": @"--no-guardian" };
        }

        // 5. 建虚拟屏
        NSError *createError = nil;
        mgr = P0VCreateVirtualDisplays(P0VVirtualConfigs(opt),
                                       [VDManager savedIdentityOffset],
                                       &createError);
        if (!mgr) {
            verdict = @{ @"pass": @NO, @"label": @"ABORTED",
                         @"reasons": @[[NSString stringWithFormat:@"虚拟屏创建失败: %@", createError.localizedDescription]] };
            break;
        }
        virtualIDs = mgr.displayIDs;
        result[@"virtualDisplays"] = @{ @"displayIDs": virtualIDs,
                                        @"liveness": [mgr liveness] };
        P0Log(@"虚拟屏就绪: %@", [virtualIDs componentsJoinedByString:@", "]);

        // 6. 基线捕获（TCC 不通过就别进禁用阶段）
        NSDictionary *baselineCapture = P0VCaptureDisplays(virtualIDs, opt.captureMs);
        NSError *sckError = nil;
        NSArray *sckIDs = [PipelineProbe shareableDisplayIDsWithError:&sckError];
        result[@"baseline"] = @{
            @"captures": baselineCapture,
            @"sckIDs": sckIDs ?: @[],
            @"sckError": sckError.localizedDescription ?: @"",
            @"activeIDs": P0VActiveDisplayIDs(),
        };
        if (![baselineCapture[@"allHasContent"] boolValue]) {
            verdict = @{ @"pass": @NO, @"label": @"ABORTED",
                         @"reasons": @[@"基线捕获不是 HAS_CONTENT（先解决屏幕录制授权/TCC）"] };
            break;
        }

        if (opt.dryRun) {
            verdict = @{ @"pass": @NO, @"label": @"DRY_RUN",
                         @"reasons": @[@"已创建虚拟屏并取得 HAS_CONTENT 基线；按 --dry-run 未禁动物理屏"] };
            break;
        }

        // 7. 禁用
        P0Log(@"禁用物理屏: %@", [targets componentsJoinedByString:@", "]);
        displayedDisabled = YES;  // 事务可能超时后才迟到生效，先按「已变更」对待
        NSDictionary *disableDetail = nil;
        NSError *disableError = nil;
        BOOL commitOK = P0VApplyDisplayEnabledChanges(targets, @[], opt.scope,
                                                      opt.commitTimeoutSec, &disableDetail, &disableError);
        if (P0VWindowServerHung()) {
            result[@"disable"] = @{ @"targets": targets, @"commitOK": @NO,
                                    @"hung": @YES, @"detail": disableDetail ?: @{} };
            verdict = @{ @"pass": @NO, @"label": @"WINDOWSERVER_HUNG",
                         @"reasons": @[@"显示配置事务超时；已停止后续操作，守护进程将尝试恢复"] };
            break;
        }

        NSArray *activeAfter = nil;
        BOOL removed = P0VWaitUntil(5000, ^BOOL{
            NSSet *active = [NSSet setWithArray:P0VActiveDisplayIDs()];
            for (NSNumber *t in targets) if ([active containsObject:t]) return NO;
            return YES;
        }, &activeAfter);

        NSMutableArray *stillActive = [NSMutableArray array];
        NSMutableArray *stillOnline = [NSMutableArray array];
        NSMutableArray *slsStill = [NSMutableArray array];
        NSSet *activeSet = [NSSet setWithArray:P0VActiveDisplayIDs()];
        NSSet *onlineSet = [NSSet setWithArray:P0VOnlineDisplayIDs()];
        NSSet *slsSet = [NSSet setWithArray:P0VAllDisplayIDsFromSkyLight() ?: @[]];
        for (NSNumber *t in targets) {
            if ([activeSet containsObject:t]) [stillActive addObject:t];
            if ([onlineSet containsObject:t]) [stillOnline addObject:t];
            if ([slsSet containsObject:t]) [slsStill addObject:t];
        }

        NSError *sckAfterError = nil;
        NSArray *sckAfter = [PipelineProbe shareableDisplayIDsWithError:&sckAfterError] ?: @[];
        NSSet *sckSet = [NSSet setWithArray:sckAfter];
        NSMutableArray *sckStillShows = [NSMutableArray array];
        for (NSNumber *t in targets) if ([sckSet containsObject:t]) [sckStillShows addObject:t];

        BOOL vdActive = YES;
        for (NSNumber *vd in virtualIDs) if (![activeSet containsObject:vd]) vdActive = NO;
        NSDictionary *duringCapture = @{ @"rows": @[], @"allHasContent": @NO };
        if (!gCancelRequested) duringCapture = P0VCaptureDisplays(virtualIDs, opt.captureMs);
        NSDictionary *pointer = gCancelRequested ? @{ @"ok": @NO, @"skipped": @YES } : P0VPointerCheck(targets);
        NSDictionary *input = gCancelRequested ? @{ @"ok": @NO, @"skipped": @YES } : P0VInputCheck(targets);

        BOOL activeSetEqualsVirtual = NO;
        if ([opt.mode isEqualToString:@"all"]) {
            activeSetEqualsVirtual = (activeSet.count == virtualIDs.count) &&
                                     [activeSet isEqualToSet:[NSSet setWithArray:virtualIDs]];
        } else {
            NSMutableSet *expected = [NSMutableSet setWithArray:virtualIDs];
            for (NSNumber *n in physical) if (![targets containsObject:n]) [expected addObject:n];
            activeSetEqualsVirtual = [activeSet isEqualToSet:expected];
        }

        result[@"disable"] = @{
            @"targets": targets,
            @"commitOK": @(commitOK),
            @"commitScope": opt.scope == P0VCommitScopePermanent ? @"permanent" : @"session",
            @"detail": disableDetail ?: @{},
            @"error": disableError.localizedDescription ?: @"",
            @"removedFromActive": @(removed),
            @"stillActive": stillActive,
            @"stillOnline": stillOnline,
            @"slsStillLists": slsStill,
            @"sckStillShows": sckStillShows,
            @"sckError": sckAfterError.localizedDescription ?: @"",
        };
        result[@"during"] = @{
            @"activeIDs": P0VActiveDisplayIDs(),
            @"onlineIDs": P0VOnlineDisplayIDs(),
            @"slsIDs": P0VAllDisplayIDsFromSkyLight() ?: @[],
            @"virtualActive": @(vdActive),
            @"activeSetMatchesExpected": @(activeSetEqualsVirtual),
            @"captures": duringCapture,
            @"pointer": pointer,
            @"input": input,
        };

        if (gCancelRequested) {
            verdict = @{ @"pass": @NO, @"label": @"CANCELLED" };
            break;
        }

        // 8. 唤醒观察
        result[@"watch"] = P0VWatch(targets, virtualIDs, opt.watchSecs,
                                    opt.reassert, opt.scope, opt.commitTimeoutSec);
        if (P0VWindowServerHung()) {
            verdict = @{ @"pass": @NO, @"label": @"WINDOWSERVER_HUNG",
                         @"reasons": @[@"观察期内的再次禁用事务超时"] };
            break;
        }

        // 9. V-03 重建测试
        if ([opt.mode isEqualToString:@"all"] && opt.rebuildTest && !gCancelRequested) {
            result[@"rebuildTest"] = P0VRebuildTest();
        }

        // 10. 判定
        NSArray *watchEvents = result[@"watch"][@"reenableEvents"] ?: @[];
        NSArray *virtualLost = result[@"watch"][@"virtualLost"] ?: @[];
        BOOL wakeTestRan = opt.watchSecs > 0 && ![result[@"watch"][@"skipped"] boolValue];
        BOOL disableEffective = removed && stillActive.count == 0;
        BOOL vdCaptureOK = [duringCapture[@"allHasContent"] boolValue] && vdActive;
        BOOL sckClean = sckStillShows.count == 0;
        BOOL pointerOK = [pointer[@"ok"] boolValue];
        BOOL inputOK = [input[@"ok"] boolValue];
        BOOL noReenable = wakeTestRan ? (watchEvents.count == 0 && virtualLost.count == 0) : YES;
        BOOL rebuildPlanned = [opt.mode isEqualToString:@"all"] && opt.rebuildTest;
        BOOL rebuildSkipped = result[@"rebuildTest"][@"skipped"] != nil;
        BOOL rebuildTested = rebuildPlanned && !rebuildSkipped;
        BOOL rebuildOK = rebuildTested ? [result[@"rebuildTest"][@"ok"] boolValue] : YES;

        NSMutableArray *reasons = [NSMutableArray array];
        if (!disableEffective) [reasons addObject:@"SLS_DISABLE_NO_EFFECT：目标屏仍在 active list"];
        if (!vdCaptureOK) [reasons addObject:@"虚拟屏捕获失败或不在 active list"];
        if (!sckClean) [reasons addObject:@"被禁用的物理屏仍出现在 SCShareableContent"];
        if (!pointerOK) [reasons addObject:@"指针落点越出当前 active 屏或落入被禁用屏"];
        if (!inputOK) [reasons addObject:@"输入事件未落到虚拟屏并集（可能缺辅助功能授权）"];
        if (!noReenable) [reasons addObject:@"观察期内物理屏被重新 enable 或虚拟屏丢失"];
        if (!rebuildOK) [reasons addObject:@"只剩虚拟屏时无法再建屏/捕获"];
        if (!activeSetEqualsVirtual) [reasons addObject:@"active display 集合与预期不符（空间未完全收缩）"];

        BOOL pass = disableEffective && vdCaptureOK && sckClean && pointerOK &&
                    inputOK && noReenable && rebuildOK && activeSetEqualsVirtual;
        NSString *label = pass ? (wakeTestRan ? @"PASS" : @"PASS_NO_WAKE_TEST") : @"FAIL";
        verdict = @{
            @"pass": @(pass),
            @"label": label,
            @"mode": opt.mode,
            @"disableEffective": @(disableEffective),
            @"virtualCapture": @(vdCaptureOK),
            @"sckClean": @(sckClean),
            @"pointerContained": @(pointerOK),
            @"inputInjected": @(inputOK),
            @"noReenable": @(noReenable),
            @"wakeTestRan": @(wakeTestRan),
            @"rebuildOK": @(rebuildOK),
            @"rebuildTested": @(rebuildTested),
            @"activeSetMatchesExpected": @(activeSetEqualsVirtual),
            @"reasons": reasons,
        };
    } while (0);

    // 收尾：无论成功失败，只要可能动过显示就恢复
    if (displayedDisabled) {
        NSDictionary *restore = P0VRestoreAndVerify(snapshot, mgr, opt.scope, opt.commitTimeoutSec);
        result[@"restore"] = restore;
        restored = [restore[@"ok"] boolValue];
        if (restored && snapshotPath) {
            NSString *donePath = [snapshotPath stringByAppendingString:@".done"];
            [@"restored" writeToFile:donePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
        if (!restored) {
            NSMutableArray *reasons = [verdict[@"reasons"] mutableCopy] ?: [NSMutableArray array];
            [reasons addObject:@"恢复失败：请看 restore 明细并用 restore 子命令手动恢复"];
            verdict = @{ @"pass": @NO, @"label": @"RESTORE_FAILED",
                         @"reasons": reasons,
                         @"previousLabel": verdict[@"label"] ?: @"" };
        }
    } else {
        if (mgr) [mgr destroyAll];
        result[@"restore"] = @{ @"ok": @YES, @"note": @"未进入禁用阶段，仅销毁虚拟屏" };
        restored = YES;
        // 没动过物理屏，通知守护进程不必兜底恢复。
        if (snapshotPath) {
            NSString *donePath = [snapshotPath stringByAppendingString:@".done"];
            [@"no-display-change" writeToFile:donePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
    }

    result[@"verdict"] = verdict;

    // 人读摘要
    printf("\n=== 结果 ===\n");
    printf("  场景: %s（禁用一个=%s，禁用全部=%s）\n",
           [opt.mode UTF8String],
           [opt.mode isEqualToString:@"one"] ? "是" : "否",
           [opt.mode isEqualToString:@"all"] ? "是" : "否");
    printf("  判定: %s\n", [verdict[@"label"] UTF8String]);
    NSArray *reasons = verdict[@"reasons"];
    for (NSString *r in reasons) printf("    - %s\n", r.UTF8String);
    if (result[@"restore"]) {
        printf("  恢复: %s\n", [result[@"restore"][@"ok"] boolValue] ? "OK" : "FAIL");
    }
    printf("  结果 JSON: %s\n", opt.outPath.UTF8String);
    if (snapshotPath) printf("  快照: %s\n", snapshotPath.UTF8String);

    NSError *writeError = nil;
    if (!P0WriteJSON(result, opt.outPath, &writeError)) {
        P0Error(@"写结果失败: %@", writeError.localizedDescription);
    }

    if (!restored && displayedDisabled) *exitCode = 2;
    else if ([verdict[@"pass"] boolValue]) *exitCode = 0;
    else *exitCode = 1;
    return result;
}

#pragma mark - 选项解析

static BOOL P0VParseRunOptions(int argc, const char **argv, P0VOptions *opt) {
    for (int i = 2; i < argc; i++) {
        const char *a = argv[i];
        const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;
        if (!strcmp(a, "--mode") && v) {
            NSString *m = [NSString stringWithUTF8String:v];
            if (![m isEqualToString:@"one"] && ![m isEqualToString:@"all"]) {
                P0Error(@"--mode 只接受 one|all");
                return NO;
            }
            opt.mode = m; i++;
        } else if (!strcmp(a, "--target") && v) {
            NSUInteger n = 0;
            if (!P0VParseUnsigned(v, &n)) return NO;
            opt.target = @(n); i++;
        } else if (!strcmp(a, "--spec") && v) {
            NSUInteger w = 0, h = 0;
            if (!P0VParseSpec([NSString stringWithUTF8String:v], &w, &h)) {
                P0Error(@"--spec 需形如 1920x1080");
                return NO;
            }
            opt.width = w; opt.height = h; i++;
        } else if (!strcmp(a, "--hidpi")) {
            opt.hiDPI = YES;
        } else if (!strcmp(a, "--count") && v) {
            NSUInteger n = 0;
            if (!P0VParseUnsigned(v, &n) || n < 1 || n > 4) return NO;
            opt.count = n; i++;
        } else if (!strcmp(a, "--watch-secs") && v) {
            int n = 0;
            if (!P0VParseInt(v, &n) || n < 0) return NO;
            opt.watchSecs = n; i++;
        } else if (!strcmp(a, "--commit-timeout") && v) {
            int n = 0;
            if (!P0VParseInt(v, &n) || n < 5) return NO;
            opt.commitTimeoutSec = n; i++;
        } else if (!strcmp(a, "--capture-ms") && v) {
            int n = 0;
            if (!P0VParseInt(v, &n) || n < 300) return NO;
            opt.captureMs = n; i++;
        } else if (!strcmp(a, "--commit") && v) {
            NSString *s = [NSString stringWithUTF8String:v];
            if ([s isEqualToString:@"permanent"]) opt.scope = P0VCommitScopePermanent;
            else if ([s isEqualToString:@"session"]) opt.scope = P0VCommitScopeSession;
            else return NO;
            i++;
        } else if (!strcmp(a, "--reassert")) {
            opt.reassert = YES;
        } else if (!strcmp(a, "--dry-run")) {
            opt.dryRun = YES;
        } else if (!strcmp(a, "--no-rebuild-test")) {
            opt.rebuildTest = NO;
        } else if (!strcmp(a, "--allow-stale-slots")) {
            opt.allowStaleSlots = YES;
        } else if (!strcmp(a, "--no-guardian")) {
            opt.useGuardian = NO;
        } else if (!strcmp(a, "--yes")) {
            opt.yes = YES;
        } else if (!strcmp(a, "--out") && v) {
            opt.outPath = [NSString stringWithUTF8String:v]; i++;
        } else {
            P0Error(@"未知参数: %s", a);
            return NO;
        }
    }
    return YES;
}

#pragma mark - main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // 守护模式最先处理，不能走正常初始化。
        if (argc >= 2 && !strcmp(argv[1], "--guardian")) {
            NSString *snapPath = (argc >= 3) ? [NSString stringWithUTF8String:argv[2]] : nil;
            pid_t parent = 0;
            for (int i = 3; i + 1 < argc; i++) {
                if (!strcmp(argv[i], "--parent-pid")) parent = (pid_t)atoi(argv[i + 1]);
            }
            if (!snapPath || parent <= 0) {
                P0Error(@"--guardian 需要 <snapshot> --parent-pid N");
                return 3;
            }
            return P0VRunGuardian(snapPath, parent);
        }

        if (argc < 2) { P0VUsage(); return 3; }
        NSString *cmd = [NSString stringWithUTF8String:argv[1]];

        if ([cmd isEqualToString:@"probe"]) return P0VCommandProbe();
        if ([cmd isEqualToString:@"snapshot"]) {
            NSString *out = @"/tmp/p0v-display-snapshot.json";
            for (int i = 2; i + 1 < argc; i++) {
                if (!strcmp(argv[i], "--out")) out = [NSString stringWithUTF8String:argv[i + 1]];
            }
            return P0VCommandSnapshot(out);
        }
        if ([cmd isEqualToString:@"restore"]) {
            NSString *path = nil;
            P0VCommitScope scope = P0VCommitScopeSession;
            int timeout = 20;
            for (int i = 2; i < argc; i++) {
                if (!strcmp(argv[i], "--snapshot") && i + 1 < argc) path = [NSString stringWithUTF8String:argv[++i]];
                else if (!strcmp(argv[i], "--commit") && i + 1 < argc) {
                    scope = !strcmp(argv[++i], "permanent") ? P0VCommitScopePermanent : P0VCommitScopeSession;
                } else if (!strcmp(argv[i], "--commit-timeout") && i + 1 < argc) {
                    timeout = atoi(argv[++i]);
                }
            }
            if (!path) { P0VUsage(); return 3; }
            return P0VCommandRestore(path, scope, timeout);
        }
        if ([cmd isEqualToString:@"run"]) {
            P0VOptions *opt = [[P0VOptions alloc] init];
            if (!P0VParseRunOptions(argc, argv, opt)) { P0VUsage(); return 3; }

            signal(SIGINT, P0VSignalHandler);
            signal(SIGTERM, P0VSignalHandler);
            signal(SIGHUP, P0VSignalHandler);
            P0VResetWindowServerHung();

            int exitCode = 1;
            (void)P0VRunScenario(opt, &exitCode);
            return exitCode;
        }

        P0VUsage();
        return 3;
    }
}
