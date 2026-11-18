//
//  pipeline_kiosk_probe.m
//  M1-Skeleton
//
//  帧管线在「禁屏独占」条件下的实测（D-10 目标档验证）。
//
//  为什么要禁屏才能测准：M1-Pre 实测记录显示，物理屏在线时 SCK 送帧只有 1–2fps，
//  禁掉全部物理屏后同样链路可达 18fps。产品运行态就是「禁屏后推流」，所以 20fps
//  目标只能在禁屏条件下验证，否则测出来的是无关的合成负载噪声。
//
//  ★ 本探针会临时把物理屏全部禁掉（屏幕变黑），期间由 P0V 守护进程兜底恢复。
//    流程：防睡眠 → 快照 + 启动守护（握手）→ 建虚拟屏 → 禁物理屏（保留虚拟屏）→
//          隔离校验（必须有且仅有虚拟屏）→ 采编环回 → 恢复。
//
//  ★ 四道保险（缺一条都可能把机器留在黑屏态，2026-11-18 已实际发生）：
//    1. 宿主必须实现 --guardian（本文件第一段就处理），否则 P0VStartGuardian 握手失败、
//       拒绝禁屏 —— 没有兜底就绝不改显示配置。
//    2. 快照必须在建虚拟屏之前拍，否则恢复时虚拟屏被当成 main，销毁后拓扑破碎。
//    3. keep 必须包含本会话虚拟屏，禁完自检 active 非空；零显示比泄漏更致命。
//    4. SIGINT/SIGTERM/SIGHUP 与看门狗都会先恢复再退出，@finally 不是唯一出口。
//
//  用法：
//    ./pipeline_kiosk_probe --preflight          # 只验兜底链路，不碰显示配置
//    ./pipeline_kiosk_probe [--spec WxH] [--duration-ms N] [--fps N] [--bpp D]
//                           [--out PATH] [--shot PATH] [--no-loopback]
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import "M1RDPDriver.h"
#import "M1FramePipeline.h"
#import "M1FrameReceiver.h"
#import "M1DatagramSink.h"
#import "P0VDisplayControl.h"

static double M1KioskNowMs(void) {
    return [[NSDate date] timeIntervalSince1970] * 1000.0;
}

#pragma mark - 信号安全恢复（2026-11-18 黑屏事故的直接教训）

// 事故复盘：探针只在 @finally 里恢复物理屏，而 SIGINT/SIGTERM 的默认动作是
// 立即终止进程 —— @finally 根本不会执行。用户 Ctrl+C 或关掉终端窗口（SIGHUP）
// 就等于「把物理屏永久留在禁用态」。
// 这里改为：信号处理函数只往自管道写一个字节（async-signal-safe），
// 由专门的线程读管道后执行恢复再退出。
static int gSignalPipe[2] = { -1, -1 };

static void M1KioskSignalHandler(int sig) {
    if (gSignalPipe[1] >= 0) {
        char c = (char)sig;
        ssize_t n = write(gSignalPipe[1], &c, 1);
        (void)n;
    }
}

static M1RDPDriver *gDriver = nil;
static BOOL gRestoreDone = NO;

// 恢复只执行一次；信号路径、正常路径、看门狗路径共用。
static BOOL M1KioskRestoreOnce(const char *tag) {
    @synchronized ([M1RDPDriver class]) {
        if (gRestoreDone) return YES;
        gRestoreDone = YES;
        if (!gDriver) return YES;
        NSError *e = nil;
        printf("\n[%s] 正在恢复物理屏并销毁虚拟屏…\n", tag);
        fflush(stdout);
        BOOL ok = [gDriver restorePhysicalAndDestroyDisplaysError:&e];
        printf("[%s] 恢复%s%s\n", tag, ok ? "成功" : "失败",
               ok ? "" : e.localizedDescription.UTF8String);
        fflush(stdout);
        return ok;
    }
}

