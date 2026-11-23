//
//  P1SessionState.h
//  P1-ClientProbe
//
//  控制协议 v1 §2 会话状态机（双端共用的合法性校验，不含网络/UI 编排）。
//  事件名对应 PROTOCOL.md 的消息 type，另加 tls-connected / heartbeat-timeout 两个本地事件。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const P1SessionErrorDomain;

typedef NS_ENUM(NSInteger, P1SessionErrorCode) {
    P1SessionErrorInvalidTransition = 1,
    P1SessionErrorInputNotAllowed,
};

typedef NS_ENUM(NSInteger, P1SessionState) {
    P1SessionStateDiscovered = 0,
    P1SessionStateTLSConnected,
    P1SessionStatePaired,
    P1SessionStateNegotiated,
    P1SessionStateDisplaysReady,
    P1SessionStateStreaming,
    P1SessionStateSuspended,
    P1SessionStateClosed,
};

NSString *P1SessionStateName(P1SessionState state);
BOOL P1SessionIsTerminal(P1SessionState state);

@interface P1SessionStateMachine : NSObject

@property (nonatomic, readonly) P1SessionState state;

- (BOOL)handleEvent:(NSString *)event error:(NSError * _Nullable * _Nullable)error;

// PROTOCOL §6：注入只接受 STREAMING 态
- (BOOL)canAcceptInput;

- (void)reset;

@end

NS_ASSUME_NONNULL_END
