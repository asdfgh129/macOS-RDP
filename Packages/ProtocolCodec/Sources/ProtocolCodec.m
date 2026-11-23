//
//  ProtocolCodec.m
//  P1-ClientProbe
//

#import "ProtocolCodec.h"

NSString * const P1ProtocolErrorDomain = @"P1ProtocolErrorDomain";

const NSUInteger P1ControlMaxFrameBytes = 1024 * 1024;  // 1 MiB
const uint16_t P1FrameMagic = 0x4D52;                   // 'MR'
const uint8_t  P1ProtocolVersion = 1;      // 控制通道 JSON 版本，与帧头版本相互独立
const uint8_t  P1FrameHeaderVersion = 3;   // v3：新增 64-bit 采集墙钟（epoch 微秒）
const NSUInteger P1FrameHeaderSize = 26;
// QUIC short header + AEAD tag 约 20–30 B，1200 B MTU 下留足头空间（D-01）
const NSUInteger P1FrameMaxPayload = 1150;
// fragCount 是 uint16，故单帧最多 65535 片（≈75MB）。v1 的 255 片上限已在 3440×1440
// 的关键帧上被证明不够用，见 docs/RESULTS-BY-OS.md §5.8。
const uint32_t P1FrameMaxFragments = 65535;

static NSError *P1Err(P1ProtocolErrorCode code, NSString *desc) {
    return [NSError errorWithDomain:P1ProtocolErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: desc ?: @""}];
}

static void P1PutU16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)(v & 0xFF);
}
static void P1PutU32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)((v >> 16) & 0xFF);
    p[2] = (uint8_t)((v >> 8) & 0xFF); p[3] = (uint8_t)(v & 0xFF);
}
static uint16_t P1GetU16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t P1GetU32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}
static void P1PutU64(uint8_t *p, uint64_t v) {
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (56 - 8 * i));
}
static uint64_t P1GetU64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v = (v << 8) | p[i];
    return v;
}

#pragma mark - 控制通道

NSDictionary *P1MakeControlMessage(NSString *type, int64_t seq, NSDictionary *payload) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    m[@"v"] = @(P1ProtocolVersion);
    m[@"type"] = type ?: @"";
    m[@"seq"] = @(seq);
    if (payload) [m addEntriesFromDictionary:payload];
    return m;
}

NSData *P1EncodeControlMessage(NSDictionary *msg, NSError **error) {
    if (![msg isKindOfClass:[NSDictionary class]]) {
        if (error) *error = P1Err(P1ProtocolErrorBadMessage, @"message is not a dictionary");
        return nil;
    }
    NSMutableDictionary *m = [msg mutableCopy];
    if (!m[@"v"]) m[@"v"] = @(P1ProtocolVersion);
    if (![m[@"v"] isEqual:@(P1ProtocolVersion)]) {
        if (error) *error = P1Err(P1ProtocolErrorBadVersion, @"unsupported protocol version");
        return nil;
    }
    if (![m[@"type"] isKindOfClass:[NSString class]] || [(NSString *)m[@"type"] length] == 0) {
        if (error) *error = P1Err(P1ProtocolErrorBadMessage, @"missing type");
        return nil;
    }
    if (![m[@"seq"] isKindOfClass:[NSNumber class]]) {
        if (error) *error = P1Err(P1ProtocolErrorBadMessage, @"missing numeric seq");
        return nil;
    }
    if (![NSJSONSerialization isValidJSONObject:m]) {
        if (error) *error = P1Err(P1ProtocolErrorBadJSON, @"payload is not JSON-serializable");
        return nil;
    }
    NSError *jerr = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:m options:0 error:&jerr];
    if (!json) {
        if (error) *error = P1Err(P1ProtocolErrorBadJSON, jerr.localizedDescription ?: @"json encode failed");
        return nil;
    }
    if (json.length == 0 || json.length > P1ControlMaxFrameBytes) {
        if (error) *error = P1Err(P1ProtocolErrorBadLength, @"control frame size out of range");
        return nil;
    }
    NSMutableData *out = [NSMutableData dataWithCapacity:json.length + 4];
    uint8_t len[4];
    P1PutU32(len, (uint32_t)json.length);
    [out appendBytes:len length:4];
    [out appendData:json];
    return out;
}

