//
//  ProbeUtil.m
//  P0-TahoeProbe
//

#import "ProbeUtil.h"
#import "CGVirtualDisplaySPI.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <libproc.h>

#pragma mark - Logging

void P0Log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"HH:mm:ss.SSS"];
    fprintf(stderr, "[%s] %s\n", [[fmt stringFromDate:[NSDate date]] UTF8String], [msg UTF8String]);
}

void P0Error(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"HH:mm:ss.SSS"];
    fprintf(stderr, "[%s] !! %s\n", [[fmt stringFromDate:[NSDate date]] UTF8String], [msg UTF8String]);
}

NSString *P0JSONString(id object) {
    if (![NSJSONSerialization isValidJSONObject:object]) {
        object = @{@"unserializable": [[object description] copy] ?: @"(nil)"};
    }
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&err];
    if (!data) return [NSString stringWithFormat:@"{\"jsonError\":\"%@\"}", err.localizedDescription];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

void P0Emit(NSString *stage, NSDictionary *payload) {
    NSMutableDictionary *m = [payload mutableCopy] ?: [NSMutableDictionary dictionary];
    m[@"stage"] = stage;
    m[@"ts"] = @([[NSDate date] timeIntervalSince1970]);
    printf("%s\n", [P0JSONString(m) UTF8String]);
    fflush(stdout);
}

