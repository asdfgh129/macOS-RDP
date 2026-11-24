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
#import "P0VDisplayControl.h"

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
    __block NSArray<NSDictionary *> *virtualDisplays = @[];
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
            virtualDisplays = displays;
            printf("  [独占] 虚拟屏 %s（首屏 %lux%lu）C-09=%s\n",
                   ids.description.UTF8String, (unsigned long)virtualW, (unsigned long)virtualH, c09.UTF8String);
            return displays;
        };
        host.onAttemptFailed = ^{
            endExclusive();
            virtualID = 0; virtualDisplays = @[]; virtualW = 0; virtualH = 0;
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

    // 要推流的屏：独占会话按新建虚拟屏全量（FR-01 N 屏）；镜像诊断只推 --display 一块。
    NSArray<NSDictionary *> *streamDisplays = nil;
    if (exclusive && virtualDisplays.count > 0) {
        streamDisplays = virtualDisplays;
    } else {
        streamDisplays = @[ @{ @"displayID": @(displayID) } ];
    }

    __block int errCount = 0;
    NSMutableArray<M1FramePipeline *> *pipes = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, M1FramePipeline *> *pipeByDisplay = [NSMutableDictionary dictionary];
    for (NSDictionary *disp in streamDisplays) {
        NSNumber *didNum = disp[@"displayID"];
        if (![didNum isKindOfClass:[NSNumber class]]) continue;
        uint32_t did = didNum.unsignedIntValue;
        if (did == 0 || pipeByDisplay[didNum]) continue;
        M1FramePipelineConfig *cfg = [M1FramePipelineConfig new];
        cfg.targetFps = fps;
        cfg.outputWidth = outW;
        cfg.outputHeight = outH;
        M1FramePipeline *pipe = [[M1FramePipeline alloc] initWithDisplayID:(CGDirectDisplayID)did
                                                                    config:cfg sink:host
                                                                   onError:^(NSError *e) {
            errCount += 1;
            if (errCount <= 3) fprintf(stderr, "  [管线错误] %s\n", e.localizedDescription.UTF8String);
        }];
        if (![pipe start:&err]) {
            printf("✗ 管线启动失败 displayID=%u: %s\n", did, err.localizedDescription.UTF8String);
            for (M1FramePipeline *p in pipes) [p stop];
            endExclusive(); [host shutdown];
            return NO;
        }
        [pipes addObject:pipe];
        pipeByDisplay[didNum] = pipe;
        printf("推流开始：displayID=%u  %dx%d  %dms @ %dfps\n",
               did, pipe.pixelWidth, pipe.pixelHeight, durationMs, fps);
    }
    if (pipes.count == 0) {
        printf("✗ 没有可推流的显示\n");
        endExclusive(); [host shutdown];
        return NO;
    }

    // 请求按屏路由；displayID=0 是旧版客户端（单屏/全部屏）。
    // 900ms 合并窗口也按屏独立：一块屏的在途 IDR 不应吞掉另一块屏的请求。
    NSMutableDictionary<NSNumber *, NSNumber *> *lastKeyframeByDisplay = [NSMutableDictionary dictionary];
    host.onKeyframeRequest = ^(uint32_t displayID) {
        NSArray<M1FramePipeline *> *targets = pipes;
        if (displayID != 0) {
            M1FramePipeline *target = pipeByDisplay[@(displayID)];
            if (!target) return;
            targets = @[ target ];
        }
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        NSNumber *key = @(displayID);
        @synchronized (lastKeyframeByDisplay) {
            NSNumber *last = lastKeyframeByDisplay[key];
            if (last && now - last.doubleValue < 0.9) return;
            lastKeyframeByDisplay[key] = @(now);
        }
        for (M1FramePipeline *p in targets) [p requestKeyframe];
    };
    host.onFrameNack = ^(uint32_t displayID, uint32_t frameSeq,
                         uint16_t fragCount, NSIndexSet *indices) {
        (void)fragCount;
        NSArray<M1FramePipeline *> *targets = pipes;
        if (displayID != 0) {
            M1FramePipeline *target = pipeByDisplay[@(displayID)];
            if (!target) return;
            targets = @[ target ];
        }
        for (M1FramePipeline *p in targets) {
            NSError *re = nil;
            NSUInteger n = indices.count == 0
                ? [p.sender resendAllFragmentsForFrameSeq:frameSeq error:&re]
                : [p.sender resendFragmentsForFrameSeq:frameSeq indices:indices error:&re];
            if (n == 0 && re) fprintf(stderr, "  [补片] displayID=%u: %s\n",
                                      displayID, re.localizedDescription.UTF8String);
        }
    };

    // 输入回传：record 不真注入（单机环回安全）；real 才 CGEventPost。
    // 每块屏的 Quartz bounds 作为该 displayID 的坐标基准。
    id<M1EventSink> sink = nil;
    M1RecordingEventSink *recorder = nil;
    if ([inject isEqualToString:@"real"]) sink = [M1CGEventSink new];
    else { recorder = [M1RecordingEventSink new]; sink = recorder; }
    M1InputInjector *injector = [[M1InputInjector alloc] initWithSink:sink];
    NSMutableDictionary<NSNumber *, NSValue *> *rects = [NSMutableDictionary dictionary];
    for (NSDictionary *disp in streamDisplays) {
        NSNumber *didNum = disp[@"displayID"];
        if (![didNum isKindOfClass:[NSNumber class]]) continue;
        CGRect r = CGDisplayBounds((CGDirectDisplayID)didNum.unsignedIntValue);
        if (!CGRectIsEmpty(r)) rects[didNum] = [NSValue valueWithRect:(NSRect)r];
    }
    if (rects.count == 0) {
        CGRect fallback = CGRectMake(0, 0, virtualW ?: (specW ?: 1920), virtualH ?: (specH ?: 1080));
        injector.targetDisplayRect = fallback;
    } else {
        injector.targetDisplayRect = [rects.allValues.firstObject rectValue];
    }
    injector.displayRects = rects;
    printf("输入目标屏 %lu 块%s\n", (unsigned long)rects.count,
           rects.count ? "" : "（无 Quartz bounds，回退到原点 rect）");
    __block NSUInteger injectOK = 0, injectFail = 0;
    host.onInputEvent = ^(NSDictionary *event) {
        NSError *ie = nil;
        if ([injector injectEvent:event error:&ie]) injectOK += 1;
        else injectFail += 1;
    };

    [NSThread sleepForTimeInterval:durationMs / 1000.0];
    [host flushSimulatedHeld];
    for (M1FramePipeline *p in pipes) [p stop];
    [host shutdown];
    endExclusive();

    uint64_t cap = 0, enc = 0, sent = 0, dropped = 0, fragments = 0;
    NSMutableArray<NSDictionary *> *displayJSON = [NSMutableArray array];
    for (M1FramePipeline *p in pipes) {
        M1FramePipelineStats *s = p.stats;
        cap += s.framesCaptured;
        enc += s.framesEncoded;
        sent += s.framesSent;
        dropped += s.framesDroppedBeforeEncoder;
        fragments += s.fragmentsSent;
        [displayJSON addObject:@{
            @"displayID": @(p.displayID), @"w": @(p.pixelWidth), @"h": @(p.pixelHeight),
            @"framesCaptured": @(s.framesCaptured), @"framesEncoded": @(s.framesEncoded),
            @"framesSent": @(s.framesSent), @"fragmentsSent": @(s.fragmentsSent),
            @"keyframes": @(s.keyframes),
        }];
        printf("serve[%u]: captured=%llu encoded=%llu sent=%llu dropped=%llu key=%llu\n",
               p.displayID, s.framesCaptured, s.framesEncoded, s.framesSent,
               s.framesDroppedBeforeEncoder, s.keyframes);
    }
    printf("serve: 合计 frames captured=%llu encoded=%llu sent=%llu dropped=%llu fragments=%llu（%lu 屏）\n",
           cap, enc, sent, dropped, fragments, (unsigned long)pipes.count);
    printf("serve: input ok=%lu fail=%lu record=%lu | 控制到达最大间隔=%.1fms (offset %.1fms)\n",
           (unsigned long)injectOK, (unsigned long)injectFail,
           (unsigned long)recorder.postCount, host.maxControlGapMs, host.maxGapAtOffsetMs);
    if (outPath.length > 0) {
        NSDictionary *json = @{
            @"framesCaptured": @(cap), @"framesEncoded": @(enc),
            @"framesSent": @(sent), @"fragmentsSent": @(fragments),
            @"framesDroppedBeforeEncoder": @(dropped),
            @"inputOK": @(injectOK), @"inputFail": @(injectFail),
            @"maxControlGapMs": @(host.maxControlGapMs),
            @"maxGapAtOffsetMs": @(host.maxGapAtOffsetMs),
            @"c09": c09,
            @"displays": displayJSON,
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
        // ★ 守护模式必须最先处理：P0VStartGuardian 用同一个二进制 re-exec。
        //   缺这一段时父进程会等不到 <snapshot>.guardian-ready，禁屏被拒绝。
        if (argc > 1 && strcmp(argv[1], "--guardian") == 0) {
            NSString *snap = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : nil;
            pid_t parent = 0;
            for (int i = 3; i + 1 < argc; i++) {
                if (strcmp(argv[i], "--parent-pid") == 0) parent = atoi(argv[i + 1]);
            }
            if (!snap || parent <= 0) return 3;
            return P0VRunGuardian(snap, parent);
        }

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