NSDictionary *P1DecodeControlMessage(NSData *jsonBytes, NSError **error) {
    if (jsonBytes.length == 0) {
        if (error) *error = P1Err(P1ProtocolErrorBadLength, @"empty control frame");
        return nil;
    }
    NSError *jerr = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:jsonBytes options:0 error:&jerr];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        if (error) *error = P1Err(P1ProtocolErrorBadJSON, jerr.localizedDescription ?: @"not a JSON object");
        return nil;
    }
    NSDictionary *d = obj;
    if (![d[@"v"] isKindOfClass:[NSNumber class]] ||
        [(NSNumber *)d[@"v"] integerValue] != P1ProtocolVersion) {
        if (error) *error = P1Err(P1ProtocolErrorBadVersion, @"missing or unsupported v");
        return nil;
    }
    if (![d[@"type"] isKindOfClass:[NSString class]] || [(NSString *)d[@"type"] length] == 0) {
        if (error) *error = P1Err(P1ProtocolErrorBadMessage, @"missing type");
        return nil;
    }
    if (d[@"seq"] && ![d[@"seq"] isKindOfClass:[NSNumber class]]) {
        if (error) *error = P1Err(P1ProtocolErrorBadMessage, @"seq is not numeric");
        return nil;
    }
    return d;
}

@implementation P1ControlFrameParser {
    NSMutableData *_buf;
}

- (instancetype)init {
    if ((self = [super init])) _buf = [NSMutableData data];
    return self;
}

- (void)appendData:(NSData *)data {
    if (data.length) [_buf appendData:data];
}

- (NSUInteger)bufferedBytes { return _buf.length; }

- (void)reset { [_buf setLength:0]; }

- (NSDictionary *)nextMessageWithError:(NSError **)error {
    if (error) *error = nil;
    if (_buf.length < 4) return nil;               // 正常中间态：还差长度前缀

    const uint8_t *p = _buf.bytes;
    uint32_t len = P1GetU32(p);

    if (len == 0 || len > P1ControlMaxFrameBytes) {
        // 长度前缀不可信 ⇒ 流已错位，整段丢弃，由上层断开重连。
        [_buf setLength:0];
        if (error) *error = P1Err(P1ProtocolErrorBadLength, @"untrusted length prefix");
        return nil;
    }
    if (_buf.length < 4 + (NSUInteger)len) return nil;  // 正常中间态：等后续字节

    NSData *body = [_buf subdataWithRange:NSMakeRange(4, len)];
    [_buf replaceBytesInRange:NSMakeRange(0, 4 + len) withBytes:NULL length:0];

    NSError *derr = nil;
    NSDictionary *msg = P1DecodeControlMessage(body, &derr);
    if (!msg && error) *error = derr;
    return msg;
}

@end

#pragma mark - 帧通道

NSData *P1PackFrameHeader(P1FrameHeader h) {
    // 用字面量 26：P1FrameHeaderSize 是 const NSUInteger（运行期只读），
    // 不能用作 C 数组长度，否则会退化成 VLA 并触发 -Wgnu-folding-constant。
    //
    // v3 布局（大端）：
    //   0..1 magic | 2 ver | 3 flags | 4..7 displayID | 8..11 frameSeq
    //   | 12..13 fragIdx | 14..15 fragCount | 16..17 payloadLen
    //   | 18..25 capturedAtUs（主机 epoch 微秒，用于 A-02 capture→render 打点）
    uint8_t b[26] = {0};
    P1PutU16(b + 0, P1FrameMagic);
    b[2] = P1FrameHeaderVersion;
    b[3] = h.flags;
    P1PutU32(b + 4, h.displayID);
    P1PutU32(b + 8, h.frameSeq);
    P1PutU16(b + 12, h.fragIdx);
    P1PutU16(b + 14, h.fragCount);
    P1PutU16(b + 16, h.payloadLen);
    P1PutU64(b + 18, h.capturedAtUs);
    return [NSData dataWithBytes:b length:P1FrameHeaderSize];
}

