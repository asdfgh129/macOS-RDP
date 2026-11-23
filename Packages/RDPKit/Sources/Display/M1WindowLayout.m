//
//  M1WindowLayout.m
//  M1-Skeleton
//

#import "M1WindowLayout.h"
#import <ApplicationServices/ApplicationServices.h>
#import <math.h>
#import <unistd.h>

NSString * const M1WindowLayoutErrorDomain = @"M1WindowLayout";

static NSError *M1WLErr(M1WindowLayoutErrorCode code, NSString *desc) {
    return [NSError errorWithDomain:M1WindowLayoutErrorDomain code:code
        userInfo:@{ NSLocalizedDescriptionKey: desc ?: @"M1WindowLayout error" }];
}

static NSArray<NSNumber *> *M1RectArray(CGRect r) {
    return @[ @(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height) ];
}

static BOOL M1RectFromArray(id obj, CGRect *out) {
    if (![obj isKindOfClass:[NSArray class]] || [(NSArray *)obj count] != 4) return NO;
    NSArray *a = obj;
    for (id v in a) {
        if (![v isKindOfClass:[NSNumber class]]) return NO;
    }
    if (out) {
        *out = CGRectMake([a[0] doubleValue], [a[1] doubleValue],
                          [a[2] doubleValue], [a[3] doubleValue]);
    }
    return YES;
}

static BOOL M1RectApproxEqual(CGRect a, CGRect b) {
    const double eps = 0.5;
    return fabs(a.origin.x - b.origin.x) <= eps && fabs(a.origin.y - b.origin.y) <= eps &&
           fabs(a.size.width - b.size.width) <= eps && fabs(a.size.height - b.size.height) <= eps;
}

// 显示重配后窗口可能仍在移动，AX 与 CG 的读数会有少量时差。
static BOOL M1RectNear(CGRect a, CGRect b, double eps) {
    return fabs(a.origin.x - b.origin.x) <= eps && fabs(a.origin.y - b.origin.y) <= eps &&
           fabs(a.size.width - b.size.width) <= eps && fabs(a.size.height - b.size.height) <= eps;
}

static BOOL M1CurrentCGWindowFrame(uint32_t windowNumber, CGRect *out) {
    CFArrayRef raw = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, windowNumber);
    if (!raw) return NO;
    BOOL found = NO;
    for (NSDictionary *d in (__bridge_transfer NSArray *)raw) {
        NSNumber *num = d[(__bridge NSString *)kCGWindowNumber];
        if (num.unsignedIntValue != windowNumber) continue;
        NSDictionary *b = d[(__bridge NSString *)kCGWindowBounds];
        if (![b isKindOfClass:[NSDictionary class]]) continue;
        if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)b, out)) found = YES;
        break;
    }
    return found;
}

#pragma mark - M1WindowInfo

@implementation M1WindowInfo

+ (instancetype)infoWithOwnerPID:(pid_t)pid
                    windowNumber:(uint32_t)windowNumber
                       ownerName:(NSString *)ownerName
                           title:(NSString *)title
                           frame:(CGRect)frame
                       displayID:(uint32_t)displayID
                           layer:(NSInteger)layer {
    M1WindowInfo *w = [M1WindowInfo new];
    w.ownerPID = pid;
    w.windowNumber = windowNumber;
    w.ownerName = ownerName ?: @"";
    w.title = title ?: @"";
    w.frame = frame;
    w.displayID = displayID;
    w.layer = layer;
    return w;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        @"pid": @(_ownerPID),
        @"windowNumber": @(_windowNumber),
        @"ownerName": _ownerName ?: @"",
        @"title": _title ?: @"",
        @"frame": M1RectArray(_frame),
        @"displayID": @(_displayID),
        @"layer": @(_layer),
    };
}

+ (instancetype)infoWithDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    CGRect frame;
    if (!M1RectFromArray(dict[@"frame"], &frame)) return nil;
    NSNumber *pid = dict[@"pid"], *wnum = dict[@"windowNumber"];
    if (![pid isKindOfClass:[NSNumber class]] || ![wnum isKindOfClass:[NSNumber class]]) return nil;
    return [M1WindowInfo infoWithOwnerPID:(pid_t)pid.intValue
                             windowNumber:wnum.unsignedIntValue
                                ownerName:dict[@"ownerName"]
                                    title:dict[@"title"]
                                    frame:frame
                                displayID:[dict[@"displayID"] unsignedIntValue]
                                    layer:[dict[@"layer"] integerValue]];
}

@end

#pragma mark - M1WindowLayoutSnapshot

@implementation M1WindowLayoutSnapshot

