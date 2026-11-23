//
//  M1Takeover.m
//  M1-Skeleton
//

#import "M1Takeover.h"

@interface M1TakeoverDetector ()
@property (nonatomic, assign) double shiftDownAt;
@property (nonatomic, assign) double graceDeadline;
@property (nonatomic, assign) double totalDeferred;
@property (nonatomic, assign) BOOL gestureFired;
@end

@implementation M1TakeoverDetector

- (instancetype)init {
    self = [super init];
    if (self) {
        _shiftHoldSeconds = 3.0;
        _graceSeconds = 10.0;
        _maxDeferSeconds = 60.0;
    }
    return self;
}

- (M1TakeoverVerdict)handleSignal:(M1TakeoverSignal)signal atTime:(double)now {
    switch (signal) {
        case M1TakeoverSignalShiftDown:
            if (!_shiftHeld) {
                _shiftHeld = YES;
                _shiftDownAt = now;
            }
            return M1TakeoverVerdictNone;

        case M1TakeoverSignalShiftUp:
            // 已触发的缓冲不因松手撤销（D-06：客户端只能延后不能否决）。
            if (_shiftHeld && !_gestureFired) {
                _shiftHeld = NO;
                _shiftDownAt = 0;
            }
            return M1TakeoverVerdictNone;

        case M1TakeoverSignalHotplug:
        case M1TakeoverSignalSleepWake:
        case M1TakeoverSignalScreenLock:
            // 二级 fail-safe：立即断开，清掉可能在进行的缓冲。
            _shiftHeld = NO;
            _gestureFired = NO;
            _pendingDisconnect = NO;
            return M1TakeoverVerdictForceDisconnect;
    }
    return M1TakeoverVerdictNone;
}

- (M1TakeoverVerdict)tickAtTime:(double)now {
    // 一级手势判定：Shift 按住超过阈值。
    if (_shiftHeld && !_gestureFired && now - _shiftDownAt >= _shiftHoldSeconds) {
        _gestureFired = YES;
        _pendingDisconnect = YES;
        _graceDeadline = now + _graceSeconds;
        _totalDeferred = 0;
        return M1TakeoverVerdictGestureStarted;
    }
    // 缓冲到期：强制断开。
    if (_pendingDisconnect && now >= _graceDeadline) {
        _pendingDisconnect = NO;
        _shiftHeld = NO;
        return M1TakeoverVerdictForceDisconnect;
    }
    return M1TakeoverVerdictNone;
}

- (M1TakeoverVerdict)requestDeferAtTime:(double)now {
    if (!_pendingDisconnect) return M1TakeoverVerdictDeferRejected;
    double remaining = _graceDeadline - now;
    if (remaining <= 0) {
        _pendingDisconnect = NO;
        return M1TakeoverVerdictForceDisconnect;
    }
    // 每次延后一个 graceSeconds（把 deadline 后移），累计不超过 maxDeferSeconds。
    double grant = _graceSeconds;
    if (_totalDeferred + grant > _maxDeferSeconds + 1e-9) {
        grant = MAX(0.0, _maxDeferSeconds - _totalDeferred);
        if (grant <= 1e-9) return M1TakeoverVerdictDeferRejected;
    }
    _totalDeferred += grant;
    _graceDeadline += grant;
    _deferCount++;
    return M1TakeoverVerdictDeferAccepted;
}

- (void)reset {
    _shiftHeld = NO;
    _shiftDownAt = 0;
    _gestureFired = NO;
    _pendingDisconnect = NO;
    _graceDeadline = 0;
    _totalDeferred = 0;
    _deferCount = 0;
}

@end
