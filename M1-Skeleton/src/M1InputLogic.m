//
//  M1InputLogic.m
//  M1-Skeleton
//

#import "M1InputLogic.h"

NSString * const M1InputLogicErrorDomain = @"M1InputLogic";

// CGEventFlags 位值（与 IOKit/hidsystem/ev_keymap.h 一致）
static const uint64_t kM1FlagCaps   = 1ULL << 16;
static const uint64_t kM1FlagShift  = 1ULL << 17;
static const uint64_t kM1FlagCtrl   = 1ULL << 18;
static const uint64_t kM1FlagOpt    = 1ULL << 19;
static const uint64_t kM1FlagCmd    = 1ULL << 20;

uint64_t M1EventFlagsFromDict(NSDictionary<NSString *, NSNumber *> *flags) {
    uint64_t f = 0;
    if ([flags[@"caps"] boolValue])  f |= kM1FlagCaps;
    if ([flags[@"shift"] boolValue]) f |= kM1FlagShift;
    if ([flags[@"ctrl"] boolValue])  f |= kM1FlagCtrl;
    if ([flags[@"opt"] boolValue])   f |= kM1FlagOpt;
    if ([flags[@"cmd"] boolValue])   f |= kM1FlagCmd;
    return f;
}

static double M1Clamp01(double v) {
    if (v < 0.0) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
}

CGPoint M1PointInDisplayRect(double nx, double ny, CGRect displayRect) {
    double x = M1Clamp01(nx), y = M1Clamp01(ny);
    return CGPointMake(displayRect.origin.x + x * displayRect.size.width,
                       displayRect.origin.y + y * displayRect.size.height);
}

static NSError *M1InputErr(NSInteger code, NSString *desc) {
    return [NSError errorWithDomain:M1InputLogicErrorDomain code:code
        userInfo:@{ NSLocalizedDescriptionKey: desc }];
}

NSDictionary<NSString *, id> *M1InjectionPlan(NSDictionary *event,
                                               CGRect targetDisplayRect,
                                               NSError **error) {
    NSString *kind = event[@"kind"];
    uint64_t flags = M1EventFlagsFromDict(event[@"flags"]);
    uint32_t displayID = [event[@"displayID"] unsignedIntValue];

    if ([kind isEqualToString:@"mouse"]) {
        id x = event[@"x"], y = event[@"y"];
        if (![x isKindOfClass:[NSNumber class]] || ![y isKindOfClass:[NSNumber class]]) {
            if (error) *error = M1InputErr(1, @"mouse 缺 x/y");
            return nil;
        }
        CGPoint p = M1PointInDisplayRect([x doubleValue], [y doubleValue], targetDisplayRect);
        return @{
            @"kind": @"mouse", @"displayID": @(displayID),
            @"x": @(p.x), @"y": @(p.y),
            @"button": event[@"button"] ?: @"left",
            @"action": event[@"action"] ?: @"move",
            @"flags": @(flags),
        };
    }
    if ([kind isEqualToString:@"key"]) {
        return @{
            @"kind": @"key", @"displayID": @(displayID),
            @"keyCode": event[@"keyCode"] ?: @(0),
            @"unicode": event[@"unicode"] ?: @"",
            @"flags": @(flags),
        };
    }
    if ([kind isEqualToString:@"scroll"]) {
        return @{
            @"kind": @"scroll", @"displayID": @(displayID),
            @"dx": event[@"dx"] ?: @(0), @"dy": event[@"dy"] ?: @(0),
            @"flags": @(flags),
        };
    }
    if ([kind isEqualToString:@"flags"]) {
        return @{ @"kind": @"flags", @"flags": @(flags) };
    }
    if (error) *error = M1InputErr(2, @"未知事件 kind");
    return nil;
}
