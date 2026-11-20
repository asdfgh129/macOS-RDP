//
//  M1FrameSender.m
//  M1-Skeleton
//

#import "M1FrameSender.h"

static NSError *M1PipeErr(M1PipelineErrorCode code, NSString *msg) {
    return [NSError errorWithDomain:M1PipelineErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

#pragma mark - 统计

@interface M1FrameSenderStats ()
@property (nonatomic, assign) uint64_t framesSent;
@property (nonatomic, assign) uint64_t keyframesSent;
@property (nonatomic, assign) uint64_t fragmentsSent;
@property (nonatomic, assign) uint64_t bytesSent;
@property (nonatomic, assign) uint64_t sinkFailures;
@property (nonatomic, assign) uint64_t payloadBytesSent;
@end

@implementation M1FrameSenderStats

- (NSString *)description {
    return [NSString stringWithFormat:
            @"frames=%llu key=%llu frags=%llu bytes=%llu payload=%llu sinkFail=%llu",
            self.framesSent, self.keyframesSent, self.fragmentsSent,
            self.bytesSent, self.payloadBytesSent, self.sinkFailures];
}

@end

#pragma mark - 发送器

@interface M1FrameSender ()
@property (nonatomic, strong) id<M1DatagramSink> sink;
@property (nonatomic, assign) uint32_t seq;
@property (nonatomic, strong) M1FrameSenderStats *stats;
// 定向补片缓存：frameSeq → 该帧的分片（单份，带帧头原样重发）。
//   sendPayload 在编码线程写，resendFragments 在控制收包队列读，用锁保护。
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<NSData *> *> *fragCache;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fragCacheOrder;
@property (nonatomic, strong) NSLock *cacheLock;
@property (nonatomic, assign) uint64_t fragmentsResent;
@end

@implementation M1FrameSender

- (instancetype)initWithSink:(id<M1DatagramSink>)sink {
    return [self initWithSink:sink startSeq:0];
}

- (instancetype)initWithSink:(id<M1DatagramSink>)sink startSeq:(uint32_t)startSeq {
    NSParameterAssert(sink);
    self = [super init];
    if (self) {
        _sink = sink;
        _seq = startSeq;
        _stats = [[M1FrameSenderStats alloc] init];
        _keyframeCopies = 1;
        _pframeCopies = 1;
        _fragmentCacheFrames = 64;
        _fragCache = [NSMutableDictionary dictionary];
        _fragCacheOrder = [NSMutableArray array];
        _cacheLock = [NSLock new];
    }
    return self;
}

- (uint64_t)fragmentsResent { return _fragmentsResent; }

- (uint32_t)nextFrameSeq { return _seq; }
- (void)resetStats { self.stats = [[M1FrameSenderStats alloc] init]; }

- (BOOL)sendFrame:(M1EncodedFrame *)frame
        displayID:(uint32_t)displayID
            error:(NSError **)error {
    P1FrameFlags flags = 0;
    if (frame.isKeyframe) flags |= P1FrameFlagKeyframe;
    if (frame.carriesParamSets) flags |= P1FrameFlagHasParamSets;
    return [self sendPayload:frame.avccPayload displayID:displayID flags:flags error:error];
}

- (BOOL)sendPayload:(NSData *)payload
          displayID:(uint32_t)displayID
              flags:(P1FrameFlags)flags
              error:(NSError **)error {
    if (error) *error = nil;
    if (payload.length == 0) {
        if (error) *error = M1PipeErr(M1PipelineErrorEmptyPayload, @"空载荷");
        return NO;
    }

    // 末片标志由 P1FragmentPayload 按实际位置补写，这里先掩掉避免调用方误传后残留。
    P1FrameHeader proto = {0};
    proto.flags = (uint8_t)(flags & (uint8_t)~P1FrameFlagLastFragment);
    proto.displayID = displayID;
    proto.frameSeq = _seq;
    uint32_t seq = _seq;

    NSError *fragErr = nil;
    NSArray<NSData *> *frags = P1FragmentPayload(payload, proto, &fragErr);
    if (!frags) {
        if (error) {
            *error = M1PipeErr(M1PipelineErrorFragmentationFailed,
                               fragErr.localizedDescription ?: @"分片失败");
        }
        return NO;
    }

    // 分片逐个投递。任何一片失败即中止——继续发剩下的只会让接收端组出坏帧。
    // 多副本按「整帧一遍」发送，副本之间相隔整帧的分片数；传输层若有节拍，
    // 两份会自然拉开时间，降低同一次突发丢包把两份一起带走的概率。
    NSUInteger copies = (flags & P1FrameFlagKeyframe) ? self.keyframeCopies : self.pframeCopies;
    if (copies == 0) copies = 1;
    NSUInteger fragCount = frags.count;
    for (NSUInteger pass = 0; pass < copies; pass++) {
        // 每轮轮转一个非整倍数的偏移（17/28…），让同一分片的各副本落在
        // 不同的相对相位。实测三份副本仍出现「同一分片全丢」，说明丢包与
        // 报文位置相关（周期性丢弃/长突发），固定间隔 72 片会把副本对齐。
        NSUInteger offset = (pass == 0 || fragCount == 0)
            ? 0 : ((pass * 17 + pass * pass * 11) % fragCount);
        for (NSUInteger i = 0; i < fragCount; i++) {
            NSData *frag = frags[(i + offset) % fragCount];
            NSError *sendErr = nil;
            if (![self.sink sendDatagram:frag error:&sendErr]) {
                self.stats.sinkFailures += 1;
                if (error) {
                    *error = M1PipeErr(M1PipelineErrorSinkFailed,
                                       sendErr.localizedDescription ?: @"datagram 投递失败");
                }
                return NO;
            }
            self.stats.fragmentsSent += 1;
            self.stats.bytesSent += frag.length;
        }
    }

    self.stats.framesSent += 1;
    self.stats.payloadBytesSent += payload.length;
    if (flags & P1FrameFlagKeyframe) self.stats.keyframesSent += 1;
    [self cacheFragments:frags forFrameSeq:seq];
    _seq += 1;
    return YES;
}

#pragma mark - 定向补片

- (void)cacheFragments:(NSArray<NSData *> *)frags forFrameSeq:(uint32_t)seq {
    NSUInteger limit = self.fragmentCacheFrames;
    if (limit == 0) return;
    [self.cacheLock lock];
    NSNumber *key = @(seq);
    if (!self.fragCache[key]) [self.fragCacheOrder addObject:key];
    self.fragCache[key] = frags;
    while (self.fragCacheOrder.count > limit) {
        NSNumber *old = self.fragCacheOrder.firstObject;
        [self.fragCacheOrder removeObjectAtIndex:0];
        [self.fragCache removeObjectForKey:old];
    }
    [self.cacheLock unlock];
}

- (NSUInteger)resendFragmentsForFrameSeq:(uint32_t)frameSeq
                                 indices:(NSIndexSet *)indices
                                   error:(NSError **)error {
    if (error) *error = nil;
    if (indices.count == 0) return 0;
    if (self.fragmentCacheFrames == 0) return 0;   // 缓存关闭：即便残留旧条目也不重发
    [self.cacheLock lock];
    NSArray<NSData *> *frags = self.fragCache[@(frameSeq)];
    [self.cacheLock unlock];
    if (!frags) return 0;

    NSUInteger sent = 0;
    for (NSUInteger i = indices.firstIndex; i != NSNotFound;
         i = [indices indexGreaterThanIndex:i]) {
        if (i >= frags.count) break;
        NSError *sendErr = nil;
        if (![self.sink sendDatagram:frags[i] error:&sendErr]) {
            self.stats.sinkFailures += 1;
            if (error) {
                *error = M1PipeErr(M1PipelineErrorSinkFailed,
                                   sendErr.localizedDescription ?: @"补片投递失败");
            }
            break;
        }
        sent++;
        self.fragmentsResent++;
        self.stats.fragmentsSent += 1;
        self.stats.bytesSent += frags[i].length;
    }
    return sent;
}

- (NSUInteger)resendAllFragmentsForFrameSeq:(uint32_t)frameSeq error:(NSError **)error {
    if (error) *error = nil;
    if (self.fragmentCacheFrames == 0) return 0;
    [self.cacheLock lock];
    NSArray<NSData *> *frags = self.fragCache[@(frameSeq)];
    [self.cacheLock unlock];
    if (!frags) return 0;

    NSUInteger sent = 0;
    for (NSData *frag in frags) {
        NSError *sendErr = nil;
        if (![self.sink sendDatagram:frag error:&sendErr]) {
            self.stats.sinkFailures += 1;
            if (error) {
                *error = M1PipeErr(M1PipelineErrorSinkFailed,
                                   sendErr.localizedDescription ?: @"补片投递失败");
            }
            break;
        }
        sent++;
        self.fragmentsResent++;
        self.stats.fragmentsSent += 1;
        self.stats.bytesSent += frag.length;
    }
    return sent;
}

@end