BOOL P1UnpackFrameHeader(NSData *data, P1FrameHeader *out, NSError **error) {
    if (error) *error = nil;
    if (data.length < P1FrameHeaderSize) {
        if (error) *error = P1Err(P1ProtocolErrorTruncated, @"header shorter than 26 bytes");
        return NO;
    }
    const uint8_t *b = data.bytes;
    uint16_t magic = P1GetU16(b);
    if (magic != P1FrameMagic) {
        if (error) *error = P1Err(P1ProtocolErrorBadMagic, @"bad magic");
        return NO;
    }
    if (b[2] != P1FrameHeaderVersion) {
        // 旧帧头不再接受：v1 位宽不够（3440×1440 关键帧会超过 255 片），
        // v2 没有采集时间戳（A-02 无法结算 capture→render），都属于必须换格式的缺陷。
        if (error) *error = P1Err(P1ProtocolErrorBadVersion, @"bad frame version");
        return NO;
    }
    P1FrameHeader h;
    h.flags = b[3];
    h.displayID = P1GetU32(b + 4);
    h.frameSeq = P1GetU32(b + 8);
    h.fragIdx = P1GetU16(b + 12);
    h.fragCount = P1GetU16(b + 14);
    h.payloadLen = P1GetU16(b + 16);
    h.capturedAtUs = P1GetU64(b + 18);

    if (h.fragCount == 0 || h.fragIdx >= h.fragCount) {
        if (error) *error = P1Err(P1ProtocolErrorBadHeader, @"fragIdx out of range");
        return NO;
    }
    if (h.payloadLen == 0 || h.payloadLen > P1FrameMaxPayload) {
        if (error) *error = P1Err(P1ProtocolErrorPayloadTooLarge, @"payloadLen out of range");
        return NO;
    }
    if (out) *out = h;
    return YES;
}

NSArray<NSData *> *P1FragmentPayload(NSData *payload, P1FrameHeader proto, NSError **error) {
    if (error) *error = nil;
    if (payload.length == 0) {
        if (error) *error = P1Err(P1ProtocolErrorBadHeader, @"empty payload");
        return nil;
    }
    NSUInteger count = (payload.length + P1FrameMaxPayload - 1) / P1FrameMaxPayload;
    if (count > P1FrameMaxFragments) {
        if (error) *error = P1Err(P1ProtocolErrorPayloadTooLarge,
                                  @"too many fragments (>65535)");
        return nil;
    }
    NSMutableArray<NSData *> *out = [NSMutableArray arrayWithCapacity:count];
    const uint8_t *base = payload.bytes;
    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger off = i * P1FrameMaxPayload;
        NSUInteger n = MIN(P1FrameMaxPayload, payload.length - off);
        P1FrameHeader h = proto;
        h.fragIdx = (uint16_t)i;
        h.fragCount = (uint16_t)count;
        h.payloadLen = (uint16_t)n;
        if (i == count - 1) h.flags |= P1FrameFlagLastFragment;
        else h.flags &= (uint8_t)~P1FrameFlagLastFragment;

        NSMutableData *frag = [NSMutableData dataWithCapacity:P1FrameHeaderSize + n];
        [frag appendData:P1PackFrameHeader(h)];
        [frag appendBytes:(base + off) length:n];
        [out addObject:frag];
    }
    return out;
}

@interface P1ReassembledFrame ()
@property (nonatomic, readwrite) uint32_t displayID;
@property (nonatomic, readwrite) uint32_t frameSeq;
@property (nonatomic, readwrite) BOOL keyframe;
@property (nonatomic, readwrite) BOOL carriesParamSets;
@property (nonatomic, readwrite) uint64_t capturedAtUs;
@property (nonatomic, readwrite, copy) NSData *payload;
@end

@implementation P1ReassembledFrame
@end

// 正在累积的一帧：slots[i] 为 NSNull 或该分片的载荷。
@interface P1PartialFrame : NSObject
@property (nonatomic, assign) uint32_t displayID;
@property (nonatomic, assign) uint32_t frameSeq;
@property (nonatomic, assign) uint16_t fragCount;
@property (nonatomic, assign) BOOL keyframe;
@property (nonatomic, assign) BOOL carriesParamSets;
@property (nonatomic, assign) uint64_t capturedAtUs;
@property (nonatomic, assign) double lastProgressMs;   // 最近一次收到新分片的时刻
@property (nonatomic, assign) BOOL repairEmitted;      // 本帧是否已请求过定向补片
@property (nonatomic, assign) NSUInteger repairAttempts;  // 已请求次数（含重问）
@property (nonatomic, assign) double repairRequestedAtMs;
@property (nonatomic, assign) NSUInteger receivedCount;
@property (nonatomic, assign) NSUInteger totalBytes;
@property (nonatomic, strong) NSMutableArray *slots;
@end

@implementation P1PartialFrame
@end

