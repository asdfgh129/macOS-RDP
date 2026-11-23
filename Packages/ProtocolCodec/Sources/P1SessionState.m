//
//  P1SessionState.m
//  P1-ClientProbe
//

#import "P1SessionState.h"

NSString * const P1SessionErrorDomain = @"P1SessionErrorDomain";

NSString *P1SessionStateName(P1SessionState state) {
    switch (state) {
        case P1SessionStateDiscovered:   return @"DISCOVERED";
        case P1SessionStateTLSConnected: return @"TLS_CONNECTED";
        case P1SessionStatePaired:       return @"PAIRED";
        case P1SessionStateNegotiated:   return @"NEGOTIATED";
        case P1SessionStateDisplaysReady:return @"DISPLAYS_READY";
        case P1SessionStateStreaming:    return @"STREAMING";
        case P1SessionStateSuspended:    return @"SUSPENDED";
        case P1SessionStateClosed:       return @"CLOSED";
    }
    return @"UNKNOWN";
}

BOOL P1SessionIsTerminal(P1SessionState state) {
    return state == P1SessionStateClosed;
}

static NSError *P1StateErr(P1SessionErrorCode code, NSString *desc) {
    return [NSError errorWithDomain:P1SessionErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: desc ?: @""}];
}

@implementation P1SessionStateMachine

- (instancetype)init {
    if ((self = [super init])) {
        _state = P1SessionStateDiscovered;
    }
    return self;
}

- (void)reset {
    _state = P1SessionStateDiscovered;
}

- (BOOL)canAcceptInput {
    return _state == P1SessionStateStreaming;
}

- (BOOL)handleEvent:(NSString *)event error:(NSError **)error {
    if (event.length == 0) {
        if (error) *error = P1StateErr(P1SessionErrorInvalidTransition, @"empty event");
        return NO;
    }
    if ([event isEqualToString:@"bye"] || [event isEqualToString:@"session-error"]) {
        if (_state == P1SessionStateClosed) {
            if (error) *error = P1StateErr(P1SessionErrorInvalidTransition, @"already closed");
            return NO;
        }
        _state = P1SessionStateClosed;
        return YES;
    }

    if ([event isEqualToString:@"input"] && _state != P1SessionStateStreaming) {
        if (error) *error = P1StateErr(P1SessionErrorInputNotAllowed, @"input outside STREAMING");
        return NO;
    }

    P1SessionState next = _state;
    BOOL accepted = NO;

    switch (_state) {
        case P1SessionStateDiscovered:
            if ([event isEqualToString:@"hello"] ||
                [event isEqualToString:@"tls-connected"]) {
                next = P1SessionStateTLSConnected;
                accepted = YES;
            }
            break;

        case P1SessionStateTLSConnected:
            if ([event isEqualToString:@"pair-request"] ||
                [event isEqualToString:@"pair-confirm"]) {
                next = P1SessionStatePaired;
                accepted = YES;
            } else if ([event isEqualToString:@"session-resume"]) {
                // 已配对重连：跳过协商，沿用上次协商结果。
                next = P1SessionStateNegotiated;
                accepted = YES;
            }
            break;

        case P1SessionStatePaired:
            if ([event isEqualToString:@"capabilities"]) {
                next = P1SessionStateNegotiated;
                accepted = YES;
            }
            break;

        case P1SessionStateNegotiated:
            if ([event isEqualToString:@"session-start"]) {
                next = P1SessionStateDisplaysReady;
                accepted = YES;
            }
            break;

        case P1SessionStateDisplaysReady:
            if ([event isEqualToString:@"session-ready"]) {
                next = P1SessionStateStreaming;
                accepted = YES;
            }
            break;

        case P1SessionStateStreaming:
            if ([event isEqualToString:@"heartbeat-timeout"]) {
                next = P1SessionStateSuspended;
                accepted = YES;
            } else if ([event isEqualToString:@"heartbeat"] ||
                       [event isEqualToString:@"input"] ||
                       [event isEqualToString:@"keyframe-request"] ||
                       [event isEqualToString:@"keyframe-sent"] ||
                       [event isEqualToString:@"session-update"]) {
                accepted = YES;  // 保持在 STREAMING
            }
            break;

        case P1SessionStateSuspended:
            if ([event isEqualToString:@"session-resume"]) {
                next = P1SessionStateNegotiated;
                accepted = YES;
            }
            break;

        case P1SessionStateClosed:
            break;
    }

    if (!accepted) {
        if (error) {
            NSString *detail = [NSString stringWithFormat:@"%@ not allowed in %@",
                                event, P1SessionStateName(_state)];
            *error = P1StateErr(P1SessionErrorInvalidTransition, detail);
        }
        return NO;
    }
    _state = next;
    return YES;
}

@end
