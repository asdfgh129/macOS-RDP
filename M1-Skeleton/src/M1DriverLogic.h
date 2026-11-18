//
//  M1DriverLogic.h
//  M1-Skeleton
//
//  RDPDriver 中的纯逻辑（Foundation-only，不碰 WindowServer / CGEvent）。
//  单独成文件以便 CLI 单测无需链接 VDManager / P0VDisplayControl / IOKit。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 凭据 → CGEvent unicode 按键序列。
// 每个元素 @{@"unicode":@(UniChar), @"keyCode":@(CGKeyCode)}；Return 以 keyCode=36 追加。
// 字符由 unicode 决定（keyCode=0 仅占位），避免维护键码表，支持中文（A-03）。
NSArray<NSDictionary *> *M1CredentialEventSequence(NSString *credential)
    NS_SWIFT_NAME(credentialEventSequence(_:));

// C-09 隔离判定：active ⊆ 本会话虚拟屏则返回 nil，否则返回泄漏的物理屏 ID 数组。
NSArray<NSNumber *> * _Nullable M1IsolationLeakedDisplays(NSArray<NSNumber *> *active,
                                                           NSArray<NSNumber *> *sessionVirtuals)
    NS_SWIFT_NAME(isolationLeakedDisplays(active:sessionVirtuals:));

// C-09 完整判定：既检查「有物理屏泄漏」，也检查「一块 active 屏都没有」。
//
// 后者是 2026-11-18 黑屏事故的直接成因：探针把 keepIDs 传成了空数组，
// 于是连刚建好的虚拟屏也被一起禁用，active 变成空集；
// 而旧判定用的是「active ⊆ 虚拟屏」，空集天然满足，安全检查直接放行，
// 系统进入「零显示」状态 —— 没有画面、没有光标、唤醒事件无处落地。
// 返回 nil 表示隔离成立；否则返回违规原因（纯字符串，便于日志与断言）。
NSString * _Nullable M1IsolationViolation(NSArray<NSNumber *> *active,
                                          NSArray<NSNumber *> *sessionVirtuals)
    NS_SWIFT_NAME(isolationViolation(active:sessionVirtuals:));

NS_ASSUME_NONNULL_END
