//
//  P1InputCodec.m
//  P1-ClientProbe
//

#import "P1InputCodec.h"
#import "ProtocolCodec.h"
#import <math.h>

NSString * const P1InputErrorDomain = @"P1InputErrorDomain";
const NSUInteger P1InputMaxEventsPerSecond = 1000;

static NSError *P1InputErr(P1InputErrorCode code, NSString *desc) {
    return [NSError errorWithDomain:P1InputErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: desc ?: @""}];
}

static NSDictionary *P1FlagsDict(NSDictionary *flags) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"cmd"]   = @(NO);
    out[@"shift"] = @(NO);
    out[@"opt"]   = @(NO);
    out[@"ctrl"]  = @(NO);
    out[@"caps"]  = @(NO);
    if ([flags isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"cmd", @"shift", @"opt", @"ctrl", @"caps"]) {
            id v = flags[key];
            if ([v isKindOfClass:[NSNumber class]] &&
                ([v integerValue] == 0 || [v integerValue] == 1)) {
                out[key] = @([v boolValue]);
            }
        }
    }
    return out;
}

NSDictionary *P1InputFlagsState(NSDictionary *flags, NSError **error) {
    if (flags && ![flags isKindOfClass:[NSDictionary class]]) {
        if (error) *error = P1InputErr(P1InputErrorBadFlags, @"flags is not a dictionary");
        return nil;
    }
    NSArray *keys = @[@"cmd", @"shift", @"opt", @"ctrl", @"caps"];
    for (NSString *key in keys) {
        id v = flags[key];
        if (v && ![v isKindOfClass:[NSNumber class]]) {
            if (error) *error = P1InputErr(P1InputErrorBadFlags, @"flag value is not numeric/bool");
            return nil;
        }
        if (v && [v integerValue] != 0 && [v integerValue] != 1) {
            if (error) *error = P1InputErr(P1InputErrorBadFlags, @"flag value must be 0 or 1");
            return nil;
        }
    }
    return P1FlagsDict(flags);
}

static NSDictionary *P1BaseEvent(NSString *kind, uint32_t displayID, NSDictionary *flags) {
    NSMutableDictionary *e = [NSMutableDictionary dictionary];
    e[@"kind"] = kind;
    e[@"displayID"] = @(displayID);
    e[@"flags"] = P1FlagsDict(flags);
    return e;
}

NSDictionary *P1MakeMouseEvent(uint32_t displayID,
                               double x, double y,
                               NSString *button, NSString *action,
                               NSDictionary *flags) {
    NSMutableDictionary *e = [P1BaseEvent(@"mouse", displayID, flags) mutableCopy];
    e[@"x"] = @(x);
    e[@"y"] = @(y);
    e[@"button"] = button ?: @"left";
    e[@"action"] = action ?: @"move";
    return e;
}

NSDictionary *P1MakeKeyEvent(uint32_t displayID,
                             uint16_t keyCode,
                             NSString *unicode,
                             NSDictionary *flags) {
    NSMutableDictionary *e = [P1BaseEvent(@"key", displayID, flags) mutableCopy];
    e[@"keyCode"] = @(keyCode);
    if (unicode.length) e[@"unicode"] = unicode;
    return e;
}

NSDictionary *P1MakeScrollEvent(uint32_t displayID,
                                double dx, double dy,
                                NSDictionary *flags) {
    NSMutableDictionary *e = [P1BaseEvent(@"scroll", displayID, flags) mutableCopy];
    e[@"dx"] = @(dx);
    e[@"dy"] = @(dy);
    return e;
}

NSDictionary *P1MakeFlagsEvent(NSDictionary *flags) {
    NSMutableDictionary *e = [P1BaseEvent(@"flags", 0, flags) mutableCopy];
    return e;
}

NSDictionary *P1MakeTextEvent(uint32_t displayID, NSString *text, NSDictionary *flags) {
    NSMutableDictionary *e = [P1BaseEvent(@"text", displayID, flags) mutableCopy];
    if (text.length) e[@"text"] = text;
    return e;
}

NSDictionary *P1MakeInputMessage(int64_t seq, NSDictionary *event) {
    return P1MakeControlMessage(@"input", seq, @{@"event": event});
}

