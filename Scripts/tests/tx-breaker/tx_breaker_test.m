//
//  tx_breaker_test.m
//  显示事务硬熔断（NFR-06）故障注入测试
//
//  背景：RESULTS-BY-OS §5.48 I 把「真挂起（WindowServer 冻结）的硬熔断」列为未闭合项，
//  因为人工冻结 WindowServer 会连带崩显示栈并踢回 loginwindow。这里换一种注入方式：
//  在 P0VPerformTransactionV 内部让事务线程永不返回（P0V_FAULT_TX），
//  显示配置根本不会提交，因此物理屏不受影响，但事务语义与真挂起一致。
//
//  三种模式：
//    normal    幂等事务（把已 active 的主屏再 enable 一次），验证正常路径不被误判
//    hang      事务线程不返回、WS 可响应 → 应在软死线 8s + 宽限期 12s 后熔断
//    wsfreeze  事务线程不返回、WS 探测无响应 → 应在软死线 + 1s 探测窗口内熔断
//
//  判据还包括：熔断后必须拒绝后续显示事务（不再发 SPI），且物理屏状态未被改动。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#import "P0VDisplayControl.h"

static double Now(void) { return CFAbsoluteTimeGetCurrent(); }

static BOOL ContainsID(NSArray<NSNumber *> *ids, CGDirectDisplayID did) {
    for (NSNumber *n in ids) if (n.unsignedIntValue == did) return YES;
    return NO;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *mode = (argc > 1) ? [NSString stringWithUTF8String:argv[1]] : @"normal";
        const char *fault = getenv("P0V_FAULT_TX");
        CGDirectDisplayID mainID = CGMainDisplayID();
        NSArray<NSNumber *> *activeBefore = P0VActiveDisplayIDs();

        printf("== tx-breaker ==\n");
        printf("mode            : %s\n", mode.UTF8String);
        printf("P0V_FAULT_TX    : %s\n", (fault && *fault) ? fault : "(unset)");
        printf("main display    : %u\n", mainID);
        printf("active before   : %s\n", [[activeBefore description] UTF8String]);
        fflush(stdout);

        BOOL expectFault = ![mode isEqualToString:@"normal"];
        if (expectFault && (!fault || !*fault)) {
            printf("FAIL: 故障模式必须先设置 P0V_FAULT_TX=hang|wsfreeze（否则会真的禁用物理屏）\n");
            return 2;
        }
        if (!expectFault && fault && *fault) {
            printf("FAIL: normal 模式不允许带 P0V_FAULT_TX\n");
            return 2;
        }

        NSDictionary *detail = nil;
        NSError *err = nil;
        double t0 = Now();
        BOOL ok = expectFault
            // 故障注入下事务永不提交：把主屏放进 toDisable 只是为了让 verify 始终为假
            ? P0VApplyDisplayEnabledChanges(@[@(mainID)], @[], P0VCommitScopeSession, 8, &detail, &err)
            // 正常路径用幂等事务（已 active 的屏再 enable），不会改变任何显示状态
            : P0VApplyDisplayEnabledChanges(@[], @[@(mainID)], P0VCommitScopeSession, 8, &detail, &err);
        double elapsed = Now() - t0;

        NSArray<NSNumber *> *activeAfter = P0VActiveDisplayIDs();
        BOOL hung = P0VWindowServerHung();

        printf("returned        : %s (code=%ld)\n", ok ? "YES" : "NO", (long)err.code);
        printf("elapsed         : %.2fs\n", elapsed);
        printf("detail          : %s\n", [[detail description] UTF8String]);
        printf("hung flag       : %s\n", hung ? "YES" : "NO");
        printf("active after    : %s\n", [[activeAfter description] UTF8String]);

        __block int failures = 0;
        void (^check)(BOOL, NSString *) = ^(BOOL cond, NSString *what) {
            printf("  %s %s\n", cond ? "PASS" : "FAIL", what.UTF8String);
            if (!cond) failures++;
        };

        if (!expectFault) {
            check(ok, @"正常幂等事务应成功");
            check(elapsed < 3.0, @"正常事务应在 3s 内返回");
            check(!hung, @"正常事务不得置挂起标志");
            check(err == nil, @"正常事务不应有错误");
            check(ContainsID(activeAfter, mainID), @"主屏应仍然 active");
        } else {
            check(!ok, @"故障注入下事务必须判定失败");
            check(err != nil && err.code == 11, @"错误码应为 11（事务超时/疑似挂起）");
            check(hung, @"必须置 WindowServer 挂起标志");
            check(detail[@"timedOut"] != nil, @"detail 应带 timedOut");
            check(ContainsID(activeAfter, mainID), @"故障注入不得真正改动物理屏");

            NSString *reason = detail[@"reason"];
            if ([mode isEqualToString:@"hang"]) {
                check(elapsed >= 7.8 && elapsed <= 21.5,
                      @"hang：应在 8s 软死线 + 12s 宽限期后熔断（实测窗口 7.8–21.5s）");
                check([reason isEqualToString:@"state-not-converged"],
                      @"hang：熔断原因应为 state-not-converged");
            } else if ([mode isEqualToString:@"wsfreeze"]) {
                check(elapsed >= 7.8 && elapsed <= 11.5,
                      @"wsfreeze：应在软死线 + ≤1s 探测窗口内熔断（NFR-06 的 8s 语义）");
                check([reason isEqualToString:@"ws-unresponsive"],
                      @"wsfreeze：熔断原因应为 ws-unresponsive");
            } else {
                printf("FAIL: 未知模式 %s\n", mode.UTF8String);
                failures++;
            }

            // 熔断后不得再发显示事务：应立即拒绝，且错误码 10。
            NSDictionary *d2 = nil;
            NSError *e2 = nil;
            double t1 = Now();
            BOOL ok2 = P0VApplyDisplayEnabledChanges(@[], @[@(mainID)], P0VCommitScopeSession, 8, &d2, &e2);
            double dt2 = Now() - t1;
            printf("2nd call        : ok=%d code=%ld elapsed=%.3fs\n",
                   ok2, (long)e2.code, dt2);
            check(!ok2 && e2.code == 10, @"熔断后必须拒绝新事务（code 10）");
            check(dt2 < 0.2, @"拒绝应即时返回（<200ms），证明没有再发 SPI");
            check(P0VWindowServerHung(), @"拒绝后挂起标志保持");
        }

        printf("== %s ==\n", failures == 0 ? "PASS" : "FAIL");
        return failures == 0 ? 0 : 1;
    }
}
