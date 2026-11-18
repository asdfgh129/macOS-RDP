//
//  P1InputCodec.h
//  P1-ClientProbe
//
//  控制协议 v1 §3.1 input 载荷编解码 + 注入速率限制。
//  纯 Foundation，不依赖 AppKit / WindowServer，可单机单测。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const P1InputErrorDomain;

typedef NS_ENUM(NSInteger, P1InputErrorCode) {
    P1InputErrorBadMessage = 1,
    P1InputErrorBadKind,
    P1InputErrorBadCoordinate,
    P1InputErrorBadButton,
    P1InputErrorBadKey,
    P1InputErrorBadFlags,
    P1InputErrorBadScroll,
    P1InputErrorBadFrame,
};

// PROTOCOL §3.1：单会话 ≤ 1000 event/s
extern const NSUInteger P1InputMaxEventsPerSecond;

#pragma mark - 事件构造（控制端用）

NSDictionary *P1MakeMouseEvent(uint32_t displayID,
                               double x, double y,
                               NSString *button, NSString *action,
                               NSDictionary * _Nullable flags);

NSDictionary *P1MakeKeyEvent(uint32_t displayID,
                             uint16_t keyCode,
                             NSString * _Nullable unicode,
                             NSDictionary * _Nullable flags);

NSDictionary *P1MakeScrollEvent(uint32_t displayID,
                                double dx, double dy,
                                NSDictionary * _Nullable flags);

// 修饰键全量同步事件；displayID 记为 0，不参与屏坐标。
NSDictionary *P1MakeFlagsEvent(NSDictionary * _Nullable flags);

// 事件 → 完整控制消息（type:"input"，含 v/seq/event）
NSDictionary *P1MakeInputMessage(int64_t seq, NSDictionary *event);

#pragma mark - 编解码 / 校验

// 事件 → 4B 长度前缀 + JSON 控制帧（复用 ProtocolCodec）
NSData * _Nullable P1EncodeInputMessage(int64_t seq,
                                        NSDictionary *event,
                                        NSError * _Nullable * _Nullable error);

// 控制帧 → 规范化 input 事件字典（含 seq；不含 v/type）
NSDictionary * _Nullable P1DecodeInputEvent(NSData *controlFrame,
                                            NSError * _Nullable * _Nullable error);

// 规范化 + 校验裸事件字典；失败返回 nil
NSDictionary * _Nullable P1NormalizeInputEvent(NSDictionary *event,
                                               NSError * _Nullable * _Nullable error);

// 六位修饰键的全量状态（缺失当 0，非法值返回 nil）
NSDictionary * _Nullable P1InputFlagsState(NSDictionary * _Nullable flags,
                                           NSError * _Nullable * _Nullable error);

// 超限时应丢弃的事件：mouse move 与 scroll（down/up/drag/key/flags 保留）
BOOL P1InputIsDroppableEvent(NSDictionary *event);

#pragma mark - 注入速率限制

@interface P1InputRateLimiter : NSObject

// 默认上限 P1InputMaxEventsPerSecond，窗口 1s；时间戳由调用方传入，便于确定性单测。
- (instancetype)initWithEventsPerSecond:(NSUInteger)rate;
- (BOOL)shouldAcceptEvent:(NSDictionary *)event atTime:(double)now;

@property (nonatomic, readonly) NSUInteger droppedEvents;
- (void)reset;

@end

NS_ASSUME_NONNULL_END
