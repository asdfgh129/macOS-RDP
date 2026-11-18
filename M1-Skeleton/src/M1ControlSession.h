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

@end

NS_ASSUME_NONNULL_END

#endif /* M1ControlSession_h */
