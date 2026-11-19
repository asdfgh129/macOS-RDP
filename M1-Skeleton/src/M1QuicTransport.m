//
//  M1QuicTransport.m
//  M1-Skeleton
//

#import "M1QuicTransport.h"

#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <os/lock.h>
#import <string.h>

NSString * const M1QuicErrorDomain = @"M1Quic";

static NSError *M1QuicErr(M1QuicErrorCode code, NSString *msg) {
    return [NSError errorWithDomain:M1QuicErrorDomain code:code
                            userInfo:@{NSLocalizedDescriptionKey: msg}];
}

// M1_QUIC_DEBUG=1 时把握手/状态细节打到 stderr（探针调试用，业务默认静默）。
static BOOL M1QLogOn(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = getenv("M1_QUIC_DEBUG") != NULL; });
    return on;
}
#define M1QLOG(fmt, ...) do { \
    if (M1QLogOn()) fprintf(stderr, "[quic %8.1fms] " fmt "\n", \
        [[NSDate date] timeIntervalSince1970] * 1000.0, ##__VA_ARGS__); \
} while (0)

static NSString *M1DescribeNWError(nw_error_t e) {
    if (!e) return @"(no error)";
    nw_error_domain_t d = nw_error_get_error_domain(e);
    int code = (int)nw_error_get_error_code(e);
    NSString *dom = (d == nw_error_domain_posix) ? @"posix" : @"dns";
    CFErrorRef cf = nw_error_copy_cf_error(e);
    NSString *detail = cf ? [(__bridge NSError *)cf localizedDescription] : nil;
    if (cf) CFRelease(cf);
    if (detail.length > 0) return [NSString stringWithFormat:@"%@/%d (%@)", dom, code, detail];
    return [NSString stringWithFormat:@"%@/%d", dom, code];
}

#pragma mark - 身份与指纹

// 本进程专用的临时钥匙串。
//
// 为什么不能用默认（登录）钥匙串：SecPKCS12Import 不带 kSecImportExportKeychain 时会把
// 条目写进登录钥匙串并持久化，ACL 里记的是「当时那个二进制」。我们是 ad-hoc 签名，
// 重新构建一次就换了身份，于是后续进程签名时 securityd 会判定 ACL 不符 → 拉起
// SecurityAgent 授权框 → 后台 CLI 永远等不到答复 → SecKeyCreateSignature 里的
// mach_msg 永久阻塞 → TLS 服务端发不出 CertificateVerify → 握手卡在 preparing
// 直到超时，全程无错误码（实测调用栈见 docs/RESULTS-BY-OS.md NEG-03）。
//
// 放进一次性临时钥匙串后，条目不会污染用户钥匙串，ACL 每次都按当前进程现建。
static SecKeychainRef gM1TempKeychain = NULL;

static void M1DestroyTempKeychain(void) {
    if (gM1TempKeychain) {
        SecKeychainDelete(gM1TempKeychain);
        CFRelease(gM1TempKeychain);
        gM1TempKeychain = NULL;
    }
}

static SecKeychainRef M1TempKeychain(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                [NSString stringWithFormat:@"m1rdp-identity-%d.keychain", getpid()]];
        const char *pw = "m1rdp-ephemeral";
        // PID 可能被复用：上次异常退出（kill -9 / 崩溃，atexit 不执行）会留下同名文件，
        // 此时 SecKeychainCreate 直接报「已存在」，身份就会被无谓地拒绝。先清掉残留
        // ——文件名含本进程 PID，只可能是已死进程留下的。
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        OSStatus st = SecKeychainCreate(path.fileSystemRepresentation,
                                       (UInt32)strlen(pw), pw, false, NULL, &gM1TempKeychain);
        if (st != errSecSuccess || !gM1TempKeychain) {
            // 不降级到登录钥匙串：那条路径会写持久 ACL，之后每次签名都可能拉起
            // SecurityAgent 授权框（用户看到的是「一直弹要密码的窗口」），见 NEG-04。
            M1QLOG("临时钥匙串创建失败 st=%d → 身份导入将被拒绝", (int)st);
            gM1TempKeychain = NULL;
            return;
        }
        SecKeychainUnlock(gM1TempKeychain, (UInt32)strlen(pw), pw, true);
        atexit(M1DestroyTempKeychain);
    });
    return gM1TempKeychain;
}

