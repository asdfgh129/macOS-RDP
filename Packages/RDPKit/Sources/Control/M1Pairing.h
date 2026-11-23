//
//  M1Pairing.h
//  M1-Skeleton
//
//  PROTOCOL.md §2 / §6 配对认证的纯逻辑层：6 位配对码、有效期、试错锁定、
//  TOFU 证书指纹绑定与变更检测。不碰 Keychain / 网络 / UI，便于确定性单测；
//  持久化由调用方注入 store（生产用 Keychain 适配，测试用内存字典）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const M1PairingErrorDomain;

typedef NS_ENUM(NSInteger, M1PairingErrorCode) {
    M1PairingErrorBadCode = 1,        // 配对码格式错误
    M1PairingErrorExpired,            // 配对码过期（>5min）
    M1PairingErrorTooManyAttempts,    // 试错超限，锁定中
    M1PairingErrorFingerprintChanged, // TOFU 指纹变更，须重新配对
    M1PairingErrorNotPaired,          // 尚未配对
};

#pragma mark - 配对码

// 6 位数字配对码，cryptographically secure 随机（arc4random_uniform 足够）。
NSString *M1GeneratePairingCode(void);

// 校验格式：恰好 6 位 [0-9]。
BOOL M1IsValidPairingCode(NSString *code);

#pragma mark - 证书指纹规范化

// 接受 "AA:BB:.." / "AABB.." / 带空格形式，统一为小写无分隔的 64 hex（SHA-256）。
// 非法（长度不是 64 hex）返回 nil。
NSString * _Nullable M1NormalizeFingerprint(NSString *raw);

#pragma mark - 持久化适配（生产用 Keychain 实现此协议）

@protocol M1PairingStore <NSObject>
- (NSString * _Nullable)loadFingerprint;
- (void)saveFingerprint:(NSString *)fingerprint;
- (void)clearFingerprint;
@end

#pragma mark - 配对状态（纯逻辑，时间由调用方注入，便于单测）

@interface M1PairingState : NSObject

@property (nonatomic, readonly) BOOL isPaired;
@property (nonatomic, readonly, nullable) NSString *peerFingerprint;
@property (nonatomic, readonly) NSUInteger failedAttempts;
@property (nonatomic, readonly) BOOL isLocked;

// 生成/刷新配对码。now 为当前绝对时间（秒，如 NSDate.timeIntervalSince1970）。
// 生成后作废旧码并重置试错计数。
- (NSString *)issueCodeAtTime:(double)now;

// 校验客户端提交的配对码。成功则配对并绑定 fingerprint，失败累计试错。
// 返回绑定的指纹（成功）或 nil（失败，error 填充）。
- (NSString * _Nullable)confirmCode:(NSString *)code
                        fingerprint:(NSString *)rawFingerprint
                             atTime:(double)now
                               error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(confirm(code:fingerprint:atTime:));

// TOFU 校验：已配对时指纹必须与绑定值一致；未配对返回 M1PairingErrorNotPaired。
- (BOOL)verifyFingerprint:(NSString *)rawFingerprint
                    error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(verify(fingerprint:));

// 清除配对（重新配对外科手术用）。
- (void)unpair;

// 注入锁定时长/试错上限用于测试；生产用默认值（5min / 5 次 / 10min）。
@property (nonatomic, assign) NSTimeInterval codeTTL;
@property (nonatomic, assign) NSUInteger maxAttempts;
@property (nonatomic, assign) NSTimeInterval lockDuration;

// 注入持久化 store；nil 表示不持久化（仅内存）。
- (instancetype)initWithStore:(nullable id<M1PairingStore>)store;

@end

// 内存实现，供测试与 CLI 使用。
@interface M1InMemoryPairingStore : NSObject <M1PairingStore>
@property (nonatomic, copy, nullable) NSString *fingerprint;
@end

NS_ASSUME_NONNULL_END
