//
//  M1ControlLink.h
//  M1-Skeleton
//
//  控制消息在 **不可靠 datagram 上** 的可靠投递层（D-14）。
//
//  为什么不用 QUIC 可靠流：本机 macOS 26.5 / Intel 实测，QUIC stream 模式
//  （nw_parameters_create + nw_quic_create_options，不设 datagram）
//  双端会永久停在 nw_connection_state_preparing，换证书、换 ALPN、换 IPv6/127.0.0.1
//  均复现；同一条代码路径把 stream 换成 datagram 后 12–80ms 就握手成功。
//  所以控制通道不依赖流，而是复用已验证可用的 datagram 连接，自建「序号 + 累计确认 + 重传」。
//
//  报文格式（14 字节头，大端）：
//    0     magic 'C'(0x43)   与帧分片魔数 'M'(0x4D) 区分
//    1     version = 1
//    2     kind              0=DATA, 1=ACK
//    3     flags             保留
//    4..7  seq               DATA 的消息序号，从 1 起
//    8..11 ack               本端已连续收到的最大 seq（ACK 包同样带）
//    12..13 payloadLen       DATA 载荷长度（ACK 为 0）
//    14..  payload
//
//  语义：有序、去重、失败可感知——够控制消息用（配对/协商/心跳），
//  不为它实现拥塞控制：控制流量是每秒几条，且有 1s 心跳兜底。
//

#ifndef M1ControlLink_h
#define M1ControlLink_h

#import <Foundation/Foundation.h>
#import "M1DatagramSink.h"
#import "M1MessageSink.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const M1ControlLinkDomain;

// 用 enum 而不是 extern const：这两个值要能出现在数组维度等常量表达式里，
// 同时保证 .h/.m 只有一处真值来源。
typedef NS_ENUM(NSUInteger, M1ControlLinkConstants) {
    M1ControlLinkHeaderSize = 14,     // magic+ver+kind+flags + seq + ack + payloadLen
    M1ControlLinkMaxPayload = 1200,   // 14 + 1200 = 1214 < 1497 协商下限，留足余量
};

typedef NS_ENUM(NSInteger, M1ControlLinkErrorCode) {
    M1ControlLinkErrorTooLarge = 1,
    M1ControlLinkErrorSendFailed,
    M1ControlLinkErrorUnacked,      // 重传次数耗尽
    M1ControlLinkErrorProtocol,
};

@class M1ControlLink;

@protocol M1ControlLinkDelegate <NSObject>
@optional
// 按序交付一条完整控制消息（已去重、已排序）。
- (void)controlLink:(M1ControlLink *)link didDeliverMessage:(NSData *)message;
- (void)controlLink:(M1ControlLink *)link didFailWithError:(NSError *)error;
@end

@interface M1ControlLink : NSObject <M1MessageSink>

- (instancetype)initWithSink:(id<M1DatagramSink>)sink NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<M1ControlLinkDelegate> delegate;

// 收到 datagram 时调用。返回 YES = 这是控制包（已消费）；NO = 不是（调用方交给帧通道）。
- (BOOL)feedDatagram:(NSData *)datagram;

// 发送一条控制消息（自动分配 seq、登记重传）。超过 M1ControlLinkMaxPayload 直接拒绝。
- (BOOL)sendMessage:(NSData *)message error:(NSError * _Nullable * _Nullable)error;

// 推进重传；生产由内部定时器每 50ms 调一次，测试里手动调以保持确定性。
- (void)tickAtMs:(double)nowMs;

@property (nonatomic, copy, nullable) double (^clock)(void);   // 毫秒时钟，默认 CACurrentMediaTime*1000
@property (nonatomic, assign) uint32_t retryIntervalMs;        // 默认 250
@property (nonatomic, assign) NSUInteger maxAttempts;          // 默认 8
@property (nonatomic, assign) BOOL autoTick;                   // 默认 YES；测试置 NO

@property (nonatomic, readonly) NSUInteger sentMessages;
@property (nonatomic, readonly) NSUInteger deliveredMessages;
@property (nonatomic, readonly) NSUInteger retransmits;
@property (nonatomic, readonly) NSUInteger duplicatesSeen;
@property (nonatomic, readonly) NSUInteger heldOutOfOrder;     // 曾因乱序暂存的条数
@property (nonatomic, readonly) NSUInteger acksReceived;
@property (nonatomic, readonly) uint32_t lastAckReceived;     // 对端已连续确认到的 seq
@property (nonatomic, readonly) BOOL hasPending;               // 还有未确认的消息

@end

NS_ASSUME_NONNULL_END

#endif /* M1ControlLink_h */
