//
//  M1ControlChannel.h
//  M1-Skeleton
//
//  控制通道：可靠 QUIC 流 + 协议 v1 控制帧（PROTOCOL.md §3）。
//
//  职责边界：
//    - 把 NSDictionary 编码成「4B 大端长度前缀 + UTF-8 JSON」并投给 sink
//    - 把流上收到的任意字节块（半帧 / 多帧粘包 / 跨包）解析回 NSDictionary
//    - 维护本端 seq 单调递增、统计与协议错误
//  不做：会话语义（谁该发什么、状态迁移）——那在 M1ControlSession。
//
//  之所以把分帧独立于传输：可靠流不保留写入边界，粘包/拆包是常态而非边缘情况，
//  必须能在无网络环境（内存 sink）里被单测钉住。
//

#ifndef M1ControlChannel_h
#define M1ControlChannel_h

#import <Foundation/Foundation.h>
#import "M1MessageSink.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const M1ControlErrorDomain;

typedef NS_ENUM(NSInteger, M1ControlErrorCode) {
    M1ControlErrorSinkFailed = 1,   // 传输层拒收
    M1ControlErrorEncodeFailed,     // 消息不合法（缺 type、非 JSON）
    M1ControlErrorProtocol,         // 收到错位字节（长度前缀不可信等）
};

@class M1ControlChannel;

@protocol M1ControlChannelDelegate <NSObject>
@optional
- (void)controlChannel:(M1ControlChannel *)channel didReceiveMessage:(NSDictionary *)message;
// 流错位：协议错误后通道已 reset，调用方应断开重连（不要继续在同一流上猜边界）。
- (void)controlChannel:(M1ControlChannel *)channel didFailWithError:(NSError *)error;
@end

@interface M1ControlChannel : NSObject

- (instancetype)initWithSink:(id<M1MessageSink>)sink NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<M1ControlChannelDelegate> delegate;

// 投喂从可靠流收到的原始字节。同步回调 delegate。
- (void)feedBytes:(NSData *)bytes;

// 发送一条控制消息：必须含 type，其余键作为载荷；seq 由本类自动分配（从 1 起）。
- (BOOL)sendMessage:(NSDictionary *)message error:(NSError * _Nullable * _Nullable)error;

// 指定 seq（重连重放 / 测试用）。
- (BOOL)sendMessage:(NSDictionary *)message
                seq:(int64_t)seq
              error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) int64_t nextSeq;        // 下一条将使用的 seq
@property (nonatomic, readonly) NSUInteger sentCount;
@property (nonatomic, readonly) NSUInteger receivedCount;
@property (nonatomic, readonly) NSUInteger protocolErrors;
@property (nonatomic, readonly) NSUInteger bufferedBytes;   // 解析器里尚未成帧的字节

- (void)resetSequence;

@end

NS_ASSUME_NONNULL_END

#endif /* M1ControlChannel_h */