@implementation P1FrameReassembler {
    NSMutableDictionary<NSNumber *, P1PartialFrame *> *_partials;
    NSMutableDictionary<NSNumber *, P1ReassembledFrame *> *_ready;
    BOOL _haveNext;
    uint32_t _nextSeq;             // 下一个应交出的 frameSeq
    BOOL _needsKeyframe;
    NSUInteger _droppedFrames;
    NSUInteger _droppedKeyframes;
    NSUInteger _droppedPFrames;
    NSUInteger _fragmentsDiscarded;
    NSUInteger _discardWipe;
    NSUInteger _discardAhead;
    NSUInteger _aheadRejects;          // 自上次交付以来被超前窗口拒收的分片数
    NSUInteger _discardWindowFull;
    NSUInteger _discardStale;
    NSUInteger _repairRequests;
    double _lastRepairRttMs;
    NSUInteger _repairRttSamples;
    NSMutableArray<NSString *> *_dropDetails;
    uint32_t _lastCompletedSeq;
    BOOL _haveDisplay;
    uint32_t _activeDisplay;
    double _gapSinceMs;            // 首次观察到「nextSeq 缺失但已有更晚帧」的时刻
    NSUInteger _gapRepairAttempts; // nextSeq 整帧零分片时的整帧重发请求次数
    double _gapRepairRequestedAtMs;
}

- (instancetype)init {
    if ((self = [super init])) {
        _frameDeadlineMs = 120.0;
        _repairRequestMs = 60.0;
        _repairGraceMs = 250.0;
        _repairRetryMs = 120.0;
        _maxRepairAttempts = 3;
        _maxRepairFragments = 64;
        _maxFramesInFlight = 4;
        [self reset];
    }
    return self;
}

- (void)reset {
    // 新会话：帧状态与统计一起清零。首帧必须是关键帧——中途加入的 P 帧无参考帧，
    // 交给解码器只会报错，不如直接等 Host 的 IDR。
    _partials = [NSMutableDictionary dictionary];
    _ready = [NSMutableDictionary dictionary];
    _haveNext = NO;
    _nextSeq = 0;
    _needsKeyframe = YES;
    _droppedFrames = 0;
    _droppedKeyframes = 0;
    _droppedPFrames = 0;
    _fragmentsDiscarded = 0;
    _discardWipe = 0;
    _discardAhead = 0;
    _aheadRejects = 0;
    _discardWindowFull = 0;
    _discardStale = 0;
    _repairRequests = 0;
    _lastRepairRttMs = 0;
    _repairRttSamples = 0;
    _dropDetails = [NSMutableArray array];
    _lastCompletedSeq = 0;
    _haveDisplay = NO;
    _activeDisplay = 0;
    _gapSinceMs = 0;
    _gapRepairAttempts = 0;
    _gapRepairRequestedAtMs = 0;
}

- (NSUInteger)droppedKeyframes { return _droppedKeyframes; }
- (NSUInteger)droppedPFrames { return _droppedPFrames; }
- (NSString *)debugState {
    P1PartialFrame *np = _partials[@(_nextSeq)];
    uint32_t minSeq = UINT32_MAX, maxSeq = 0;
    for (NSNumber *k in _partials) {
        if (k.unsignedIntValue < minSeq) minSeq = k.unsignedIntValue;
        if (k.unsignedIntValue > maxSeq) maxSeq = k.unsignedIntValue;
    }
    for (NSNumber *k in _ready) {
        if (k.unsignedIntValue < minSeq) minSeq = k.unsignedIntValue;
        if (k.unsignedIntValue > maxSeq) maxSeq = k.unsignedIntValue;
    }
    NSString *npDesc = np ? [NSString stringWithFormat:@"fc=%u recv=%lu key=%d att=%lu missing=%lu",
                             np.fragCount, (unsigned long)np.receivedCount, np.keyframe ? 1 : 0,
                             (unsigned long)np.repairAttempts,
                             (unsigned long)[self missingIndicesOfPartial:np].count]
                          : @"none";
    return [NSString stringWithFormat:
            @"haveNext=%d next=%u kf=%d partials=%lu ready=%lu inflight=%u..%u nextPartial[%@]",
            _haveNext ? 1 : 0, _nextSeq, _needsKeyframe ? 1 : 0,
            (unsigned long)_partials.count, (unsigned long)_ready.count,
            minSeq == UINT32_MAX ? 0 : minSeq, maxSeq, npDesc];
}

- (NSString *)discardBreakdown {
    return [NSString stringWithFormat:@"wipe=%lu ahead=%lu winFull=%lu stale=%lu",
            (unsigned long)_discardWipe, (unsigned long)_discardAhead,
            (unsigned long)_discardWindowFull, (unsigned long)_discardStale];
}
- (NSArray<NSString *> *)recentDropDetails { return [_dropDetails copy]; }
- (NSUInteger)repairRequests { return _repairRequests; }
- (double)lastRepairRttMs { return _lastRepairRttMs; }
- (NSUInteger)repairRttSamples { return _repairRttSamples; }

- (BOOL)hasActiveKeyframeAtMs:(double)nowMs withinMs:(double)windowMs {
    for (P1PartialFrame *p in _partials.allValues) {
        if (p.keyframe && nowMs - p.lastProgressMs <= windowMs) return YES;
    }
    return NO;
}

