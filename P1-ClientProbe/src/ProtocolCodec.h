//
//  ProtocolCodec.h
//  P1-ClientProbe
//
//  控制协议 v1 / 帧头 v2 编解码（对应 docs/PROTOCOL.md §1 §3 §4）：
//    - 控制通道：4 字节大端长度前缀 + UTF-8 JSON，流式解析（支持粘包/拆包）
//    - 帧通道：18 字节大端帧头 pack/unpack、分片切分、按 frameSeq 重组与丢帧判据
//
//  纯函数 + 纯内存状态机，不依赖 WindowServer / 网络，任何机器可跑单测。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const P1ProtocolErrorDomain;

typedef NS_ENUM(NSInteger, P1ProtocolErrorCode) {
    P1ProtocolErrorBadJSON = 1,
    P1ProtocolErrorBadMessage,          // 缺 v/type，或类型不对
    P1ProtocolErrorBadVersion,          // v != 1
    P1ProtocolErrorBadLength,           // 长度前缀为 0 或超过上限
    P1ProtocolErrorTruncated,           // 数据不足（流式解析的正常中间态，不算错误）
    P1ProtocolErrorBadMagic,
    P1ProtocolErrorBadHeader,           // fragIdx >= fragCount 等
    P1ProtocolErrorPayloadTooLarge,
};

// 控制通道单帧上限：1 MiB。超过视为恶意/错位，直接断开而不是继续攒内存。
extern const NSUInteger P1ControlMaxFrameBytes;

// 帧通道常量（PROTOCOL.md §4）
extern const uint16_t P1FrameMagic;        // 0x4D52 'MR'
extern const uint8_t  P1ProtocolVersion;      // 1（控制通道 JSON 的 v 字段）
// 帧头版本。v2 把 fragIdx/fragCount 从 uint8 扩到 uint16：
//   v1 单帧上限 255×1150≈286KB，3440×1440 的关键帧就会打穿（整帧发不出去）。
//   帧头因此从 16B 变 18B；P1FrameMaxPayload 不变，18+1150=1168 仍在 1497 协商下限内。
extern const uint8_t  P1FrameHeaderVersion;   // 2
extern const NSUInteger P1FrameHeaderSize;    // 18
extern const NSUInteger P1FrameMaxPayload;    // 1150（QUIC datagram 头空间安全值）
// 单帧分片数硬上限 65535（受 fragCount 位宽约束），≈75MB。
extern const uint32_t P1FrameMaxFragments;

typedef NS_OPTIONS(uint8_t, P1FrameFlags) {
    P1FrameFlagKeyframe      = 1 << 0,  // bit0
    P1FrameFlagLastFragment  = 1 << 1,  // bit1：帧末分片
    P1FrameFlagHasParamSets  = 1 << 2,  // bit2：含 SPS/PPS
};

typedef struct {
    uint8_t  flags;
    uint32_t displayID;
    uint32_t frameSeq;
    uint16_t fragIdx;
    uint16_t fragCount;
    uint16_t payloadLen;
} P1FrameHeader;

#pragma mark - 控制通道

// 生成一条控制消息帧（自动补齐 v=1）。msg 必须含 type:NSString、seq:NSNumber。
NSData * _Nullable P1EncodeControlMessage(NSDictionary *msg, NSError * _Nullable * _Nullable error);

// 便捷构造：P1MakeControlMessage(@"heartbeat", 42, @{@"ts": @(123)})
NSDictionary *P1MakeControlMessage(NSString *type, int64_t seq, NSDictionary * _Nullable payload);

// 解析一整帧（不含长度前缀，输入为前缀之后的 JSON 字节）。
NSDictionary * _Nullable P1DecodeControlMessage(NSData *jsonBytes, NSError * _Nullable * _Nullable error);

// 流式解析：appendData 后反复取 nextMessage，直到返回 nil。
// 返回 nil 且 error 为 nil ⇒ 数据还不够，等更多字节（正常中间态）。
@interface P1ControlFrameParser : NSObject
- (void)appendData:(NSData *)data;
- (nullable NSDictionary *)nextMessageWithError:(NSError * _Nullable * _Nullable)error;
@property (nonatomic, readonly) NSUInteger bufferedBytes;
- (void)reset;
@end

#pragma mark - 帧通道

NSData *P1PackFrameHeader(P1FrameHeader header);
BOOL P1UnpackFrameHeader(NSData *data, P1FrameHeader *out, NSError * _Nullable * _Nullable error);

// 把一帧编码数据切成若干分片，每片已带好 16 字节头并返回完整可发送的 NSData。
// 分片载荷上限 P1FrameMaxPayload，片段数上限 P1FrameMaxFragments。
NSArray<NSData *> * _Nullable P1FragmentPayload(NSData *payload,
                                                P1FrameHeader proto,
                                                NSError * _Nullable * _Nullable error);

// 分片重组：按 displayID + frameSeq 累积，检测 seq 缺口并置 needsKeyframe。
@interface P1FrameReassembler : NSObject

// 交入一个分片（header 与 payload 已分开解析）。整帧收齐返回完整载荷，否则 nil。
- (nullable NSData *)acceptHeader:(P1FrameHeader)header
                          payload:(NSData *)payload
                            error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) BOOL needsKeyframe;   // 需要向 Host 请求关键帧
@property (nonatomic, readonly) NSUInteger droppedFrames;  // 因缺口/错位丢弃的帧数
@property (nonatomic, readonly) uint32_t lastCompletedSeq;
- (void)reset;

@end

NS_ASSUME_NONNULL_END
