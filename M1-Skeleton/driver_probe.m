//
//  driver_probe.m
//  M1-Skeleton
//
//  RDPDriver 只读侦察入口：只调用 probeEnvironment（不建屏/禁屏/注入/锁屏）。
//  用于验证驱动层可编译链接且对当前环境只读判定正确。
//

#import <Foundation/Foundation.h>
#import "M1RDPDriver.h"

int main(void) {
    @autoreleasepool {
        M1RDPDriver *driver = [[M1RDPDriver alloc] init];
        NSDictionary *env = [driver probeEnvironment];
        NSData *json = [NSJSONSerialization dataWithJSONObject:env
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
        printf("%s\n", json ? [[[NSString alloc] initWithData:json
            encoding:NSUTF8StringEncoding] UTF8String] : "{}\n");
        return 0;
    }
}
