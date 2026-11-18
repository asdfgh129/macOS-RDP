//
//  pipeline_probe.m
//  M1-Skeleton
//
//  帧管线实机环回验证（D-10 主路径）：
//    SCK 采集 → VT H.264 编码 → 协议分片 → [环回] → 重组 → VT 硬解 → 首帧 PNG
//
//  环回 sink 把每个 datagram 直接喂给接收端，不落盘、不联网——这样能在单机上
//  验证「分片格式与解码链路真的对得上」，而不只是看统计数字。
//
//  安全：本探针**不建虚拟屏、不禁物理屏、不改显示配置**，只采集当前已有显示。
//  用法：
//    ./pipeline_probe [--display ID] [--duration-ms N] [--fps N] [--bpp D]
//                     [--out PATH] [--shot PATH] [--no-loopback] [--keyframe-at MS]
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import "M1FramePipeline.h"
#import "M1FrameReceiver.h"
#import "M1DatagramSink.h"

static double M1NowMs(void) {
    return [[NSDate date] timeIntervalSince1970] * 1000.0;
}

// 环回 sink：把每个 datagram 直接交给接收端。线程 = 编码器回调线程。
@interface M1LoopbackSink : NSObject <M1DatagramSink>
@property (nonatomic, strong) M1FrameReceiver *receiver;
@property (nonatomic, assign) uint64_t forwarded;
@end

@implementation M1LoopbackSink
- (BOOL)sendDatagram:(NSData *)datagram error:(NSError **)error {
    if (error) *error = nil;
    self.forwarded += 1;
    [self.receiver acceptDatagram:datagram error:NULL];
    return YES;
}
@end