static SecIdentityRef M1CopyIdentity(NSString *path, NSString *password,
                                    NSError * _Nullable * _Nullable error) {
    NSData *p12 = [NSData dataWithContentsOfFile:path];
    if (p12.length == 0) {
        if (error) *error = M1QuicErr(M1QuicErrorIdentityUnusable,
            [NSString stringWithFormat:@"读不到身份文件 %@", path]);
        return NULL;
    }
    // ACL 只信任当前进程；钥匙串用一次性临时库（见上）。
    SecAccessRef access = NULL;
    SecTrustedApplicationRef selfApp = NULL;
    if (SecTrustedApplicationCreateFromPath(NULL, &selfApp) == errSecSuccess && selfApp) {
        const void *trusted[] = { selfApp };
        CFArrayRef trustedList = CFArrayCreate(NULL, trusted, 1, &kCFTypeArrayCallBacks);
        if (trustedList) {
            SecAccessCreate(CFSTR("macOS-RDP M1 identity"), trustedList, &access);
            CFRelease(trustedList);
        }
        CFRelease(selfApp);
    }
    NSMutableDictionary *opts = [@{ (__bridge id)kSecImportExportPassphrase: password ?: @"" }
                                 mutableCopy];
    if (access) opts[(__bridge id)kSecImportExportAccess] = (__bridge id)access;
    // 只允许导入进程私有钥匙串。宁可这次握手失败，也不能回退到登录钥匙串——
    // 回退会留下带持久 ACL 的私钥条目，表现为反复弹出无密码的「允许签名」授权框，
    // 并且每次重建二进制都会再来一次。
    SecKeychainRef kc = M1TempKeychain();
    if (!kc) {
        if (access) CFRelease(access);
        if (error) *error = M1QuicErr(M1QuicErrorIdentityUnusable,
            @"无法创建进程私有临时钥匙串，拒绝导入到登录钥匙串（否则会持续弹出授权框）");
        return NULL;
    }
    opts[(__bridge id)kSecImportExportKeychain] = (__bridge id)kc;
    CFArrayRef items = NULL;
    OSStatus st = SecPKCS12Import((__bridge CFDataRef)p12,
                                  (__bridge CFDictionaryRef)opts, &items);
    if (access) CFRelease(access);
    if (st != errSecSuccess || items == NULL || CFArrayGetCount(items) == 0) {
        if (items) CFRelease(items);
        if (error) *error = M1QuicErr(M1QuicErrorIdentityUnusable,
            [NSString stringWithFormat:@"SecPKCS12Import 失败（OSStatus %d）", (int)st]);
        return NULL;
    }
    SecIdentityRef ident = NULL;
    NSDictionary *item = (__bridge NSDictionary *)CFArrayGetValueAtIndex(items, 0);
    id identityRef = item[(__bridge id)kSecImportItemIdentity];
    if (identityRef) {
        ident = (SecIdentityRef)CFBridgingRetain(identityRef);
    }
    CFRelease(items);
    if (!ident && error) {
        *error = M1QuicErr(M1QuicErrorIdentityUnusable, @"p12 里没有可用的 identity");
    }
    return ident;
}

// 同一个 p12 在**一个进程里只导入一次**。
//
// 原因：每次 SecPKCS12Import 都会往临时钥匙串里再插一条同证书的私钥条目，
// 而私钥条目带 ACL —— 重复条目会让 securityd 在后续签名时去挑条目并可能走授权流程，
// 一旦走授权就会永久阻塞（NEG-03 的完整现象）。这里按「路径+密码+size+mtime」去重，
// 让一个进程内只有一条私钥条目，签名路径稳定。
//
// 缓存键带 size+mtime，探针重新生成身份后不会读到旧条目。
typedef struct {
    void *key;          // CFStringRef
    SecIdentityRef ident;
} M1IdentityCacheEntry;

static os_unfair_lock gIdLock = OS_UNFAIR_LOCK_INIT;
static M1IdentityCacheEntry gIdCache[4];
static size_t gIdCacheCount = 0;