#pragma mark 内部

// 丢帧原因要能回答两个问题：丢的是不是关键帧、缺的是不是尾部连续分片。
// 随机丢片缺片位置分散；发送突发灌满 QUIC 队列时通常成片缺在尾部。
- (void)noteDropOfPartial:(P1PartialFrame *)p reason:(NSString *)reason {
    if (p.keyframe) _droppedKeyframes++;
    else _droppedPFrames++;
    if (_dropDetails.count >= 16) return;
    NSMutableString *missing = [NSMutableString string];
    NSUInteger missCount = 0;
    for (NSUInteger i = 0; i < p.slots.count; i++) {
        if (p.slots[i] == (id)[NSNull null]) {
            missCount++;
            if (missCount <= 8) [missing appendFormat:@"%lu ", (unsigned long)i];
        }
    }
    [_dropDetails addObject:[NSString stringWithFormat:
        @"seq=%u key=%d recv=%lu/%lu miss=%lu [%@] %@",
        p.frameSeq, p.keyframe, (unsigned long)p.receivedCount,
        (unsigned long)p.fragCount, (unsigned long)missCount,
        [missing stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]], reason]];
}

- (void)dropPartial:(P1PartialFrame *)p countAsFrame:(BOOL)countAsFrame {
    if (countAsFrame) {
        _droppedFrames++;
        [self noteDropOfPartial:p reason:(p.repairEmitted ? @"deadline-after-repair"
                                                         : @"deadline-before-repair")];
    }
    _fragmentsDiscarded += p.receivedCount;
    _discardWipe += p.receivedCount;
    [_partials removeObjectForKey:@(p.frameSeq)];
}

// 判丢之后的统一收尾：已经无法按序解码，全部在途/待交帧作废，只等关键帧。
- (void)declareLoss {
    for (P1PartialFrame *p in _partials.allValues) {
        _droppedFrames++;
        [self noteDropOfPartial:p reason:(p.repairEmitted ? @"gap-after-repair" : @"gap")];
        _fragmentsDiscarded += p.receivedCount;
        _discardWipe += p.receivedCount;
    }
    for (P1ReassembledFrame *f in _ready.allValues) {
        if (f.keyframe) _droppedKeyframes++;
        else _droppedPFrames++;
        if (_dropDetails.count < 16) {
            [_dropDetails addObject:[NSString stringWithFormat:
                @"seq=%u key=%d ready-dropped gap", f.frameSeq, f.keyframe]];
        }
    }
    _droppedFrames += _ready.count;
    [_partials removeAllObjects];
    [_ready removeAllObjects];
    _aheadRejects = 0;
    _needsKeyframe = YES;
    _haveNext = NO;
    _gapSinceMs = 0;
    _gapRepairAttempts = 0;
    _gapRepairRequestedAtMs = 0;
}

// 关键帧到达：先清掉关键帧之前的残留（它们已无参考价值），再以该帧为新的顺序起点。
- (void)restartAtKeyframeSeq:(uint32_t)seq {
    _aheadRejects = 0;
    NSUInteger lost = 0;
    for (P1PartialFrame *p in _partials.allValues) {
        [self noteDropOfPartial:p reason:@"pre-keyframe"];
        _fragmentsDiscarded += p.receivedCount;
        _discardWipe += p.receivedCount;
        lost++;
    }
    for (P1ReassembledFrame *f in _ready.allValues) {
        if (f.keyframe) _droppedKeyframes++;
        else _droppedPFrames++;
        lost++;
    }
    _droppedFrames += lost;
    [_partials removeAllObjects];
    [_ready removeAllObjects];
    _haveNext = YES;
    _nextSeq = seq;
    _needsKeyframe = NO;
    _gapSinceMs = 0;
    _gapRepairAttempts = 0;
    _gapRepairRequestedAtMs = 0;
}

// 帧期限判据是「停止推进」而不是「总耗时」：大帧（WAN 上的 IDR）可以合法地
// 持续收上几百毫秒，只要不断有新分片进来；真正缺片后 120ms 内没有新分片即判丢。
//
// v4：首次超期先不判死，把缺失片下标交给发送端做定向重发，并给一个 repairGraceMs
// 的补片窗口。整帧重发（尤其是 IDR 的 70+ 片）在 WAN 上代价太高且会与在途帧抢带宽，
// 一两片缺失时只补那几片通常一个 RTT 内就能收尾。
- (NSIndexSet *)missingIndicesOfPartial:(P1PartialFrame *)p {
    NSMutableIndexSet *missing = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < p.slots.count; i++) {
        if (p.slots[i] == (id)[NSNull null]) [missing addIndex:i];
    }
    return missing;
}

