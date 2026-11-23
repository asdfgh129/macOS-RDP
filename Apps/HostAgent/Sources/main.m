//
//  main.m
//  veild-host-agent
//
//  产品入口（第 4 轮）：短生命周期 CLI，直接消费 RDPKit / ProtocolCodec 静态库。
//    · 默认 selftest：纯逻辑（配对、会话状态机、输入映射、编码参数），不碰 WindowServer
//    · --capture <displayID> <seconds>：单机采集 + H.264 编码 + 计数 sink
//    · --serve [--port N] ...      ：真实 QUIC 监听 + 会话协商 + 采集推流 + 输入回传，
//                                   可与 VeilRD client 直接对连，不必经过 stream_probe
//
//  与 stream_probe 共用 M1StreamSession 节点层（第 4 轮抽出），协议行为一致：
//  控制帧与帧分片共用一条 datagram，控制包优先，A-02 时钟探针由客户端发出。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "M1Pairing.h"
#import "M1SessionCoordinator.h"
#import "M1FramePipeline.h"
#import "M1VideoEncoder.h"
#import "M1DatagramSink.h"
#import "M1InputLogic.h"
#import "M1InputInjector.h"
#import "M1RDPDriver.h"
#import "M1QuicTransport.h"
#import "M1StreamSession.h"

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

#pragma mark - --serve：真实会话入口

static void AgentServeUsage(void) {
    fprintf(stderr,
        "用法: veild-host-agent --serve [--port N] [--port-file PATH]\n"
        "       [--spec WxH] [--fps N] [--duration-ms N] [--wait-ms N]\n"
        "       [--display ID] [--mirror] [--keep-main] [--inject record|real]\n"
        "       [--identity PATH] [--pass PASS] [--out JSON]\n"
        "  默认独占会话（按客户端规格建虚拟屏并禁物理屏）；--mirror 采物理主屏仅作诊断。\n"
        "  --inject 默认 record；双机真机验收改 real（需辅助功能授权）。\n");
}

static BOOL AgentParseSpec(NSString *spec, int32_t *w, int32_t *h) {
    int sw = 0, sh = 0;
    if (sscanf(spec.UTF8String, "%dx%d", &sw, &sh) != 2 || sw <= 0 || sh <= 0) return NO;
    *w = sw; *h = sh;
    return YES;
}