static SecIdentityRef M1CopyIdentityCached(NSString *path, NSString *password,
                                           NSError * _Nullable * _Nullable error) {
    NSDictionary *st = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    NSString *key = [NSString stringWithFormat:@"%@|%@|%llu|%.3f", path, password ?: @"",
                     (unsigned long long)[st fileSize],
                     [[st fileModificationDate] timeIntervalSince1970]];

    os_unfair_lock_lock(&gIdLock);
    for (size_t i = 0; i < gIdCacheCount; i++) {
        if ([(__bridge NSString *)gIdCache[i].key isEqualToString:key]) {
            SecIdentityRef hit = (SecIdentityRef)CFRetain(gIdCache[i].ident);
            os_unfair_lock_unlock(&gIdLock);
            return hit;
        }
    }
    os_unfair_lock_unlock(&gIdLock);

    SecIdentityRef fresh = M1CopyIdentity(path, password, error);
    if (!fresh) return NULL;

    os_unfair_lock_lock(&gIdLock);
    if (gIdCacheCount < 4) {
        gIdCache[gIdCacheCount].key = (void *)CFBridgingRetain(key);
        gIdCache[gIdCacheCount].ident = (SecIdentityRef)CFRetain(fresh);
        gIdCacheCount++;
    }
    os_unfair_lock_unlock(&gIdLock);
    return fresh;   // 调用方持有 +1
}