- (instancetype)init {
    self = [super init];
    if (self) {
        _windows = @[];
        _displayBounds = @{};
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableArray *wins = [NSMutableArray array];
    for (M1WindowInfo *w in _windows) [wins addObject:[w dictionaryRepresentation]];
    NSMutableDictionary *displays = [NSMutableDictionary dictionary];
    for (NSNumber *key in _displayBounds) {
        displays[key.stringValue] = M1RectArray(M1RectGetValue(_displayBounds[key]));
    }
    return @{
        @"windows": wins,
        @"displayBounds": displays,
        @"mainDisplayID": @(_mainDisplayID),
    };
}

+ (instancetype)snapshotWithDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    M1WindowLayoutSnapshot *snap = [M1WindowLayoutSnapshot new];
    NSMutableArray *wins = [NSMutableArray array];
    id rawWins = dict[@"windows"];
    if ([rawWins isKindOfClass:[NSArray class]]) {
        for (id d in rawWins) {
            M1WindowInfo *w = [M1WindowInfo infoWithDictionary:d];
            if (w) [wins addObject:w];
        }
    }
    NSMutableDictionary *displays = [NSMutableDictionary dictionary];
    id rawDisplays = dict[@"displayBounds"];
    if ([rawDisplays isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in rawDisplays) {
            CGRect r;
            if (!M1RectFromArray(rawDisplays[key], &r)) continue;
            unsigned int displayID = (unsigned int)strtoul(key.UTF8String, NULL, 10);
            displays[@(displayID)] = M1RectValue(r);
        }
    }
    snap.windows = wins;
    snap.displayBounds = displays;
    snap.mainDisplayID = [dict[@"mainDisplayID"] unsignedIntValue];
    return snap;
}

@end

#pragma mark - M1WindowRestoreTask

@interface M1WindowRestoreTask ()
@property (nonatomic, strong, readwrite) M1WindowInfo *window;
@property (nonatomic, assign, readwrite) CGRect currentFrame;
@property (nonatomic, assign, readwrite) CGRect targetFrame;
@end

@implementation M1WindowRestoreTask

+ (instancetype)taskWithWindow:(M1WindowInfo *)window
                  currentFrame:(CGRect)currentFrame
                   targetFrame:(CGRect)targetFrame {
    M1WindowRestoreTask *t = [M1WindowRestoreTask new];
    t.window = window;
    t.currentFrame = currentFrame;
    t.targetFrame = targetFrame;
    return t;
}

@end

#pragma mark - 计划

// 目标位置夹取：优先用快照所在屏；至少保留一块标题栏可见，避免窗口跑到屏幕外。
static CGRect M1ClampFrame(CGRect rect, NSDictionary<NSNumber *, NSValue *> *bounds,
                           uint32_t preferredDisplayID) {
    if (bounds.count == 0) return rect;
    CGRect screen = CGRectZero;
    BOOL found = NO;
    NSValue *pv = preferredDisplayID ? bounds[@(preferredDisplayID)] : nil;
    if (pv) {
        screen = M1RectGetValue(pv);
        found = YES;
    }
    if (!found) {
        CGPoint center = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
        CGFloat best = CGFLOAT_MAX;
        for (NSNumber *key in bounds) {
            CGRect b = M1RectGetValue(bounds[key]);
            if (CGRectContainsPoint(b, center)) {
                screen = b;
                found = YES;
                break;
            }
            CGFloat dx = CGRectGetMidX(b) - center.x;
            CGFloat dy = CGRectGetMidY(b) - center.y;
            CGFloat d = dx * dx + dy * dy;
            if (d < best) {
                best = d;
                screen = b;
                found = YES;
            }
        }
    }
    if (!found) return rect;

    CGFloat minVisW = MIN(120.0, MAX(32.0, rect.size.width));
    CGFloat minVisH = MIN(40.0, MAX(24.0, rect.size.height));
    CGFloat minX = screen.origin.x - rect.size.width + minVisW;
    CGFloat maxX = CGRectGetMaxX(screen) - minVisW;
    CGFloat minY = screen.origin.y;
    CGFloat maxY = CGRectGetMaxY(screen) - minVisH;

    CGRect out = rect;
    out.origin.x = MAX(minX, MIN(rect.origin.x, maxX));
    out.origin.y = MAX(minY, MIN(rect.origin.y, maxY));
    return out;
}

@implementation M1WindowLayoutPlanner