- (void)evictExpiredAt:(double)nowMs {
    NSMutableArray<P1PartialFrame *> *expired = [NSMutableArray array];
    for (P1PartialFrame *p in _partials.allValues) {
        // 补片请求要比判丢早：WAN 上 NACK 往返 + 重发要 100ms 量级，
        // 等判丢那一刻才请求，补片必然晚于任何一个合理的等待窗口。
        // 重发的分片也可能再丢，所以按 repairRetryMs 重问，最多 maxRepairAttempts 次。
        BOOL stalled = nowMs - p.lastProgressMs > self.repairRequestMs;
        BOOL retryDue = p.repairAttempts > 0 && p.repairAttempts < MAX(1, self.maxRepairAttempts) &&
                        nowMs - p.repairRequestedAtMs >= self.repairRetryMs;
        if (self.onMissingFragments && (stalled || retryDue) &&
            (!p.repairEmitted || retryDue)) {
            NSIndexSet *missing = [self missingIndicesOfPartial:p];
            if (missing.count > 0 && missing.count <= MAX(1, self.maxRepairFragments)) {
                p.repairEmitted = YES;
                p.repairAttempts += 1;
                p.repairRequestedAtMs = nowMs;
                _repairRequests++;
                self.onMissingFragments(p.frameSeq, p.fragCount, missing, p.keyframe);
            }
        }
        // 补片窗口从「最近一次请求」起算：每次重问都把期限往后推一个窗口，
        // 但重问次数有上限，所以一个死帧最多占住链路几百毫秒。
        double deadline = p.repairEmitted
            ? MAX(self.repairGraceMs, self.frameDeadlineMs)
            : self.frameDeadlineMs;
        double ref = p.repairEmitted ? MAX(p.lastProgressMs, p.repairRequestedAtMs)
                                     : p.lastProgressMs;
        if (nowMs - ref > deadline) [expired addObject:p];
    }
    if (expired.count == 0) return;

    NSMutableArray<P1PartialFrame *> *dead = [NSMutableArray array];
    BOOL emitted = NO;
    for (P1PartialFrame *p in expired) {
        if (!p.repairEmitted && self.onMissingFragments) {
            NSIndexSet *missing = [self missingIndicesOfPartial:p];
            if (missing.count > 0 && missing.count <= MAX(1, self.maxRepairFragments)) {
                p.repairEmitted = YES;
                p.repairAttempts += 1;
                p.repairRequestedAtMs = nowMs;
                _repairRequests++;
                self.onMissingFragments(p.frameSeq, p.fragCount, missing, p.keyframe);
                emitted = YES;
                continue;
            }
        }
        [dead addObject:p];
    }
    if (emitted) {
        // 同批超期多半是同一段链路抖动造成的：已经发出补片请求，就先别让
        // 同批的其他帧立刻宣告整链丢失（declareLoss 会连补片中的帧一起清掉）。
        for (P1PartialFrame *p in dead) {
            p.repairEmitted = YES;
            p.lastProgressMs = nowMs;
        }
        return;
    }
    for (P1PartialFrame *p in dead) [self dropPartial:p countAsFrame:YES];
    [self declareLoss];
}