// 叶子证书 DER 的 SHA-256，小写 hex。配对层 TOFU 用的就是这串。
static NSString *M1FingerprintOfSecCertificate(sec_certificate_t cert) {
    SecCertificateRef ref = sec_certificate_copy_ref(cert);
    if (!ref) return nil;
    CFDataRef der = SecCertificateCopyData(ref);
    CFRelease(ref);
    if (!der) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(CFDataGetBytePtr(der), (CC_LONG)CFDataGetLength(der), digest);
    CFRelease(der);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

NSString *M1QuicIdentityFingerprint(NSString *identityPath, NSString *password, NSError **error) {
    SecIdentityRef identity = M1CopyIdentityCached(identityPath, password, error);
    if (!identity) return nil;
    SecCertificateRef cert = NULL;
    OSStatus st = SecIdentityCopyCertificate(identity, &cert);
    CFRelease(identity);
    if (st != errSecSuccess || !cert) {
        if (error) *error = M1QuicErr(M1QuicErrorIdentityUnusable,
            [NSString stringWithFormat:@"取不到证书（OSStatus %d）", (int)st]);
        return nil;
    }
    CFDataRef der = SecCertificateCopyData(cert);
    CFRelease(cert);
    if (!der) {
        if (error) *error = M1QuicErr(M1QuicErrorIdentityUnusable, @"证书没有 DER 数据");
        return nil;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(CFDataGetBytePtr(der), (CC_LONG)CFDataGetLength(der), digest);
    CFRelease(der);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

#pragma mark - 统计
@interface M1QuicTransportStats ()
@property (nonatomic, assign) uint64_t datagramsSent;
@property (nonatomic, assign) uint64_t bytesSent;
@property (nonatomic, assign) uint64_t datagramsReceived;
@property (nonatomic, assign) uint64_t bytesReceived;
@property (nonatomic, assign) uint64_t sendErrors;
@end

@implementation M1QuicTransportStats
@end

#pragma mark - 传输

@interface M1QuicTransport ()
@property (nonatomic, readwrite) M1QuicState state;
@property (nonatomic, readwrite) M1QuicTransportStats *stats;
@property (nonatomic, readwrite) BOOL isListener;
@property (nonatomic, readwrite) uint16_t listenPort;
@property (nonatomic, readwrite) NSUInteger maxDatagramPayload;
@property (nonatomic, readwrite, nullable) M1QuicTransport *acceptedConnection;
@property (nonatomic, readwrite, nullable) NSString *peerCertificateSHA256;

@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) nw_listener_t listener;
@property (nonatomic, strong) nw_connection_t conn;
@property (nonatomic, strong) NSCondition *readyCond;
@property (nonatomic, assign) BOOL readyFlag;
@property (nonatomic, strong) NSError *failError;

@property (nonatomic, strong) nw_parameters_t baseParams;   // 重试要复用同一份参数
@property (nonatomic, assign) NSUInteger connGeneration;    // 每次重连 +1，丢弃过期回调
@property (nonatomic, readwrite) NSUInteger connectAttempts;

@property (nonatomic, copy) NSString *alpn;
@property (nonatomic, copy, nullable) NSString *identityPath;
@property (nonatomic, copy, nullable) NSString *identityPass;
@property (nonatomic, assign) BOOL verifyPeer;
@property (nonatomic, copy, nullable) NSString *host;
@property (nonatomic, assign) uint16_t port;
@end

@implementation M1QuicTransport

#pragma mark 初始化

- (instancetype)initAsClientToHost:(NSString *)host
                              port:(uint16_t)port
                              alpn:(NSString *)alpn
                      identityPath:(NSString *)identityPath
                      identityPass:(NSString *)identityPass
                        verifyPeer:(BOOL)verifyPeer {
    if ((self = [super init])) {
        _host = [host copy];
        _port = port;
        _alpn = [alpn copy] ?: @"rdp1";
        _identityPath = [identityPath copy];
        _identityPass = [identityPass copy];
        _verifyPeer = verifyPeer;
        [self commonInit];
        _isListener = NO;
    }
    return self;
}

- (instancetype)initAsListenerOnPort:(uint16_t)port
                                alpn:(NSString *)alpn
                        identityPath:(NSString *)identityPath
                        identityPass:(NSString *)identityPass
                          verifyPeer:(BOOL)verifyPeer {
    if ((self = [super init])) {
        _port = port;
        _alpn = [alpn copy] ?: @"rdp1";
        _identityPath = [identityPath copy];
        _identityPass = [identityPass copy];
        _verifyPeer = verifyPeer;
        [self commonInit];
        _isListener = YES;
    }
    return self;
}

// 内部：包装一条已建立的入站连接。
- (instancetype)initWithAcceptedConnection:(nw_connection_t)conn
                                      alpn:(NSString *)alpn
                             verifyPeer:(BOOL)verifyPeer {
    if ((self = [super init])) {
        _alpn = [alpn copy] ?: @"rdp1";
        _verifyPeer = verifyPeer;
        [self commonInit];
        _isListener = NO;
        _conn = conn;
    }
    return self;
}

- (void)commonInit {
    _queue = dispatch_queue_create("m1.quic.transport", DISPATCH_QUEUE_SERIAL);
    _stats = [M1QuicTransportStats new];
    _state = M1QuicStateIdle;
    _readyCond = [NSCondition new];
    _maxDatagramPayload = 0;
    _connectTimeoutMs = 3000;
    _maxConnectAttempts = 2;
    _connectAttempts = 0;
}

#pragma mark 参数构造

- (nw_parameters_t)makeParametersWithError:(NSError **)error {
    SecIdentityRef identity = NULL;
    if (self.identityPath.length > 0) {
        identity = M1CopyIdentityCached(self.identityPath, self.identityPass, error);
        if (!identity) return NULL;
    }

    nw_parameters_t params = nw_parameters_create();
    nw_protocol_stack_t stack = nw_parameters_copy_default_protocol_stack(params);

    nw_protocol_options_t quic = nw_quic_create_options();
    // ★ D-01：这条连接只有一条 QUIC datagram flow，不重传、不排序。
    // 可靠控制通道不在这里做：本机实测 QUIC stream 模式无法完成握手（见 D-14），
    // 控制消息改走 M1ControlLink 在同一条 datagram 连接上自建确认/重传。
    nw_quic_set_stream_is_datagram(quic, true);
    // 诊断开关：M1_QUIC_FORCE_STREAM=1 时退回 QUIC 普通流模式，用于复核 D-14 的前提。
    if (getenv("M1_QUIC_FORCE_STREAM")) {
        nw_quic_set_stream_is_datagram(quic, false);
        M1QLOG("诊断：强制 QUIC stream 模式（非 datagram）");
    }
    // 我们愿意接收的单帧上限（对端会取 min 后通过传输参数协商）。
    nw_quic_set_max_datagram_frame_size(quic, 1500);
    // idle 超时：帧通道 30s（有持续推流）；控制通道更短，靠 1s 心跳保活、断了要快速发现。
    nw_quic_set_idle_timeout(quic, 30000);
    // 注意：keepalive 只有 metadata 版本（nw_quic_set_keepalive_interval 收 metadata），
    // 不能在 options 阶段设置；连接 ready 后可再补。
    nw_protocol_stack_set_transport_protocol(stack, quic);
    if (M1QLogOn()) {
        nw_protocol_definition_t def = nw_protocol_options_copy_definition(quic);
        BOOL isQuic = def && nw_protocol_definition_is_equal(def,
                                     nw_protocol_copy_quic_definition());
        M1QLOG("params: transportIsQUIC=%d datagram=%d alpn=%s verifyPeer=%d",
               (int)isQuic, (int)nw_quic_get_stream_is_datagram(quic),
               self.alpn.UTF8String, (int)self.verifyPeer);
    }

    sec_protocol_options_t sec = nw_quic_copy_sec_protocol_options(quic);
    sec_protocol_options_add_tls_application_protocol(sec, self.alpn.UTF8String);
    if (identity) {
        sec_identity_t sid = sec_identity_create(identity);
        if (sid) sec_protocol_options_set_local_identity(sec, sid);
        CFRelease(identity);
    }

    __weak typeof(self) weakSelf = self;
    NSString *expected = self.expectedPeerFingerprint;
    sec_protocol_options_set_peer_authentication_required(sec, self.verifyPeer ? true : false);
    // 自己判：拿到对端证书链 → 算指纹 → 记录；开了钉死就比对。
    sec_protocol_options_set_verify_block(sec,
        ^(sec_protocol_metadata_t metadata, sec_trust_t trust, sec_protocol_verify_complete_t complete) {
            __block NSString *leaf = nil;
            sec_protocol_metadata_access_peer_certificate_chain(metadata,
                ^(sec_certificate_t certificate) {
                    if (!leaf) leaf = M1FingerprintOfSecCertificate(certificate);
                });
            M1QLOG("verify block: leaf=%s trust=%p", leaf.UTF8String ?: "(none)", (__bridge void *)trust);
            M1QuicTransport *strong = weakSelf;
            if (!strong) { complete(false); return; }
            dispatch_async(strong.queue, ^{
                strong.peerCertificateSHA256 = leaf;
            });
            if (!strong.verifyPeer) { complete(true); return; }
            BOOL accepted = (expected.length > 0) && leaf != nil && [leaf isEqualToString:expected];
            complete(accepted ? true : false);
            if (!accepted) {
                // 只 complete(false) 的话 QUIC 会一直吊在 preparing 直到 idle 超时，
                // 上层拿不到任何结论。这里主动取消并给出明确错误，让「拒绝」是即时的。
                dispatch_async(strong.queue, ^{
                    NSString *exp = expected.length > 16 ? [expected substringToIndex:16] : (expected ?: @"");
                    NSString *act = leaf.length > 16 ? [leaf substringToIndex:16] : (leaf ?: @"(无证书)");
                    NSString *reason = expected.length == 0
                        ? @"要求校验但未提供指纹锚点"
                        : [NSString stringWithFormat:@"指纹不符：期望 %@… 实际 %@…", exp, act];
                    [strong transitionFailed:M1QuicErr(M1QuicErrorFingerprintMismatch, reason)];
                    if (strong.conn) {
                        nw_connection_cancel(strong.conn);
                        strong.conn = nil;
                    }
                });
            }
        },
        self.queue);

    return params;
}

#pragma mark 启停

- (void)start {
    if (self.state != M1QuicStateIdle) return;
    self.state = M1QuicStatePreparing;

    NSError *err = nil;
    nw_parameters_t params = [self makeParametersWithError:&err];
    if (!params) {
        [self transitionFailed:err ?: M1QuicErr(M1QuicErrorIdentityUnusable, @"参数构造失败")];
        return;
    }

    if (self.isListener) {
        // 必须显式指定端口：nw_listener_create(params) 会完全忽略 init 里传的 port，
        // 每次分到随机端口（实测 --port 46600 实际监听 61174）。单机环回靠 port-file
        // 传端口还能糊过去，跨机就不行——防火墙规则和人工抄写都要求端口固定。
        char portStr[8];
        snprintf(portStr, sizeof(portStr), "%u", (unsigned)self.port);
        nw_listener_t l = nw_listener_create_with_port(portStr, params);
        if (!l) {
            [self transitionFailed:M1QuicErr(M1QuicErrorListenerFailed, @"nw_listener_create 失败")];
            return;
        }
        self.listener = l;
        nw_listener_set_queue(l, self.queue);
        __weak typeof(self) weakSelf = self;
        nw_listener_set_state_changed_handler(l, ^(nw_listener_state_t st, nw_error_t e) {
            M1QuicTransport *strong = weakSelf;
            if (!strong) return;
            switch (st) {
                case nw_listener_state_ready: {
                    uint16_t p = nw_listener_get_port(strong.listener);
                    M1QLOG("listener ready port=%u", (unsigned)p);
                    strong.listenPort = p;
                    strong.state = M1QuicStateReady;
                    [strong.readyCond lock];
                    strong.readyFlag = YES;
                    [strong.readyCond broadcast];
                    [strong.readyCond unlock];
                    if ([strong.delegate respondsToSelector:@selector(quicTransportDidBecomeReady:)]) {
                        [strong.delegate quicTransportDidBecomeReady:strong];
                    }
                    break;
                }
                case nw_listener_state_failed:
                    M1QLOG("listener FAILED %s", M1DescribeNWError(e).UTF8String);
                    [strong transitionFailed:M1QuicErr(M1QuicErrorListenerFailed,
                        [NSString stringWithFormat:@"监听失败：%@",
                         e ? @(nw_error_get_error_code(e)).stringValue : @"unknown"])];
                    break;
                case nw_listener_state_cancelled:
                    strong.state = M1QuicStateCancelled;
                    break;
                default:
                    break;
            }
        });
        nw_listener_set_new_connection_handler(l, ^(nw_connection_t conn) {
            M1QuicTransport *strong = weakSelf;
            if (!strong) return;
            if (strong.acceptedConnection) {   // 单客户端模型：多余的连接直接丢
                nw_connection_cancel(conn);
                return;
            }
            M1QLOG("inbound connection accepted");
            M1QuicTransport *child = [[M1QuicTransport alloc] initWithAcceptedConnection:conn
                                                                                   alpn:strong.alpn
                                                                             verifyPeer:strong.verifyPeer];
            child.delegate = strong.delegate;   // 上层只跟 listener 对象打交道
            strong.acceptedConnection = child;
            [child beginConnection];
            if ([strong.delegate respondsToSelector:@selector(quicTransport:didAcceptConnection:)]) {
                [strong.delegate quicTransport:strong didAcceptConnection:child];
            }
        });
        nw_listener_start(l);
        return;
    }

    // 客户端
    self.baseParams = params;
    [self startClientAttempt];
}

// 客户端建立/重建连接。每次尝试建新 nw_connection 并重新挂handler，用 generation 丢弃旧回调。
- (void)startClientAttempt {
    self.connectAttempts += 1;
    self.connGeneration += 1;
    NSUInteger gen = self.connGeneration;

    NSString *portStr = [NSString stringWithFormat:@"%u", (unsigned)self.port];
    nw_endpoint_t ep = nw_endpoint_create_host(self.host.UTF8String, portStr.UTF8String);
    nw_connection_t conn = nw_connection_create(ep, self.baseParams);
    if (!conn) {
        [self transitionFailed:M1QuicErr(M1QuicErrorConnectionFailed, @"nw_connection_create 失败")];
        return;
    }
    self.conn = conn;
    [self beginConnection];
    [self armConnectWatchdogForGeneration:gen];
}

// 握手看门狗：QUIC Initial 丢包会按 1s/2s/4s 退避重传，实测出现 6–11s 的离群。
// 与其让上层干等，不如在 N 毫秒后换一条新连接重来——重试几乎总能立刻成功。
- (void)armConnectWatchdogForGeneration:(NSUInteger)gen {
    if (self.connectTimeoutMs == 0 || self.isListener) return;
    __weak typeof(self) weakSelf = self;
    uint32_t timeoutMs = self.connectTimeoutMs;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutMs * NSEC_PER_MSEC),
                   self.queue, ^{
        M1QuicTransport *s = weakSelf;
        if (!s) return;
        if (s.connGeneration != gen) return;              // 已重试过，回调过期
        if (s.state != M1QuicStatePreparing) return;      // 已 ready / 已失败
        if (M1QLogOn()) {
            if (s.conn) {
                char *desc = nw_connection_copy_description(s.conn);
                M1QLOG("conn desc: %s", desc ? desc : "(nil)");
                if (desc) free(desc);
            } else {
                M1QLOG("conn desc: conn is nil (state=%d)", (int)s.state);
            }
        }
        nw_connection_t dead = s.conn;
        s.conn = nil;
        if (dead) nw_connection_cancel(dead);
        M1QLOG("connect watchdog: %.0fms 未 ready，第 %lu 次尝试作废",
               (double)timeoutMs, (unsigned long)s.connectAttempts);
        if (s.connectAttempts < s.maxConnectAttempts) {
            [s startClientAttempt];
        } else {
            [s transitionFailed:M1QuicErr(M1QuicErrorTimeout,
                [NSString stringWithFormat:@"握手 %u 次尝试均超时（每次 %ums）",
                 (unsigned)s.maxConnectAttempts, (unsigned)timeoutMs])];
        }
    });
}

