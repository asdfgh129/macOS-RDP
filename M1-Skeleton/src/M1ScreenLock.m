//
//  M1ScreenLock.m
//  M1-Skeleton
//

#import "M1ScreenLock.h"
#import <dlfcn.h>

static NSString * const kM1LoginFramework =
    @"/System/Library/PrivateFrameworks/login.framework/Versions/A/login";

static void *M1OpenLoginFramework(void) {
    static void *handle = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen(kM1LoginFramework.UTF8String, RTLD_NOW);
    });
    return handle;
}

BOOL M1ScreenLockSymbolAvailable(void) {
    void *h = M1OpenLoginFramework();
    return h && dlsym(h, "SACLockScreenImmediate") != NULL;
}

BOOL M1LockScreenNow(NSError * _Nullable * _Nullable error) {
    void *h = M1OpenLoginFramework();
    if (!h) {
        if (error) *error = [NSError errorWithDomain:@"M1ScreenLock" code:1
            userInfo:@{ NSLocalizedDescriptionKey: @"dlopen login.framework 失败" }];
        return NO;
    }
    typedef void (*LockFn)(void);
    LockFn fn = (LockFn)dlsym(h, "SACLockScreenImmediate");
    if (!fn) {
        if (error) *error = [NSError errorWithDomain:@"M1ScreenLock" code:2
            userInfo:@{ NSLocalizedDescriptionKey: @"SACLockScreenImmediate 符号缺失" }];
        return NO;
    }
    fn();
    return YES;
}