// nextSeq 完全没有分片、但更晚的帧已经在途/就绪 ⇒ 给一个期限，到期即判丢。
// nextSeq 自己还有分片时走上面的「停止推进」判据，避免把慢速大帧误杀。
//
// v5：整帧零分片没有任何 partial，缺片补丁无从谈起——在判丢之前先按 frameSeq
// 请求整帧重发（fragCount=0、missingIndices 为空）。WAN 突发丢包会整帧带走
// 4~6 片的 P 帧，之前这里直接 declareLoss，把在途 partial 和已就绪帧一起清掉，
// 只能等下一个 IDR；一次微突发级联成多次关键帧重建。整帧重发也只占该帧本身
// 的带宽，命中缓存时一个 RTT 就能续上。
- (void)checkGapDeadlineAt:(double)nowMs {
    if (!_haveNext) {
        _gapSinceMs = 0;
        _gapRepairAttempts = 0;
        return;
    }
    if (_partials[@(_nextSeq)] != nil) {
        _gapSinceMs = 0;
        _gapRepairAttempts = 0;
        return;
    }
    BOOL gap = NO;
    for (NSNumber *k in _ready) {
        if (k.unsignedIntValue > _nextSeq) { gap = YES; break; }
    }
    if (!gap) {
        for (NSNumber *k in _partials) {
            if (k.unsignedIntValue > _nextSeq) { gap = YES; break; }
        }
    }
    if (!gap) {
        _gapSinceMs = 0;
        _gapRepairAttempts = 0;
        return;
    }
    if (_gapSinceMs == 0) { _gapSinceMs = nowMs; return; }
    BOOL retryDue = _gapRepairAttempts == 0
        || nowMs - _gapRepairRequestedAtMs >= self.repairRetryMs;
    if (self.onMissingFragments && retryDue &&
        _gapRepairAttempts < MAX(1, self.maxRepairAttempts) &&
        nowMs - _gapSinceMs >= self.repairRequestMs) {
        _gapRepairAttempts++;
        _gapRepairRequestedAtMs = nowMs;
        _repairRequests++;
        self.onMissingFragments(_nextSeq, 0, [NSIndexSet indexSet], NO);
        return;
    }
    double deadline = _gapRepairAttempts > 0
        ? MAX(self.repairGraceMs, self.frameDeadlineMs)
        : self.frameDeadlineMs;
    double ref = _gapRepairAttempts > 0
        ? MAX(_gapSinceMs, _gapRepairRequestedAtMs)
        : _gapSinceMs;
    if (nowMs - ref < deadline) return;
    _droppedFrames++;   // _nextSeq 一个分片都没收到
    [self declareLoss];
}

- (void)drainInto:(NSMutableArray<P1ReassembledFrame *> *)out {
    if (_ready[@(_nextSeq)] != nil) _aheadRejects = 0;   // 顺序推进了就不算追不上
    while (_haveNext) {
        P1ReassembledFrame *f = _ready[@(_nextSeq)];
        if (!f) break;
        [_ready removeObjectForKey:@(_nextSeq)];
        [out addObject:f];
        _lastCompletedSeq = _nextSeq;
        _nextSeq++;
    }
}

#pragma mark 入口

- (NSArray<P1ReassembledFrame *> *)acceptHeader:(P1FrameHeader)header
                                        payload:(NSData *)payload
                                          error:(NSError **)error {
    return [self acceptHeader:header payload:payload
                        nowMs:CFAbsoluteTimeGetCurrent() * 1000.0
                        error:error];
}

