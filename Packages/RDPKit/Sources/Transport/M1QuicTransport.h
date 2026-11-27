//
//  M1QuicTransport.h
//  M1-Skeleton
//
//  D-01 的真实实现：QUIC unreliable datagram（RFC 9221）作为帧通道。
//
//  为什么不用 UDP 自己拼：Network.framework 从 macOS 13 起暴露了 QUIC datagram flow
//  （nw_quic_set_stream_is_datagram / nw_quic_get_stream_usable_datagram_frame_size），
//  一个连接只能有一条 datagram flow；TLS 1.3 握手随连接建立，证书指纹正好是
//  TOFU 配对的锚点（D-02 的 M1PairingState 直接吃这个指纹）。
//
//  本类只做「一次投递 = 一个 datagram」，不重传、不排序、不保证到达——
//  丢包后的关键帧重建由 P1 协议层负责（PROTOCOL.md §4）。
//
//  线程模型：所有回调在内部串行队列上，调用方不要在回调里做阻塞操作。
//

#ifndef M1QuicTransport_h
#define M1QuicTransport_h

#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import "M1DatagramSink.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const M1QuicErrorDomain;

typedef NS_ENUM(NSInteger, M1QuicErrorCode) {
    M1QuicErrorNotReady = 1,        // 连接未 ready 就发送
    M1QuicErrorSendFailed,          // nw_connection_send 报错
    M1QuicErrorListenerFailed,      // listener 建立/启动失败
    M1QuicErrorConnectionFailed,    // 握手/传输失败
    M1QuicErrorIdentityUnusable,    // 身份（p12）加载失败
    M1QuicErrorTimeout,             // 等待 ready / 收包超时
    M1QuicErrorFingerprintMismatch, // 对端证书指纹与钉死值不符（TOFU 拒绝）
};

typedef NS_ENUM(NSInteger, M1QuicState) {
    M1QuicStateIdle = 0,
    M1QuicStatePreparing,
    M1QuicStateReady,
    M1QuicStateFailed,
    M1QuicStateCancelled,
};

@class M1QuicTransport;

@protocol M1QuicTransportDelegate <NSObject>
@optional
// 传输可用（客户端=握手完成；服务端=监听已起或已接受连接，看角色）。
- (void)quicTransportDidBecomeReady:(M1QuicTransport *)transport;
// 收到一个完整 datagram（已按 QUIC datagram frame 边界还原）。
- (void)quicTransport:(M1QuicTransport *)transport didReceiveDatagram:(NSData *)datagram;
- (void)quicTransport:(M1QuicTransport *)transport didFailWithError:(NSError *)error;
// 服务端专用：接受了一条入站连接。
- (void)quicTransport:(M1QuicTransport *)transport didAcceptConnection:(M1QuicTransport *)connection;
@end

@interface M1QuicTransportStats : NSObject
@property (nonatomic, readonly) uint64_t datagramsSent;
@property (nonatomic, readonly) uint64_t bytesSent;         // 仅载荷，不含 QUIC 头
@property (nonatomic, readonly) uint64_t datagramsReceived;
@property (nonatomic, readonly) uint64_t bytesReceived;
@property (nonatomic, readonly) uint64_t sendErrors;
// 发送侧背压观测：QUIC datagram 没有应用层确认，只能看「调用 send 到完成回调」的
// 时延判断内部队列是否积压。窗口满时数据报先排队（datagramsSent 已计入）。
@property (nonatomic, readonly) uint64_t sendQueued;          // 进入排队（在飞窗口满）的次数
@property (nonatomic, readonly) uint64_t sendQueueDrops;      // 排队溢出被拒的次数
@property (nonatomic, readonly) uint64_t sendInFlightMax;     // 在飞峰值
@property (nonatomic, readonly) uint64_t sendCompletionSamples;
@property (nonatomic, readonly) double sendCompletionMaxMs;   // 完成回调最大时延
@property (nonatomic, readonly) double sendCompletionAvgMs;
@end

@interface M1QuicTransport : NSObject <M1DatagramSink>

// 高优先级投递：插到发送队列最前，不排在整帧分片之后。
// 控制通道（心跳/关键帧请求/补片请求）用它——这些包只有几包/秒，
// 但排在几十上百个帧分片后面时，到达接收端已经超过任何合理的判丢窗口。
// 仍经过节拍器（≤一个节拍间隔）与队列上限。
- (BOOL)sendPriorityDatagram:(NSData *)datagram error:(NSError * _Nullable * _Nullable)error;

