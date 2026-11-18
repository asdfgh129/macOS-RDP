//
//  M1SessionCoordinator.h
//  M1-Skeleton
//
//  Host 独占会话生命周期编排（D-04 / D-06 / D-08 Path A）。不实现帧管线（D-10 留接口）。
//
//  Path A 固定步骤（顺序不可调换）：
//    0 防睡眠断言（D-08 前置；屏睡会让采集为空）
//    1 选择规格（客户端决定 N 屏 / 分辨率）
//    2 建齐全部虚拟屏（必须在禁物理屏之前，D-05 平台崩溃点）
//    3 快照 + 禁全部物理屏（C-09 显示空间隔离；登录 UI 自动迁移到虚拟屏）
//    4 [可选] 远程登录：呈现登录界面 → 注入凭据解锁（凭据不落盘）
//    5 STREAMING（帧管线接入点，本版留空）
//    6 断开：恢复物理屏（按快照）→ 销毁虚拟屏 → 锁屏（D-06）
//
//  现场接管（D-06 §3）走 M1TakeoverDetector，触发时跳过缓冲直接 step 6。
//
//   WindowServer 操作通过 id<M1SessionDriver> 注入，便于单测状态序列；
//   生产驱动由 RDPKit 提供（封装 VDManager + P0VDisplayControl + M1ScreenLock）。
//

#import <Foundation/Foundation.h>
#import "M1Takeover.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const M1SessionErrorDomain;

typedef NS_ENUM(NSInteger, M1SessionErrorCode) {
    M1SessionErrorBadSpecs = 1,
    M1SessionErrorStepFailed,
    M1SessionErrorRecoveryFailed,
    M1SessionErrorNeedCredential,
};

typedef NS_ENUM(NSInteger, M1HostSessionPhase) {
    M1HostSessionIdle = 0,
    M1HostSessionPreventingSleep,
    M1HostSessionDisplaysCreating,
    M1HostSessionDisplaysReady,
    M1HostSessionPhysicalDisabled,
    M1HostSessionAuthenticating,
    M1HostSessionStreaming,
    M1HostSessionRecovering,
    M1HostSessionLocked,
    M1HostSessionFailed,
};

NSString *M1HostSessionPhaseName(M1HostSessionPhase phase);

// WindowServer / 系统操作抽象；生产实现调真实 API，测试实现记录调用序列。
// 带 error: 的方法用 __attribute__((swift_error(none))) 保持签名在 Swift 中
// 以 (error: AutoreleasingUnsafeMutablePointer<NSError?>?) 形式导入，
// 便于 Swift 侧的 mock 实现对号入座（不转成 throws）。
#define M1_SWIFT_KEEP_ERROR __attribute__((swift_error(none)))

@protocol M1SessionDriver <NSObject>
- (BOOL)acquireSleepAssertionError:(NSError * _Nullable * _Nullable)error
    M1_SWIFT_KEEP_ERROR NS_SWIFT_NAME(acquireSleepAssertion(_:));
- (void)releaseSleepAssertion NS_SWIFT_NAME(releaseSleepAssertion());
- (BOOL)createVirtualDisplays:(NSArray<NSDictionary *> *)specs
                        error:(NSError * _Nullable * _Nullable)error
    M1_SWIFT_KEEP_ERROR NS_SWIFT_NAME(createVirtualDisplays(_:error:));
- (NSArray<NSNumber *> *)createdDisplayIDs NS_SWIFT_NAME(createdDisplayIDs());
- (BOOL)snapshotAndDisablePhysicalExcept:(NSArray<NSNumber *> *)keepIDs
                                   error:(NSError * _Nullable * _Nullable)error
    M1_SWIFT_KEEP_ERROR NS_SWIFT_NAME(snapshotAndDisablePhysicalExcept(_:error:));
- (BOOL)verifyIsolationError:(NSError * _Nullable * _Nullable)error
    M1_SWIFT_KEEP_ERROR NS_SWIFT_NAME(verifyIsolation(_:));  // C-09: active ⊆ 本会话虚拟屏
- (BOOL)injectUnlockCredential:(NSString *)credential
                         error:(NSError * _Nullable * _Nullable)error
    M1_SWIFT_KEEP_ERROR NS_SWIFT_NAME(injectUnlockCredential(_:error:));
- (BOOL)restorePhysicalAndDestroyDisplaysError:(NSError * _Nullable * _Nullable)error
    M1_SWIFT_KEEP_ERROR NS_SWIFT_NAME(restorePhysicalAndDestroyDisplays(_:));
- (BOOL)lockScreenError:(NSError * _Nullable * _Nullable)error
    M1_SWIFT_KEEP_ERROR NS_SWIFT_NAME(lockScreen(_:));
@end

@interface M1SessionCoordinator : NSObject

@property (nonatomic, readonly) M1HostSessionPhase phase;
@property (nonatomic, strong, readonly) NSArray<NSNumber *> *specsSummary;
@property (nonatomic, strong, readonly) M1TakeoverDetector *takeover;

- (instancetype)initWithDriver:(id<M1SessionDriver>)driver;

// 建立独占会话。specs = @[@{@"width":@1920,@"height":@1080,...}, ...]。
// needsLogin=YES 时执行 step 4 远程登录（credential 仅运行时传入，不落盘）。
- (BOOL)startWithSpecs:(NSArray<NSDictionary *> *)specs
             needsLogin:(BOOL)needsLogin
             credential:(nullable NSString *)credential
                  error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(start(specs:needsLogin:credential:));

// 正常断开：恢复物理屏 → 销毁虚拟屏 → 锁屏（D-06 step 2）。
- (BOOL)endSessionError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(endSession());

// 现场接管（二级 fail-safe 或一级手势缓冲到期）：立即走断开，不等远程确认。
- (BOOL)takeoverNowError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(takeoverNow());

@end

NS_ASSUME_NONNULL_END