// 给已有 nw_connection_t 装 handler 并 start（客户端 / 入站连接共用）。
- (void)beginConnection {
    nw_connection_set_queue(self.conn, self.queue);
    __weak typeof(self) weakSelf = self;
    NSUInteger gen = self.connGeneration;   // 被看门狗作废的连接，其回调一律忽略
    nw_connection_set_state_changed_handler(self.conn, ^(nw_connection_state_t st, nw_error_t e) {
        M1QuicTransport *strong = weakSelf;
        if (!strong) return;
        if (strong.connGeneration != gen) {
            M1QLOG("stale conn gen=%lu (now %lu) state %d 忽略",
                   (unsigned long)gen, (unsigned long)strong.connGeneration, (int)st);
            return;
        }
        M1QLOG("connection state -> %d %s", (int)st, M1DescribeNWError(e).UTF8String);
        switch (st) {
            case nw_connection_state_ready:
                [strong refreshNegotiatedDatagramSize];
                M1QLOG("negotiated maxDatagram=%lu", (unsigned long)strong.maxDatagramPayload);
                strong.state = M1QuicStateReady;
                [strong.readyCond lock];
                strong.readyFlag = YES;
                [strong.readyCond broadcast];
                [strong.readyCond unlock];
                if ([strong.delegate respondsToSelector:@selector(quicTransportDidBecomeReady:)]) {
                    [strong.delegate quicTransportDidBecomeReady:strong];
                }
                [strong receiveNext];
                break;
            case nw_connection_state_failed:
                [strong transitionFailed:M1QuicErr(M1QuicErrorConnectionFailed,
                    [NSString stringWithFormat:@"连接失败：%d",
                     e ? (int)nw_error_get_error_code(e) : -1])];
                break;
            case nw_connection_state_cancelled:
                if (strong.state != M1QuicStateFailed) strong.state = M1QuicStateCancelled;
                [strong.readyCond lock];
                [strong.readyCond broadcast];
                [strong.readyCond unlock];
                break;
            default:
                break;
        }
    });
    nw_connection_start(self.conn);
}

