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

// 重组完成、可按序解码的一帧。
@interface P1ReassembledFrame : NSObject
@property (nonatomic, readonly) uint32_t displayID;
@property (nonatomic, readonly) uint32_t frameSeq;
@property (nonatomic, readonly) BOOL keyframe;
@property (nonatomic, readonly) BOOL carriesParamSets;
@property (nonatomic, readonly, copy) NSData *payload;
@end

// 定向补片回调：某帧停止推进、首次超期时把缺失分片下标交出。
//   missingIndices 为缺失片下标（升序，个数 ≤ maxRepairFragments）；
//   整帧一个分片都没收到时 fragCount=0 且 missingIndices 为空——表示按 frameSeq
//   请求整帧重发（发送端从分片缓存重发该帧全部分片）。
//   keyframe 表示该帧是否关键帧（整帧请求时未知，恒为 NO）。
//   回调在 acceptHeader 的调用线程上同步执行，实现方必须非阻塞（只做控制消息入队）。
typedef void (^P1MissingFragmentsHandler)(uint32_t frameSeq, uint16_t fragCount,
                                          NSIndexSet *missingIndices, BOOL keyframe);

// 分片重组 v3：按 displayID + frameSeq 位图累积，容忍乱序与重复；
// 一个帧自首片到达起超过 frameDeadlineMs 仍未收齐即判丢（其后帧一并作废），
// 置 needsKeyframe 并只接受关键帧重启。收齐的帧按 frameSeq 顺序交付。
//
// v4 增加定向补片：首次超期时先回调 onMissingFragments 并延长 repairGraceMs，
// 让发送端只重发缺失片；补片仍没到才按上面的规则判丢。
// v5 补上整帧丢失：nextSeq 零分片时同样先按 app 层语义请求整帧重发，再判丢。
@interface P1FrameReassembler : NSObject

// 交入一个分片（header 与 payload 已分开解析）。
// 返回本次可以按序交付的帧（通常 0 或 1 帧，积压解除时可能多帧）；从不超过 maxFramesInFlight。
- (NSArray<P1ReassembledFrame *> *)acceptHeader:(P1FrameHeader)header
                                        payload:(NSData *)payload
                                          error:(NSError * _Nullable * _Nullable)error;

// 显式时间版本，单测用来拨动帧期限。
- (NSArray<P1ReassembledFrame *> *)acceptHeader:(P1FrameHeader)header
                                        payload:(NSData *)payload
                                          nowMs:(double)nowMs
                                          error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic) double frameDeadlineMs;      // 默认 120ms
// 停滞多久就发补片请求。要比 frameDeadlineMs 早，给补片留出往返时间；
// 提前请求的代价只是多一个可能白发的 NACK（重复分片本来就会被忽略）。
@property (nonatomic) double repairRequestMs;      // 默认 60ms
// 发出补片请求后的额外等待窗口；补片到齐即继续交付，否则到期判丢。
@property (nonatomic) double repairGraceMs;        // 默认 250ms
// 补片没到时的重问间隔与次数上限：重发的分片本身也可能再丢一次，
// 一次 NACK 石沉大海就整帧判死、退回 1.5s 的关键帧重建，代价太大。
@property (nonatomic) double repairRetryMs;        // 默认 120ms
@property (nonatomic) NSUInteger maxRepairAttempts; // 默认 3
// 单次补片请求的缺失片上限；超过说明缺口太大，直接走关键帧重建更划算。
@property (nonatomic) NSUInteger maxRepairFragments; // 默认 64
@property (nonatomic, copy, nullable) P1MissingFragmentsHandler onMissingFragments;
@property (nonatomic, readonly) NSUInteger repairRequests;   // 已发出的补片请求数
// 最近一次「补片请求发出 → 该帧收齐」的耗时；补片本身丢了不算采样。
@property (nonatomic, readonly) double lastRepairRttMs;
@property (nonatomic, readonly) NSUInteger repairRttSamples;
@property (nonatomic) NSUInteger maxFramesInFlight; // 默认 4，同时也是 seq 超前窗口
@property (nonatomic, readonly) BOOL needsKeyframe;        // 需要向 Host 请求关键帧
@property (nonatomic, readonly) NSUInteger droppedFrames;  // 已判定丢弃的整帧数
@property (nonatomic, readonly) NSUInteger droppedKeyframes;  // 其中关键帧（丢片导致收不齐）
@property (nonatomic, readonly) NSUInteger droppedPFrames;    // 其中 P 帧
// 最近 16 次丢帧的细节（seq/key/收到片数/缺失分片下标），用于区分
// 「WAN 随机丢片」与「发送突发把 QUIC 队列灌满」。
@property (nonatomic, readonly, copy) NSArray<NSString *> *recentDropDetails;
@property (nonatomic, readonly) NSUInteger fragmentsDiscarded; // 随之丢弃的分片数（含重复/迟到）
@property (nonatomic, readonly) uint32_t lastCompletedSeq;
// 是否有关键帧仍在推进（最近 withinMs 内收到新分片）。接收端用它避免在
// 在途 IDR 还在增长时再请求一个新 IDR，否则连环 IDR 会互相打断。
- (BOOL)hasActiveKeyframeAtMs:(double)nowMs withinMs:(double)windowMs;
- (void)reset;

@end

NS_ASSUME_NONNULL_END
