//
//  ProtocolCodec.m
//  P1-ClientProbe
//

#import "ProtocolCodec.h"

NSString * const P1ProtocolErrorDomain = @"P1ProtocolErrorDomain";

const NSUInteger P1ControlMaxFrameBytes = 1024 * 1024;  // 1 MiB
const uint16_t P1FrameMagic = 0x4D52;                   // 'MR'
const uint8_t  P1ProtocolVersion = 1;
const NSUInteger P1FrameHeaderSize = 16;
const NSUInteger P1FrameMaxPayload = 1200;

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
    // 用字面量 16：P1FrameHeaderSize 是 const NSUInteger（运行期只读），
    // 不能用作 C 数组长度，否则会退化成 VLA 并触发 -Wgnu-folding-constant。
    uint8_t b[16] = {0};
    P1PutU16(b + 0, P1FrameMagic);
    b[2] = P1ProtocolVersion;
    b[3] = h.flags;
    P1PutU32(b + 4, h.displayID);
    P1PutU32(b + 8, h.frameSeq);
    b[12] = h.fragIdx;
    b[13] = h.fragCount;
    P1PutU16(b + 14, h.payloadLen);
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
    if (b[2] != P1ProtocolVersion) {
        if (error) *error = P1Err(P1ProtocolErrorBadVersion, @"bad frame version");
        return NO;
    }
    P1FrameHeader h;
    h.flags = b[3];
    h.displayID = P1GetU32(b + 4);
    h.frameSeq = P1GetU32(b + 8);
    h.fragIdx = b[12];
    h.fragCount = b[13];
    h.payloadLen = P1GetU16(b + 14);

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
    if (count > 255) {
        if (error) *error = P1Err(P1ProtocolErrorPayloadTooLarge, @"too many fragments (>255)");
        return nil;
    }
    NSMutableArray<NSData *> *out = [NSMutableArray arrayWithCapacity:count];
    const uint8_t *base = payload.bytes;
    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger off = i * P1FrameMaxPayload;
        NSUInteger n = MIN(P1FrameMaxPayload, payload.length - off);
        P1FrameHeader h = proto;
        h.fragIdx = (uint8_t)i;
        h.fragCount = (uint8_t)count;
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

@implementation P1FrameReassembler {
    NSMutableData *_acc;
    BOOL _active;
    uint32_t _curSeq;
    uint32_t _curDisplay;
    uint8_t _expectIdx;
    BOOL _completedAny;
}

- (instancetype)init {
    if ((self = [super init])) {
        _acc = [NSMutableData data];
        _needsKeyframe = NO;
        _droppedFrames = 0;
        _lastCompletedSeq = 0;
    }
    return self;
}

- (void)reset {
    // 新会话：帧状态与统计一起清零，避免上一会话的缺口/关键帧请求泄漏到新会话。
    [_acc setLength:0];
    _active = NO;
    _expectIdx = 0;
    _needsKeyframe = NO;
    _completedAny = NO;
    _droppedFrames = 0;
    _lastCompletedSeq = 0;
}

- (void)dropCurrentFrame {
    [_acc setLength:0];
    _active = NO;
    _expectIdx = 0;
    _droppedFrames++;
}

- (NSData *)acceptHeader:(P1FrameHeader)header payload:(NSData *)payload error:(NSError **)error {
    if (error) *error = nil;
    if (header.fragCount == 0 || header.fragIdx >= header.fragCount) {
        if (error) *error = P1Err(P1ProtocolErrorBadHeader, @"fragIdx out of range");
        return nil;
    }
    if (payload.length != header.payloadLen) {
        if (error) *error = P1Err(P1ProtocolErrorBadHeader, @"payloadLen mismatches payload");
        return nil;
    }

    BOOL startsFrame = (header.fragIdx == 0);

    // 粘在旧帧中途却来了新帧/新屏 ⇒ 丢弃旧帧
    if (_active && (header.displayID != _curDisplay || header.frameSeq != _curSeq)) {
        [self dropCurrentFrame];
        _needsKeyframe = YES;
    }

    if (!_active) {
        if (!startsFrame) {
            // 中间分片先到（前面的丢了）⇒ 丢弃，等关键帧
            _droppedFrames++;
            _needsKeyframe = YES;
            return nil;
        }
        // frameSeq 缺口检测
        if (_completedAny && header.frameSeq != _lastCompletedSeq + 1) {
            _droppedFrames++;
            if (!(header.flags & P1FrameFlagKeyframe)) _needsKeyframe = YES;
        }
        _active = YES;
        _curSeq = header.frameSeq;
        _curDisplay = header.displayID;
        _expectIdx = 0;
        [_acc setLength:0];
    }

    if (header.fragIdx != _expectIdx) {
        // 分片错位：整帧作废
        [self dropCurrentFrame];
        _needsKeyframe = YES;
        return nil;
    }

    [_acc appendData:payload];
    _expectIdx++;

    BOOL isLast = (header.flags & P1FrameFlagLastFragment) || (header.fragIdx + 1 == header.fragCount);
    if (!isLast) return nil;

    NSData *whole = [_acc copy];
    _lastCompletedSeq = header.frameSeq;
    _completedAny = YES;
    _active = NO;
    _expectIdx = 0;
    [_acc setLength:0];
    if (header.flags & P1FrameFlagKeyframe) _needsKeyframe = NO;
    return whole;
}

@end