- (NSArray<P1ReassembledFrame *> *)acceptHeader:(P1FrameHeader)header
                                        payload:(NSData *)payload
                                          nowMs:(double)nowMs
                                          error:(NSError **)error {
    if (error) *error = nil;
    if (header.fragCount == 0 || header.fragIdx >= header.fragCount) {
        if (error) *error = P1Err(P1ProtocolErrorBadHeader, @"fragIdx out of range");
        return @[];
    }
    if (payload.length != header.payloadLen) {
        if (error) *error = P1Err(P1ProtocolErrorBadHeader, @"payloadLen mismatches payload");
        return @[];
    }
    if (self.maxFramesInFlight < 1) self.maxFramesInFlight = 1;

    NSMutableArray<P1ReassembledFrame *> *delivered = [NSMutableArray array];
    [self evictExpiredAt:nowMs];

    // 单屏会话：别的 displayID 的分片不属于本重组器。
    if (!_haveDisplay) {
        _haveDisplay = YES;
        _activeDisplay = header.displayID;
    } else if (header.displayID != _activeDisplay) {
        _fragmentsDiscarded++; _discardStale++;
        [self checkGapDeadlineAt:nowMs];
        return delivered;
    }

    BOOL isKey = (header.flags & P1FrameFlagKeyframe) != 0;

    // 缺口期间只接受关键帧（参考链已断，P 帧解不出可用画面）。
    if (_needsKeyframe && !isKey) {
        _fragmentsDiscarded++; _discardStale++;
        [self checkGapDeadlineAt:nowMs];
        return delivered;
    }

    uint32_t seq = header.frameSeq;
    if (_haveNext && seq < _nextSeq) {          // 已交付帧的迟到分片
        _fragmentsDiscarded++; _discardStale++;
        [self checkGapDeadlineAt:nowMs];
        return delivered;
    }
    if (_ready[@(seq)] != nil) {                // 已收齐待交付帧的重复分片
        _fragmentsDiscarded++; _discardStale++;
        [self checkGapDeadlineAt:nowMs];
        return delivered;
    }
    if (_haveNext && seq > _nextSeq + (uint32_t)self.maxFramesInFlight) {
        _fragmentsDiscarded++; _discardAhead++; // 超前太远，拒绝为它开盘
        _aheadRejects++;
        // nextSeq 若已经追不上（窗口外持续来包），静默丢弃会让整段流锁死：
        // 这些分片没有 partial，补片无从发起，也永远等不到关键帧。持续超前
        // 拒收即视为整链已断，立刻走关键帧重建，把锁死换成一次 ~1s 的重启。
        if (_aheadRejects >= 64) {
            if (_dropDetails.count < 16) {
                [_dropDetails addObject:[NSString stringWithFormat:
                    @"seq=%u ahead-catchup next=%u rejects=%lu", seq, _nextSeq,
                    (unsigned long)_aheadRejects]];
            }
            _droppedFrames++;
            [self declareLoss];
            return delivered;
        }
        [self checkGapDeadlineAt:nowMs];
        return delivered;
    }

    P1PartialFrame *p = _partials[@(seq)];
    if (!p) {
        if (_partials.count >= self.maxFramesInFlight) {
            _fragmentsDiscarded++; _discardWindowFull++;
            [self checkGapDeadlineAt:nowMs];
            return delivered;
        }
        p = [[P1PartialFrame alloc] init];
        p.displayID = header.displayID;
        p.frameSeq = seq;
        p.fragCount = header.fragCount;
        p.capturedAtUs = header.capturedAtUs;
        p.lastProgressMs = nowMs;
        p.slots = [NSMutableArray arrayWithCapacity:header.fragCount];
        for (uint16_t i = 0; i < header.fragCount; i++) [p.slots addObject:[NSNull null]];
        _partials[@(seq)] = p;
    } else if (p.fragCount != header.fragCount) {
        if (header.fragIdx != 0) {              // 分片数不一致且不是首片：作废
            [self dropPartial:p countAsFrame:YES];
            [self declareLoss];
            [self checkGapDeadlineAt:nowMs];
            return delivered;
        }
        p.fragCount = header.fragCount;
        p.lastProgressMs = nowMs;
        p.receivedCount = 0;
        p.totalBytes = 0;
        p.slots = [NSMutableArray arrayWithCapacity:header.fragCount];
        for (uint16_t i = 0; i < header.fragCount; i++) [p.slots addObject:[NSNull null]];
    }

    if (p.slots[header.fragIdx] != [NSNull null]) {   // 重复分片
        _fragmentsDiscarded++; _discardStale++;
        [self checkGapDeadlineAt:nowMs];
        return delivered;
    }
    p.slots[header.fragIdx] = [payload copy];
    p.receivedCount++;
    p.totalBytes += payload.length;
    p.lastProgressMs = nowMs;
    if (isKey) p.keyframe = YES;
    if (header.flags & P1FrameFlagHasParamSets) p.carriesParamSets = YES;

    if (p.receivedCount < p.fragCount) {
        [self checkGapDeadlineAt:nowMs];
        return delivered;
    }

    // 整帧收齐
    NSMutableData *whole = [NSMutableData dataWithCapacity:p.totalBytes];
    for (NSData *d in p.slots) [whole appendData:d];
    P1ReassembledFrame *frame = [[P1ReassembledFrame alloc] init];
    frame.displayID = p.displayID;
    frame.frameSeq = p.frameSeq;
    frame.keyframe = p.keyframe;
    frame.carriesParamSets = p.carriesParamSets;
    frame.capturedAtUs = p.capturedAtUs;
    frame.payload = whole;
    [_partials removeObjectForKey:@(seq)];
    if (p.repairEmitted && p.repairRequestedAtMs > 0 && nowMs > p.repairRequestedAtMs) {
        _lastRepairRttMs = nowMs - p.repairRequestedAtMs;
        _repairRttSamples++;
    }

    if (_needsKeyframe && !frame.keyframe) {
        _droppedFrames++;
        _fragmentsDiscarded += p.receivedCount;
        _discardStale += p.receivedCount;
        [self checkGapDeadlineAt:nowMs];
        return delivered;
    }
    if (_needsKeyframe && frame.keyframe) {
        [self restartAtKeyframeSeq:frame.frameSeq];
    }
    if (!_haveNext) {
        _haveNext = YES;
        _nextSeq = frame.frameSeq;
    }
    if (frame.frameSeq < _nextSeq) {            // 迟到整帧
        _droppedFrames++;
        _fragmentsDiscarded += p.receivedCount;
        _discardStale += p.receivedCount;
        [self checkGapDeadlineAt:nowMs];
        return delivered;
    }
    _ready[@(frame.frameSeq)] = frame;
    [self drainInto:delivered];
    [self checkGapDeadlineAt:nowMs];
    return delivered;
}

@end