static BOOL AgentRunServe(int argc, const char *argv[]) {
    uint16_t port = 0;
    NSString *portFile = nil, *outPath = nil, *specText = nil;
    NSString *identity = @".state/rdp-identity.p12", *pass = @"rdpdev", *inject = @"record";
    uint32_t waitMs = 15000;
    int durationMs = 5000, fps = 20;
    int32_t outW = 0, outH = 0, specW = 0, specH = 0;
    CGDirectDisplayID displayID = CGMainDisplayID();
    BOOL exclusive = YES, keepMain = NO;

    for (int i = 2; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--port") && i + 1 < argc) port = (uint16_t)atoi(argv[++i]);
        else if (!strcmp(a, "--port-file") && i + 1 < argc) portFile = [NSString stringWithUTF8String:argv[++i]];
        else if (!strcmp(a, "--out") && i + 1 < argc) outPath = [NSString stringWithUTF8String:argv[++i]];
        else if (!strcmp(a, "--duration-ms") && i + 1 < argc) durationMs = atoi(argv[++i]);
        else if (!strcmp(a, "--wait-ms") && i + 1 < argc) waitMs = (uint32_t)atoi(argv[++i]);
        else if (!strcmp(a, "--fps") && i + 1 < argc) fps = atoi(argv[++i]);
        else if (!strcmp(a, "--display") && i + 1 < argc) displayID = (CGDirectDisplayID)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(a, "--width") && i + 1 < argc) outW = atoi(argv[++i]);
        else if (!strcmp(a, "--height") && i + 1 < argc) outH = atoi(argv[++i]);
        else if (!strcmp(a, "--spec") && i + 1 < argc) specText = [NSString stringWithUTF8String:argv[++i]];
        else if (!strcmp(a, "--identity") && i + 1 < argc) identity = [NSString stringWithUTF8String:argv[++i]];
        else if (!strcmp(a, "--pass") && i + 1 < argc) pass = [NSString stringWithUTF8String:argv[++i]];
        else if (!strcmp(a, "--inject") && i + 1 < argc) inject = [NSString stringWithUTF8String:argv[++i]];
        else if (!strcmp(a, "--mirror")) exclusive = NO;
        else if (!strcmp(a, "--keep-main")) keepMain = YES;
        else { AgentServeUsage(); return NO; }
    }
    if (specText && !AgentParseSpec(specText, &specW, &specH)) { AgentServeUsage(); return NO; }
    if (fps <= 0 || durationMs <= 0) { AgentServeUsage(); return NO; }

    NSError *err = nil;
    NSString *localFp = M1QuicIdentityFingerprint(identity, pass, &err);
    if (localFp.length == 0) {
        printf("✗ 读不到 QUIC 身份指纹 %s: %s\n", identity.UTF8String,
               err.localizedDescription.UTF8String ?: "unknown");
        return NO;
    }

    M1StreamNode *host = [M1StreamNode new];
    host.identityPath = identity;
    host.identityPass = pass;
    host.localFingerprint = localFp;
    host.fps = fps;

    // 独占会话：session-start 到达时按客户端规格建虚拟屏 / 禁物理屏。
    __block M1RDPDriver *driver = nil;
    __block M1SessionCoordinator *coord = nil;
    __block BOOL exclusiveEnded = NO;
    __block CGDirectDisplayID virtualID = 0;
    __block NSUInteger virtualW = 0, virtualH = 0;
    __block NSString *c09 = @"not-started";
    void (^endExclusive)(void) = ^{
        if (exclusiveEnded || !coord) return;
        exclusiveEnded = YES;
        M1SessionCoordinator *c = coord;
        coord = nil;
        NSError *e = nil;
        if (![c endSessionError:&e])
            printf("  [独占] 恢复失败: %s\n", e.localizedDescription.UTF8String ?: "unknown");
        else
            printf("  [独占] 已恢复物理屏并销毁虚拟屏\n");
        driver = nil;
    };
    if (exclusive) {
        host.displayProvider = ^NSArray<NSDictionary *> *(NSDictionary *message, NSError **perr) {
            NSArray *specs = message[@"specs"];
            if (![specs isKindOfClass:[NSArray class]] || specs.count == 0) {
                if (perr) *perr = [NSError errorWithDomain:@"veild.agent" code:6
                    userInfo:@{NSLocalizedDescriptionKey: @"session-start 缺 specs"}];
                return nil;
            }
            NSMutableArray *conv = [NSMutableArray array];
            for (NSDictionary *sp in specs) {
                NSNumber *w = sp[@"w"], *h = sp[@"h"];
                if ([w isKindOfClass:[NSNumber class]] && [h isKindOfClass:[NSNumber class]])
                    [conv addObject:@{@"width": w, @"height": h}];
            }
            if (conv.count == 0) {
                if (perr) *perr = [NSError errorWithDomain:@"veild.agent" code:6
                    userInfo:@{NSLocalizedDescriptionKey: @"session-start 缺可用宽高"}];
                return nil;
            }
            driver = [M1RDPDriver new];
            M1SessionCoordinator *c = [[M1SessionCoordinator alloc] initWithDriver:driver];
            c.locksScreenOnEnd = NO;
            if (keepMain) c.extraKeepDisplayIDs = @[@(CGMainDisplayID())];
            NSError *se = nil;
            if (![c startWithSpecs:conv needsLogin:NO credential:nil error:&se]) {
                driver = nil;
                if (perr) *perr = se;
                return nil;
            }
            NSArray<NSNumber *> *ids = c.createdDisplayIDs;
            if (ids.count == 0) {
                NSError *ee = nil; [c endSessionError:&ee];
                driver = nil;
                if (perr) *perr = [NSError errorWithDomain:@"veild.agent" code:6
                    userInfo:@{NSLocalizedDescriptionKey: @"建屏成功但没有 displayID"}];
                return nil;
            }
            coord = c;
            exclusiveEnded = NO;
            virtualID = ids.firstObject.unsignedIntValue;
            virtualW = [conv.firstObject[@"width"] unsignedIntegerValue];
            virtualH = [conv.firstObject[@"height"] unsignedIntegerValue];
            c09 = keepMain ? @"skipped-keep-main" : @"verified";
            NSMutableArray *displays = [NSMutableArray array];
            for (NSUInteger i = 0; i < ids.count; i++)
                [displays addObject:@{@"displayID": ids[i],
                                      @"w": i < conv.count ? conv[i][@"width"] : @0,
                                      @"h": i < conv.count ? conv[i][@"height"] : @0,
                                      @"synthetic": @NO}];
            printf("  [独占] 虚拟屏 %s（%lux%lu）C-09=%s\n",
                   ids.description.UTF8String, (unsigned long)virtualW, (unsigned long)virtualH, c09.UTF8String);
            return displays;
        };
        host.onAttemptFailed = ^{
            endExclusive();
            virtualID = 0; virtualW = 0; virtualH = 0;
        };
    }

    if (![host startAsHostOnPort:port error:&err]) {
        printf("✗ listener 启动失败: %s\n", err.localizedDescription.UTF8String);
        return NO;
    }
    printf("veild-host-agent 监听 %u  指纹 %s\n", host.port, localFp.UTF8String);
    printf("===== 给客户端的三项 =====\n  IP   : <本机地址>\n  端口 : %u\n  指纹 : %s\n=======================\n",
           host.port, localFp.UTF8String);
    if (portFile.length > 0) {
        NSString *payload = [NSString stringWithFormat:@"%u\n%@\n", host.port, localFp];
        [payload writeToFile:portFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    if (![host waitForStreamingTimeoutMs:waitMs]) {
        printf("✗ %us 内未进入 STREAMING: %s\n", waitMs / 1000,
               host.error.localizedDescription.UTF8String ?: "无客户端");
        endExclusive(); [host shutdown];
        return NO;
    }

    CGDirectDisplayID captureID = virtualID ?: displayID;
    M1FramePipelineConfig *cfg = [M1FramePipelineConfig new];
    cfg.targetFps = fps;
    cfg.outputWidth = outW;
    cfg.outputHeight = outH;
    __block int errCount = 0;
    M1FramePipeline *pipe = [[M1FramePipeline alloc] initWithDisplayID:captureID config:cfg
        sink:host onError:^(NSError *e) {
            errCount += 1;
            if (errCount <= 3) fprintf(stderr, "  [管线错误] %s\n", e.localizedDescription.UTF8String);
        }];
    if (![pipe start:&err]) {
        printf("✗ 管线启动失败: %s\n", err.localizedDescription.UTF8String);
        endExclusive(); [host shutdown];
        return NO;
    }
    printf("推流开始：displayID=%u  %lux%u  %dms @ %dfps\n",
           captureID, pipe.pixelWidth, pipe.pixelHeight, durationMs, fps);

    __block CFAbsoluteTime lastKeyframe = 0;
    host.onKeyframeRequest = ^{
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastKeyframe < 0.9) return;
        lastKeyframe = now;
        [pipe requestKeyframe];
    };
    host.onFrameNack = ^(uint32_t frameSeq, uint16_t fragCount, NSIndexSet *indices) {
        (void)fragCount;
        NSError *re = nil;
        NSUInteger n = indices.count == 0
            ? [pipe.sender resendAllFragmentsForFrameSeq:frameSeq error:&re]
            : [pipe.sender resendFragmentsForFrameSeq:frameSeq indices:indices error:&re];
        if (n == 0 && re) fprintf(stderr, "  [补片] %s\n", re.localizedDescription.UTF8String);
    };

    // 输入回传：record 不真注入（单机环回安全）；real 才 CGEventPost。
    id<M1EventSink> sink = nil;
    M1RecordingEventSink *recorder = nil;
    if ([inject isEqualToString:@"real"]) sink = [M1CGEventSink new];
    else { recorder = [M1RecordingEventSink new]; sink = recorder; }
    M1InputInjector *injector = [[M1InputInjector alloc] initWithSink:sink];
    injector.targetDisplayRect = CGRectMake(0, 0,
        virtualW ?: (specW ?: 1920), virtualH ?: (specH ?: 1080));
    __block NSUInteger injectOK = 0, injectFail = 0;
    host.onInputEvent = ^(NSDictionary *event) {
        NSError *ie = nil;
        if ([injector injectEvent:event error:&ie]) injectOK += 1;
        else injectFail += 1;
    };

    [NSThread sleepForTimeInterval:durationMs / 1000.0];
    [host flushSimulatedHeld];
    [pipe stop];
    [host shutdown];
    endExclusive();

    M1FramePipelineStats *ps = pipe.stats;
    printf("serve: frames captured=%llu encoded=%llu sent=%llu dropped=%llu fragments=%llu\n",
           ps.framesCaptured, ps.framesEncoded, ps.framesSent, ps.framesDroppedBeforeEncoder,
           ps.fragmentsSent);
    printf("serve: input ok=%lu fail=%lu record=%lu | 控制到达最大间隔=%.1fms\n",
           (unsigned long)injectOK, (unsigned long)injectFail,
           (unsigned long)recorder.postCount, host.maxControlGapMs);
    if (outPath.length > 0) {
        NSDictionary *json = @{
            @"framesCaptured": @(ps.framesCaptured), @"framesEncoded": @(ps.framesEncoded),
            @"framesSent": @(ps.framesSent), @"fragmentsSent": @(ps.fragmentsSent),
            @"inputOK": @(injectOK), @"inputFail": @(injectFail),
            @"maxControlGapMs": @(host.maxControlGapMs), @"c09": c09,
            @"stateLog": host.stateLog ?: @[],
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:json
                                                       options:NSJSONWritingPrettyPrinted error:NULL];
        [data writeToFile:outPath atomically:YES];
    }
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 2 && strcmp(argv[1], "--serve") == 0) {
            return AgentRunServe(argc, argv) ? 0 : 1;
        }
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