#pragma mark - 客户端

// 连到 host:port。identityPath 可为 nil（不提供客户端证书）。
// verifyPeer=NO 时接受任意服务端证书（M1-A 第 1 步用；第 2 步接指纹钉死后必须为 YES）。
- (instancetype)initAsClientToHost:(NSString *)host
                              port:(uint16_t)port
                              alpn:(NSString *)alpn
                      identityPath:(nullable NSString *)identityPath
                      identityPass:(nullable NSString *)identityPass
                        verifyPeer:(BOOL)verifyPeer;

#pragma mark - 服务端

// 监听 port（0 = 由系统分配，起来后读 listenPort）并接受一条入站连接。
- (instancetype)initAsListenerOnPort:(uint16_t)port
                                alpn:(NSString *)alpn
                        identityPath:(NSString *)identityPath
                        identityPass:(nullable NSString *)identityPass
                          verifyPeer:(BOOL)verifyPeer;

- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<M1QuicTransportDelegate> delegate;
@property (nonatomic, readonly) M1QuicState state;
@property (nonatomic, readonly) M1QuicTransportStats *stats;

// 客户端握手看门狗：超时即丢弃这条连接重试一条（治 QUIC Initial 重传退避导致的 6–11s 离群）。
// connectTimeoutMs=0 关闭；默认 3000ms、2 次尝试。
@property (nonatomic, assign) uint32_t connectTimeoutMs;
@property (nonatomic, assign) NSUInteger maxConnectAttempts;
// 已发起的握手次数（含重试），用于观测离群是否被重试吃掉。
@property (nonatomic, readonly) NSUInteger connectAttempts;

@property (nonatomic, readonly) BOOL isListener;
@property (nonatomic, readonly) uint16_t listenPort;          // 仅 listener 有意义
// 当前连接可用的最大 datagram 载荷（含我们自己的 16B 帧头）。0 = 尚未协商出来。
@property (nonatomic, readonly) NSUInteger maxDatagramPayload;
// 服务端：接受入站连接后产生的连接对象（客户端角色对象自身持有连接）。
@property (nonatomic, readonly, nullable) M1QuicTransport *acceptedConnection;
// 入站连接的对端 "IP:port"（仅 accepted 连接有值），用于日志确认是谁连进来。
@property (nonatomic, readonly, copy, nullable) NSString *peerDescription;
// 入站连接指回监听对象，连接失败/取消时由子对象把父对象的 acceptedConnection 置 nil，
// 否则单客户端模型会把后续所有重连都丢掉（无人值守 host 必须能接重试）。
@property (nonatomic, weak, nullable) M1QuicTransport *parentListener;

// 服务端 TLS 指纹（对端证书 SHA-256，小写 hex）。配对层用它做 TOFU。
@property (nonatomic, readonly, nullable) NSString *peerCertificateSHA256;

// 指纹钉死（D-02/TOFU）：设置后 verifyPeer=YES 时，握手必须与这串完全一致才放行。
// 只在 start 之前设置有效。
@property (nonatomic, copy, nullable) NSString *expectedPeerFingerprint;

- (void)start;
- (void)cancel;

// 阻塞等待 ready，超时返回 NO。仅探针/工具用，业务代码别在回调线程调。
- (BOOL)waitUntilReadyTimeoutMs:(uint32_t)timeoutMs;

@end

// 读取 p12 身份并返回其叶子证书 SHA-256（小写 hex）。
// 配对 UI 要展示「本机指纹」、自检要比对钉死值，都需要它。
NSString * _Nullable M1QuicIdentityFingerprint(NSString *identityPath,
                                               NSString * _Nullable password,
                                               NSError * _Nullable * _Nullable error);

// NFR-07 E2：p12 身份口令的取值来源（避免把私钥口令写在命令行里被同机进程看到）。
// 优先级：显式参数 > 环境变量 VEILRD_IDENTITY_PASS > 钥匙串（service `veild-identity`,
// account `$USER`）> 开发默认 `rdpdev`。走最后一档时 outUsedDevDefault 置 YES，
// 调用方应打印一次告警；生产部署必须用环境变量或钥匙串。
NSString *M1ResolveIdentityPassphrase(NSString * _Nullable explicitPass,
                                      BOOL * _Nullable outUsedDevDefault);

NS_ASSUME_NONNULL_END

#endif /* M1QuicTransport_h */
