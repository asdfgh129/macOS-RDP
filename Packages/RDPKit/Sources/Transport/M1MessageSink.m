//
//  M1MessageSink.m
//  M1-Skeleton
//

#import "M1MessageSink.h"

@implementation M1MemoryMessageSink

- (instancetype)init {
    if ((self = [super init])) {
        _messages = [NSMutableArray array];
    }
    return self;
}

- (BOOL)sendMessage:(NSData *)message error:(NSError **)error {
    if (self.onSend) {
        if (!self.onSend(message, error)) return NO;
    }
    if (message.length > 0) [self.messages addObject:[message copy]];
    return YES;
}

- (NSData *)concatenated {
    NSMutableData *all = [NSMutableData data];
    for (NSData *d in self.messages) [all appendData:d];
    return all;
}

- (void)reset {
    [self.messages removeAllObjects];
}

@end