BOOL P0WriteJSON(id object, NSString *path, NSError * _Nullable * _Nullable error) {
    if (![NSJSONSerialization isValidJSONObject:object]) {
        if (error) *error = [NSError errorWithDomain:@"P0" code:1
                                           userInfo:@{NSLocalizedDescriptionKey: @"object is not valid JSON"}];
        return NO;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                  options:NSJSONWritingPrettyPrinted
                                                    error:error];
    if (!data) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

NSDictionary * _Nullable P0ReadJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

NSString *P0RectString(CGRect rect) {
    return [NSString stringWithFormat:@"{%.0f,%.0f,%.0f,%.0f}",
            rect.origin.x, rect.origin.y, rect.size.width, rect.size.height];
}

void P0SleepMs(int ms) {
    usleep((useconds_t)ms * 1000);
}

#pragma mark - Environment

static NSString *P0SysctlString(const char *key) {
    size_t size = 0;
    if (sysctlbyname(key, NULL, &size, NULL, 0) != 0 || size == 0) return @"?";
    char *buf = malloc(size);
    if (!buf) return @"?";
    if (sysctlbyname(key, buf, &size, NULL, 0) != 0) { free(buf); return @"?"; }
    NSString *s = [NSString stringWithUTF8String:buf] ?: @"?";
    free(buf);
    return s;
}

// hw.physicalcpu / hw.logicalcpu 是 int32 而不是 C 字符串。用 P0SysctlString 读它
// 会把 4 字节整数当字符串解析，输出 "\u0006" 这类控制字符（2026-11-17 实测踩到）。
static int P0SysctlInt(const char *key, int fallback) {
    int value = 0;
    size_t size = sizeof(value);
    if (sysctlbyname(key, &value, &size, NULL, 0) != 0) return fallback;
    return value;
}

// GUI 会话判据：CGSessionCopyCurrentDictionary 只在已登录的 Aqua 会话里返回非 NULL。
// 旧实现用 getuid() != 0 判断，对任何非 root 进程恒为真，等于没有判据；
// 而 README §11.4 把 GUI_SESSION 当作第二道闸门，判错会让整轮结论作废。
static BOOL P0IsLoggedInGUI(void) {
    CFDictionaryRef session = CGSessionCopyCurrentDictionary();
    BOOL gui = (session != NULL);
    if (session) CFRelease(session);
    return gui;
}

NSDictionary *P0SystemInfo(void) {
    NSProcessInfo *pi = [NSProcessInfo processInfo];
    NSOperatingSystemVersion v = pi.operatingSystemVersion;
    NSBundle *bundle = [NSBundle mainBundle];
    // 命令行工具的 TCC 归属是父进程（Terminal / iTerm / sshd），记录下来便于排查权限。
    // 命令行工具的 TCC responsible process 就是父进程，名字直接决定该给谁授权。
    pid_t ppid = getppid();
    char pname[256] = {0};
    proc_name(ppid, pname, sizeof(pname));
    NSString *parent = [NSString stringWithUTF8String:pname] ?: @"(unknown)";

#if defined(__arm64__) || defined(__aarch64__)
    NSString *arch = @"arm64";
#else
    NSString *arch = @"x86_64";
#endif

    return @{
        @"osVersion": [NSString stringWithFormat:@"%ld.%ld.%ld",
                       (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion],
        @"arch": arch,
        @"cpuBrand": P0SysctlString("machdep.cpu.brand_string"),
        @"model": P0SysctlString("hw.model"),
        @"physicalCores": @(P0SysctlInt("hw.physicalcpu", -1)),
        @"logicalCores": @(P0SysctlInt("hw.logicalcpu", -1)),
        @"bundleId": bundle.bundleIdentifier ?: @"(command line tool)",
        @"pid": @(getpid()),
        @"parentApp": parent,
        @"uid": @(getuid()),
        @"isLoggedInGUI": @(P0IsLoggedInGUI()),
    };
}

NSDictionary *P0OSPolicy(void) {
    NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
    NSInteger major = v.majorVersion;
    NSString *name;
    P0OSFamily family;
    switch (major) {
        case 26: name = @"Tahoe";   family = P0OSFamilyTahoe;   break;
        case 15: name = @"Sequoia"; family = P0OSFamilySequoia; break;
        case 14: name = @"Sonoma";  family = P0OSFamilyOther;   break;
        case 13: name = @"Ventura"; family = P0OSFamilyOther;   break;
        default:
            name = [NSString stringWithFormat:@"macOS %ld", (long)major];
            family = P0OSFamilyOther;
            break;
    }
    BOOL tahoe = (family == P0OSFamilyTahoe);
    // Tahoe 专属 workaround（保守 canvas / identity walk / offset 持久化）只在 26 上启用；
    // Sequoia 15.5 实证：直建目标分辨率 + 单次 apply 即可提交（diag2 D/F），
    // 而两次 WindowServer 事故恰恰都发生在保守 canvas→promote 路径上。
    // 其它版本走与 Sequoia 相同的最小风险路径，结论仅供参考。
    return @{
        @"osMajor": @(major),
        @"osVersion": [NSString stringWithFormat:@"%ld.%ld.%ld",
                       (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion],
        @"osName": name,
        @"family": @(family),
        @"conservativeFirst": @(tahoe),
        @"identityWalk": @(tahoe),
        @"persistIdentity": @(tahoe),
        @"maxRetries": @(tahoe ? 4 : 1),
        // mode 提交等待全版本必需：15.5 实测 applySettings 异步生效（1–3s），
        // 双屏时第二块屏受全局重配置影响可能更慢，放宽到 10s。
        @"modeWaitMs": @10000,
    };
}

NSArray<NSDictionary *> *P0DisplayList(void) {
    NSMutableArray<NSNumber *> *candidates = [NSMutableArray array];

    // 虚拟屏的 CGDirectDisplayID 往往是任意 32 位数（0x1f0xxxxx 之类），只遍历 1..64
    // 会整块漏掉。先用 Quartz 取 online / active 的真实 ID，再补小 ID 覆盖 stale 僵尸项。
    for (int pass = 0; pass < 2; pass++) {
        uint32_t count = 0;
        CGError cgErr = pass == 0 ? CGGetOnlineDisplayList(0, NULL, &count)
                                  : CGGetActiveDisplayList(0, NULL, &count);
        if (cgErr != kCGErrorSuccess || count == 0) continue;
        CGDirectDisplayID *buf = calloc(count, sizeof(CGDirectDisplayID));
        if (!buf) continue;
        uint32_t got = count;
        cgErr = pass == 0 ? CGGetOnlineDisplayList(count, buf, &got)
                          : CGGetActiveDisplayList(count, buf, &got);
        if (cgErr == kCGErrorSuccess) {
            for (uint32_t i = 0; i < got; i++) [candidates addObject:@(buf[i])];
        }
        free(buf);
    }
    // 1..64：物理屏常见小 ID，且能把 offline 但 bounds 非空的 stale display 一起列出。
    for (CGDirectDisplayID did = 1; did <= 64; did++) [candidates addObject:@(did)];

    NSSet *unique = [NSSet setWithArray:candidates];
    NSArray *sorted = [[unique allObjects] sortedArrayUsingSelector:@selector(compare:)];

    NSMutableArray *out = [NSMutableArray array];
    for (NSNumber *num in sorted) {
        CGDirectDisplayID did = num.unsignedIntValue;
        CGRect bounds = CGDisplayBounds(did);
        BOOL online = CGDisplayIsOnline(did);
        BOOL active = CGDisplayIsActive(did);
        // 实测（15.5 Intel）：不存在的 displayID 上 CGDisplayIsOnline/IsActive 也返回 true，
        // 不能靠它们过滤 1..64 补查带来的幽灵项。真实屏与 stale 屏的 bounds 都非空，
        // 空 bounds 直接跳过即可，stale 僵尸项（bounds 非空但 offline）仍会被列出。
        if (CGRectIsEmpty(bounds)) continue;

        size_t pixelW = 0, pixelH = 0, pointW = 0, pointH = 0;
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(did);
        if (mode) {
            pixelW = CGDisplayModeGetPixelWidth(mode);
            pixelH = CGDisplayModeGetPixelHeight(mode);
            pointW = CGDisplayModeGetWidth(mode);
            pointH = CGDisplayModeGetHeight(mode);
            CGDisplayModeRelease(mode);
        }
        [out addObject:@{
            @"displayID": @(did),
            @"online": @(online),
            @"active": @(active),
            @"builtin": @(CGDisplayIsBuiltin(did)),
            @"main": @(CGDisplayIsMain(did)),
            @"bounds": P0RectString(bounds),
            @"points": [NSString stringWithFormat:@"%zux%zu", pointW, pointH],
            @"pixels": [NSString stringWithFormat:@"%zux%zu", pixelW, pixelH],
            @"vendor": @(CGDisplayVendorNumber(did)),
            @"model": @(CGDisplayModelNumber(did)),
            @"serial": @(CGDisplaySerialNumber(did)),
        }];
    }
    return out;
}

#pragma mark - Private SPI runtime resolution

static NSDictionary<NSString *, Class> *gVDClasses = nil;

static NSArray<NSString *> *VDFrameworkCandidates(void) {
    // Tahoe 把部分系统框架放进 Cryptexes，绝对路径可能失效；先给 dyld 按名字查找的
    // 形式（"X.framework/X"），再补绝对路径兜底。dlopen 失败不视为错误，只要类已注册即可。
    return @[
        @"CoreGraphics.framework/CoreGraphics",
        @"CoreDisplay.framework/CoreDisplay",
        @"/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        @"/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        @"/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
        @"/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay",
        @"/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        @"/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    ];
}

BOOL VDLoadPrivateClasses(void) {
    // CoreGraphics 一般已因链接而加载；显式 dlopen 其余候选，
    // 确保 Objective-C 类在 NSClassFromString 之前完成注册。
    for (NSString *path in VDFrameworkCandidates()) {
        void *h = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL);
        if (h) P0Log(@"dlopen OK: %@", path.lastPathComponent);
    }

    NSArray *names = @[
        @"CGVirtualDisplayMode",
        @"CGVirtualDisplaySettings",
        @"CGVirtualDisplayDescriptor",
        @"CGVirtualDisplay",
    ];
    NSMutableDictionary *found = [NSMutableDictionary dictionary];
    for (NSString *name in names) {
        Class c = NSClassFromString(name);
        if (!c) c = objc_getClass(name.UTF8String);  // runtime 直查，绕开 NSClassFromString 的注册时机差异
        if (c) found[name] = c;
        else P0Error(@"private class NOT FOUND: %@", name);
    }
    gVDClasses = [found copy];
    return (found.count == names.count);
}

Class _Nullable VDClass(NSString *name) {
    if (!gVDClasses) VDLoadPrivateClasses();
    Class c = gVDClasses[name];
    if (!c) c = NSClassFromString(name);
    if (!c) c = objc_getClass(name.UTF8String);
    return c;
}

BOOL VDResponds(id object, SEL selector) {
    return object && selector && [object respondsToSelector:selector];
}

NSArray<NSString *> * _Nullable VDSelectorDump(NSString *className) {
    Class c = VDClass(className);
    if (!c) return nil;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(c, &count);
    NSMutableArray *sels = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        [sels addObject:NSStringFromSelector(method_getName(methods[i]))];
    }
    free(methods);
    // 属性列表单独 dump，能看出 maxPixelsWide / serialNum 这类属性是否被改名。
    unsigned int pcount = 0;
    objc_property_t *props = class_copyPropertyList(c, &pcount);
    for (unsigned int i = 0; i < pcount; i++) {
        [sels addObject:[NSString stringWithFormat:@"@property(%s)", property_getName(props[i])]];
    }
    free(props);
    [sels sortUsingSelector:@selector(compare:)];
    return sels;
}
