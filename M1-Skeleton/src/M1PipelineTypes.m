//
//  M1PipelineTypes.m
//  M1-Skeleton
//

#import "M1PipelineTypes.h"

NSString * const M1PipelineErrorDomain = @"M1Pipeline";

@implementation M1EncodedFrame

- (NSString *)description {
    return [NSString stringWithFormat:
            @"<M1EncodedFrame %luB key=%d ps=%d enc=%.1fms>",
            (unsigned long)self.avccPayload.length,
            self.isKeyframe, self.carriesParamSets, self.encodeLatencyMs];
}

@end
