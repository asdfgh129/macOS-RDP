//
//  M1Pairing.m
//  M1-Skeleton
//

#import "M1Pairing.h"

NSString * const M1PairingErrorDomain = @"M1Pairing";

static const NSTimeInterval kM1CodeTTL = 300.0;          // 5 分钟
static const NSUInteger kM1MaxAttempts = 5;
static const NSTimeInterval kM1LockDuration = 600.0;     // 10 分钟

static NSError *M1PairingErr(M1PairingErrorCode code, NSString *desc) {
    return [NSError errorWithDomain:M1PairingErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: desc }];
}

#pragma mark - 配对码

NSString *M1GeneratePairingCode(void) {
    uint32_t v = arc4random_uniform(1000000);
    return [NSString stringWithFormat:@"%06u", v];
}

BOOL M1IsValidPairingCode(NSString *code) {
    if (code.length != 6) return NO;
    for (NSUInteger i = 0; i < 6; i++) {
        unichar c = [code characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    return YES;
}

NSString * _Nullable M1NormalizeFingerprint(NSString *raw) {
    if (!raw) return nil;
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c == ':' || c == ' ' || c == '-') continue;
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) {
            return nil;
        }
        [hex appendFormat:@"%c", (char)tolower((int)c)];
    }
    return hex.length == 64 ? [hex copy] : nil;
}

#pragma mark - 配对状态

@interface M1PairingState ()
@property (nonatomic, copy, nullable) NSString *currentCode;
@property (nonatomic, assign) double issuedAt;
@property (nonatomic, assign) double lockedUntil;
@property (nonatomic, strong, nullable) id<M1PairingStore> store;
@end

@implementation M1PairingState

- (instancetype)init {
    return [self initWithStore:nil];
}

- (instancetype)initWithStore:(nullable id<M1PairingStore>)store {
    self = [super init];
    if (self) {
        _codeTTL = kM1CodeTTL;
        _maxAttempts = kM1MaxAttempts;
        _lockDuration = kM1LockDuration;
        _store = store;
        _peerFingerprint = [store loadFingerprint];
    }
    return self;
}

- (BOOL)isPaired {
    return self.peerFingerprint.length == 64;
}

- (BOOL)isLocked {
    // 锁定状态由调用方带 now 判定；这里用 lockedUntil>0 表示「曾锁定」，
    // 具体是否仍在锁定由 confirmCode: 内部按传入时间判断。
    return self.lockedUntil > 0;
}

- (NSString *)issueCodeAtTime:(double)now {
    self.currentCode = M1GeneratePairingCode();
    self.issuedAt = now;
    _failedAttempts = 0;
    self.lockedUntil = 0;
    return self.currentCode;
}

- (NSString * _Nullable)confirmCode:(NSString *)code
                        fingerprint:(NSString *)rawFingerprint
                             atTime:(double)now
                               error:(NSError * _Nullable * _Nullable)error {
    if (self.lockedUntil > now) {
        if (error) *error = M1PairingErr(M1PairingErrorTooManyAttempts, @"配对试错超限，锁定中");
        return nil;
    }
    // 锁定已过期则自动解锁并清零试错。
    if (self.lockedUntil > 0 && self.lockedUntil <= now) {
        self.lockedUntil = 0;
        _failedAttempts = 0;
    }
    if (!self.currentCode) {
        if (error) *error = M1PairingErr(M1PairingErrorBadCode, @"尚未生成配对码");
        return nil;
    }
    if (now - self.issuedAt > self.codeTTL) {
        if (error) *error = M1PairingErr(M1PairingErrorExpired, @"配对码已过期");
        return nil;
    }
    if (!M1IsValidPairingCode(code) || ![code isEqualToString:self.currentCode]) {
        _failedAttempts++;
        if (_failedAttempts >= self.maxAttempts) {
            self.lockedUntil = now + self.lockDuration;
        }
        if (error) *error = M1PairingErr(M1PairingErrorBadCode, @"配对码错误");
        return nil;
    }
    NSString *fp = M1NormalizeFingerprint(rawFingerprint);
    if (!fp) {
        if (error) *error = M1PairingErr(M1PairingErrorBadCode, @"证书指纹格式非法（须 64 hex）");
        return nil;
    }
    // 已配对时重新配对要求指纹一致，防止中间人替换。
    if (self.isPaired && ![fp isEqualToString:self.peerFingerprint]) {
        if (error) *error = M1PairingErr(M1PairingErrorFingerprintChanged, @"证书指纹变更，拒绝重新绑定");
        return nil;
    }
    _peerFingerprint = [fp copy];
    [self.store saveFingerprint:fp];
    // 配对成功后码一次性作废。
    self.currentCode = nil;
    _failedAttempts = 0;
    return fp;
}

- (BOOL)verifyFingerprint:(NSString *)rawFingerprint
                    error:(NSError * _Nullable * _Nullable)error {
    if (!self.isPaired) {
        if (error) *error = M1PairingErr(M1PairingErrorNotPaired, @"尚未配对");
        return NO;
    }
    NSString *fp = M1NormalizeFingerprint(rawFingerprint);
    if (!fp || ![fp isEqualToString:self.peerFingerprint]) {
        if (error) *error = M1PairingErr(M1PairingErrorFingerprintChanged, @"证书指纹不匹配，须重新配对");
        return NO;
    }
    return YES;
}

- (void)unpair {
    _peerFingerprint = nil;
    self.currentCode = nil;
    self.lockedUntil = 0;
    _failedAttempts = 0;
    [self.store clearFingerprint];
}

@end

#pragma mark - 内存 store

@implementation M1InMemoryPairingStore
- (NSString * _Nullable)loadFingerprint { return self.fingerprint; }
- (void)saveFingerprint:(NSString *)fingerprint { self.fingerprint = fingerprint; }
- (void)clearFingerprint { self.fingerprint = nil; }
@end
