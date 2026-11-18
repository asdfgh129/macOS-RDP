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
    }
    return self;
}

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
    for (NSData *frag in frags) {
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

    self.stats.framesSent += 1;
    self.stats.payloadBytesSent += payload.length;
    if (flags & P1FrameFlagKeyframe) self.stats.keyframesSent += 1;
    _seq += 1;
    return YES;
}

@end