static BOOL P1IsFiniteNumber(id v) {
    if (![v isKindOfClass:[NSNumber class]]) return NO;
    return isfinite([(NSNumber *)v doubleValue]);
}

NSDictionary *P1NormalizeInputEvent(NSDictionary *event, NSError **error) {
    if (![event isKindOfClass:[NSDictionary class]]) {
        if (error) *error = P1InputErr(P1InputErrorBadMessage, @"event is not a dictionary");
        return nil;
    }
    NSString *kind = event[@"kind"];
    if (![kind isKindOfClass:[NSString class]]) {
        if (error) *error = P1InputErr(P1InputErrorBadKind, @"missing kind");
        return nil;
    }
    NSArray *validKinds = @[@"mouse", @"key", @"scroll", @"flags", @"text"];
    if (![validKinds containsObject:kind]) {
        if (error) *error = P1InputErr(P1InputErrorBadKind, @"unknown kind");
        return nil;
    }

    NSError *flagErr = nil;
    NSDictionary *flags = P1InputFlagsState(event[@"flags"], &flagErr);
    if (!flags) {
        if (error) *error = flagErr;
        return nil;
    }

    id rawDisplay = event[@"displayID"];
    uint32_t displayID = 0;
    if (rawDisplay && [rawDisplay isKindOfClass:[NSNumber class]]) {
        int64_t v = [(NSNumber *)rawDisplay longLongValue];
        if (v < 0 || v > UINT32_MAX) {
            if (error) *error = P1InputErr(P1InputErrorBadMessage, @"displayID out of range");
            return nil;
        }
        displayID = (uint32_t)v;
    } else if (rawDisplay) {
        if (error) *error = P1InputErr(P1InputErrorBadMessage, @"displayID is not numeric");
        return nil;
    }

    NSMutableDictionary *out = [P1BaseEvent(kind, displayID, flags) mutableCopy];

    if ([kind isEqualToString:@"mouse"]) {
        id x = event[@"x"], y = event[@"y"];
        if (!P1IsFiniteNumber(x) || !P1IsFiniteNumber(y) ||
            [x doubleValue] < 0.0 || [x doubleValue] > 1.0 ||
            [y doubleValue] < 0.0 || [y doubleValue] > 1.0) {
            if (error) *error = P1InputErr(P1InputErrorBadCoordinate, @"x/y must be finite in 0..1");
            return nil;
        }
        NSString *button = event[@"button"] ?: @"left";
        NSString *action = event[@"action"] ?: @"move";
        if (![@[@"left", @"right", @"other"] containsObject:button]) {
            if (error) *error = P1InputErr(P1InputErrorBadButton, @"unknown button");
            return nil;
        }
        if (![@[@"down", @"up", @"move", @"drag"] containsObject:action]) {
            if (error) *error = P1InputErr(P1InputErrorBadButton, @"unknown action");
            return nil;
        }
        out[@"x"] = @([x doubleValue]);
        out[@"y"] = @([y doubleValue]);
        out[@"button"] = button;
        out[@"action"] = action;
    } else if ([kind isEqualToString:@"key"]) {
        id keyCode = event[@"keyCode"];
        NSString *unicode = event[@"unicode"];
        if (unicode && ![unicode isKindOfClass:[NSString class]]) {
            if (error) *error = P1InputErr(P1InputErrorBadKey, @"unicode is not a string");
            return nil;
        }
        if (unicode.length > 256) {
            if (error) *error = P1InputErr(P1InputErrorBadKey, @"unicode too long");
            return nil;
        }
        int64_t code = 0;
        if (keyCode) {
            if (!P1IsFiniteNumber(keyCode)) {
                if (error) *error = P1InputErr(P1InputErrorBadKey, @"keyCode is not numeric");
                return nil;
            }
            code = [(NSNumber *)keyCode longLongValue];
            if (code < 0 || code > 127) {
                if (error) *error = P1InputErr(P1InputErrorBadKey, @"keyCode out of range");
                return nil;
            }
        }
        if (!keyCode && !unicode.length) {
            if (error) *error = P1InputErr(P1InputErrorBadKey, @"key requires keyCode or unicode");
            return nil;
        }
        out[@"keyCode"] = @((uint16_t)code);
        if (unicode.length) out[@"unicode"] = unicode;
    } else if ([kind isEqualToString:@"scroll"]) {
        id dx = event[@"dx"], dy = event[@"dy"];
        if (!P1IsFiniteNumber(dx) || !P1IsFiniteNumber(dy)) {
            if (error) *error = P1InputErr(P1InputErrorBadScroll, @"dx/dy must be finite numbers");
            return nil;
        }
        out[@"dx"] = @([dx doubleValue]);
        out[@"dy"] = @([dy doubleValue]);
    } else if ([kind isEqualToString:@"text"]) {
        NSString *text = event[@"text"];
        if (![text isKindOfClass:[NSString class]] || text.length == 0) {
            if (error) *error = P1InputErr(P1InputErrorBadKey, @"text requires non-empty string");
            return nil;
        }
        if (text.length > 256) {
            if (error) *error = P1InputErr(P1InputErrorBadKey, @"text too long");
            return nil;
        }
        out[@"text"] = text;
    }

    return out;
}

