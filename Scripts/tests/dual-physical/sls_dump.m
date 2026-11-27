//
//  sls_dump.m —— 打印 SkyLight 注册表里每块屏的详情（只读，不改显示配置）
//  用途：双物理屏独占异常后判断物理屏是否还在 WS 注册表里（enabled/online/active）。
//
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "P0VDisplayControl.h"

int main(void) {
    @autoreleasepool {
        NSArray<NSNumber *> *sls = P0VAllDisplayIDsFromSkyLight();
        NSArray<NSNumber *> *active = P0VActiveDisplayIDs();
        printf("sls=%lu active=%lu\n", (unsigned long)sls.count, (unsigned long)active.count);
        NSArray<NSDictionary *> *dicts = P0VDisplayDictionaries(sls ?: @[]);
        for (NSDictionary *d in dicts) {
            printf("  id=%-12u vendor=0x%08x model=%-6u online=%d active=%d builtin=%d mirrorOf=%u points=%s\n",
                   [d[@"id"] unsignedIntValue],
                   [d[@"vendorID"] unsignedIntValue],
                   [d[@"modelID"] unsignedIntValue],
                   [d[@"online"] boolValue], [d[@"active"] boolValue],
                   [d[@"builtin"] boolValue], [d[@"mirrorOf"] unsignedIntValue],
                   [(d[@"points"] ?: @"?") UTF8String]);
        }
    }
    return 0;
}
