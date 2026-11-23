//
//  M1DatagramSink.h
//  M1-Skeleton
//
//  帧通道的传输 seam。帧管线只依赖这个协议，不直接依赖 QUIC/Network.framework，
//  这样分片、序号、标志位这些纯逻辑可以在任何机器上单测，不碰网络与 WindowServer。
//
//  生产实现：M1QUICDatagramSink（P2 接 nw_connection 的 datagram 模式，D-01）
//  测试实现：M1MemoryDatagramSink（收集字节，用于回环一致性验证）
//

#ifndef M1DatagramSink_h
#define M1DatagramSink_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 一条已带 16 字节帧头的完整分片，可直接投递为一个 QUIC datagram。
@protocol M1DatagramSink <NSObject>

// 发送一个分片。返回 NO 时必须填充 error（通常是队列满/连接断开）。
// 实现约定：本方法同步返回；丢包由 QUIC 层负责，不在这里重传。
- (BOOL)sendDatagram:(NSData *)datagram error:(NSError * _Nullable * _Nullable)error;

@end

// 内存收集实现：按到达顺序保存每个分片，供分片/重组一致性测试使用。
@interface M1MemoryDatagramSink : NSObject <M1DatagramSink>

@property (nonatomic, readonly) NSMutableArray<NSData *> *datagrams;

// >0 时，第 failAfterCount+1 个分片起一律失败并返回 M1PipelineErrorSinkFailed，
// 用于验证发送器对传输错误的传播与统计。0 = 永不失败。
@property (nonatomic, assign) NSUInteger failAfterCount;
@property (nonatomic, assign) NSUInteger sendCount;   // 调用次数（含失败）

- (void)reset;

@end

NS_ASSUME_NONNULL_END

#endif /* M1DatagramSink_h */
