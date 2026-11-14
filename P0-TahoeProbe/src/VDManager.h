//
//  VDManager.h
//  P0-TahoeProbe
//
//  虚拟显示器的创建、存活判定、identity 逃逸与分辨率提升。
//  Tahoe 相关行为参考：
//   - peetzweg/opendisplay PR #219：stale display 的 bounds 非空但 online/active 均 false，
//     liveness 判据必须同时检查 online + active，不能只看 bounds。
//   - peetzweg/opendisplay issue #171 / PR #288：WindowServer 会记住「被污染的」
//     vendor/product/serial 组合，导致虚拟屏永不出现在 SCShareableContent；
//     解法是换一组新 identity 重建并持久化成功的 offset。
//   - PR #288 另记录：直接以大尺寸建屏可能只得到壁纸 + 光标，
//     解法是先用保守 canvas 建立稳定 identity，等 SCK 看见后再原地提升。
//

#ifndef VDManager_h
#define VDManager_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// 每块屏的配置：@{@"width":@1920, @"height":@1080, @"hiDPI":@0, @"refreshRate":@60, @"name":@"..."}
@interface VDManager : NSObject

@property (nonatomic, copy, readonly) NSArray<NSDictionary *> *configs;
@property (nonatomic, assign, readonly) uint32_t identityOffset;
@property (nonatomic, assign, readonly) BOOL conservativeFirst;
@property (nonatomic, strong, readonly) NSArray<id> *displays;      // 必须全程持有，释放即注销
@property (nonatomic, strong, readonly) NSArray<NSNumber *> *displayIDs;

// SPI 同步调用超时（WindowServer 疑似挂起）时置 YES。
// 一旦置位，调用方必须立即停止全部建屏/重试动作，不得再向 WindowServer 发请求。
@property (nonatomic, assign, readonly) BOOL windowServerHung;

- (instancetype)initWithConfigs:(NSArray<NSDictionary *> *)configs
                 identityOffset:(uint32_t)offset
              conservativeFirst:(BOOL)conservativeFirst;

// 创建全部虚拟屏。返回 NO 表示至少一个 initWithDescriptor:/applySettings: 失败。
- (BOOL)createAll;

// 每块屏的存活状态。usable = online && active && bounds 非空。
// 注意 CGDisplayCopyDisplayMode 在刚创建的虚拟屏上可能返回 nil，只记录不作硬性失败。
- (NSArray<NSDictionary *> *)liveness;

- (BOOL)allUsable;

// 保守 canvas → 目标分辨率。返回 NO 时应调用 rollbackToConservative。
- (BOOL)promoteToTarget;
- (BOOL)rollbackToConservative;

// 等 WindowServer 完成注册（默认最多 3 秒，逐屏检查 usable）。
- (BOOL)waitUntilUsableTimeoutMs:(int)timeoutMs;

// 等每块屏的实际 CGDisplayMode 落到请求的 points 尺寸。
// applySettings: 是异步提交（15.5 实测需 1-3 秒，attach 期内的首次 apply 可能被吞），
// 只查 online/active 会把 1x1 的未提交状态误判为可用。超时中途会补一次 apply。
- (BOOL)waitUntilModeMatchesTimeoutMs:(int)timeoutMs conservative:(BOOL)conservative;

- (void)destroyAll;

// identity 持久化：成功的 offset 存到 ~/.p0_identity.json，下次直接复用。
+ (uint32_t)savedIdentityOffset;
+ (BOOL)saveIdentityOffset:(uint32_t)offset error:(NSError **)error;
+ (NSString *)identityPath;

@end

NS_ASSUME_NONNULL_END

#endif /* VDManager_h */
