//
//  M1ControlLink.m
//  M1-Skeleton
//

#import "M1ControlLink.h"
#import <QuartzCore/QuartzCore.h>

NSString * const M1ControlLinkDomain = @"M1ControlLink";

static const uint8_t kMagic = 'C';
static const uint8_t kVersion = 1;
static const uint8_t kKindData = 0;
static const uint8_t kKindAck  = 1;

static NSError *M1LinkErr(M1ControlLinkErrorCode code, NSString *msg) {
    return [NSError errorWithDomain:M1ControlLinkDomain code:code
                            userInfo:@{NSLocalizedDescriptionKey: msg ?: @""}];
}

static void PutU32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);  p[3] = (uint8_t)v;
}
static uint32_t GetU32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

@interface M1ControlLink ()
@property (nonatomic, strong) id<M1DatagramSink> sink;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSData *> *unacked;   // seq -> 完整报文
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *attempts;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *lastSentMs;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSData *> *held;      // 乱序暂存
@property (nonatomic, assign) uint32_t lastDelivered;
@property (nonatomic, assign) uint32_t nextSeq;
@property (nonatomic, strong) dispatch_queue_t timerQueue;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, readwrite) NSUInteger sentMessages;
@property (nonatomic, readwrite) NSUInteger deliveredMessages;
@property (nonatomic, readwrite) NSUInteger retransmits;
@property (nonatomic, readwrite) NSUInteger duplicatesSeen;
@property (nonatomic, readwrite) NSUInteger heldOutOfOrder;
@property (nonatomic, readwrite) NSUInteger acksReceived;
@property (nonatomic, readwrite) uint32_t lastAckReceived;
@property (nonatomic, assign) BOOL failed;
@end

@implementation M1ControlLink

- (instancetype)initWithSink:(id<M1DatagramSink>)sink {
    if ((self = [super init])) {
        _sink = sink;
        _unacked = [NSMutableDictionary dictionary];
        _attempts = [NSMutableDictionary dictionary];
        _lastSentMs = [NSMutableDictionary dictionary];
        _held = [NSMutableDictionary dictionary];
        _lastDelivered = 0;
        _nextSeq = 1;
        _retryIntervalMs = 250;
        _maxAttempts = 8;
        _autoTick = YES;
        _timerQueue = dispatch_queue_create("m1.control.link", DISPATCH_QUEUE_SERIAL);
        __weak typeof(self) weakSelf = self;
        _clock = ^double { return CACurrentMediaTime() * 1000.0; };
        (void)weakSelf;
    }
    return self;
}

- (BOOL)hasPending {
    @synchronized (self) { return self.unacked.count > 0; }
}

#pragma mark - 定时器

- (void)ensureTimer {
    if (self.timer || !self.autoTick) return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.timerQueue);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                              50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(t, ^{
        M1ControlLink *s = weakSelf;
        if (!s || !s.autoTick) return;
        [s tickAtMs:s.clock ? s.clock() : 0];
    });
    self.timer = t;
    dispatch_resume(t);
}

- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
}

#pragma mark - 发送

- (BOOL)sendMessage:(NSData *)message error:(NSError **)error {
    if (message.length == 0) {
        if (error) *error = M1LinkErr(M1ControlLinkErrorProtocol, @"空控制消息");
        return NO;
    }
    if (message.length > M1ControlLinkMaxPayload) {
        if (error) *error = M1LinkErr(M1ControlLinkErrorTooLarge,
            [NSString stringWithFormat:@"控制消息 %luB 超过单包上限 %luB",
             (unsigned long)message.length, (unsigned long)M1ControlLinkMaxPayload]);
        return NO;
    }
    uint32_t seq = 0;
    @synchronized (self) {
        if (self.failed) {
            if (error) *error = M1LinkErr(M1ControlLinkErrorSendFailed, @"链路已因重传耗尽失败");
            return NO;
        }
        seq = self.nextSeq++;
    }
    NSData *packet = [self packetWithKind:kKindData seq:seq ack:self.lastAckReceived payload:message];
    NSError *sendErr = nil;
    if (![self.sink sendDatagram:packet error:&sendErr]) {
        if (error) *error = M1LinkErr(M1ControlLinkErrorSendFailed,
            sendErr.localizedDescription ?: @"datagram 投递失败");
        return NO;
    }
    @synchronized (self) {
        self.unacked[@(seq)] = packet;
        self.attempts[@(seq)] = @1;
        self.lastSentMs[@(seq)] = @(self.clock ? self.clock() : 0);
        self.sentMessages += 1;
    }
    [self ensureTimer];
    return YES;
}

- (NSData *)packetWithKind:(uint8_t)kind
                       seq:(uint32_t)seq
                       ack:(uint32_t)ack
                   payload:(NSData *)payload {
    NSMutableData *p = [NSMutableData dataWithCapacity:M1ControlLinkHeaderSize + payload.length];
    uint8_t h[M1ControlLinkHeaderSize] = {0};
    h[0] = kMagic;
    h[1] = kVersion;
    h[2] = kind;
    h[3] = 0;
    PutU32(&h[4], seq);
    PutU32(&h[8], ack);
    uint16_t len = (uint16_t)payload.length;
    h[12] = (uint8_t)(len >> 8);
    h[13] = (uint8_t)len;
    [p appendBytes:h length:M1ControlLinkHeaderSize];
    if (payload.length) [p appendData:payload];
    return p;
}

