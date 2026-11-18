// P1SessionState 单元测试：覆盖 PROTOCOL.md §2 状态迁移与 §6 输入态约束。
#import <Foundation/Foundation.h>
#import "P1SessionState.h"

static int gFail = 0;
static void Expect(BOOL cond, const char *name) {
    if (cond) printf("[PASS] %s\n", name);
    else { gFail++; printf("[FAIL] %s\n", name); }
}
static void ExpectState(P1SessionStateMachine *sm, P1SessionState want, const char *name) {
    if (sm.state == want) printf("[PASS] %s\n", name);
    else {
        gFail++;
        printf("[FAIL] %s got=%s want=%s\n", name,
               [P1SessionStateName(sm.state) UTF8String], [P1SessionStateName(want) UTF8String]);
    }
}
static BOOL Fire(P1SessionStateMachine *sm, NSString *event) {
    NSError *err = nil;
    BOOL ok = [sm handleEvent:event error:&err];
    if (!ok) printf("  (rejected %s: %s)\n", [event UTF8String], err.localizedDescription.UTF8String);
    return ok;
}

int main(void) {
    @autoreleasepool {
        P1SessionStateMachine *sm = [[P1SessionStateMachine alloc] init];
        ExpectState(sm, P1SessionStateDiscovered, "initial-state");
        Expect([P1SessionStateName(P1SessionStateStreaming) isEqual:@"STREAMING"], "state-name");
        Expect(!P1SessionIsTerminal(P1SessionStateSuspended) &&
               P1SessionIsTerminal(P1SessionStateClosed), "terminal-state");

        // 会话前输入必须拒绝
        NSError *err = nil;
        Expect(![sm handleEvent:@"input" error:&err] &&
               err.code == P1SessionErrorInputNotAllowed, "input-before-streaming-rejected");
        Expect(![sm canAcceptInput], "input-not-accepted-yet");

        // 完整链路
        Expect(Fire(sm, @"hello"), "event-hello");
        ExpectState(sm, P1SessionStateTLSConnected, "state-tls");
        Expect(Fire(sm, @"pair-request"), "event-pair-request");
        ExpectState(sm, P1SessionStatePaired, "state-paired");
        Expect(Fire(sm, @"capabilities"), "event-capabilities");
        ExpectState(sm, P1SessionStateNegotiated, "state-negotiated");
        Expect(Fire(sm, @"session-start"), "event-session-start");
        ExpectState(sm, P1SessionStateDisplaysReady, "state-displays-ready");
        Expect(Fire(sm, @"session-ready"), "event-session-ready");
        ExpectState(sm, P1SessionStateStreaming, "state-streaming");
        Expect([sm canAcceptInput], "input-accepted-in-streaming");

        // STREAMING 内自环事件
        NSArray *inFlow = @[@"input", @"heartbeat", @"keyframe-request", @"keyframe-sent", @"session-update"];
        for (NSString *e in inFlow) {
            Expect(Fire(sm, e), [[NSString stringWithFormat:@"streaming-self-%@", e] UTF8String]);
        }
        ExpectState(sm, P1SessionStateStreaming, "still-streaming");

        // 心跳超时 → 重连 → 关闭
        Expect(Fire(sm, @"heartbeat-timeout"), "event-heartbeat-timeout");
        ExpectState(sm, P1SessionStateSuspended, "state-suspended");
        Expect(![sm canAcceptInput], "input-rejected-while-suspended");
        Expect(Fire(sm, @"session-resume"), "event-session-resume");
        ExpectState(sm, P1SessionStateNegotiated, "resume-to-negotiated");
        Expect(Fire(sm, @"bye"), "event-bye");
        ExpectState(sm, P1SessionStateClosed, "state-closed");

        // CLOSED 是终态
        Expect(!Fire(sm, @"hello"), "closed-is-terminal");

        // 已配对重连：TLS_CONNECTED 直接 session-resume
        P1SessionStateMachine *resume = [[P1SessionStateMachine alloc] init];
        Expect(Fire(resume, @"tls-connected") && Fire(resume, @"session-resume"), "resume-fast-path");
        ExpectState(resume, P1SessionStateNegotiated, "resume-fast-state");

        // 非法迁移：NEGOTIATED 不能直跳 STREAMING；PIARED 不能重复 pair-confirm
        P1SessionStateMachine *bad = [[P1SessionStateMachine alloc] init];
        err = nil;
        Expect(![bad handleEvent:@"session-ready" error:&err] &&
               err.code == P1SessionErrorInvalidTransition, "reject-jump-to-streaming");
        Expect(Fire(bad, @"hello") && Fire(bad, @"pair-request"), "bad-fsm-setup");
        Expect(!Fire(bad, @"pair-confirm"), "reject-duplicate-pair");

        // reset 全清
        [resume reset];
        ExpectState(resume, P1SessionStateDiscovered, "reset-returns-to-discovered");

        printf(gFail ? "\n%d FAILED\n" : "\nALL PASS\n", gFail);
    }
    return gFail ? 1 : 0;
}
