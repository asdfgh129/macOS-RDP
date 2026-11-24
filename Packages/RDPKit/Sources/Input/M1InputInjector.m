//
//  M1InputInjector.m
//  M1-Skeleton
//

#import "M1InputInjector.h"
#import <ApplicationServices/ApplicationServices.h>

#pragma mark - 真实 CGEvent 下沉

@interface M1CGEventSink ()
@property (nonatomic, assign) uint64_t lastFlags;
@end

@implementation M1CGEventSink

static void M1Post(CGEventRef e, pid_t pid) {
    if (!e) return;
    if (pid > 0) CGEventPostToPid(pid, e);
    else CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

- (BOOL)postPlan:(NSDictionary<NSString *, id> *)plan error:(NSError **)error {
    NSString *kind = plan[@"kind"];
    CGEventFlags flags = (CGEventFlags)[plan[@"flags"] unsignedLongLongValue];

    if ([kind isEqualToString:@"mouse"]) {
        CGPoint p = CGPointMake([plan[@"x"] doubleValue], [plan[@"y"] doubleValue]);
        NSString *button = plan[@"button"] ?: @"left";
        NSString *action = plan[@"action"] ?: @"move";
        CGMouseButton cgButton = [button isEqualToString:@"right"] ? kCGMouseButtonRight
                               : [button isEqualToString:@"other"] ? kCGMouseButtonCenter
                               : kCGMouseButtonLeft;
        CGEventType type;
        if ([action isEqualToString:@"down"]) {
            type = cgButton == kCGMouseButtonRight ? kCGEventRightMouseDown
                 : cgButton == kCGMouseButtonCenter ? kCGEventOtherMouseDown : kCGEventLeftMouseDown;
        } else if ([action isEqualToString:@"up"]) {
            type = cgButton == kCGMouseButtonRight ? kCGEventRightMouseUp
                 : cgButton == kCGMouseButtonCenter ? kCGEventOtherMouseUp : kCGEventLeftMouseUp;
        } else { // move / drag
            type = cgButton == kCGMouseButtonRight ? kCGEventRightMouseDragged
                 : cgButton == kCGMouseButtonCenter ? kCGEventOtherMouseDragged : kCGEventMouseMoved;
            if ([action isEqualToString:@"drag"] && cgButton == kCGMouseButtonLeft)
                type = kCGEventLeftMouseDragged;
        }
        CGEventRef e = CGEventCreateMouseEvent(NULL, type, p, cgButton);
        if (e) CGEventSetFlags(e, flags);
        M1Post(e, self.targetPID);
        _lastFlags = flags;
        return YES;
    }
    if ([kind isEqualToString:@"key"]) {
        CGKeyCode code = (CGKeyCode)[plan[@"keyCode"] unsignedShortValue];
        NSString *unicode = plan[@"unicode"];
        CGEventRef down = CGEventCreateKeyboardEvent(NULL, code, true);
        CGEventRef up = CGEventCreateKeyboardEvent(NULL, code, false);
        if (unicode.length) {
            for (NSUInteger i = 0; i < unicode.length; i++) {
                UniChar u = [unicode characterAtIndex:i];
                if (down) CGEventKeyboardSetUnicodeString(down, 1, &u);
                if (up) CGEventKeyboardSetUnicodeString(up, 1, &u);
            }
        }
        if (down) CGEventSetFlags(down, flags);
        if (up) CGEventSetFlags(up, flags);
        M1Post(down, self.targetPID);
        M1Post(up, self.targetPID);
        _lastFlags = flags;
        return YES;
    }
    if ([kind isEqualToString:@"scroll"]) {
        CGEventRef e = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2,
            (int32_t)[plan[@"dx"] intValue], (int32_t)[plan[@"dy"] intValue]);
        if (e) CGEventSetFlags(e, flags);
        M1Post(e, self.targetPID);
        _lastFlags = flags;
        return YES;
    }
    if ([kind isEqualToString:@"flags"]) {
        // 修饰键全量同步：发一个 flagsChanged 事件携带完整掩码。
        CGEventRef e = CGEventCreate(NULL);
        if (e) {
            CGEventSetType(e, kCGEventFlagsChanged);
            CGEventSetFlags(e, flags);
            M1Post(e, self.targetPID);
        }
        _lastFlags = flags;
        return YES;
    }
    if (error) *error = [NSError errorWithDomain:@"M1InputInjector" code:1
        userInfo:@{ NSLocalizedDescriptionKey: @"未知注入计划" }];
    return NO;
}

@end

#pragma mark - 记录型下沉（不注入）

@interface M1RecordingEventSink ()
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *mutablePlans;
@end

@implementation M1RecordingEventSink

- (instancetype)init {
    if ((self = [super init])) _mutablePlans = [NSMutableArray array];
    return self;
}