NSData *P1EncodeInputMessage(int64_t seq, NSDictionary *event, NSError **error) {
    NSError *normErr = nil;
    NSDictionary *normalized = P1NormalizeInputEvent(event, &normErr);
    if (!normalized) {
        if (error) *error = normErr;
        return nil;
    }
    return P1EncodeControlMessage(P1MakeInputMessage(seq, normalized), error);
}

NSDictionary *P1DecodeInputEvent(NSData *controlFrame, NSError **error) {
    if (controlFrame.length < 5) {
        if (error) *error = P1InputErr(P1InputErrorBadFrame, @"control frame too short");
        return nil;
    }
    const uint8_t *p = controlFrame.bytes;
    uint32_t declared = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
                        ((uint32_t)p[2] << 8) | p[3];
    if ((NSUInteger)declared != controlFrame.length - 4) {
        if (error) *error = P1InputErr(P1InputErrorBadFrame, @"length prefix mismatch");
        return nil;
    }
    NSData *body = [controlFrame subdataWithRange:NSMakeRange(4, declared)];
    NSError *jerr = nil;
    NSDictionary *msg = P1DecodeControlMessage(body, &jerr);
    if (!msg) {
        if (error) *error = jerr;
        return nil;
    }
    if (![msg[@"type"] isEqualToString:@"input"]) {
        if (error) *error = P1InputErr(P1InputErrorBadMessage, @"message is not input");
        return nil;
    }
    NSError *normErr = nil;
    NSDictionary *event = P1NormalizeInputEvent(msg[@"event"], &normErr);
    if (!event) {
        if (error) *error = normErr;
        return nil;
    }
    NSMutableDictionary *out = [event mutableCopy];
    out[@"seq"] = msg[@"seq"];
    return out;
}

BOOL P1InputIsDroppableEvent(NSDictionary *event) {
    NSString *kind = event[@"kind"];
    if ([kind isEqualToString:@"scroll"]) return YES;
    if ([kind isEqualToString:@"mouse"] &&
        [event[@"action"] isEqualToString:@"move"]) return YES;
    return NO;
}

@implementation P1InputRateLimiter {
    NSMutableArray<NSNumber *> *_times;
    NSUInteger _rate;
}

- (instancetype)initWithEventsPerSecond:(NSUInteger)rate {
    if ((self = [super init])) {
        _rate = rate ?: P1InputMaxEventsPerSecond;
        _times = [NSMutableArray arrayWithCapacity:_rate];
        _droppedEvents = 0;
    }
    return self;
}

- (void)reset {
    [_times removeAllObjects];
    _droppedEvents = 0;
}

- (BOOL)shouldAcceptEvent:(NSDictionary *)event atTime:(double)now {
    // 移除 1s 窗口外的记录（按到达时间，不做未来时间的校验）
    NSMutableIndexSet *expired = [NSMutableIndexSet indexSet];
    NSUInteger i = 0;
    for (NSNumber *t in _times) {
        if ([t doubleValue] <= now - 1.0) [expired addIndex:i];
        i++;
    }
    [_times removeObjectsAtIndexes:expired];

    if (_times.count < _rate) {
        [_times addObject:@(now)];
        return YES;
    }
    // 超限时只丢 move/scroll，保留 down/up/drag/key/flags（PROTOCOL §3.1）
    if (P1InputIsDroppableEvent(event)) {
        _droppedEvents++;
        return NO;
    }
    return YES;
}

@end