+ (NSArray<M1WindowRestoreTask *> *)planFromSnapshot:(M1WindowLayoutSnapshot *)snapshot
                                             windows:(NSArray<M1WindowInfo *> *)currentWindows
                                  disabledDisplayIDs:(NSSet<NSNumber *> *)disabledDisplayIDs
                                       currentBounds:(NSDictionary<NSNumber *, NSValue *> *)currentBounds {
    if (snapshot.windows.count == 0 || disabledDisplayIDs.count == 0) return @[];

    NSMutableDictionary<NSString *, M1WindowInfo *> *byKey = [NSMutableDictionary dictionary];
    for (M1WindowInfo *w in currentWindows) {
        if (w.layer != 0 || w.ownerPID <= 0) continue;
        byKey[[NSString stringWithFormat:@"%d#%u", w.ownerPID, w.windowNumber]] = w;
    }

    NSMutableArray<M1WindowRestoreTask *> *tasks = [NSMutableArray array];
    for (M1WindowInfo *s in snapshot.windows) {
        if (s.layer != 0 || s.displayID == 0) continue;
        // 只有原本在被禁物理屏上的窗口才会被 WindowServer 搬走。
        if (![disabledDisplayIDs containsObject:@(s.displayID)]) continue;
        M1WindowInfo *now = byKey[[NSString stringWithFormat:@"%d#%u", s.ownerPID, s.windowNumber]];
        if (!now) continue;
        if (M1RectApproxEqual(now.frame, s.frame) && now.displayID == s.displayID) continue;

        CGRect target = M1ClampFrame(s.frame, currentBounds, s.displayID);
        if (M1RectApproxEqual(now.frame, target)) continue;
        [tasks addObject:[M1WindowRestoreTask taskWithWindow:s
                                               currentFrame:now.frame
                                                targetFrame:target]];
    }
    return tasks;
}

@end

#pragma mark - 生产 provider

static NSDictionary<NSNumber *, NSValue *> *M1ActiveDisplayBounds(void) {
    uint32_t count = 0;
    if (CGGetActiveDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) return @{};
    CGDirectDisplayID ids[count];
    if (CGGetActiveDisplayList(count, ids, &count) != kCGErrorSuccess) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) {
        out[@(ids[i])] = M1RectValue(CGDisplayBounds(ids[i]));
    }
    return out;
}

static uint32_t M1DisplayContainingRect(CGRect r, NSDictionary<NSNumber *, NSValue *> *bounds) {
    CGPoint center = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
    for (NSNumber *key in bounds) {
        if (CGRectContainsPoint(M1RectGetValue(bounds[key]), center)) return key.unsignedIntValue;
    }
    CGFloat bestArea = 0;
    uint32_t bestID = 0;
    for (NSNumber *key in bounds) {
        CGRect inter = CGRectIntersection(r, M1RectGetValue(bounds[key]));
        if (CGRectIsNull(inter) || CGRectIsEmpty(inter)) continue;
        CGFloat area = inter.size.width * inter.size.height;
        if (area > bestArea) {
            bestArea = area;
            bestID = key.unsignedIntValue;
        }
    }
    return bestID;
}

@implementation M1WindowLayoutAXProvider

- (BOOL)accessibilityTrusted {
    return AXIsProcessTrusted();
}

- (M1WindowLayoutSnapshot *)captureLayoutExcludingPIDs:(NSSet<NSNumber *> *)pids {
    NSDictionary<NSNumber *, NSValue *> *bounds = M1ActiveDisplayBounds();
    CFArrayRef raw = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!raw) return nil;

    NSMutableArray<M1WindowInfo *> *windows = [NSMutableArray array];
    for (NSDictionary *d in (__bridge_transfer NSArray *)raw) {
        NSNumber *pidNum = d[(__bridge NSString *)kCGWindowOwnerPID];
        NSNumber *wnum = d[(__bridge NSString *)kCGWindowNumber];
        if (![pidNum isKindOfClass:[NSNumber class]] || ![wnum isKindOfClass:[NSNumber class]]) continue;
        pid_t pid = (pid_t)pidNum.intValue;
        if (pid <= 0 || [pids containsObject:@(pid)]) continue;

        NSNumber *layerNum = d[(__bridge NSString *)kCGWindowLayer];
        NSInteger layer = layerNum.integerValue;
        if (layer != 0) continue;

        NSNumber *onScreen = d[(__bridge NSString *)kCGWindowIsOnscreen];
        if (onScreen && !onScreen.boolValue) continue;

        NSNumber *alpha = d[(__bridge NSString *)kCGWindowAlpha];
        if (alpha && alpha.doubleValue <= 0.01) continue;

        CGRect frame = CGRectZero;
        id boundsObj = d[(__bridge NSString *)kCGWindowBounds];
        if (![boundsObj isKindOfClass:[NSDictionary class]] ||
            !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)boundsObj, &frame)) {
            continue;
        }
        if (frame.size.width < 2 || frame.size.height < 2) continue;

        NSString *owner = d[(__bridge NSString *)kCGWindowOwnerName];
        NSString *title = d[(__bridge NSString *)kCGWindowName];
        [windows addObject:[M1WindowInfo infoWithOwnerPID:pid
                                             windowNumber:wnum.unsignedIntValue
                                                ownerName:owner
                                                    title:title
                                                    frame:frame
                                                displayID:M1DisplayContainingRect(frame, bounds)
                                                    layer:layer]];
    }

    M1WindowLayoutSnapshot *snap = [M1WindowLayoutSnapshot new];
    snap.windows = windows;
    snap.displayBounds = bounds;
    snap.mainDisplayID = CGMainDisplayID();
    return snap;
}