- (BOOL)postPlan:(NSDictionary<NSString *, id> *)plan error:(NSError **)error {
    // 注入发生在控制收包队列，读取发生在主线程（打印/断言），加锁避免并发改数组。
    @synchronized (self) {
        [_mutablePlans addObject:[plan copy]];
    }
    return YES;
}

- (NSArray<NSDictionary *> *)plans {
    @synchronized (self) { return [_mutablePlans copy]; }
}

- (NSUInteger)postCount {
    @synchronized (self) { return _mutablePlans.count; }
}

- (void)reset {
    @synchronized (self) { [_mutablePlans removeAllObjects]; }
}

@end

#pragma mark - Injector

@interface M1InputInjector ()
@property (nonatomic, strong) id<M1EventSink> sink;
@property (nonatomic, assign) uint64_t flags;
@property (nonatomic, assign) CFMachPortRef takeoverTap;
@property (nonatomic, assign) CFRunLoopSourceRef takeoverSource;
@property (nonatomic, weak) M1TakeoverDetector *takeoverDetector;
@end

@implementation M1InputInjector

- (instancetype)initWithSink:(id<M1EventSink>)sink {
    self = [super init];
    if (self) {
        _sink = sink;
        _targetDisplayRect = CGRectZero;
    }
    return self;
}

- (BOOL)injectEvent:(NSDictionary *)event error:(NSError **)error {
    CGRect rect = _targetDisplayRect;
    NSNumber *displayID = event[@"displayID"];
    if ([displayID isKindOfClass:[NSNumber class]] && self.displayRects.count > 0) {
        NSValue *val = self.displayRects[displayID];
        if (val) {
            rect = val.rectValue;
        } else if ([event[@"kind"] isEqualToString:@"mouse"]) {
            // 鼠标坐标必须以目标屏 bounds 为基准；查不到就拒绝，
            // 否则会静默落到另一块屏的坐标上（多屏时尤其难查）。
            if (error) *error = [NSError errorWithDomain:@"M1InputInjector" code:3
                userInfo:@{ NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"未知 displayID=%@", displayID] }];
            return NO;
        }
    }
    NSError *planErr = nil;
    NSDictionary *plan = M1InjectionPlan(event, rect, &planErr);
    if (!plan) {
        if (error) *error = planErr;
        return NO;
    }
    // 事件自带 flags 时先全量同步修饰键状态。
    if (event[@"flags"]) _flags = M1EventFlagsFromDict(event[@"flags"]);
    return [_sink postPlan:plan error:error];
}

- (uint64_t)currentFlags { return _flags; }

#pragma mark - 现场接管 tap

static CGEventRef M1TakeoverTapCallback(CGEventTapProxy proxy, CGEventType type,
                                        CGEventRef event, void *refcon) {
    M1InputInjector *self = (__bridge M1InputInjector *)refcon;
    M1TakeoverDetector *detector = self.takeoverDetector;
    if (!detector) return event;
    double now = [[NSDate date] timeIntervalSince1970];
    if (type == kCGEventFlagsChanged) {
        CGEventFlags f = CGEventGetFlags(event);
        BOOL shiftNow = (f & kCGEventFlagMaskShift) != 0;
        // 检测器自身去抖：只在边沿喂信号，tick 负责按住时长。
        static BOOL M1LastShift = NO;
        if (shiftNow && !M1LastShift) [detector handleSignal:M1TakeoverSignalShiftDown atTime:now];
        if (!shiftNow && M1LastShift) [detector handleSignal:M1TakeoverSignalShiftUp atTime:now];
        M1LastShift = shiftNow;
    }
    return event; // 不吞掉本机事件（现场用户正常操作）
}

- (BOOL)installTakeoverTapWithDetector:(M1TakeoverDetector *)detector error:(NSError **)error {
    [self removeTakeoverTap];
    _takeoverDetector = detector;
    CGEventMask mask = CGEventMaskBit(kCGEventFlagsChanged);
    _takeoverTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
                                    mask, M1TakeoverTapCallback, (__bridge void *)self);
    if (!_takeoverTap) {
        if (error) *error = [NSError errorWithDomain:@"M1InputInjector" code:2
            userInfo:@{ NSLocalizedDescriptionKey:
                @"CGEventTap 创建失败（需要辅助功能授权 / 无 GUI 会话）" }];
        return NO;
    }
    _takeoverSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _takeoverTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), _takeoverSource, kCFRunLoopCommonModes);
    CGEventTapEnable(_takeoverTap, true);
    return YES;
}

- (void)removeTakeoverTap {
    if (_takeoverTap) {
        CGEventTapEnable(_takeoverTap, false);
        if (_takeoverSource) CFRunLoopRemoveSource(CFRunLoopGetMain(), _takeoverSource, kCFRunLoopCommonModes);
        CFRelease(_takeoverSource);
        CFRelease(_takeoverTap);
        _takeoverSource = NULL;
        _takeoverTap = NULL;
    }
    _takeoverDetector = nil;
}

- (void)dealloc { [self removeTakeoverTap]; }

@end
