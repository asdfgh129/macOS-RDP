//
//  main.m
//  veild-host-agent
//
//  第一轮工程骨架的可执行入口。仅引用现有 M1 纯逻辑，证明源码路径与 target 接线正确；
//  真实采集/编码/驱动管线仍在 M1-Skeleton，第二轮再归位。
//

#import <Foundation/Foundation.h>
#import "M1Pairing.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        M1PairingState *state = [[M1PairingState alloc] initWithStore:[[M1InMemoryPairingStore alloc] init]];
        NSString *code = [state issueCodeAtTime:NSDate.date.timeIntervalSince1970];
        printf("veild-host-agent shell ok; pairing code=%s\n", code.UTF8String);
    }
    return 0;
}