static void M1KioskInstallSignalSafety(int64_t watchdogDeadlineMs) {
    if (pipe(gSignalPipe) != 0) return;
    fcntl(gSignalPipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(gSignalPipe[1], F_SETFD, FD_CLOEXEC);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = M1KioskSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);   // 关终端窗口也走这条路

    [NSThread detachNewThreadWithBlock:^{
        char c = 0;
        if (read(gSignalPipe[0], &c, 1) == 1) {
            char tag[48];
            snprintf(tag, sizeof(tag), "signal %d", (int)c);
            M1KioskRestoreOnce(tag);
        }
        _exit(130);
    }];

    if (watchdogDeadlineMs > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, watchdogDeadlineMs * NSEC_PER_MSEC),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            fprintf(stderr, "\n[watchdog] 超过 %llds 仍未收尾，强制恢复后退出\n",
                    watchdogDeadlineMs / 1000);
            M1KioskRestoreOnce("watchdog");
            _exit(9);
        });
    }
}

@interface M1KioskLoopbackSink : NSObject <M1DatagramSink>
@property (nonatomic, strong) M1FrameReceiver *receiver;
@property (nonatomic, assign) uint64_t forwarded;
@end

@implementation M1KioskLoopbackSink
- (BOOL)sendDatagram:(NSData *)datagram error:(NSError **)error {
    if (error) *error = nil;
    self.forwarded += 1;
    [self.receiver acceptDatagram:datagram error:NULL];
    return YES;
}
@end

