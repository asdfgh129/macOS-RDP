//
//  M1MessageSink.h
//  M1-Skeleton
//
//  可靠控制通道的传输 seam（对应 M1DatagramSink 的「可靠」版本）。
//
//  为什么需要两个 seam：一条 nw_connection 只映射一条 QUIC 流（SDK 无 nw_quic_create_stream），
//  所以帧走 datagram 连接、控制走可靠连接（D-14）。控制通道只依赖本协议，
//  这样 4B 长度前缀解析、粘包/拆包、序号这些逻辑可以在无网络环境单测。
//
//  生产实现：M1QuicTransport（M1QuicStreamModeReliable）
//  测试实现：M1MemoryMessageSink
//

#ifndef M1MessageSink_h
#define M1MessageSink_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol M1MessageSink <NSObject>

// 往可靠流追加一段字节。**不关闭流**；分帧由上层负责（控制通道用 4B 大端长度前缀）。
// 返回 NO 时必须填充 error。
- (BOOL)sendMessage:(NSData *)message error:(NSError * _Nullable * _Nullable)error;

@end

// 内存实现：按调用顺序保存每段字节，供控制通道分帧测试使用。
@interface M1MemoryMessageSink : NSObject <M1MessageSink>

@property (nonatomic, readonly) NSMutableArray<NSData *> *messages;

// 可选钩子：发送时同步回调（测试里用来把字节转投给对端 channel）。
@property (nonatomic, copy, nullable) BOOL (^onSend)(NSData *message, NSError * _Nullable * _Nullable error);

// 把已收集的消息按原顺序拼起来（模拟可靠流字节序），便于验证拆包。
- (NSData *)concatenated;

- (void)reset;

@end

NS_ASSUME_NONNULL_END

#endif /* M1MessageSink_h */
