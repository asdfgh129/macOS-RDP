//
//  M1ControlSession.h
//  M1-Skeleton
//
//  会话语义层：把 PROTOCOL v1 §3 的控制消息序列跑在 M1ControlChannel 上，
//  每一跳都走 P1SessionStateMachine 的合法性校验（不自己发明状态迁移）。
//
//  实测状态序列（双端必须一致）：
//    DISCOVERED → TLS_CONNECTED → PAIRED → NEGOTIATED → DISPLAYS_READY → STREAMING
//
//  两条配对路径：
//    · TOFU 已配对（expectedPeerFingerprint 非空、无 pairingCode）：
//      hello 里带指纹，收到对端 hello 后本地确认即进 PAIRED，不再走 6 位码。
//      TLS 层已经按指纹钉死，本地确认只是状态机语义。
//    · 首次配对（给 pairingCode）：Client 发 pair-request，Host 比对后回 pair-confirm。
//      注意 M1-A 只做静态比对；TTL/试错锁定仍由 M1PairingState 负责，M1-D 接到 UI 时替换。
//
//  M1-A 阶段 session-ready 里的 display 是「按请求规格合成的占位」并带 synthetic:true，
//  真正的 VDManager displayID 要在 M1-B 建屏后才存在。
//

#ifndef M1ControlSession_h
#define M1ControlSession_h

#import <Foundation/Foundation.h>
#import "M1ControlChannel.h"
#import "P1SessionState.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const M1ControlSessionErrorDomain;

typedef NS_ENUM(NSInteger, M1ControlSessionErrorCode) {
    M1ControlSessionErrorInvalidState = 1,   // 状态机拒绝该事件
    M1ControlSessionErrorProtocol,           // 对端消息缺字段 / 值不合法
    M1ControlSessionErrorFingerprint,        // hello 指纹与钉死值不符
    M1ControlSessionErrorVersion,            // 协议版本无交集
    M1ControlSessionErrorPairingCode,        // 配对码不匹配
    M1ControlSessionErrorSend,               // 控制消息发不出去
    M1ControlSessionErrorRateLimited,        // 关键帧请求 300ms 限流
};

typedef NS_ENUM(NSInteger, M1ControlRole) {
    M1ControlRoleClient = 0,
    M1ControlRoleHost = 1,
};

@interface M1ControlSessionConfig : NSObject
@property (nonatomic, assign) M1ControlRole role;
@property (nonatomic, copy) NSString *hostName;
// 本方证书指纹（hello 上报，便于对端做 TOFU 记录）。
@property (nonatomic, copy, nullable) NSString *localFingerprint;
// 对端钉死指纹；给出即走 TOFU 已配对路径。
@property (nonatomic, copy, nullable) NSString *expectedPeerFingerprint;
// 首次配对码（6 位）；给出则走 pair-request/pair-confirm。
@property (nonatomic, copy, nullable) NSString *pairingCode;
// session-start 请求的规格（客户端用）。
@property (nonatomic, copy) NSArray<NSDictionary *> *specs;
@property (nonatomic, assign) int fps;
@property (nonatomic, assign) int bitrateKbps;
// 心跳间隔；0 = 关闭（单测用）。
@property (nonatomic, assign) uint32_t heartbeatIntervalMs;
@end

@class M1ControlSession;

@protocol M1ControlSessionDelegate <NSObject>
@optional
- (void)controlSessionDidReachStreaming:(M1ControlSession *)session;
- (void)controlSession:(M1ControlSession *)session didChangeState:(P1SessionState)state;
- (void)controlSession:(M1ControlSession *)session didFailWithError:(NSError *)error;

// Host 侧：session-start 到达后、回 session-ready 之前调用，用来准备真实显示
// （D-04 建虚拟屏 / 禁物理屏）。返回的每一项至少含 displayID/w/h，
// 会原样放进 session-ready；返回 nil 表示准备失败（回 session-error 并结束会话），
// 未实现或返回空数组则沿用 M1-A 的合成占位（displayID=1000+i, synthetic:YES）。
// 回调在控制收包队列上，可能耗时数秒（建屏/禁屏），调用方需自行保证 UI 不被阻塞。
- (NSArray<NSDictionary *> * _Nullable)controlSession:(M1ControlSession *)session
                        prepareDisplaysForSessionStart:(NSDictionary *)message
                                              error:(NSError * _Nullable * _Nullable)error;

// Host 侧：收到 Client 的 keyframe-request，应立刻让编码器产出 IDR。
//   回调在控制收包队列上；不能阻塞（码流线程可能正在等这个决定）。
- (void)controlSessionDidRequestKeyframe:(M1ControlSession *)session;

