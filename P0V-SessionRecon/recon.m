// P0V-SessionRecon/recon.m
// 目的：只读侦察「macOS 独占式会话」所需的私有能力在本机是否存在，以及是否被 entitlement 拦截。
//
// 背景（2026-11-17 需求修正）：
//   产品要求是「控制端登入 → 被控端锁屏/置黑 → 控制端看到的是自己规格的桌面」，
//   不是 VNC 镜像（不捕获、不暴露被控端物理屏）。因此需要的三件能力：
//     1. 建虚拟屏并把桌面放到虚拟屏上      → CGVirtualDisplay（P0 已验证）
//     2. 把物理屏置黑/禁用，且不影响虚拟屏  → 本工具侦察（SLSConfigureDisplayEnabled 等）
//     3. 会话级独占（不是新建会话）          → 本工具侦察 + entitlement 取证
//
// 安全约束：默认只读。--test-config 仅做「开事务 → 取消」，不提交任何显示变更。
//
// 输出：人类可读行 + 末尾一行 JSON（供脚本解析）。

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <dlfcn.h>

extern CFDictionaryRef CGSessionCopyCurrentDictionary(void);

static NSMutableArray *gChecks = nil;

static void record(NSString *group, NSString *name, BOOL exists, NSString *note) {
    [gChecks addObject:@{@"group": group, @"name": name,
                         @"exists": @(exists), @"note": note ?: @""}];
    printf("  %-6s %-46s %s\n", exists ? "YES" : "no", name.UTF8String, note.UTF8String);
}

static void checkSym(void *h, NSString *group, const char *sym) {
    void *p = h ? dlsym(h, sym) : NULL;
    record(group, [NSString stringWithUTF8String:sym], p != NULL, p ? @"" : @"");
}

static void dumpSelectors(NSString *group, const char *cls) {
    Class c = objc_getClass(cls);
    if (!c) { record(group, [NSString stringWithFormat:@"class %s", cls], NO, @"未找到"); return; }
    record(group, [NSString stringWithFormat:@"class %s", cls], YES,
           [NSString stringWithFormat:@"super=%s", class_getName(class_getSuperclass(c))]);
    unsigned int n = 0;
    Method *ms = class_copyMethodList(object_getClass(c), &n);
    for (unsigned i = 0; i < n; i++) {
        const char *sn = sel_getName(method_getName(ms[i]));
        if (strstr(sn, "ession") || strstr(sn, "isplay") || strstr(sn, "haring")) {
            record(group, [NSString stringWithFormat:@"+[%s %s]", cls, sn], YES, @"");
        }
    }
    free(ms);
}

// 只做「开事务 → 取消」，不提交，不改任何显示状态。
// 这一步验证的是：我们能否进入显示配置事务（公开 API，无需 entitlement），
// 从而在同一个事务里调用私有 SLSConfigureDisplayEnabled 去禁用物理屏。
static NSString *testConfigTransaction(void) {
    CGDisplayConfigRef cfg = NULL;
    CGError e = CGBeginDisplayConfiguration(&cfg);
    if (e != kCGErrorSuccess || cfg == NULL) {
        return [NSString stringWithFormat:@"CGBeginDisplayConfiguration 失败: err=%d cfg=%p", e, cfg];
    }
    CGError c = CGCancelDisplayConfiguration(cfg);
    return [NSString stringWithFormat:@"begin OK（cfg 非空），cancel=%d（0=成功）", c];
}

