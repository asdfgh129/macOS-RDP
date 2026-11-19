//
//  ProtocolCodec.m
//  P1-ClientProbe
//

#import "ProtocolCodec.h"

NSString * const P1ProtocolErrorDomain = @"P1ProtocolErrorDomain";

const NSUInteger P1ControlMaxFrameBytes = 1024 * 1024;  // 1 MiB
const uint16_t P1FrameMagic = 0x4D52;                   // 'MR'
const uint8_t  P1ProtocolVersion = 1;      // 控制通道 JSON 版本，与帧头版本相互独立
const uint8_t  P1FrameHeaderVersion = 2;   // v2：fragIdx/fragCount 扩到 uint16
const NSUInteger P1FrameHeaderSize = 18;
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
    // 用字面量 18：P1FrameHeaderSize 是 const NSUInteger（运行期只读），
    // 不能用作 C 数组长度，否则会退化成 VLA 并触发 -Wgnu-folding-constant。
    //
    // v2 布局（大端）：
    //   0..1 magic | 2 ver | 3 flags | 4..7 displayID | 8..11 frameSeq
    //   | 12..13 fragIdx | 14..15 fragCount | 16..17 payloadLen
    uint8_t b[18] = {0};
    P1PutU16(b + 0, P1FrameMagic);
    b[2] = P1FrameHeaderVersion;
    b[3] = h.flags;
    P1PutU32(b + 4, h.displayID);
    P1PutU32(b + 8, h.frameSeq);
    P1PutU16(b + 12, h.fragIdx);
    P1PutU16(b + 14, h.fragCount);
    P1PutU16(b + 16, h.payloadLen);
    return [NSData dataWithBytes:b length:P1FrameHeaderSize];
}

