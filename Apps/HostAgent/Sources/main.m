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
- (BOOL)replaceVirtualDisplays:(NSArray<NSDictionary *> *)specs
                         error:(NSError * _Nullable * _Nullable)error {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSUInteger i = 0; i < specs.count; i++) { [ids addObject:@(2000 + (uint32_t)i)]; }
    self.created = ids;
    return YES;
}
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
        "       [--max-sessions N] [--display ID] [--mirror] [--keep-main]\n"
        "       [--inject record|real] [--identity PATH] [--pass PASS] [--out JSON]\n"
        "       [--allow-fingerprint HEX]\n"
        "  默认独占会话（按客户端规格建虚拟屏并禁物理屏）；--mirror 采物理主屏仅作诊断。\n"
        "  --inject 默认 record；双机真机验收改 real（需辅助功能授权）。\n"
        "  --allow-fingerprint 钉死允许接入的客户端证书指纹（NFR-07；不给则任何客户端可接入）。\n"
        "  --max-sessions 默认 1（一个客户端一个 agent）；N>1 时每个会话结束即清理并等下一个，0=不限。\n");
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
    NSString *identity = @".state/rdp-identity.p12", *pass = nil, *inject = @"record";
    NSString *allowFp = nil;
    uint32_t waitMs = 15000;
    int durationMs = 5000, fps = 20;
    NSUInteger maxSessions = 1;
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
        else if (!strcmp(a, "--max-sessions") && i + 1 < argc) maxSessions = (NSUInteger)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(a, "--display") && i + 1 < argc) displayID = (CGDirectDisplayID)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(a, "--width") && i + 1 < argc) outW = atoi(argv[++i]);
        else if (!strcmp(a, "--height") && i + 1 < argc) outH = atoi(argv[++i]);
        else if (!strcmp(a, "--spec") && i + 1 < argc) specText = [NSString stringWithUTF8String:argv[++i]];
        else if (!strcmp(a, "--identity") && i + 1 < argc) identity = [NSString stringWithUTF8String:argv[++i]];
        else if (!strcmp(a, "--pass") && i + 1 < argc) pass = [NSString stringWithUTF8String:argv[++i]];
        else if (!strcmp(a, "--inject") && i + 1 < argc) inject = [NSString stringWithUTF8String:argv[++i]];
        else if (!strcmp(a, "--mirror")) exclusive = NO;
        else if (!strcmp(a, "--keep-main")) keepMain = YES;
        else if (!strcmp(a, "--allow-fingerprint") && i + 1 < argc) allowFp = [NSString stringWithUTF8String:argv[++i]];
        else { AgentServeUsage(); return NO; }
    }
    if (specText && !AgentParseSpec(specText, &specW, &specH)) { AgentServeUsage(); return NO; }
    if (fps <= 0 || durationMs <= 0) { AgentServeUsage(); return NO; }

    // NFR-07 E2：口令优先取环境变量/钥匙串，不默认写在命令行里。
    BOOL usedDevPass = NO;
    pass = M1ResolveIdentityPassphrase(pass, &usedDevPass);
    if (usedDevPass) {
        fprintf(stderr, "⚠ 身份口令使用开发默认值 rdpdev（NFR-07 E2）：生产部署请设置 "
                        "VEILRD_IDENTITY_PASS 或写入钥匙串 `veild-identity`\n");
    }

    NSError *err = nil;
    NSString *localFp = M1QuicIdentityFingerprint(identity, pass, &err);
    if (localFp.length == 0) {
        printf("✗ 读不到 QUIC 身份指纹 %s: %s\n", identity.UTF8String,
               err.localizedDescription.UTF8String ?: "unknown");
        return NO;
    }

    // NFR-07：无人值守主机必须钉死允许接入的客户端指纹，否则输入注入对任何
    // 能完成 TLS 握手的对端开放。--allow-fingerprint 缺省 nil（联调/P0 兼容）。
    NSString *pinnedFp = nil;
    if (allowFp.length > 0) {
        pinnedFp = M1NormalizeFingerprint(allowFp);
        if (pinnedFp.length == 0) {
            printf("✗ --allow-fingerprint 不是合法 SHA-256 指纹: %s\n", allowFp.UTF8String);
            return NO;
        }
    } else {
        printf("⚠ 未钉死客户端指纹（--allow-fingerprint）：任何客户端都可接入并注入输入\n");
    }

    M1StreamNode *host = [M1StreamNode new];
    host.identityPath = identity;
    host.identityPass = pass;
    host.localFingerprint = localFp;
    host.expectedFingerprint = pinnedFp;
    host.fps = fps;

    // 显示事务串行队列：建屏/还屏都是秒级 WindowServer 事务，跨轮必须互斥。
    // 上一轮收尾还屏期间，下一位客户端的 session-start 要在这里排队等它做完，
    // 否则两轮显示事务并发会互踩（实测：session 2 建出的屏被上一轮销毁）。
    dispatch_queue_t displayTxQueue = dispatch_queue_create("veild.display-tx",
                                                            DISPATCH_QUEUE_SERIAL);

    // 独占会话：session-start 到达时按客户端规格建虚拟屏 / 禁物理屏。
    __block M1RDPDriver *driver = nil;
    __block M1SessionCoordinator *coord = nil;
    __block BOOL exclusiveEnded = NO;
    __block CGDirectDisplayID virtualID = 0;
    __block NSArray<NSDictionary *> *virtualDisplays = @[];
    __block NSArray<NSDictionary *> *virtualConv = @[];
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
        // 由 displayID 列表拼 displayProvider 返回值。
        NSArray<NSDictionary *> *(^displayList)(NSArray<NSNumber *> *, NSArray *) =
            ^NSArray<NSDictionary *> *(NSArray<NSNumber *> *ids, NSArray *conv) {
            NSMutableArray *displays = [NSMutableArray array];
            for (NSUInteger i = 0; i < ids.count; i++)
                [displays addObject:@{@"displayID": ids[i],
                                      @"w": i < conv.count ? conv[i][@"width"] : @0,
                                      @"h": i < conv.count ? conv[i][@"height"] : @0,
                                      @"synthetic": @NO}];
            return displays;
        };
        NSArray<NSDictionary *> *(^buildDisplays)(NSDictionary *, NSError **) =
            ^NSArray<NSDictionary *> *(NSDictionary *message, NSError **perr) {
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
            // 会话之间不还屏：同进程销毁后再 initWithDescriptor 会让新屏永远
            // online=0（Tahoe 实测两次），只有「先建新再拆旧」的换屏路径安全。
            // 规格相同直接沿用；不同就走会话内换屏。
            if (coord) {
                if ([conv isEqualToArray:virtualConv]) {
                    printf("  [独占] 沿用虚拟屏 %s（规格未变）\n", virtualDisplays.description.UTF8String);
                    return virtualDisplays;
                }
                NSError *ae = nil;
                if (![coord applySpecs:conv error:&ae]) {
                    if (perr) *perr = ae;
                    return nil;
                }
                NSArray<NSNumber *> *newIDs = coord.createdDisplayIDs;
                virtualDisplays = displayList(newIDs, conv);
                virtualConv = conv;
                virtualID = newIDs.firstObject.unsignedIntValue;
                virtualW = [conv.firstObject[@"width"] unsignedIntegerValue];
                virtualH = [conv.firstObject[@"height"] unsignedIntegerValue];
                printf("  [独占] 换屏 %s（首屏 %lux%lu）\n",
                       newIDs.description.UTF8String, (unsigned long)virtualW, (unsigned long)virtualH);
                return virtualDisplays;
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
            virtualDisplays = displayList(ids, conv);
            virtualConv = conv;
            printf("  [独占] 虚拟屏 %s（首屏 %lux%lu）C-09=%s\n",
                   ids.description.UTF8String, (unsigned long)virtualW, (unsigned long)virtualH, c09.UTF8String);
            return virtualDisplays;
        };
        host.displayProvider = ^NSArray<NSDictionary *> *(NSDictionary *message, NSError **perr) {
            __block NSArray<NSDictionary *> *result = nil;
            __block NSError *buildErr = nil;
            // 门禁：等上一轮收尾（还屏，秒级）做完再建屏；运行期也与它同锁互斥。
            dispatch_sync(displayTxQueue, ^{ result = buildDisplays(message, &buildErr); });
            if (!result && perr) *perr = buildErr;
            return result;
        };
        host.onAttemptFailed = ^{
            // 显示保留给下一次接入复用（销毁再建会弄坏 VD 注册）。这里只需
            // 与显示事务串行地确认旧管线已停，避免它还在往死连接推帧。
            dispatch_sync(displayTxQueue, ^{
                printf("  [独占] 接入失败，虚拟屏保留待复用\n");
                fflush(stdout);
            });
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

    // 要推流的屏：独占会话按新建虚拟屏全量（FR-01 N 屏）；镜像诊断只推 --display 一块。
    // 每轮会话开始时重算（虚拟屏每轮新建，displayID 不复用）。
    __block int errCount = 0;
    NSMutableArray<M1FramePipeline *> *pipes = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, M1FramePipeline *> *pipeByDisplay = [NSMutableDictionary dictionary];
    // 换屏时旧管线已产出的统计：最终汇总要把它们算进去，否则数据看起来像丢了。
    NSMutableArray<NSDictionary *> *retiredPipes = [NSMutableArray array];

    // 停掉并记账当前全部管线（换屏前调用；旧屏随即会被销毁）。
    void (^retirePipelines)(void) = ^{
        @synchronized (pipes) {
            for (M1FramePipeline *p in pipes) {
                M1FramePipelineStats *s = p.stats;
                [retiredPipes addObject:@{
                    @"displayID": @(p.displayID), @"w": @(p.pixelWidth), @"h": @(p.pixelHeight),
                    @"framesCaptured": @(s.framesCaptured), @"framesEncoded": @(s.framesEncoded),
                    @"framesSent": @(s.framesSent), @"fragmentsSent": @(s.fragmentsSent),
                    @"framesDroppedBeforeEncoder": @(s.framesDroppedBeforeEncoder),
                    @"keyframes": @(s.keyframes), @"retired": @YES,
                }];
                [p stop];
            }
            [pipes removeAllObjects];
            [pipeByDisplay removeAllObjects];
        }
    };

    // M3 加固：SIGTERM/SIGINT 必须走有序收尾（停管线→还物理屏→销毁虚拟屏→摘 guardian）。
    // 直接被杀会让 WindowServer 留在「物理屏已禁、VD 未拆」的脏态，guardian 兜底
    // 在 Tahoe 上恢复失败（CGError 1001），机器变无头只能重启。
    static dispatch_source_t termSrc = nil, intSrc = nil;
    void (^handleTermination)(NSString *) = ^(NSString *signame) {
        printf("\n[信号] 收到 %s，开始有序收尾\n", signame.UTF8String);
        fflush(stdout);
        [host shutdown];
        dispatch_sync(displayTxQueue, ^{
            retirePipelines();
            endExclusive();
        });
        printf("[信号] 显示已恢复，退出\n");
        fflush(stdout);
        exit(0);
    };
    dispatch_queue_t sigQueue = dispatch_queue_create("veild.signal", DISPATCH_QUEUE_SERIAL);
    for (NSNumber *sigNum in @[ @(SIGTERM), @(SIGINT) ]) {
        int sig = sigNum.intValue;
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)sig, 0, sigQueue);
        if (!src) {
            printf("⚠ 无法监听信号 %d，被杀时将无还屏保护\n", sig);
            continue;
        }
        NSString *name = (sig == SIGTERM) ? @"SIGTERM" : @"SIGINT";
        dispatch_source_set_event_handler(src, ^{ handleTermination(name); });
        dispatch_resume(src);
        if (sig == SIGTERM) termSrc = src; else intSrc = src;
    }

    // 启动一组管线；任一失败就停掉本批并返回 NO（调用方负责回滚显示）。
    BOOL (^startPipelines)(NSArray<NSDictionary *> *) = ^BOOL(NSArray<NSDictionary *> *displays) {
        NSMutableArray *fresh = [NSMutableArray array];
        NSMutableDictionary *freshMap = [NSMutableDictionary dictionary];
        for (NSDictionary *disp in displays) {
            NSNumber *didNum = disp[@"displayID"];
            if (![didNum isKindOfClass:[NSNumber class]]) continue;
            uint32_t did = didNum.unsignedIntValue;
            if (did == 0 || freshMap[didNum]) continue;
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
            NSError *startErr = nil;
            if (![pipe start:&startErr]) {
                printf("✗ 管线启动失败 displayID=%u: %s\n",
                       did, startErr.localizedDescription.UTF8String);
                for (M1FramePipeline *p in fresh) [p stop];
                return NO;
            }
            [fresh addObject:pipe];
            freshMap[didNum] = pipe;
            printf("推流开始：displayID=%u  %dx%d  %dms @ %dfps\n",
                   did, pipe.pixelWidth, pipe.pixelHeight, durationMs, fps);
        }
        @synchronized (pipes) {
            [pipes addObjectsFromArray:fresh];
            [pipeByDisplay addEntriesFromDictionary:freshMap];
        }
        return fresh.count > 0;
    };

    // 请求按屏路由；displayID=0 是旧版客户端（单屏/全部屏）。
    // 900ms 合并窗口也按屏独立：一块屏的在途 IDR 不应吞掉另一块屏的请求。
    NSMutableDictionary<NSNumber *, NSNumber *> *lastKeyframeByDisplay = [NSMutableDictionary dictionary];
    host.onKeyframeRequest = ^(uint32_t displayID) {
        NSArray<M1FramePipeline *> *targets = nil;
        M1FramePipeline *one = nil;
        @synchronized (pipes) {
            targets = [pipes copy];
            one = pipeByDisplay[@(displayID)];
        }
        if (displayID != 0) {
            if (!one) return;
            targets = @[ one ];
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
        NSArray<M1FramePipeline *> *targets = nil;
        M1FramePipeline *one = nil;
        @synchronized (pipes) {
            targets = [pipes copy];
            one = pipeByDisplay[@(displayID)];
        }
        if (displayID != 0) {
            if (!one) return;
            targets = @[ one ];
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
    // 换屏后屏 bounds 变化，注入坐标基准必须跟着换。
    void (^refreshRects)(NSArray<NSDictionary *> *) = ^(NSArray<NSDictionary *> *displays) {
        NSMutableDictionary<NSNumber *, NSValue *> *fresh = [NSMutableDictionary dictionary];
        for (NSDictionary *disp in displays) {
            NSNumber *didNum = disp[@"displayID"];
            if (![didNum isKindOfClass:[NSNumber class]]) continue;
            CGRect r = CGDisplayBounds((CGDirectDisplayID)didNum.unsignedIntValue);
            if (!CGRectIsEmpty(r)) fresh[didNum] = [NSValue valueWithRect:(NSRect)r];
        }
        if (fresh.count == 0) {
            CGRect fallback = CGRectMake(0, 0, virtualW ?: (specW ?: 1920), virtualH ?: (specH ?: 1080));
            injector.targetDisplayRect = fallback;
        } else {
            injector.targetDisplayRect = [fresh.allValues.firstObject rectValue];
        }
        injector.displayRects = fresh;
        printf("输入目标屏 %lu 块%s\n", (unsigned long)fresh.count,
               fresh.count ? "" : "（无 Quartz bounds，回退到原点 rect）");
    };
    // 输入坐标基准每轮会话起管线后按实际屏刷新（refreshRects），此处不预设。
    __block NSUInteger injectOK = 0, injectFail = 0;
    host.onInputEvent = ^(NSDictionary *event) {
        NSError *ie = nil;
        if ([injector injectEvent:event error:&ie]) injectOK += 1;
        else injectFail += 1;
    };

    // FR-07：会话内换屏（控制收包队列上同步执行）。
    // 事务顺序：停旧管线 → 建新屏（驱动内保证旧屏在失败时不动）→ 起新管线。
    // 任一步失败都回到旧屏旧管线，回 session-update-result{ok:false}，会话不中断。
    if (exclusive) {
        host.onSessionUpdateSpecs = ^NSArray<NSDictionary *> *(NSArray<NSDictionary *> *specs,
                                                                 NSError **perr) {
            M1SessionCoordinator *c = coord;
            if (!c) {
                if (perr) *perr = [NSError errorWithDomain:@"veild.agent" code:7
                    userInfo:@{NSLocalizedDescriptionKey: @"独占会话未就绪"}];
                return nil;
            }
            NSMutableArray *conv = [NSMutableArray array];
            for (NSDictionary *sp in specs) {
                NSNumber *w = sp[@"w"], *h = sp[@"h"];
                if ([w isKindOfClass:[NSNumber class]] && [h isKindOfClass:[NSNumber class]])
                    [conv addObject:@{@"width": w, @"height": h}];
            }
            if (conv.count != specs.count || conv.count == 0) {
                if (perr) *perr = [NSError errorWithDomain:@"veild.agent" code:7
                    userInfo:@{NSLocalizedDescriptionKey: @"session-update 缺可用宽高"}];
                return nil;
            }
            NSArray<NSDictionary *> *oldDisplays = virtualDisplays;
            NSArray<NSDictionary *> *oldConv = virtualConv;
            retirePipelines();

            NSError *se = nil;
            if (![c applySpecs:conv error:&se]) {
                if (!startPipelines(oldDisplays)) {
                    fprintf(stderr, "  [换屏] 回滚后旧管线重启失败\n");
                }
                if (perr) *perr = se ?: [NSError errorWithDomain:@"veild.agent" code:7
                    userInfo:@{NSLocalizedDescriptionKey: @"换屏失败"}];
                return nil;
            }
            NSArray<NSNumber *> *ids = c.createdDisplayIDs;
            NSMutableArray *displays = [NSMutableArray array];
            for (NSUInteger i = 0; i < ids.count; i++)
                [displays addObject:@{@"displayID": ids[i],
                                      @"w": i < conv.count ? conv[i][@"width"] : @0,
                                      @"h": i < conv.count ? conv[i][@"height"] : @0,
                                      @"synthetic": @NO}];
            if (ids.count == 0 || !startPipelines(displays)) {
                // 新屏生效但管线起不来：换回旧规格，恢复旧管线。
                NSError *rbErr = nil;
                BOOL back = oldConv.count > 0 && [c applySpecs:oldConv error:&rbErr];
                if (back && startPipelines(oldDisplays)) refreshRects(oldDisplays);
                if (perr) *perr = [NSError errorWithDomain:@"veild.agent" code:7
                    userInfo:@{NSLocalizedDescriptionKey: back
                        ? @"新屏管线启动失败，已回滚旧屏" : @"新屏管线启动失败且回滚失败"}];
                return nil;
            }
            virtualDisplays = displays;
            virtualConv = conv;
            virtualID = ids.firstObject.unsignedIntValue;
            virtualW = [conv.firstObject[@"width"] unsignedIntegerValue];
            virtualH = [conv.firstObject[@"height"] unsignedIntegerValue];
            refreshRects(displays);
            @synchronized (lastKeyframeByDisplay) { [lastKeyframeByDisplay removeAllObjects]; }
            printf("  [换屏] %lu 屏 → %lux%lu（首屏 displayID=%u）\n",
                   (unsigned long)ids.count, (unsigned long)virtualW, (unsigned long)virtualH,
                   virtualID);
            return displays;
        };
    }

    // 会话循环：一个进程连续服务多个客户端（--max-sessions >1 或 0）。
    // 每轮结束（对端 bye / 传输断 / duration 到）立即清理：停管线、清键帧节流。
    // 显示不还：同进程销毁虚拟屏后再建会让新屏永远 online=0（Tahoe 实测），
    // 下一轮按规格复用/换屏。物理屏在整个常驻期间保持独占，进程退出才恢复。
    // 收尾统一在 displayTxQueue 上执行：与下一轮建屏/换屏是同一串行域。
    void (^cleanupSession)(void) = ^{
        BOOL hasPipes = NO;
        @synchronized (pipes) { hasPipes = pipes.count > 0; }
        if (!hasPipes) return;   // 已收过尾（bye 与时长到可能双双到达）
        // 这段收尾是上一轮的：若新一轮已接上（理论上要快过收尾入队），
        // 不能拆它的管线。
        if (host.session) return;
        [host flushSimulatedHeld];
        retirePipelines();
        @synchronized (lastKeyframeByDisplay) { [lastKeyframeByDisplay removeAllObjects]; }
        [host prepareForNextSession];
    };
    dispatch_semaphore_t sessionEndSem = dispatch_semaphore_create(0);
    host.onSessionClosed = ^{
        // 先放行主线程再看结果：收尾是秒级的，不能让下一轮的判定等它。
        dispatch_semaphore_signal(sessionEndSem);
        dispatch_async(displayTxQueue, ^{ cleanupSession(); });
    };
    NSUInteger sessionsServed = 0, failedAttempts = 0;
    while (maxSessions == 0 || sessionsServed < maxSessions) {
        if (![host waitForStreamingTimeoutMs:waitMs]) {
            if (host.error && maxSessions != 1) {
                // 常驻模式：单次接入失败（握手/会话错误）不终止进程，也不算会话数。
                printf("  [会话] 接入失败：%s（继续等下一位）\n",
                       host.error.localizedDescription.UTF8String ?: "unknown");
                [host prepareForNextSession];
                if (++failedAttempts >= 5) {
                    printf("✗ 连续 %lu 次接入失败，放弃常驻\n", (unsigned long)failedAttempts);
                    break;
                }
                continue;
            }
            printf("✗ %us 内未进入 STREAMING: %s\n", waitMs / 1000,
                   host.error.localizedDescription.UTF8String ?: "无客户端");
            break;
        }
        failedAttempts = 0;
        sessionsServed += 1;
        printf("  [会话 %lu] STREAMING，开始推流（上限 %dms）\n",
               (unsigned long)sessionsServed, durationMs);

        NSArray<NSDictionary *> *streamDisplays = nil;
        if (exclusive && virtualDisplays.count > 0) streamDisplays = virtualDisplays;
        else streamDisplays = @[ @{ @"displayID": @(displayID) } ];

        if (!startPipelines(streamDisplays)) {
            printf("✗ 没有可推流的显示\n");
            dispatch_sync(displayTxQueue, ^{
                retirePipelines();
                [host prepareForNextSession];
            });
            break;
        }
        refreshRects(streamDisplays);
        @synchronized (lastKeyframeByDisplay) { [lastKeyframeByDisplay removeAllObjects]; }

        // 客户端可能起管线期间就已离开；上一轮迟到的结束信号也不能把这一轮
        // 瞬间判成结束——先清陈旧信号，再按「是否还在线」决定等真实结束。
        while (dispatch_semaphore_wait(sessionEndSem, DISPATCH_TIME_NOW) == 0) {}
        BOOL clientLeft = !host.streaming;
        BOOL reachedDurationEnd = NO;
        if (!clientLeft) {
            reachedDurationEnd = dispatch_semaphore_wait(sessionEndSem,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)durationMs * NSEC_PER_MSEC)) != 0;
            if (!reachedDurationEnd) clientLeft = YES;
        }
        printf("  [会话 %lu] 结束（%s），收尾\n", (unsigned long)sessionsServed,
               reachedDurationEnd ? "时长到" : "客户端离开");

        // 客户端离开：onSessionClosed 已把收尾排进 displayTxQueue。
        // 时长到是 host 主动结束，onSessionClosed 不会来：就地拆本轮连接再收尾，
        // 与下一轮建屏同队列，必然串行。
        if (reachedDurationEnd) {
            dispatch_sync(displayTxQueue, ^{
                [host endCurrentSession];
                cleanupSession();
            });
        }
        fflush(stdout);
    }
    // 关停本身可能再触发一次 onSessionClosed（收尾入队），所以先 shutdown
    // 再用队列屏障把收尾/还屏全部排干，最后才还屏退出。
    [host shutdown];
    dispatch_sync(displayTxQueue, ^{
        retirePipelines();
        endExclusive();
    });

    uint64_t cap = 0, enc = 0, sent = 0, dropped = 0, fragments = 0;
    NSMutableArray<NSDictionary *> *displayJSON = [NSMutableArray array];
    // 每轮结束都把管线退休记账，汇总只需读账本（retired:true 标记来自换屏或会话收尾）。
    for (NSDictionary *r in retiredPipes) {
        cap += [r[@"framesCaptured"] unsignedLongLongValue];
        enc += [r[@"framesEncoded"] unsignedLongLongValue];
        sent += [r[@"framesSent"] unsignedLongLongValue];
        dropped += [r[@"framesDroppedBeforeEncoder"] unsignedLongLongValue];
        fragments += [r[@"fragmentsSent"] unsignedLongLongValue];
        [displayJSON addObject:r];
        printf("serve[%u]: captured=%llu encoded=%llu sent=%llu dropped=%llu key=%llu\n",
               [r[@"displayID"] unsignedIntValue],
               [r[@"framesCaptured"] unsignedLongLongValue],
               [r[@"framesEncoded"] unsignedLongLongValue],
               [r[@"framesSent"] unsignedLongLongValue],
               [r[@"framesDroppedBeforeEncoder"] unsignedLongLongValue],
               [r[@"keyframes"] unsignedLongLongValue]);
    }
    printf("serve: 合计 frames captured=%llu encoded=%llu sent=%llu dropped=%llu fragments=%llu（%lu 屏 / %lu 会话）\n",
           cap, enc, sent, dropped, fragments,
           (unsigned long)retiredPipes.count, (unsigned long)sessionsServed);
    printf("serve: input ok=%lu fail=%lu record=%lu | 控制到达最大间隔=%.1fms (offset %.1fms)\n",
           (unsigned long)injectOK, (unsigned long)injectFail,
           (unsigned long)recorder.postCount, host.maxControlGapMs, host.maxGapAtOffsetMs);
    NSDictionary *ctlDiag = [host controlDiagnostics];
    {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *k in ctlDiag.allKeys) [parts addObject:[NSString stringWithFormat:@"%@=%@", k, ctlDiag[k]]];
        printf("serve: 控制面 %s\n", [[parts componentsJoinedByString:@" "] UTF8String]);
        fflush(stdout);
    }
    if (outPath.length > 0) {
        NSDictionary *json = @{
            @"framesCaptured": @(cap), @"framesEncoded": @(enc),
            @"framesSent": @(sent), @"fragmentsSent": @(fragments),
            @"framesDroppedBeforeEncoder": @(dropped),
            @"inputOK": @(injectOK), @"inputFail": @(injectFail),
            @"maxControlGapMs": @(host.maxControlGapMs),
            @"maxGapAtOffsetMs": @(host.maxGapAtOffsetMs),
            @"c09": c09,
            @"sessions": @(sessionsServed),
            @"displays": displayJSON,
            @"stateLog": host.stateLog ?: @[],
            @"control": ctlDiag,
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