static NSArray *displayTopology(void) {
    uint32_t n = 0;
    CGGetActiveDisplayList(0, NULL, &n);
    CGDirectDisplayID ids[16];
    CGGetActiveDisplayList(n, ids, &n);
    NSMutableArray *out = [NSMutableArray array];
    for (uint32_t i = 0; i < n; i++) {
        CGRect b = CGDisplayBounds(ids[i]);
        [out addObject:@{
            @"id": @(ids[i]),
            @"pixels": [NSString stringWithFormat:@"%zux%zu",
                        CGDisplayPixelsWide(ids[i]), CGDisplayPixelsHigh(ids[i])],
            @"bounds": [NSString stringWithFormat:@"%.0fx%.0f", b.size.width, b.size.height],
            @"main": @(CGDisplayIsMain(ids[i])),
            @"mirrors": @(CGDisplayMirrorsDisplay(ids[i])),
            @"asleep": @(CGDisplayIsAsleep(ids[i])),
            @"vendorID": @(CGDisplayVendorNumber(ids[i])),
            @"modelID": @(CGDisplayModelNumber(ids[i])),
        }];
    }
    return out;
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    BOOL testConfig = NO;
    for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--test-config")) testConfig = YES;

    gChecks = [NSMutableArray array];

    printf("=== 0. 环境 ===\n");
    NSProcessInfo *pi = [NSProcessInfo processInfo];
    record(@"env", @"operatingSystemVersion",
           YES, [NSString stringWithFormat:@"%@", pi.operatingSystemVersionString]);

    printf("\n=== 1. 会话层：能否创建/枚举 GUI 会话 ===\n");
    void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW);
    record(@"session", @"dlopen SkyLight", sl != NULL, sl ? @"" : @"失败");
    const char *sessSyms[] = {
        "SLSCopySessionList", "SLSCopyCurrentSessionDictionary",
        "SLSCreateSession", "SLSCreateSessionWithDataAndVisibility",
        "SLSCreateSessionWithDataAndOptions", "SLSCreateLoginSession",
        "SLSMoveSessionToConsoleTemporaryBridge",
        "SLSSessionCreateSessionIDWithOptions", "SLSSessionSwitchToAuditSessionID",
        "SLSSessionCopyAllSessionProperties", NULL
    };
    for (int i = 0; sessSyms[i]; i++) checkSym(sl, @"session", sessSyms[i]);
    dumpSelectors(@"session", "SLSessionOwner");

    printf("\n=== 2. 显示控制：能否把物理屏置黑/禁用 ===\n");
    const char *dispSyms[] = {
        "SLSBeginDisplayConfiguration", "SLSConfigureDisplayEnabled",
        "SLSConfigureDisplayMirrorOfDisplay", "SLSConfigureDisplayMode",
        "SLSConfigureDisplayOrigin", "SLSCompleteDisplayConfiguration",
        "SLSCaptureDisplay", "SLSGetDisplayList", "SLSGetOnlineDisplayList", NULL
    };
    for (int i = 0; dispSyms[i]; i++) checkSym(sl, @"display", dispSyms[i]);
    printf("  -- 公开等价物 --\n");
    const char *pubSyms[] = {
        "CGBeginDisplayConfiguration", "CGConfigureDisplayMirrorOfDisplay",
        "CGCompleteDisplayConfiguration", "CGCancelDisplayConfiguration",
        "CGDisplayCapture", "CGDisplayRelease", "CGDisplaySetDisplayMode", NULL
    };
    for (int i = 0; pubSyms[i]; i++) checkSym(RTLD_DEFAULT, @"display-public", pubSyms[i]);

    printf("\n=== 3. 锁屏能力 ===\n");
    void *lg = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_NOW);
    record(@"lock", @"dlopen login.framework", lg != NULL, lg ? @"" : @"失败");
    checkSym(lg, @"lock", "SACLockScreenImmediate");
    checkSym(sl, @"lock", "SLSDeviceLock");

    printf("\n=== 4. 当前显示拓扑 ===\n");
    NSArray *topo = displayTopology();
    for (NSDictionary *d in topo) {
        printf("  id=%-12s %-10s main=%s mirrors=%s vendor=%s\n",
               [d[@"id"] description].UTF8String, [d[@"pixels"] UTF8String],
               [d[@"main"] boolValue] ? "Y" : "N",
               [d[@"mirrors"] description].UTF8String,
               [d[@"vendorID"] description].UTF8String);
    }

    NSMutableDictionary *json = [NSMutableDictionary dictionary];
    json[@"checks"] = gChecks;
    json[@"topology"] = topo;
    json[@"osVersion"] = pi.operatingSystemVersionString;

    CFDictionaryRef cur = CGSessionCopyCurrentDictionary();
    if (cur) {
        json[@"currentSession"] = [(__bridge id)cur copy];
        CFRelease(cur);
    }

    typedef void *(*ListFn)(void);
    ListFn listFn = sl ? (ListFn)dlsym(sl, "SLSCopySessionList") : NULL;
    if (listFn) {
        CFArrayRef arr = (CFArrayRef)listFn();
        if (arr) { json[@"sessions"] = (__bridge id)arr; CFRelease(arr); }
    }

    if (testConfig) {
        printf("\n=== 5. 显示配置事务（开→取消，不提交）===\n");
        NSString *r = testConfigTransaction();
        printf("  %s\n", r.UTF8String);
        json[@"configTransaction"] = r;
    }

    printf("\n=== JSON ===\n");
    NSData *out = [NSJSONSerialization dataWithJSONObject:json
                                                  options:NSJSONWritingSortedKeys
                                                    error:NULL];
    printf("%s\n", [[[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] UTF8String]);
    return 0;
} }
