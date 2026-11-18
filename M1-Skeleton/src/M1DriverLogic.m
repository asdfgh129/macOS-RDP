//
//  M1DriverLogic.m
//  M1-Skeleton
//

#import "M1DriverLogic.h"

NSArray<NSDictionary *> *M1CredentialEventSequence(NSString *credential) {
    NSMutableArray *seq = [NSMutableArray array];
    for (NSUInteger i = 0; i < credential.length; i++) {
        UniChar u = [credential characterAtIndex:i];
        [seq addObject:@{ @"unicode": @(u), @"keyCode": @(0) }]; // 'a' 占位，字符由 unicode 决定
    }
    [seq addObject:@{ @"unicode": @(0), @"keyCode": @(36) }];    // Return
    return seq;
}

NSArray<NSNumber *> *M1IsolationLeakedDisplays(NSArray<NSNumber *> *active,
                                                NSArray<NSNumber *> *sessionVirtuals) {
    NSSet *allowed = [NSSet setWithArray:sessionVirtuals];
    NSMutableArray *leaked = [NSMutableArray array];
    for (NSNumber *n in active) if (![allowed containsObject:n]) [leaked addObject:n];
    return leaked.count ? leaked : nil;
}

NSString *M1IsolationViolation(NSArray<NSNumber *> *active,
                               NSArray<NSNumber *> *sessionVirtuals) {
    // 空 active 是比“泄漏”更严重的故障：系统没有任何显示在画，
    // 用户侧表现为整屏黑死且无法唤醒（2026-11-18 实测）。
    if (active.count == 0) {
        return @"no-active-display（零显示：所有屏都被禁用，系统无处绘制）";
    }
    NSArray<NSNumber *> *leaked = M1IsolationLeakedDisplays(active, sessionVirtuals);
    if (leaked.count > 0) {
        return [NSString stringWithFormat:@"physical-leak（active 仍含非本会话屏 %@）",
                [leaked componentsJoinedByString:@","]];
    }
    return nil;
}