- (BOOL)moveWindow:(M1WindowInfo *)window
         fromFrame:(CGRect)currentFrame
           toFrame:(CGRect)targetFrame
             error:(NSError **)error {
    if (!AXIsProcessTrusted()) {
        if (error) *error = M1WLErr(M1WindowLayoutErrorNotTrusted,
            @"辅助功能未授权，无法搬回窗口");
        return NO;
    }
    AXUIElementRef app = AXUIElementCreateApplication(window.ownerPID);
    if (!app) {
        if (error) *error = M1WLErr(M1WindowLayoutErrorWindowNotFound, @"无法创建 AX 应用元素");
        return NO;
    }
    // 显示重配后应用可能短暂无响应；1s 实测会超时，2s + 一次重试足够。
    AXUIElementSetMessagingTimeout(app, 2.0);

    CFTypeRef rawWins = NULL;
    AXError winsErr = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &rawWins);
    if (winsErr != kAXErrorSuccess || !rawWins) {
        if (rawWins) { CFRelease(rawWins); rawWins = NULL; }
        [NSThread sleepForTimeInterval:0.15];
        AXUIElementSetMessagingTimeout(app, 2.0);
        winsErr = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &rawWins);
    }
    if (winsErr != kAXErrorSuccess || !rawWins) {
        CFRelease(app);
        if (error) *error = M1WLErr(M1WindowLayoutErrorWindowNotFound,
            [NSString stringWithFormat:@"应用没有可访问窗口（AXError=%d）", (int)winsErr]);
        return NO;
    }
    NSArray *wins = (__bridge_transfer NSArray *)rawWins;

    AXUIElementRef match = NULL;
    for (id obj in wins) {
        AXUIElementRef el = (__bridge AXUIElementRef)obj;
        CFTypeRef numRef = NULL;
        if (AXUIElementCopyAttributeValue(el, CFSTR("AXWindowNumber"), &numRef) == kAXErrorSuccess &&
            numRef) {
            unsigned int num = 0;
            CFNumberGetValue((CFNumberRef)numRef, kCFNumberIntType, &num);
            CFRelease(numRef);
            if (num == window.windowNumber) {
                match = (AXUIElementRef)CFRetain(el);
                break;
            }
        }
    }
    // 部分应用不暴露 AXWindowNumber（Terminal/System Settings）：退回 frame 匹配。
    // currentFrame 来自恢复计划生成时，窗口可能仍在移动，优先取实时 CG frame。
    if (!match) {
        CGRect refFrame = currentFrame;
        M1CurrentCGWindowFrame(window.windowNumber, &refFrame);
        for (id obj in wins) {
            AXUIElementRef el = (__bridge AXUIElementRef)obj;
            AXValueRef posRef = NULL, sizeRef = NULL;
            if (AXUIElementCopyAttributeValue(el, kAXPositionAttribute, (CFTypeRef *)&posRef) !=
                    kAXErrorSuccess || !posRef) continue;
            if (AXUIElementCopyAttributeValue(el, kAXSizeAttribute, (CFTypeRef *)&sizeRef) !=
                    kAXErrorSuccess || !sizeRef) {
                CFRelease(posRef);
                continue;
            }
            CGPoint p = CGPointZero;
            CGSize s = CGSizeZero;
            AXValueGetValue(posRef, kAXValueCGPointType, &p);
            AXValueGetValue(sizeRef, kAXValueCGSizeType, &s);
            CFRelease(posRef);
            CFRelease(sizeRef);
            CGRect f = CGRectMake(p.x, p.y, s.width, s.height);
            if (M1RectNear(f, refFrame, 8.0)) {
                match = (AXUIElementRef)CFRetain(el);
                break;
            }
        }
    }
    CFRelease(app);
    if (!match) {
        if (error) *error = M1WLErr(M1WindowLayoutErrorWindowNotFound,
            [NSString stringWithFormat:@"窗口 %u（pid %d）已不存在", window.windowNumber, window.ownerPID]);
        return NO;
    }

    BOOL ok = YES;
    AXValueRef sizeVal = AXValueCreate(kAXValueCGSizeType, &targetFrame.size);
    if (sizeVal) {
        AXError e = AXUIElementSetAttributeValue(match, kAXSizeAttribute, sizeVal);
        if (e != kAXErrorSuccess) ok = NO;   // 不可缩放窗口只记失败，位置仍要试
        CFRelease(sizeVal);
    }
    CGPoint origin = targetFrame.origin;
    AXValueRef posVal = AXValueCreate(kAXValueCGPointType, &origin);
    if (posVal) {
        AXError e = AXUIElementSetAttributeValue(match, kAXPositionAttribute, posVal);
        if (e != kAXErrorSuccess) ok = NO;
        CFRelease(posVal);
    } else {
        ok = NO;
    }
    CFRelease(match);
    if (!ok && error) {
        *error = M1WLErr(M1WindowLayoutErrorMoveFailed,
            [NSString stringWithFormat:@"窗口 %u（pid %d）搬回失败",
                window.windowNumber, window.ownerPID]);
    }
    return ok;
}

