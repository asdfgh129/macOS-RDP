//
//  M1ControlChannel.m
//  M1-Skeleton
//

#import "M1ControlChannel.h"
#import "ProtocolCodec.h"

NSString * const M1ControlErrorDomain = @"M1Control";

static NSError *M1CtlErr(M1ControlErrorCode code, NSString *msg) {
    return [NSError errorWithDomain:M1ControlErrorDomain code:code
                            userInfo:@{NSLocalizedDescriptionKey: msg ?: @""}];
}

@interface M1ControlChannel ()
@property (nonatomic, strong) id<M1MessageSink> sink;
@property (nonatomic, strong) P1ControlFrameParser *parser;
@property (nonatomic, readwrite) int64_t nextSeq;
@property (nonatomic, readwrite) NSUInteger sentCount;
@property (nonatomic, readwrite) NSUInteger receivedCount;
@property (nonatomic, readwrite) NSUInteger protocolErrors;
@end

@implementation M1ControlChannel

- (instancetype)initWithSink:(id<M1MessageSink>)sink {
    if ((self = [super init])) {
        _sink = sink;
        _parser = [P1ControlFrameParser new];
        _nextSeq = 1;
    }
    return self;
}

- (NSUInteger)bufferedBytes { return self.parser.bufferedBytes; }

- (void)resetSequence { self.nextSeq = 1; }

#pragma mark - 发送

- (BOOL)sendMessage:(NSDictionary *)message error:(NSError **)error {
    // 心跳线程与收包线程可能同时发（心跳由定时器驱动），seq 分配必须串行化。
    @synchronized (self) {
        int64_t seq = self.nextSeq;
        if (![self sendMessage:message seq:seq error:error]) return NO;
        self.nextSeq = seq + 1;
        return YES;
    }
}

- (BOOL)sendMessage:(NSDictionary *)message seq:(int64_t)seq error:(NSError **)error {
    if (![message isKindOfClass:[NSDictionary class]]) {
        if (error) *error = M1CtlErr(M1ControlErrorEncodeFailed, @"消息不是字典");
        return NO;
    }
    NSMutableDictionary *out = [message mutableCopy];
    out[@"seq"] = @(seq);

    NSError *encErr = nil;
    NSData *frame = P1EncodeControlMessage(out, &encErr);
    if (!frame) {
        if (error) *error = M1CtlErr(M1ControlErrorEncodeFailed,
            encErr.localizedDescription ?: @"编码失败");
        return NO;
    }
    NSError *sinkErr = nil;
    if (![self.sink sendMessage:frame error:&sinkErr]) {
        if (error) *error = M1CtlErr(M1ControlErrorSinkFailed,
            sinkErr.localizedDescription ?: @"传输层拒收");
        return NO;
    }
    self.sentCount += 1;
    return YES;
}

#pragma mark - 接收

- (void)feedBytes:(NSData *)bytes {
    if (bytes.length == 0) return;
    [self.parser appendData:bytes];
    // 一次喂入可能包含 0、1 或多条完整消息，必须循环取到 nil 为止。
    for (;;) {
        NSError *err = nil;
        NSDictionary *msg = [self.parser nextMessageWithError:&err];
        if (!msg) {
            if (err) {
                self.protocolErrors += 1;
                if ([self.delegate respondsToSelector:@selector(controlChannel:didFailWithError:)]) {
                    [self.delegate controlChannel:self
                                didFailWithError:M1CtlErr(M1ControlErrorProtocol,
                                    err.localizedDescription ?: @"控制帧错位")];
                }
            }
            return;   // 无错误 = 数据还不够，等下一块
        }
        self.receivedCount += 1;
        if ([self.delegate respondsToSelector:@selector(controlChannel:didReceiveMessage:)]) {
            [self.delegate controlChannel:self didReceiveMessage:msg];
        }
    }
}

@end
