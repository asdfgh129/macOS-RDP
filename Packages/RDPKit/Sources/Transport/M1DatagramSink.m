//
//  M1DatagramSink.m
//  M1-Skeleton
//

#import "M1DatagramSink.h"
#import "M1PipelineTypes.h"

@implementation M1MemoryDatagramSink

- (instancetype)init {
    self = [super init];
    if (self) {
        _datagrams = [NSMutableArray array];
        _failAfterCount = 0;
        _sendCount = 0;
    }
    return self;
}

- (BOOL)sendDatagram:(NSData *)datagram error:(NSError **)error {
    self.sendCount += 1;
    if (self.failAfterCount > 0 && self.sendCount > self.failAfterCount) {
        if (error) {
            *error = [NSError errorWithDomain:M1PipelineErrorDomain
                                         code:M1PipelineErrorSinkFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                                        [NSString stringWithFormat:@"模拟投递失败（第 %lu 次）",
                                         (unsigned long)self.sendCount]}];
        }
        return NO;
    }
    [self.datagrams addObject:[datagram copy]];
    return YES;
}

- (void)reset {
    [self.datagrams removeAllObjects];
    self.sendCount = 0;
}

@end