- (void)refreshNegotiatedDatagramSize {
    nw_protocol_metadata_t md =
        nw_connection_copy_protocol_metadata(self.conn, nw_protocol_copy_quic_definition());
    if (!md) return;
    self.maxDatagramPayload = (NSUInteger)nw_quic_get_stream_usable_datagram_frame_size(md);
}

- (void)transitionFailed:(NSError *)error {
    self.failError = error;
    self.state = M1QuicStateFailed;
    [self.readyCond lock];
    [self.readyCond broadcast];
    [self.readyCond unlock];
    if ([self.delegate respondsToSelector:@selector(quicTransport:didFailWithError:)]) {
        [self.delegate quicTransport:self didFailWithError:error];
        }
}

- (void)cancel {
    if (self.listener) {
        nw_listener_cancel(self.listener);
        self.listener = nil;
    }
    if (self.conn) {
        nw_connection_cancel(self.conn);
        self.conn = nil;
    }
    [self.acceptedConnection cancel];
    if (self.state != M1QuicStateFailed) self.state = M1QuicStateCancelled;
    [self.readyCond lock];
    [self.readyCond broadcast];
    [self.readyCond unlock];
}

- (BOOL)waitUntilReadyTimeoutMs:(uint32_t)timeoutMs {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutMs / 1000.0];
    [self.readyCond lock];
    BOOL ok = YES;
    while (!self.readyFlag && self.state != M1QuicStateFailed) {
        if (![self.readyCond waitUntilDate:deadline]) break;
    }
    if (self.state == M1QuicStateFailed) ok = NO;
    if (!self.readyFlag) ok = NO;
    [self.readyCond unlock];
    return ok;
}