static BOOL M1SavePixelBufferPNG(CVPixelBufferRef pb, NSString *path) {
    if (!pb || path.length == 0) return NO;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    if (!ci) return NO;
    static CIContext *ctx = nil;
    if (!ctx) ctx = [CIContext contextWithOptions:nil];
    CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
    if (!cg) return NO;

    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, (__bridge CFStringRef)@"public.png", 1, NULL);
    if (!dst) { CGImageRelease(cg); return NO; }
    CGImageDestinationAddImage(dst, cg, NULL);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(cg);
    return ok;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        CGDirectDisplayID displayID = CGMainDisplayID();
        int durationMs = 5000;
        int targetFps = 20;
        double bpp = 0.12;
        NSString *outPath = nil;
        NSString *shotPath = nil;
        BOOL loopback = YES;
        int keyframeAtMs = -1;
        int32_t outW = 0, outH = 0;

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--display") == 0 && i + 1 < argc) {
                displayID = (CGDirectDisplayID)strtoul(argv[++i], NULL, 10);
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
            } else if (strcmp(argv[i], "--keyframe-at") == 0 && i + 1 < argc) {
                keyframeAtMs = atoi(argv[++i]);
            } else if (strcmp(argv[i], "--out-size") == 0 && i + 1 < argc) {
                NSArray *p = [[NSString stringWithUTF8String:argv[++i]]
                              componentsSeparatedByString:@"x"];
                if (p.count == 2) {
                    outW = (int32_t)atoi([p[0] UTF8String]);
                    outH = (int32_t)atoi([p[1] UTF8String]);
                }
            } else {
                fprintf(stderr,
                    "用法: pipeline_probe [--display ID] [--duration-ms N] [--fps N]\n"
                    "                     [--bpp D] [--out-size WxH] [--out PATH]\n"
                    "                     [--shot PATH] [--no-loopback] [--keyframe-at MS]\n");
                return 2;
            }
        }
        if (targetFps < 1) targetFps = 1;
        if (durationMs < 500) durationMs = 500;

        printf("=== M1 帧管线环回 ===\n");
        printf("  display=%u  target=%dfps  duration=%dms  bpp=%.2f  loopback=%s\n",
               displayID, targetFps, durationMs, bpp, loopback ? "on" : "off");
        if (outW > 0 && outH > 0) {
            printf("  目标输出: %dx%d（降采样）\n", outW, outH);
        }

        M1LoopbackSink *sink = [[M1LoopbackSink alloc] init];
        __block double firstDecodedMs = 0;
        __block int32_t decodedW = 0, decodedH = 0;
        __block BOOL shotSaved = NO;
        NSString *shot = shotPath;
        double t0 = M1NowMs();

        M1FrameReceiver *receiver = nil;
        if (loopback) {
            receiver = [[M1FrameReceiver alloc] initWithOnFrame:^(CVPixelBufferRef pb, uint32_t seq) {
                if (firstDecodedMs == 0) firstDecodedMs = M1NowMs() - t0;
                decodedW = (int32_t)CVPixelBufferGetWidth(pb);
                decodedH = (int32_t)CVPixelBufferGetHeight(pb);
                if (shot.length > 0 && !shotSaved) {
                    shotSaved = M1SavePixelBufferPNG(pb, shot);
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
        cfg.outputWidth = outW;
        cfg.outputHeight = outH;

        __block int errorCount = 0;
        M1FramePipeline *pipe =
            [[M1FramePipeline alloc] initWithDisplayID:displayID
                                                config:cfg
                                                  sink:sink
                                               onError:^(NSError *e) {
                errorCount += 1;
                if (errorCount <= 5) {
                    printf("  [错误] %s\n", e.localizedDescription.UTF8String);
                }
            }];

        NSError *startErr = nil;
        if (![pipe start:&startErr]) {
            printf("  start 失败: %s\n", startErr.localizedDescription.UTF8String);
            return 3;
        }
        printf("  采集尺寸: %dx%d\n", pipe.pixelWidth, pipe.pixelHeight);

        // 中途强制关键帧：验证接收端在缺口/新加入时的恢复能力。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(durationMs / 2) * NSEC_PER_MSEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (keyframeAtMs >= 0) {
                printf("  强制关键帧 @ %dms\n", keyframeAtMs);
                [pipe requestKeyframe];
            }
        });

        [NSThread sleepForTimeInterval:durationMs / 1000.0];
        double elapsedMs = M1NowMs() - t0;
        [pipe stop];

        M1FramePipelineStats *ps = [pipe stats];
        M1FrameReceiverStats *rs = receiver ? [receiver stats] : nil;

        double effFps = ps.framesSent / (elapsedMs / 1000.0);
        double kbps = (elapsedMs > 0) ? (ps.payloadBytesSent * 8.0 / elapsedMs) : 0;

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
            printf("  解码尺寸 : %dx%d  首帧延迟 %.0fms\n", decodedW, decodedH, firstDecodedMs);
        }
        if (errorCount > 0) printf("  错误总数 : %d\n", errorCount);

        // 判据
        NSString *verdict = @"FAIL";
        NSMutableArray *notes = [NSMutableArray array];
        BOOL linkOK = (ps.framesSent > 0);
        BOOL decodeOK = !loopback || (rs && rs.framesDecoded > 0);
        if (!linkOK) {
            [notes addObject:@"没有发出任何帧"];
        } else if (!decodeOK) {
            [notes addObject:@"发出了帧但接收端没解出画面"];
        } else {
            double fpsRatio = effFps / (double)targetFps;
            if (loopback && rs && ps.framesSent > 0) {
                double r = (double)rs.framesDecoded / (double)ps.framesSent;
                if (r < 0.9) {
                    [notes addObject:[NSString stringWithFormat:
                        @"解码/发送比 %.2f 偏低（丢帧或解码失败）", r]];
                }
            }
            if (fpsRatio < 0.7) {
                [notes addObject:[NSString stringWithFormat:
                    @"有效帧率只有目标的 %.0f%%（合成负载或抓帧瓶颈）", fpsRatio * 100]];
            }
            if (ps.encodeFailures > 0) {
                [notes addObject:[NSString stringWithFormat:
                    @"编码失败 %llu 次", ps.encodeFailures]];
            }
            verdict = (fpsRatio >= 0.7 && (notes.count == 0)) ? @"PASS" : @"DEGRADED";
            if (!loopback && notes.count == 0) verdict = @"PASS";
        }
        printf("  判定     : %s\n", verdict.UTF8String);
        for (NSString *n in notes) printf("    · %s\n", n.UTF8String);

        if (outPath.length > 0) {
            NSMutableDictionary *json = [NSMutableDictionary dictionary];
            json[@"displayID"] = @(displayID);
            json[@"pixelWidth"] = @(pipe.pixelWidth);
            json[@"pixelHeight"] = @(pipe.pixelHeight);
            json[@"durationMs"] = @((int)elapsedMs);
            json[@"targetFps"] = @(targetFps);
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
                    @"decodedWidth": @(decodedW),
                    @"decodedHeight": @(decodedH),
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

        return [verdict isEqualToString:@"FAIL"] ? 2 : 0;
    }
}