static BOOL M1KioskSavePNG(CVPixelBufferRef pb, NSString *path) {
    if (!pb || path.length == 0) return NO;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    if (!ci) return NO;
    static CIContext *ctx = nil;
    if (!ctx) ctx = [CIContext contextWithOptions:nil];
    CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
    if (!cg) return NO;
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path],
        (__bridge CFStringRef)@"public.png", 1, NULL);
    if (!dst) { CGImageRelease(cg); return NO; }
    CGImageDestinationAddImage(dst, cg, NULL);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(cg);
    return ok;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        // ★ 守护模式必须最先处理：P0VStartGuardian 会用同一个二进制 re-exec。
        //   本探针曾经缺这一段，守护子进程打印用法后立刻退出，于是「以为有兜底」的
        //   禁屏操作在黑屏后再也没人恢复 —— 2026-11-18 整机黑死、只能强制重启。
        if (argc > 1 && strcmp(argv[1], "--guardian") == 0) {
            NSString *snap = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : nil;
            pid_t parent = 0;
            for (int i = 3; i + 1 < argc; i++) {
                if (strcmp(argv[i], "--parent-pid") == 0) parent = atoi(argv[i + 1]);
            }
            if (!snap || parent <= 0) return 3;
            return P0VRunGuardian(snap, parent);
        }

        int32_t specW = 1920, specH = 1080;
        int durationMs = 10000;
        int targetFps = 20;
        double bpp = 0.12;
        NSString *outPath = nil;
        NSString *shotPath = nil;
        BOOL loopback = YES;
        BOOL preflight = NO;
        BOOL keepMain = NO;

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--spec") == 0 && i + 1 < argc) {
                NSArray *p = [[NSString stringWithUTF8String:argv[++i]]
                              componentsSeparatedByString:@"x"];
                if (p.count == 2) {
                    specW = (int32_t)atoi([p[0] UTF8String]);
                    specH = (int32_t)atoi([p[1] UTF8String]);
                }
            } else if (strcmp(argv[i], "--duration-ms") == 0 && i + 1 < argc) {
                durationMs = atoi(argv[++i]);
            } else if (strcmp(argv[i], "--fps") == 0 && i + 1 < argc) {
                targetFps = atoi(argv[++i]);
            } else if (strcmp(argv[i], "--bpp") == 0 && i + 1 < argc) {
                bpp = atof(argv[++i]);
            } else if (strcmp(argv[i], "--out") == 0 && i + 1 < argc) {
                outPath = [NSString stringWithUTF8String:argv[++i]];
            } else if (strcmp(argv[i], "--shot") == 0 && i + 1 < argc) {
                shotPath = [NSString stringWithUTF8String:argv[++i]];
            } else if (strcmp(argv[i], "--no-loopback") == 0) {
                loopback = NO;
            } else if (strcmp(argv[i], "--preflight") == 0) {
                preflight = YES;
            } else if (strcmp(argv[i], "--keep-main") == 0) {
                keepMain = YES;
            } else {
                fprintf(stderr,
                    "用法: pipeline_kiosk_probe [--spec WxH] [--duration-ms N] [--fps N]\n"
                    "                           [--bpp D] [--out PATH] [--shot PATH]\n"
                    "                           [--no-loopback] [--preflight] [--keep-main]\n"
                    "  --preflight  只验证兜底链路（快照 + 守护就绪握手），不改任何显示配置\n"
                    "  --keep-main  半禁屏：保留物理主屏可见，只禁其余物理屏（跳过 C-09，用于安全验证禁屏/恢复机制）\n");
                return 2;
            }
        }
        if (durationMs < 2000) durationMs = 2000;   // 首帧要 3s+，太短测不出东西

        // 预检：只跑「快照 + 守护握手 + 撤盾」，不建屏、不禁屏。
        // 每次真实禁屏前都该先跑它 —— 它能在 1 秒内证明「万一崩了有人兜底」。
        if (preflight) {
            printf("=== 兜底链路预检（不触碰显示配置）===\n");
            fflush(stdout);
            M1RDPDriver *pf = [[M1RDPDriver alloc] init];
            NSError *pfErr = nil;
            if (![pf prepareSessionShieldError:&pfErr]) {
                printf("  ✗ 护盾预备失败: %s\n", pfErr.localizedDescription.UTF8String);
                printf("  结论：禁止执行禁屏实测\n");
                return 5;
            }
            NSString *ready = [pf.snapshotPath stringByAppendingString:@".guardian-ready"];
            BOOL ok = [[NSFileManager defaultManager] fileExistsAtPath:ready];
            printf("  快照     : %s\n", pf.snapshotPath.UTF8String);
            printf("  守护就绪 : %s\n", ok ? "是（握手通过）" : "否");
            [pf disarmShield];
            printf("  结论     : %s\n", ok ? "预检通过，可以安全禁屏" : "预检失败，禁止禁屏");
            return ok ? 0 : 5;
        }

        printf("=== M1 帧管线 · 禁屏独占实测（D-10 目标档）===\n");
        printf("  虚拟屏=%dx%d  target=%dfps  duration=%dms  loopback=%s\n",
               specW, specH, targetFps, durationMs, loopback ? "on" : "off");
        if (keepMain) {
            printf("  模式: 半禁屏（保留物理主屏，屏幕全程可见；数据不代表禁屏独占性能）\n");
        } else {
            printf("  ⚠ 物理屏将被临时禁用（黑屏），由守护进程兜底恢复\n");
        }

        M1RDPDriver *driver = [[M1RDPDriver alloc] init];
        gDriver = driver;
        // 信号安全：Ctrl+C / 杀进程 / 关终端都会先恢复物理屏再退出。
        // 看门狗在「正常时长 + 120s」后强制收尾，防止管线卡死把屏留在禁用态。
        M1KioskInstallSignalSafety((int64_t)durationMs + 120000);

        NSError *err = nil;
        BOOL didDisable = NO;
        BOOL didCreate = NO;
        BOOL didAssert = NO;
        int rc = 0;
        double t0 = M1KioskNowMs();

        @try {
            // 1) 防显示睡眠：锁屏/禁屏后屏睡会让 SCK displays 变空。
            if (![driver acquireSleepAssertionError:&err]) {
                printf("  防睡眠断言失败: %s\n", err.localizedDescription.UTF8String);
                rc = 4;
                return rc;
            }
            didAssert = YES;

            // 2) 先建齐虚拟屏（D-05：建屏必须先于禁屏）。
            NSArray *specs = @[ @{ @"width": @(specW), @"height": @(specH) } ];
            if (![driver createVirtualDisplays:specs error:&err]) {
                printf("  建虚拟屏失败: %s\n", err.localizedDescription.UTF8String);
                rc = 4;
                return rc;
            }
            didCreate = YES;
            NSArray<NSNumber *> *ids = [driver createdDisplayIDs];
            if (ids.count == 0) {
                printf("  建屏后没有 displayID\n");
                rc = 4;
                return rc;
            }
            CGDirectDisplayID vid = (CGDirectDisplayID)ids.firstObject.unsignedIntValue;
            printf("  虚拟屏 displayID=%u\n", vid);

            // 3) 禁物理屏（快照 + 守护已在建屏前完成）。
            //    keep 必须显式带上本会话虚拟屏：传空数组会把虚拟屏一起禁掉 → 零显示黑屏。
            //    --keep-main 时额外保留物理主屏（半禁屏诊断：屏幕始终可用，可安全验证禁/恢复）。
            NSArray *keepIDs = ids;
            CGDirectDisplayID mainID = CGMainDisplayID();
            if (keepMain) {
                keepIDs = [ids arrayByAddingObject:@(mainID)];
                printf("  [半禁屏] 保留物理主屏 %u，仅禁其余物理屏\n", mainID);
            }
            if (![driver snapshotAndDisablePhysicalExcept:keepIDs error:&err]) {
                printf("  禁物理屏失败: %s\n", err.localizedDescription.UTF8String);
                rc = 5;
                return rc;
            }
            didDisable = YES;

            // 4) C-09 隔离校验：active 必须只剩本会话虚拟屏。
            //    半禁屏诊断模式故意保留物理主屏，此时不适用（跳过而非放宽判据）。
            if (keepMain) {
                printf("  [半禁屏] 跳过 C-09 隔离校验（保留主屏是有意为之）\n");
            } else {
                if (![driver verifyIsolationError:&err]) {
                    printf("  隔离校验失败: %s\n", err.localizedDescription.UTF8String);
                    rc = 6;
                    return rc;
                }
                printf("  物理屏已禁用，隔离校验通过\n");
            }

            // 5) 跑采编环回。
            M1KioskLoopbackSink *sink = [[M1KioskLoopbackSink alloc] init];
            __block double firstDecodedMs = 0;
            __block int32_t decW = 0, decH = 0;
            __block BOOL shotSaved = NO;
            NSString *shot = shotPath;
            double pipeStart = M1KioskNowMs();

            M1FrameReceiver *receiver = nil;
            if (loopback) {
                receiver = [[M1FrameReceiver alloc] initWithOnFrame:^(CVPixelBufferRef pb, uint32_t seq) {
                    if (firstDecodedMs == 0) firstDecodedMs = M1KioskNowMs() - pipeStart;
                    decW = (int32_t)CVPixelBufferGetWidth(pb);
                    decH = (int32_t)CVPixelBufferGetHeight(pb);
                    if (shot.length > 0 && !shotSaved) {
                        shotSaved = M1KioskSavePNG(pb, shot);
                        if (shotSaved) printf("  首帧已保存: %s\n", shot.UTF8String);
                    }
                } onNeedKeyframe:^{
                    printf("  [接收端请求关键帧]\n");
                }];
                sink.receiver = receiver;
            }

            M1FramePipelineConfig *cfg = [[M1FramePipelineConfig alloc] init];
            cfg.targetFps = targetFps;
            cfg.bitsPerPixel = bpp;

            __block int errorCount = 0;
            M1FramePipeline *pipe =
                [[M1FramePipeline alloc] initWithDisplayID:vid config:cfg sink:sink
                                                   onError:^(NSError *e) {
                    errorCount += 1;
                    if (errorCount <= 5) {
                        printf("  [错误] %s\n", e.localizedDescription.UTF8String);
                    }
                }];

            NSError *startErr = nil;
            if (![pipe start:&startErr]) {
                printf("  管线启动失败: %s\n", startErr.localizedDescription.UTF8String);
                rc = 7;
                return rc;
            }
            printf("  采集尺寸: %dx%d\n", pipe.pixelWidth, pipe.pixelHeight);

            [NSThread sleepForTimeInterval:durationMs / 1000.0];
            double elapsed = M1KioskNowMs() - pipeStart;
            [pipe stop];

            M1FramePipelineStats *ps = [pipe stats];
            M1FrameReceiverStats *rs = receiver ? [receiver stats] : nil;
            double effFps = ps.framesSent / (elapsed / 1000.0);
            double kbps = elapsed > 0 ? (ps.payloadBytesSent * 8.0 / elapsed) : 0;

            printf("\n--- 结果 ---\n");
            printf("  pipeline : %s\n", ps.summary.UTF8String);
            printf("  有效帧率 : %.1f fps（目标 %d）\n", effFps, targetFps);
            printf("  码率     : %.0f kbps\n", kbps);
            if (rs) {
                printf("  receiver : datagrams=%llu completed=%llu decoded=%llu "
                       "dropped=%llu decodeFail=%llu keyReq=%llu malformed=%llu\n",
                       rs.datagramsReceived, rs.framesCompleted, rs.framesDecoded,
                       rs.framesDropped, rs.decodeFailures, rs.keyframeRequests,
                       rs.malformedDatagrams);
                printf("  解码尺寸 : %dx%d  首帧延迟 %.0fms\n", decW, decH, firstDecodedMs);
            }
            if (errorCount > 0) printf("  错误总数 : %d\n", errorCount);

            NSString *verdict = @"FAIL";
            NSMutableArray *notes = [NSMutableArray array];
            if (ps.framesSent == 0) {
                [notes addObject:@"禁屏条件下没有发出任何帧"];
            } else if (loopback && rs && rs.framesDecoded == 0) {
                [notes addObject:@"发出了帧但接收端没解出画面"];
            } else {
                double ratio = effFps / (double)targetFps;
                if (loopback && rs && ps.framesSent > 0) {
                    double dr = (double)rs.framesDecoded / (double)ps.framesSent;
                    if (dr < 0.9) [notes addObject:[NSString stringWithFormat:
                        @"解码/发送比 %.2f 偏低", dr]];
                }
                if (ratio < 0.5) {
                    [notes addObject:[NSString stringWithFormat:
                        @"有效帧率仅目标的 %.0f%%", ratio * 100]];
                }
                verdict = notes.count == 0 ? @"PASS" : @"DEGRADED";
            }
            printf("  判定     : %s\n", verdict.UTF8String);
            for (NSString *n in notes) printf("    · %s\n", n.UTF8String);

            if (outPath.length > 0) {
                NSMutableDictionary *json = [NSMutableDictionary dictionary];
                json[@"mode"] = @"kiosk-disable-all";
                json[@"spec"] = [NSString stringWithFormat:@"%dx%d", specW, specH];
                json[@"captureSize"] = [NSString stringWithFormat:@"%dx%d",
                                        pipe.pixelWidth, pipe.pixelHeight];
                json[@"targetFps"] = @(targetFps);
                json[@"durationMs"] = @((int)elapsed);
                json[@"loopback"] = @(loopback);
                json[@"effectiveFps"] = @(round(effFps * 10) / 10.0);
                json[@"bitrateKbps"] = @(round(kbps));
                json[@"verdict"] = verdict;
                json[@"notes"] = notes;
                json[@"errorCount"] = @(errorCount);
                json[@"pipeline"] = @{
                    @"captured": @(ps.framesCaptured),
                    @"encoded": @(ps.framesEncoded),
                    @"sent": @(ps.framesSent),
                    @"droppedBeforeEncoder": @(ps.framesDroppedBeforeEncoder),
                    @"encodeFailures": @(ps.encodeFailures),
                    @"sendFailures": @(ps.sendFailures),
                    @"keyframes": @(ps.keyframes),
                    @"fragments": @(ps.fragmentsSent),
                    @"payloadBytes": @(ps.payloadBytesSent),
                    @"firstFrameLatencyMs": @(round(ps.firstFrameLatencyMs)),
                };
                if (rs) {
                    json[@"receiver"] = @{
                        @"datagrams": @(rs.datagramsReceived),
                        @"completed": @(rs.framesCompleted),
                        @"decoded": @(rs.framesDecoded),
                        @"dropped": @(rs.framesDropped),
                        @"decodeFailures": @(rs.decodeFailures),
                        @"keyframeRequests": @(rs.keyframeRequests),
                        @"malformed": @(rs.malformedDatagrams),
                        @"decodedWidth": @(decW),
                        @"decodedHeight": @(decH),
                        @"firstDecodedMs": @(round(firstDecodedMs)),
                    };
                }
                if (shot.length > 0) json[@"shot"] = shot;
                NSData *data = [NSJSONSerialization dataWithJSONObject:json
                                                              options:NSJSONWritingPrettyPrinted
                                                                error:NULL];
                if (data) {
                    [data writeToFile:outPath atomically:YES];
                    printf("  JSON: %s\n", outPath.UTF8String);
                }
            }
        } @finally {
            // 无论成功与否，必须恢复物理屏并销毁虚拟屏。
            // 统一走 M1KioskRestoreOnce：与信号路径 / 看门狗路径互斥，绝不重复施加显示事务。
            if (didDisable || didCreate) {
                BOOL ok = M1KioskRestoreOnce("normal");
                if (!ok) printf("  ⚠ 恢复未完全成功，请检查 /tmp/p0v-display-guardian.log\n");
            }
            if (didAssert) [driver releaseSleepAssertion];
            printf("  总耗时 %.1fs\n", (M1KioskNowMs() - t0) / 1000.0);
        }

        return rc;
    }
}
