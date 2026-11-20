//
//  M1FrameSender.h
//  M1-Skeleton
//
//  编码帧 → 协议分片 → datagram 投递。纯逻辑，不碰网络/WindowServer。
//
//  与 P1 协议层的关系：帧头、1150B 分片上限、末片标志全部复用 P1ProtocolCodec，
//  这里只负责三件事——分配单调 frameSeq、把编码帧的标志位翻译成 P1FrameFlags、
//  逐个分片投递并统计。协议格式的任何变化都只发生在 P1 侧，本类不复制格式知识。
//

#ifndef M1FrameSender_h
#define M1FrameSender_h

#import <Foundation/Foundation.h>
#import "M1PipelineTypes.h"
#import "M1DatagramSink.h"
#import "ProtocolCodec.h"

NS_ASSUME_NONNULL_BEGIN

@interface M1FrameSenderStats : NSObject
@property (nonatomic, readonly) uint64_t framesSent;
@property (nonatomic, readonly) uint64_t keyframesSent;
@property (nonatomic, readonly) uint64_t fragmentsSent;
@property (nonatomic, readonly) uint64_t bytesSent;        // 含 16B 帧头的线上字节
@property (nonatomic, readonly) uint64_t sinkFailures;     // 分片投递失败次数
@property (nonatomic, readonly) uint64_t payloadBytesSent; // 纯载荷字节（算码率用）
@end

@interface M1FrameSender : NSObject

- (instancetype)initWithSink:(id<M1DatagramSink>)sink;
// frameSeq 从 startSeq 开始单调递增。重连时可从上次值续上，避免接收端误判缺口。
- (instancetype)initWithSink:(id<M1DatagramSink>)sink
                    startSeq:(uint32_t)startSeq NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// 发送一帧编码结果。flags 由编码帧的 isKeyframe / carriesParamSets 推出，
// 末片标志由分片器按实际位置补，调用方无需关心。
// 返回 NO 时：*error 为 M1PipelineErrorEmptyPayload / FragmentationFailed / SinkFailed。
// 注意：分片中途失败时，前面已投递的分片不会回滚——接收端会因缺口丢弃该帧并请求
// 关键帧，这是实时流的预期行为（PROTOCOL.md §4 丢帧策略）。
- (BOOL)sendFrame:(M1EncodedFrame *)frame
        displayID:(uint32_t)displayID
            error:(NSError * _Nullable * _Nullable)error;

// 直接发原始载荷（不经编码帧）。用于测试与后续「只转发不编码」的场景。
- (BOOL)sendPayload:(NSData *)payload
          displayID:(uint32_t)displayID
              flags:(P1FrameFlags)flags
              error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) uint32_t nextFrameSeq;
@property (nonatomic, readonly) M1FrameSenderStats *stats;
- (void)resetStats;

// 跨公网防丢：同一分片重复投递 N 份。接收端把重复分片当冗余忽略，
// 丢一份不影响整帧。关键帧分片多，单帧「至少丢一片」的概率被放大，可按链路提高。
// 默认 1（不改变 LAN 环回行为）。发送端统计的 fragmentsSent 含副本。
@property (nonatomic, assign) NSUInteger keyframeCopies;
@property (nonatomic, assign) NSUInteger pframeCopies;

// 定向补片：缓存最近发送帧的分片，收到 frame-nack 时只重发缺失的那几片。
//   按帧数淘汰（默认 64 帧）；0 关闭缓存，重发请求一律返回 0。
//   重发走同一 sink（受传输层节拍/窗口约束），计入 fragmentsSent。
@property (nonatomic, assign) NSUInteger fragmentCacheFrames;
@property (nonatomic, readonly) uint64_t fragmentsResent;
// 返回实际重发的分片数；该帧不在缓存里返回 0（调用方回退到关键帧请求）。
- (NSUInteger)resendFragmentsForFrameSeq:(uint32_t)frameSeq
                                 indices:(NSIndexSet *)indices
                                   error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END

#endif /* M1FrameSender_h */