BOOL P1UnpackFrameHeader(NSData *data, P1FrameHeader *out, NSError **error) {
    if (error) *error = nil;
    if (data.length < P1FrameHeaderSize) {
        if (error) *error = P1Err(P1ProtocolErrorTruncated, @"header shorter than 16 bytes");
        return NO;
    }
    const uint8_t *b = data.bytes;
    uint16_t magic = P1GetU16(b);
    if (magic != P1FrameMagic) {
        if (error) *error = P1Err(P1ProtocolErrorBadMagic, @"bad magic");
        return NO;
    }
    if (b[2] != P1FrameHeaderVersion) {
        // v1 帧头（16B、fragIdx/fragCount 各 1B）不再接受：位宽不够，3440×1440 的关键帧
        // 会被切成 255 片以上而整帧丢失，属于必须换格式才能修的缺陷，不做兼容回退。
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
@property (nonatomic, assign) double lastProgressMs;   // 最近一次收到新分片的时刻
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
    NSUInteger _fragmentsDiscarded;
    uint32_t _lastCompletedSeq;
    BOOL _haveDisplay;
    uint32_t _activeDisplay;
    double _gapSinceMs;            // 首次观察到「nextSeq 缺失但已有更晚帧」的时刻
}

- (instancetype)init {
    if ((self = [super init])) {
        _frameDeadlineMs = 120.0;
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
    _fragmentsDiscarded = 0;
    _lastCompletedSeq = 0;
    _haveDisplay = NO;
    _activeDisplay = 0;
    _gapSinceMs = 0;
}

#pragma mark 内部

- (void)dropPartial:(P1PartialFrame *)p countAsFrame:(BOOL)countAsFrame {
    if (countAsFrame) _droppedFrames++;
    _fragmentsDiscarded += p.receivedCount;
    [_partials removeObjectForKey:@(p.frameSeq)];
}

// 判丢之后的统一收尾：已经无法按序解码，全部在途/待交帧作废，只等关键帧。
- (void)declareLoss {
    for (P1PartialFrame *p in _partials.allValues) {
        _droppedFrames++;
        _fragmentsDiscarded += p.receivedCount;
    }
    _droppedFrames += _ready.count;
    [_partials removeAllObjects];
    [_ready removeAllObjects];
    _needsKeyframe = YES;
    _haveNext = NO;
    _gapSinceMs = 0;
}

// 关键帧到达：先清掉关键帧之前的残留（它们已无参考价值），再以该帧为新的顺序起点。
- (void)restartAtKeyframeSeq:(uint32_t)seq {
    NSUInteger lost = 0;
    for (P1PartialFrame *p in _partials.allValues) {
        _fragmentsDiscarded += p.receivedCount;
        lost++;
    }
    lost += _ready.count;
    _droppedFrames += lost;
    [_partials removeAllObjects];
    [_ready removeAllObjects];
    _haveNext = YES;
    _nextSeq = seq;
    _needsKeyframe = NO;
    _gapSinceMs = 0;
}

// 帧期限判据是「停止推进」而不是「总耗时」：大帧（WAN 上的 IDR）可以合法地
// 持续收上几百毫秒，只要不断有新分片进来；真正缺片后 120ms 内没有新分片即判丢。
- (void)evictExpiredAt:(double)nowMs {
    NSMutableArray<P1PartialFrame *> *dead = [NSMutableArray array];
    for (P1PartialFrame *p in _partials.allValues) {
        if (nowMs - p.lastProgressMs > self.frameDeadlineMs) [dead addObject:p];
    }
    if (dead.count == 0) return;
    for (P1PartialFrame *p in dead) [self dropPartial:p countAsFrame:YES];
    [self declareLoss];
}

// nextSeq 完全没有分片、但更晚的帧已经在途/就绪 ⇒ 给一个期限，到期即判丢。
// nextSeq 自己还有分片时走上面的「停止推进」判据，避免把慢速大帧误杀。
- (void)checkGapDeadlineAt:(double)nowMs {
    if (!_haveNext) { _gapSinceMs = 0; return; }
    if (_partials[@(_nextSeq)] != nil) { _gapSinceMs = 0; return; }
    BOOL gap = NO;
    for (NSNumber *k in _ready) {
        if (k.unsignedIntValue > _nextSeq) { gap = YES; break; }
    }
    if (!gap) {
        for (NSNumber *k in _partials) {
            if (k.unsignedIntValue > _nextSeq) { gap = YES; break; }
        }
    }
    if (!gap) { _gapSinceMs = 0; return; }
    if (_gapSinceMs == 0) { _gapSinceMs = nowMs; return; }
    if (nowMs - _gapSinceMs < self.frameDeadlineMs) return;
    _droppedFrames++;   // _nextSeq 一个分片都没收到
    [self declareLoss];
}

- (void)drainInto:(NSMutableArray<P1ReassembledFrame *> *)out {
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
        _fragmentsDiscarded++;
        [self checkGapDeadlineAt:nowMs];
        return delivered;
    }

    BOOL isKey = (header.flags & P1FrameFlagKeyframe) != 0;

    // 缺口期间只接受关键帧（参考链已断，P 帧解不出可用画面）。
    if (_needsKeyframe && !isKey) {
        _fragmentsDiscarded++;
        [self checkGapDeadlineAt:nowMs];
        return delivered;
    }

    uint32_t seq = header.frameSeq;
    if (_haveNext && seq < _nextSeq) {          // 已交付帧的迟到分片
        _fragmentsDiscarded++;
        [self checkGapDeadlineAt:nowMs];
        return delivered;
    }
    if (_ready[@(seq)] != nil) {                // 已收齐待交付帧的重复分片
        _fragmentsDiscarded++;
        [self checkGapDeadlineAt:nowMs];
        return delivered;
    }
    if (_haveNext && seq > _nextSeq + (uint32_t)self.maxFramesInFlight) {
        _fragmentsDiscarded++;                  // 超前太远，拒绝为它开盘
        [self checkGapDeadlineAt:nowMs];
        return delivered;
    }

    P1PartialFrame *p = _partials[@(seq)];
    if (!p) {
        if (_partials.count >= self.maxFramesInFlight) {
            _fragmentsDiscarded++;
            [self checkGapDeadlineAt:nowMs];
            return delivered;
        }
        p = [[P1PartialFrame alloc] init];
        p.displayID = header.displayID;
        p.frameSeq = seq;
        p.fragCount = header.fragCount;
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
        _fragmentsDiscarded++;
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
    frame.payload = whole;
    [_partials removeObjectForKey:@(seq)];

    if (_needsKeyframe && !frame.keyframe) {
        _droppedFrames++;
        _fragmentsDiscarded += p.receivedCount;
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
        [self checkGapDeadlineAt:nowMs];
        return delivered;
    }
    _ready[@(frame.frameSeq)] = frame;
    [self drainInto:delivered];
    [self checkGapDeadlineAt:nowMs];
    return delivered;
}

@end
