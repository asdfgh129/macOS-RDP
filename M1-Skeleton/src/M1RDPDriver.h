//
//  M1RDPDriver.h
//  M1-Skeleton
//
//  M1SessionDriver 的生产实现：把 WindowServer / 系统操作接到真实 API。
//    - 防睡眠断言：IOKit IOPMAssertionCreateWithName(PreventUserIdleDisplaySleep)
//    - 建屏：VDManager（建齐先于禁屏，D-05）
//    - 禁屏/恢复：P0VDisplayControl（快照 + SLSConfigureDisplayEnabled + 守护恢复）
//    - C-09 隔离：CGGetActiveDisplayList ⊆ 本会话虚拟屏
//    - 凭据注入：CGEventPostToPid(loginwindow) + unicode（V-04 已验证路径，凭据不落盘）
//    - 锁屏：M1ScreenLock（SACLockScreenImmediate）
//
//  安全约束（沿用 P0V 探针）：
//    1. 禁屏前写快照并 spawn 守护进程；任何崩溃/强杀由守护兜底恢复。
//    2. WindowServer 事务超时（P0VWindowServerHung）后不再发配置请求。
//    3. 恢复时先启用物理屏，再销毁虚拟屏，最后写 .done 让守护退出。
//

#import <Foundation/Foundation.h>
#import "M1SessionCoordinator.h"
#import "M1DriverLogic.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const M1RDPDriverErrorDomain;

typedef NS_ENUM(NSInteger, M1RDPDriverErrorCode) {
    M1RDPDriverErrorNoAssertion = 1,
    M1RDPDriverErrorNoDisplays,
    M1RDPDriverErrorSnapshotFailed,
    M1RDPDriverErrorGuardianFailed,
    M1RDPDriverErrorDisableFailed,
    M1RDPDriverErrorIsolationViolated,
    M1RDPDriverErrorNoLoginwindow,
    M1RDPDriverErrorInjectFailed,
    M1RDPDriverErrorRestoreFailed,
    M1RDPDriverErrorWindowServerHung,
};

// 纯函数 M1CredentialEventSequence / M1IsolationLeakedDisplays 见 M1DriverLogic.h。

@interface M1RDPDriver : NSObject <M1SessionDriver>

// 快照与守护文件路径（便于测试注入临时目录；默认 NSTemporaryDirectory）。
@property (nonatomic, copy) NSString *snapshotBasePath;

// 以下只读反映内部状态，便于集成核对。
@property (nonatomic, strong, readonly, nullable) NSArray<NSNumber *> *lastActiveDisplayIDs;
@property (nonatomic, copy, readonly, nullable) NSString *snapshotPath;

// 会话结束时窗口布局恢复摘要（captured/planned/restored/failed/skipped/trusted）。
// 未禁屏或没有窗口需要搬回时为 nil。
@property (nonatomic, copy, readonly, nullable) NSDictionary *lastWindowRestoreSummary;

// 只读侦察：返回当前 active display / 私有符号可用性 / 守护状态，不改动显示配置。
- (NSDictionary *)probeEnvironment;

// 预备兜底护盾：快照当前 active 拓扑（此时还没有虚拟屏）→ 写盘 → 启动守护并等待就绪握手。
// ★ 必须在建虚拟屏之前调用，且建屏本身会自动调用它（顺序不可调换）：
//   - 快照里若混进了本会话虚拟屏，恢复时会把它当成 main，销毁后拓扑就碎了；
//   - 守护没就绪就禁屏 = 黑屏无兜底（2026-11-18 事故）。
// 返回 NO 时调用方绝不能继续做任何显示配置变更。
- (BOOL)prepareSessionShieldError:(NSError **)error;

// 撤盾：仅写 .done 让守护退出，不做任何显示配置变更（用于 --preflight 这类只验链路不改状态的场景）。
- (void)disarmShield;

@end

NS_ASSUME_NONNULL_END