// Host 侧：收到 Client 的 frame-nack，应只重发该帧缺失的分片（定向补片）。
//   frameSeq/fragCount 来自客户端重组器；indices 为缺失片下标（已校验升序、<fragCount）。
//   整帧补片请求时 fragCount=0、indices 为空：应重发该帧在缓存里的全部分片。
//   回调在控制收包队列上；不能阻塞。发送端没有该帧缓存时可不处理，
//   客户端补片窗口到期后会改走 keyframe-request。
- (void)controlSession:(M1ControlSession *)session
 didRequestFragmentsForFrame:(uint32_t)frameSeq
             fragCount:(uint16_t)fragCount
               indices:(NSIndexSet *)indices;

// Host 侧：收到客户端输入事件。
//   · 只在 STREAMING 态回调（PROTOCOL §3.1）；
//   · 事件已过 P1InputCodec 校验（kind/坐标/键码/flags 合法）与 1000 event/s 限速；
//   · 回调在控制收包队列上，注入动作若可能阻塞需自行切队列。
- (void)controlSession:(M1ControlSession *)session didReceiveInputEvent:(NSDictionary *)event;
@end

@interface M1ControlSession : NSObject <M1ControlChannelDelegate>

- (instancetype)initWithChannel:(M1ControlChannel *)channel
                         config:(M1ControlSessionConfig *)config NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<M1ControlSessionDelegate> delegate;
@property (nonatomic, readonly) P1SessionStateMachine *stateMachine;
@property (nonatomic, readonly) M1ControlRole role;

// 发 hello，开始握手。
- (void)begin;

// 正常关闭：发 bye（失败也不阻塞关闭流程）。
- (void)closeWithReason:(NSString *)reason;

@property (nonatomic, readonly) NSArray<NSString *> *stateLog;      // 状态名序列，双端比对用
@property (nonatomic, readonly) BOOL reachedStreaming;
@property (nonatomic, readonly, nullable) NSDictionary *remoteHello;
@property (nonatomic, readonly, nullable) NSDictionary *remoteCapabilities;
@property (nonatomic, readonly, nullable) NSString *sessionID;
@property (nonatomic, readonly) NSArray<NSDictionary *> *remoteDisplays;
@property (nonatomic, readonly, nullable) NSError *lastError;

#pragma mark - 输入（PROTOCOL §3.1）

// Client：发一条输入事件（kind/mouse 的 x,y 归一化/...）。
//   非 STREAMING 态一律不发送也不报错——输入是高频路径，状态抖动不该掀掉会话；
//   调用方可用 inputEventsDropped 观察。
- (BOOL)sendInputEvent:(NSDictionary *)event error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) NSUInteger inputEventsSent;      // 已发出
@property (nonatomic, readonly) NSUInteger inputEventsReceived;  // Host 已接受并回调
@property (nonatomic, readonly) NSUInteger inputEventsDropped;   // 限速丢弃 / 非 STREAMING
@property (nonatomic, readonly) NSUInteger inputEventsRejected;  // 校验失败（畸形事件）

#pragma mark - 关键帧请求（PROTOCOL §3）

// Client：帧通道判定缺口后请求 Host 立即产 IDR。
//   限流 300ms/次（Host 产 IDR 也要时间，连环请求只会互相踩）；
//   非 STREAMING 返回 NO（INVALID_STATE），限流返回 NO（RATE_LIMITED）。
- (BOOL)requestKeyframeWithError:(NSError * _Nullable * _Nullable)error;

// Client：帧重组停滞时请求 Host 定向补片（只重发缺失分片）。
//   限流 5ms/次（同批多帧可能同时停滞；重组器每帧只请求一次）；indices 最多 64 个且必须 < fragCount。
//   非 STREAMING 返回 NO（INVALID_STATE），限流/参数错返回 NO（RATE_LIMITED/PROTOCOL）。
- (BOOL)requestFragmentsForFrameSeq:(uint32_t)frameSeq
                          fragCount:(uint16_t)fragCount
                            indices:(NSIndexSet *)indices
                              error:(NSError * _Nullable * _Nullable)error;

// Client：整帧一个分片都没收到时请求 Host 重发该帧全部分片（frame-nack + all:true）。
//   独立 5ms 限流（不与定向补片互相挤占）；非 STREAMING 返回 NO（INVALID_STATE）。
- (BOOL)requestWholeFrame:(uint32_t)frameSeq error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) NSUInteger keyframeRequestsSent;      // Client 实际发出
@property (nonatomic, readonly) NSUInteger keyframeRequestsReceived;  // Host 收到并回调
@property (nonatomic, readonly) NSUInteger frameNacksSent;            // Client 发出的补片请求
@property (nonatomic, readonly) NSUInteger frameNacksReceived;        // Host 收到并回调

@end

NS_ASSUME_NONNULL_END

#endif /* M1ControlSession_h */
