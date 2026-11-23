//
//  M1ScreenLock.h
//  M1-Skeleton
//
//  SACLockScreenImmediate 私有符号封装（login.framework）。
//  仅通过 dlsym 调用，不做静态链接；符号缺失时返回 NO 而不崩溃。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 立即锁屏。成功 YES；framework/symbol 缺失返回 NO 并填 error。
BOOL M1LockScreenNow(NSError * _Nullable * _Nullable error);

// 符号是否可解析（不触发锁屏）。
BOOL M1ScreenLockSymbolAvailable(void);

NS_ASSUME_NONNULL_END