- (void)sendAck {
    uint32_t ack;
    @synchronized (self) { ack = self.lastDelivered; }
    NSData *packet = [self packetWithKind:kKindAck seq:0 ack:ack payload:[NSData data]];
    NSError *err = nil;
    if (![self.sink sendDatagram:packet error:&err]) {
        // ACK 丢了不要紧：对端会重传，我们重复 ACK 即可。
    }
}

#pragma mark - 接收

- (BOOL)feedDatagram:(NSData *)datagram {
    if (datagram.length < M1ControlLinkHeaderSize) return NO;
    const uint8_t *b = datagram.bytes;
    if (b[0] != kMagic) return NO;          // 不是控制包（帧分片魔数不同）
    if (b[1] != kVersion) return YES;       // 版本不符：认领但不处理，避免上层误判为帧
    uint8_t kind = b[2];
    uint32_t seq = GetU32(&b[4]);
    uint32_t ack = GetU32(&b[8]);
    uint16_t len = (uint16_t)((b[12] << 8) | b[13]);
    if (M1ControlLinkHeaderSize + (NSUInteger)len > datagram.length) {
        @synchronized (self) {
            self.failed = YES;
        }
        if ([self.delegate respondsToSelector:@selector(controlLink:didFailWithError:)]) {
            [self.delegate controlLink:self
                     didFailWithError:M1LinkErr(M1ControlLinkErrorProtocol, @"载荷长度越界")];
        }
        return YES;
    }

    if (kind == kKindAck) {
        [self handleAck:ack];
        return YES;
    }
    if (kind != kKindData) return YES;

    NSData *payload = [datagram subdataWithRange:
                       NSMakeRange(M1ControlLinkHeaderSize, len)];
    NSArray<NSData *> *deliverable = nil;
    @synchronized (self) {
        if (seq <= self.lastDelivered) {
            self.duplicatesSeen += 1;      // 重复包：只补 ACK，不重复交付
        } else if (seq == self.lastDelivered + 1) {
            self.lastDelivered = seq;
            NSMutableArray *out = [NSMutableArray arrayWithObject:payload];
            // 把之前暂存的后续包按序放出来
            while (self.held[@(self.lastDelivered + 1)]) {
                NSNumber *k = @(self.lastDelivered + 1);
                [out addObject:self.held[k]];
                [self.held removeObjectForKey:k];
                self.lastDelivered += 1;
            }
            deliverable = out;
        } else {
            self.held[@(seq)] = payload;   // 乱序先扣住
            self.heldOutOfOrder += 1;
        }
    }
    // 先回 ACK 再交付：即使交付方在处理中崩溃，重传也能被去重。
    [self sendAck];
    for (NSData *msg in deliverable) {
        @synchronized (self) { self.deliveredMessages += 1; }
        if ([self.delegate respondsToSelector:@selector(controlLink:didDeliverMessage:)]) {
            [self.delegate controlLink:self didDeliverMessage:msg];
        }
    }
    // 顺带确认对端在 DATA 里捎带的消息
    [self handleAck:ack];
    return YES;
}

- (void)handleAck:(uint32_t)ack {
    if (ack == 0) return;
    @synchronized (self) {
        if (ack <= self.lastAckReceived) return;
        self.lastAckReceived = ack;
        self.acksReceived += 1;
        NSMutableArray *done = [NSMutableArray array];
        for (NSNumber *k in self.unacked) if (k.unsignedIntValue <= ack) [done addObject:k];
        for (NSNumber *k in done) {
            [self.unacked removeObjectForKey:k];
            [self.attempts removeObjectForKey:k];
            [self.lastSentMs removeObjectForKey:k];
        }
    }
}

#pragma mark - 重传

- (void)tickAtMs:(double)nowMs {
    NSMutableArray<NSNumber *> *retry = [NSMutableArray array];
    NSError *failErr = nil;
    @synchronized (self) {
        if (self.failed) return;
        for (NSNumber *seq in [self.unacked.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            double last = self.lastSentMs[seq].doubleValue;
            if (nowMs - last < (double)self.retryIntervalMs) continue;
            NSUInteger tries = self.attempts[seq].unsignedIntegerValue;
            if (tries >= self.maxAttempts) {
                self.failed = YES;
                failErr = M1LinkErr(M1ControlLinkErrorUnacked,
                    [NSString stringWithFormat:@"seq=%u 重传 %lu 次仍未确认",
                     seq.unsignedIntValue, (unsigned long)tries]);
                break;
            }
            self.attempts[seq] = @(tries + 1);
            self.lastSentMs[seq] = @(nowMs);
            self.retransmits += 1;
            [retry addObject:seq];
        }
    }
    if (failErr) {
        @synchronized (self) {
            [self.unacked removeAllObjects];
            [self.attempts removeAllObjects];
            [self.lastSentMs removeAllObjects];
        }
        if ([self.delegate respondsToSelector:@selector(controlLink:didFailWithError:)]) {
            [self.delegate controlLink:self didFailWithError:failErr];
        }
        return;
    }
    for (NSNumber *seq in retry) {
        NSData *packet = nil;
        @synchronized (self) { packet = self.unacked[seq]; }
        if (!packet) continue;
        NSError *err = nil;
        [self.sink sendDatagram:packet error:&err];
    }
}

@end
