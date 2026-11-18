// P1InputCodec 单元测试：纯内存，不建屏、不联网。
// 覆盖 PROTOCOL.md §3.1（input 载荷、修饰键状态、注入限速）。
#import <Foundation/Foundation.h>
#import "P1InputCodec.h"
#import "ProtocolCodec.h"
#import <math.h>

static int gFail = 0;
static void Expect(BOOL cond, const char *name) {
    if (cond) printf("[PASS] %s\n", name);
    else { gFail++; printf("[FAIL] %s\n", name); }
}
static void ExpectInt(long got, long want, const char *name) {
    if (got == want) printf("[PASS] %s\n", name);
    else { gFail++; printf("[FAIL] %s got=%ld want=%ld\n", name, got, want); }
}

int main(void) {
    @autoreleasepool {
        NSError *err = nil;
        NSDictionary *flags = @{@"cmd": @(1), @"shift": @(0), @"caps": @(1)};

        // mouse 往返
        NSDictionary *mouse = P1MakeMouseEvent(4128835, 0.25, 0.5, @"left", @"down", flags);
        NSData *frame = P1EncodeInputMessage(7, mouse, &err);
        Expect(frame != nil && err == nil, "mouse-encode-ok");
        NSDictionary *decoded = P1DecodeInputEvent(frame, &err);
        Expect(decoded != nil && err == nil, "mouse-decode-ok");
        Expect([decoded[@"kind"] isEqual:@"mouse"], "mouse-kind");
        ExpectInt((long)[decoded[@"seq"] longLongValue], 7, "mouse-seq");
        ExpectInt((long)[decoded[@"displayID"] unsignedIntValue], 4128835, "mouse-display-id");
        Expect(fabs([decoded[@"x"] doubleValue] - 0.25) < 1e-9, "mouse-normalized-x");
        Expect([decoded[@"button"] isEqual:@"left"] && [decoded[@"action"] isEqual:@"down"],
               "mouse-button-action");
        Expect([decoded[@"flags"][@"cmd"] boolValue] && [decoded[@"flags"][@"caps"] boolValue] &&
               ![decoded[@"flags"][@"shift"] boolValue], "mouse-flags-preserved");
        Expect(![decoded[@"flags"][@"opt"] boolValue], "mouse-flags-default-zero");

        // key + IME unicode 往返
        NSDictionary *key = P1MakeKeyEvent(4128835, 12, @"你好", @{@"shift": @(1)});
        err = nil;
        decoded = P1DecodeInputEvent(P1EncodeInputMessage(8, key, &err), &err);
        Expect(decoded != nil && [decoded[@"kind"] isEqual:@"key"], "key-decode-ok");
        Expect([decoded[@"unicode"] isEqual:@"你好"], "key-unicode-ime");
        ExpectInt([decoded[@"keyCode"] intValue], 12, "key-keycode");
        Expect([decoded[@"flags"][@"shift"] boolValue], "key-flags");

        // scroll 往返
        NSDictionary *scroll = P1MakeScrollEvent(4128835, -1.5, 2.25, nil);
        err = nil;
        decoded = P1DecodeInputEvent(P1EncodeInputMessage(9, scroll, &err), &err);
        Expect(decoded != nil && [decoded[@"kind"] isEqual:@"scroll"], "scroll-decode-ok");
        Expect(fabs([decoded[@"dx"] doubleValue] + 1.5) < 1e-9 &&
               fabs([decoded[@"dy"] doubleValue] - 2.25) < 1e-9, "scroll-delta");

        // flags 全量状态
        err = nil;
        NSDictionary *flagEvent = P1MakeFlagsEvent(flags);
        decoded = P1DecodeInputEvent(P1EncodeInputMessage(10, flagEvent, &err), &err);
        Expect(decoded != nil && [decoded[@"kind"] isEqual:@"flags"], "flags-decode-ok");
        ExpectInt((long)[decoded[@"displayID"] unsignedIntValue], 0, "flags-display-zero");
        NSDictionary *state = P1InputFlagsState(@{@"cmd": @(1)}, &err);
        Expect(state && state.count == 5 && [state[@"cmd"] boolValue] &&
               ![state[@"caps"] boolValue], "flags-full-state");

        // 非法事件
        err = nil;
        NSMutableDictionary *bad = [mouse mutableCopy];
        bad[@"x"] = @(1.2);
        Expect(P1EncodeInputMessage(11, bad, &err) == nil &&
               err.code == P1InputErrorBadCoordinate, "reject-x-out-of-range");
        err = nil;
        bad = [mouse mutableCopy];
        bad[@"kind"] = @"joystick";
        Expect(P1EncodeInputMessage(12, bad, &err) == nil &&
               err.code == P1InputErrorBadKind, "reject-unknown-kind");
        err = nil;
        bad = [mouse mutableCopy];
        bad[@"flags"] = @{@"cmd": @"yes"};
        Expect(P1EncodeInputMessage(13, bad, &err) == nil &&
               err.code == P1InputErrorBadFlags, "reject-bad-flags");
        err = nil;
        Expect(P1EncodeInputMessage(14, @{@"kind": @"key", @"displayID": @(1)}, &err) == nil &&
               err.code == P1InputErrorBadKey, "reject-empty-key");
        err = nil;
        Expect(P1EncodeInputMessage(15, P1MakeMouseEvent(1, 0, 0, @"middle", @"move", nil), &err) == nil &&
               err.code == P1InputErrorBadButton, "reject-bad-button");

        // 帧层校验：非 input 消息 / 长度前缀不符
        err = nil;
        NSData *heartbeat = P1EncodeControlMessage(P1MakeControlMessage(@"heartbeat", 1, nil), &err);
        Expect(P1DecodeInputEvent(heartbeat, &err) == nil &&
               err.code == P1InputErrorBadMessage, "reject-non-input-frame");
        err = nil;
        NSMutableData *lying = [frame mutableCopy];
        uint8_t *bytes = lying.mutableBytes;
        bytes[0] = 0x00; bytes[1] = 0x00; bytes[2] = 0x00; bytes[3] = 0x01;
        Expect(P1DecodeInputEvent(lying, &err) == nil &&
               err.code == P1InputErrorBadFrame, "reject-length-prefix-mismatch");

        // 限速：1s 窗口，rate=3；超限只丢 move/scroll
        P1InputRateLimiter *limiter = [[P1InputRateLimiter alloc] initWithEventsPerSecond:3];
        NSDictionary *move = P1MakeMouseEvent(1, 0.1, 0.1, @"left", @"move", nil);
        Expect([limiter shouldAcceptEvent:move atTime:0.0], "rate-first");
        Expect([limiter shouldAcceptEvent:mouse atTime:0.1], "rate-second");
        Expect([limiter shouldAcceptEvent:key atTime:0.2], "rate-third");
        Expect(![limiter shouldAcceptEvent:move atTime:0.3], "rate-drop-move");
        Expect(![limiter shouldAcceptEvent:scroll atTime:0.3], "rate-drop-scroll");
        Expect([limiter shouldAcceptEvent:mouse atTime:0.3], "rate-keep-down");
        Expect([limiter shouldAcceptEvent:key atTime:0.3], "rate-keep-key");
        ExpectInt((long)limiter.droppedEvents, 2, "rate-drop-count");
        Expect([limiter shouldAcceptEvent:move atTime:1.1], "rate-window-expires");
        [limiter reset];
        ExpectInt((long)limiter.droppedEvents, 0, "rate-reset");

        printf(gFail ? "\n%d FAILED\n" : "\nALL PASS\n", gFail);
    }
    return gFail ? 1 : 0;
}
