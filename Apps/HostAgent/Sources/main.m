//
//  main.m
//  veild-host-agent
//
//  产品入口（第 3 轮）：短生命周期 CLI，直接消费 RDPKit / ProtocolCodec 静态库。
//  默认 selftest 只跑纯逻辑（配对、会话状态机、输入映射、编码参数），不触碰 WindowServer；
//  --capture <displayID> <seconds> 才显式启动真实采集 + H.264 编码 + 分片投递，需屏幕录制 TCC。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "M1Pairing.h"
#import "M1SessionCoordinator.h"
#import "M1FramePipeline.h"
#import "M1VideoEncoder.h"
#import "M1DatagramSink.h"
#import "M1InputLogic.h"

#pragma mark - 测试替身（不碰 WindowServer）

@interface AgentNoopDriver : NSObject <M1SessionDriver>
@property (nonatomic, strong) NSArray<NSNumber *> *created;
@end

@implementation AgentNoopDriver

- (BOOL)acquireSleepAssertionError:(NSError * _Nullable * _Nullable)error { return YES; }
- (void)releaseSleepAssertion {}
- (BOOL)createVirtualDisplays:(NSArray<NSDictionary *> *)specs
                        error:(NSError * _Nullable * _Nullable)error {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSUInteger i = 0; i < specs.count; i++) { [ids addObject:@(1000 + (uint32_t)i)]; }
    self.created = ids;
    return YES;
}
- (NSArray<NSNumber *> *)createdDisplayIDs { return self.created ?: @[]; }
- (BOOL)snapshotAndDisablePhysicalExcept:(NSArray<NSNumber *> *)keepIDs
                                   error:(NSError * _Nullable * _Nullable)error { return YES; }
- (BOOL)verifyIsolationError:(NSError * _Nullable * _Nullable)error { return YES; }
- (BOOL)injectUnlockCredential:(NSString *)credential
                         error:(NSError * _Nullable * _Nullable)error { return YES; }
- (BOOL)restorePhysicalAndDestroyDisplaysError:(NSError * _Nullable * _Nullable)error { return YES; }
- (BOOL)lockScreenError:(NSError * _Nullable * _Nullable)error { return YES; }

@end

@interface AgentCountingSink : NSObject <M1DatagramSink>
@property (nonatomic, assign) NSUInteger count;
@end

@implementation AgentCountingSink

- (BOOL)sendDatagram:(NSData *)datagram error:(NSError * _Nullable * _Nullable)error {
    self.count += 1;
    return YES;
}

@end

#pragma mark - 子命令

static void AgentRunPairing(void) {
    M1PairingState *state = [[M1PairingState alloc] initWithStore:[[M1InMemoryPairingStore alloc] init]];
    NSString *code = [state issueCodeAtTime:NSDate.date.timeIntervalSince1970];
    printf("pairing: code=%s valid=%d paired=%d\n",
           code.UTF8String, M1IsValidPairingCode(code), state.isPaired);
}

static BOOL AgentRunSessionDryRun(void) {
    AgentNoopDriver *driver = [AgentNoopDriver new];
    M1SessionCoordinator *coord = [[M1SessionCoordinator alloc] initWithDriver:driver];
    coord.locksScreenOnEnd = NO;
    NSError *error = nil;
    NSArray *specs = @[@{@"width": @1280, @"height": @720, @"displayID": @1000}];
    BOOL started = [coord startWithSpecs:specs needsLogin:NO credential:nil error:&error];
    printf("session: start=%d phase=%s displays=%s\n",
           started, M1HostSessionPhaseName(coord.phase).UTF8String,
           coord.createdDisplayIDs.description.UTF8String);
    if (!started) { printf("session error: %s\n", error.localizedDescription.UTF8String); return NO; }
    BOOL ended = [coord endSessionError:&error];
    printf("session: end=%d phase=%s\n", ended, M1HostSessionPhaseName(coord.phase).UTF8String);
    return ended;
}

static void AgentRunInputAndCodec(void) {
    CGRect bounds = CGRectMake(0, 0, 1280, 720);
    CGRect fitted = M1AspectFitRect(CGSizeMake(1920, 1080), bounds);
    CGPoint p = M1NormalizedPointFromViewPoint(CGPointMake(CGRectGetMidX(fitted), CGRectGetMinY(fitted)),
                                               fitted);
    M1EncoderConfig *enc = [M1EncoderConfig configWithWidth:1280 height:720];
    printf("input: fitted=(%.0f,%.0f,%.0f,%.0f) normalized=(%.3f,%.3f)\n",
           fitted.origin.x, fitted.origin.y, fitted.size.width, fitted.size.height, p.x, p.y);
    printf("codec: h264 targetBitrate=%d bps\n", enc.effectiveBitrate);
}

static BOOL AgentRunCapture(uint32_t displayID, NSTimeInterval seconds) {
    M1FramePipelineConfig *cfg = [M1FramePipelineConfig new];
    cfg.targetFps = 20;
    cfg.outputWidth = 1280;
    cfg.outputHeight = 720;
    AgentCountingSink *sink = [AgentCountingSink new];
    NSError *error = nil;
    M1FramePipeline *pipe = [[M1FramePipeline alloc] initWithDisplayID:(CGDirectDisplayID)displayID
                                                                config:cfg
                                                                  sink:sink
                                                               onError:^(NSError *e) {
        fprintf(stderr, "capture error: %s\n", e.localizedDescription.UTF8String);
    }];
    if (![pipe start:&error]) {
        printf("capture: start failed: %s\n", error.localizedDescription.UTF8String);
        return NO;
    }
    [NSThread sleepForTimeInterval:seconds];
    [pipe stop];
    printf("capture: %s\n", pipe.stats.summary.UTF8String);
    printf("capture: sink=%lu datagrams\n", (unsigned long)sink.count);
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL capture = argc >= 4 && strcmp(argv[1], "--capture") == 0;
        if (capture) {
            return AgentRunCapture((uint32_t)strtoul(argv[2], NULL, 10), atof(argv[3])) ? 0 : 1;
        }
        AgentRunPairing();
        if (!AgentRunSessionDryRun()) { return 1; }
        AgentRunInputAndCodec();
        printf("veild-host-agent selftest PASS\n");
    }
    return 0;
}
