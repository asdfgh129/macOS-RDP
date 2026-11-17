//
//  P0VDisplayControl.h
//  P0V-DisplayIsolation
//
//  V-01 / V-03 的显示控制层：
//    - 快照当前 active display 拓扑（id / bounds / main / mode / mirror）
//    - 在 CGBeginDisplayConfiguration 事务内调用私有 SLSConfigureDisplayEnabled
//    - 恢复快照（enable + mode + origin + mirror）
//    - 守护进程：探针被 Ctrl+C / SIGKILL / 崩溃时兜底恢复物理屏
//
//  私有符号（本机 15.5 实测存在，签名取自 Crisp 的 bridging header 与社区实现）：
//    CGError SLSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool);
//    CGError SLSGetDisplayList(uint32_t, CGDirectDisplayID *, uint32_t *);
//
//  安全前提：本层只做「可恢复的显示配置事务」。任何提交都可能被 WindowServer
//  阻塞（社区实测最长 29.5s），因此所有事务都有死线；超时后绝不重试。
//

#ifndef P0VDisplayControl_h
#define P0VDisplayControl_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, P0VCommitScope) {
    P0VCommitScopeSession = 0,   // kCGConfigureForSession：注销/重启后系统自行恢复
    P0VCommitScopePermanent = 1, // kCGConfigurePermanently：写进偏好，需手动恢复
};

#pragma mark - 单块屏记录

@interface P0VDisplayRecord : NSObject

@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, assign) CGRect bounds;        // Quartz 全局坐标（左上原点）
@property (nonatomic, assign) BOOL isMain;
@property (nonatomic, assign) BOOL isBuiltin;
@property (nonatomic, assign) BOOL online;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) uint32_t vendorID;
@property (nonatomic, assign) uint32_t modelID;
@property (nonatomic, assign) uint32_t serialNumber;
@property (nonatomic, assign) size_t pointWidth;
@property (nonatomic, assign) size_t pointHeight;
@property (nonatomic, assign) size_t pixelWidth;
@property (nonatomic, assign) size_t pixelHeight;
@property (nonatomic, assign) double refreshRate;
@property (nonatomic, assign) CGDirectDisplayID mirrorOf;  // kCGNullDirectDisplay = 未镜像
@property (nonatomic, strong, nullable) id mode;            // CGDisplayModeRef，仅内存快照有效

// 本项目虚拟屏使用 vendor 0x5030（'P0'），用于区分残留虚拟屏与物理屏。
@property (nonatomic, readonly) BOOL isP0Virtual;

- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)recordWithDictionary:(NSDictionary *)dict;

@end

#pragma mark - 拓扑快照

@interface P0VDisplaySnapshot : NSObject

@property (nonatomic, copy) NSArray<P0VDisplayRecord *> *displays;
@property (nonatomic, assign) NSTimeInterval capturedAt;

// 只快照 active display。被用户主动禁用（offline）的屏不在其中，
// 恢复时也不会去碰它们 —— 否则会把别人故意关掉的屏重新点亮。
+ (instancetype)captureActive;
+ (nullable instancetype)loadFromFile:(NSString *)path;

- (BOOL)writeToFile:(NSString *)path error:(NSError * _Nullable * _Nullable)error;
- (nullable P0VDisplayRecord *)recordForID:(CGDirectDisplayID)displayID;
- (NSArray<NSNumber *> *)displayIDs;

@end

#pragma mark - 查询

NSArray<NSNumber *> *P0VActiveDisplayIDs(void);
NSArray<NSNumber *> *P0VOnlineDisplayIDs(void);

// SLSGetDisplayList 会包含被 SLSConfigureDisplayEnabled 禁用的屏；
// CGGetActiveDisplayList 不会。恢复时靠它找回被禁用的 displayID。
NSArray<NSNumber *> * _Nullable P0VAllDisplayIDsFromSkyLight(void);

// 已注销但仍留在 WindowServer 注册表里的虚拟屏槽位（vendor=0xFFFFFFFF、1x1、offline）。
// 新建虚拟屏可能复用这些槽位并继承坏镜像态；一次创建多块会触发 WindowServer 断言
// （2026-11-17 22:03 实测，canonical_mirror_master）。多屏场景必须先检查这个列表。
NSArray<NSNumber *> *P0VStaleVirtualSlotIDs(void);

NSArray<NSDictionary *> *P0VDisplayDictionaries(NSArray<NSNumber *> *displayIDs);

BOOL P0VPrivateDisplayControlAvailable(void);

#pragma mark - 变更 / 恢复

// 在一个事务里禁用 toDisable、启用 toEnable。任一操作失败则取消整个事务。
BOOL P0VApplyDisplayEnabledChanges(NSArray<NSNumber *> *toDisable,
                                   NSArray<NSNumber *> *toEnable,
                                   P0VCommitScope scope,
                                   int timeoutSec,
                                   NSDictionary * _Nullable * _Nullable detail,
                                   NSError * _Nullable * _Nullable error);

// 恢复快照：先启用全部屏，再恢复 mirror / mode / origin。
// 分两个事务是有意为之：mode 列表要在屏重新 online 后才可靠。
BOOL P0VRestoreSnapshot(P0VDisplaySnapshot *snapshot,
                        P0VCommitScope scope,
                        int timeoutSec,
                        NSDictionary * _Nullable * _Nullable detail,
                        NSError * _Nullable * _Nullable error);

// 事务超时（WindowServer 疑似挂起）后置位。置位后调用方不得再发显示配置请求。
BOOL P0VWindowServerHung(void);
void P0VMarkWindowServerHung(void);
void P0VResetWindowServerHung(void);

#pragma mark - 守护进程

// 以独立进程组 spawn 自身 --guardian 模式。父进程退出后若未写 <snapshot>.done，
// 守护进程读快照并恢复显示。返回 YES 表示 spawn 成功（不保证后续恢复成功）。
BOOL P0VStartGuardian(NSString *snapshotPath, pid_t parentPID, NSError * _Nullable * _Nullable error);

// 守护进程主循环；返回进程退出码。
int P0VRunGuardian(NSString *snapshotPath, pid_t parentPID);

NS_ASSUME_NONNULL_END

#endif /* P0VDisplayControl_h */