#pragma mark 收发

- (BOOL)sendDatagram:(NSData *)datagram error:(NSError **)error {
    if (self.conn == nil || self.state != M1QuicStateReady) {
        if (error) *error = M1QuicErr(M1QuicErrorNotReady, @"连接未就绪，拒绝投递");
        return NO;
    }
    NSUInteger len = datagram.length;
    if (len == 0) {
        if (error) *error = M1QuicErr(M1QuicErrorSendFailed, @"空 datagram");
        return NO;
    }
    if (self.maxDatagramPayload > 0 && len > self.maxDatagramPayload) {
        if (error) *error = M1QuicErr(M1QuicErrorSendFailed,
            [NSString stringWithFormat:@"超过协商上限：%lu > %lu",
             (unsigned long)len, (unsigned long)self.maxDatagramPayload]);
        return NO;
    }

    void *buf = malloc(len);
    if (!buf) {
        if (error) *error = M1QuicErr(M1QuicErrorSendFailed, @"malloc 失败");
        return NO;
    }
    memcpy(buf, datagram.bytes, len);
    dispatch_data_t content = dispatch_data_create(buf, len, self.queue,
                                                   DISPATCH_DATA_DESTRUCTOR_FREE);

    __weak typeof(self) weakSelf = self;
    // is_complete=YES ⇒ 一次 send 就是一个 datagram 边界；不关闭连接的 message context。
    nw_connection_send(self.conn, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
                       ^(nw_error_t e) {
        if (!e) return;
        M1QuicTransport *strong = weakSelf;
        if (!strong) return;
        dispatch_async(strong.queue, ^{
            strong.stats.sendErrors += 1;
        });
    });

    self.stats.datagramsSent += 1;
    self.stats.bytesSent += len;
    return YES;
}

- (void)receiveNext {
    if (!self.conn) return;
    __weak typeof(self) weakSelf = self;
    // receive_message：一次回调 = 一个完整 datagram（保留消息边界）。
    nw_connection_receive_message(self.conn,
        ^(dispatch_data_t content, nw_content_context_t context, bool is_complete, nw_error_t error) {
            M1QuicTransport *strong = weakSelf;
            if (!strong) return;
            if (error) { M1QLOG("receive error %s", M1DescribeNWError(error).UTF8String); return; }
            NSData *data = nil;
            if (content) {
                const void *bytes = NULL;
                size_t size = 0;
                dispatch_data_t mapped = dispatch_data_create_map(content, &bytes, &size);
                if (bytes && size > 0) data = [NSData dataWithBytes:bytes length:size];
                (void)mapped;
            }
            if (data.length > 0) {
                strong.stats.datagramsReceived += 1;
                strong.stats.bytesReceived += data.length;
                if ([strong.delegate respondsToSelector:@selector(quicTransport:didReceiveDatagram:)]) {
                    [strong.delegate quicTransport:strong didReceiveDatagram:data];
                }
            }
            [strong receiveNext];
        });
}


@end