@end

#pragma mark - 恢复器

@interface M1WindowLayoutRestorer ()
@property (nonatomic, strong) id<M1WindowLayoutProvider> provider;
@end

@implementation M1WindowLayoutRestorer

- (instancetype)initWithProvider:(id<M1WindowLayoutProvider>)provider {
    self = [super init];
    if (self) {
        _provider = provider;
    }
    return self;
}

- (NSDictionary *)restoreSnapshot:(M1WindowLayoutSnapshot *)snapshot
               disabledDisplayIDs:(NSSet<NSNumber *> *)disabledDisplayIDs {
    NSUInteger captured = snapshot.windows.count;
    BOOL trusted = self.provider.accessibilityTrusted;
    NSMutableDictionary *summary = [@{
        @"captured": @(captured),
        @"planned": @(0),
        @"restored": @(0),
        @"failed": @(0),
        @"skipped": @(0),
        @"trusted": @(trusted),
    } mutableCopy];
    if (!snapshot || captured == 0 || disabledDisplayIDs.count == 0) return summary;

    NSSet *excluded = [NSSet setWithObject:@(getpid())];
    M1WindowLayoutSnapshot *now = [self.provider captureLayoutExcludingPIDs:excluded];
    if (!now) return summary;

    NSArray<M1WindowRestoreTask *> *tasks =
        [M1WindowLayoutPlanner planFromSnapshot:snapshot
                                        windows:now.windows
                             disabledDisplayIDs:disabledDisplayIDs
                                  currentBounds:now.displayBounds];
    summary[@"planned"] = @(tasks.count);
    if (tasks.count == 0) return summary;

    if (!trusted) {
        summary[@"skipped"] = @(tasks.count);
        return summary;
    }

    NSUInteger restored = 0, failed = 0;
    NSMutableArray *failedDetail = [NSMutableArray array];
    // 每窗口一次 AX 调用可能到 2s；总预算随窗口数放大，但封顶 10s 不拖住退出。
    double budget = MAX(3.0, MIN(10.0, 0.7 * (double)tasks.count));
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + budget;
    for (M1WindowRestoreTask *t in tasks) {
        if (CFAbsoluteTimeGetCurrent() > deadline) {
            failed += 1;   // 超预算按未完成计，避免拖住会话退出
            [failedDetail addObject:@{
                @"pid": @(t.window.ownerPID),
                @"windowNumber": @(t.window.windowNumber),
                @"owner": t.window.ownerName ?: @"",
                @"error": @"deadline",
            }];
            continue;
        }
        NSError *moveErr = nil;
        if ([self.provider moveWindow:t.window
                            fromFrame:t.currentFrame
                              toFrame:t.targetFrame
                                error:&moveErr]) {
            restored += 1;
        } else {
            failed += 1;
            [failedDetail addObject:@{
                @"pid": @(t.window.ownerPID),
                @"windowNumber": @(t.window.windowNumber),
                @"owner": t.window.ownerName ?: @"",
                @"title": t.window.title ?: @"",
                @"error": moveErr.localizedDescription ?: @"unknown",
            }];
        }
    }
    summary[@"restored"] = @(restored);
    summary[@"failed"] = @(failed);
    if (failedDetail.count > 0) summary[@"failedDetail"] = failedDetail;
    return summary;
}

@end
