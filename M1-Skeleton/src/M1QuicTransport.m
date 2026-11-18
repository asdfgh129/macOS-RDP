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
    return [NSString stringWithFormat:@"%@/%d", dom, code];
}

#pragma mark - 身份与指纹

static SecIdentityRef M1CopyIdentity(NSString *path, NSString *password,
                                    NSError * _Nullable * _Nullable error) {
    NSData *p12 = [NSData dataWithContentsOfFile:path];
    if (p12.length == 0) {
        if (error) *error = M1QuicErr(M1QuicErrorIdentityUnusable,
            [NSString stringWithFormat:@"读不到身份文件 %@", path]);
        return NULL;
    }
    NSDictionary *opts = @{ (__bridge id)kSecImportExportPassphrase: password ?: @"" };
    CFArrayRef items = NULL;
    OSStatus st = SecPKCS12Import((__bridge CFDataRef)p12,
                                  (__bridge CFDictionaryRef)opts, &items);
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
}

#pragma mark 参数构造

- (nw_parameters_t)makeParametersWithError:(NSError **)error {
    SecIdentityRef identity = NULL;
    if (self.identityPath.length > 0) {
        identity = M1CopyIdentity(self.identityPath, self.identityPass, error);
        if (!identity) return NULL;
    }

    nw_parameters_t params = nw_parameters_create();
    nw_protocol_stack_t stack = nw_parameters_copy_default_protocol_stack(params);

    nw_protocol_options_t quic = nw_quic_create_options();
    // ★ D-01：这条连接只有一条 QUIC datagram flow，不重传、不排序。
    nw_quic_set_stream_is_datagram(quic, true);
    // 我们愿意接收的单帧上限（对端会取 min 后通过传输参数协商）。
    nw_quic_set_max_datagram_frame_size(quic, 1500);
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
        nw_listener_t l = nw_listener_create(params);
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
    NSString *portStr = [NSString stringWithFormat:@"%u", (unsigned)self.port];
    nw_endpoint_t ep = nw_endpoint_create_host(self.host.UTF8String, portStr.UTF8String);
    nw_connection_t conn = nw_connection_create(ep, params);
    if (!conn) {
        [self transitionFailed:M1QuicErr(M1QuicErrorConnectionFailed, @"nw_connection_create 失败")];
        return;
    }
    self.conn = conn;
    [self beginConnection];
}

// 给已有 nw_connection_t 装 handler 并 start（客户端 / 入站连接共用）。
- (void)beginConnection {
    nw_connection_set_queue(self.conn, self.queue);
    __weak typeof(self) weakSelf = self;
    nw_connection_set_state_changed_handler(self.conn, ^(nw_connection_state_t st, nw_error_t e) {
        M1QuicTransport *strong = weakSelf;
        if (!strong) return;
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
