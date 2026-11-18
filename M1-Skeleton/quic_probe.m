//
//  quic_probe.m
//  M1-Skeleton
//
//  M1-A 第 1/2 步验收探针：QUIC 数据报通道 + 指纹钉死（TOFU 锚点）。
//
//  三阶段（每阶段一对独立 listener/client，避免复用连接掩盖问题）：
//    A. 不校验对端 → 连上，读出服务端证书 SHA-256（= TOFU 要钉的那串）
//    B. 用 A 读到的指纹钉死 → 必须连上，随后跑分片投递压测
//    C. 用故意错误的指纹 → 必须握手失败（证明钉死是真的在生效）
//
//  压测把 M1FrameSender 直接接到 QUIC sink 上：走的是与生产完全相同的
//  16B 帧头 + 1150B 分片路径，不是另写一套测试协议。
//
//  用法：
//    ./quic_probe [--frames N] [--frame-bytes N] [--pace-ms N] [--burst N]
//                 [--identity PATH] [--pass PWD] [--json OUT]
//

#import <Foundation/Foundation.h>
#import "M1QuicTransport.h"
#import "M1FrameSender.h"
#import "ProtocolCodec.h"

// 位图按帧的 fragCount 动态分配：v2 起 fragIdx 是 uint16（最多 65535），
// 固定 32B 位图会在 >255 片的帧上越界写。

#pragma mark - 收端统计

@interface M1QuicProbeReceiver : NSObject <M1QuicTransportDelegate>
@property (nonatomic, assign) NSUInteger datagrams;
@property (nonatomic, assign) NSUInteger bytes;
@property (nonatomic, assign) NSUInteger completeFrames;
@property (nonatomic, assign) NSUInteger lostFragments;
@property (nonatomic, assign) NSUInteger absentFrames;      // 一个分片都没到过的帧
@property (nonatomic, assign) NSUInteger expectedFrames;    // 发送端声明要发的帧数
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *fragCountOf;
@property (nonatomic, assign) NSUInteger duplicateFragments;
@property (nonatomic, assign) NSUInteger payloadMismatch;
@property (nonatomic, assign) NSUInteger reordered;
@property (nonatomic, assign) NSUInteger maxFrameSeqSeen;
@property (nonatomic, assign) uint64_t lastKey;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableData *> *fragSeen;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *completedSeq;
@property (nonatomic, assign) BOOL sawReady;
@property (nonatomic, strong) NSDate *firstArrival;
@property (nonatomic, strong) NSDate *lastArrival;
@end

@implementation M1QuicProbeReceiver
- (instancetype)init {
    if ((self = [super init])) {
        _fragSeen = [NSMutableDictionary dictionary];
        _fragCountOf = [NSMutableDictionary dictionary];
        _completedSeq = [NSMutableSet set];
    }
    return self;
}

- (void)quicTransportDidBecomeReady:(M1QuicTransport *)transport {
    if (!transport.isListener) @synchronized (self) { self.sawReady = YES; }
}

- (void)quicTransport:(M1QuicTransport *)transport didReceiveDatagram:(NSData *)datagram {
    P1FrameHeader h;
    NSError *err = nil;
    if (!P1UnpackFrameHeader(datagram, &h, &err)) return;

    @synchronized (self) {
        self.datagrams += 1;
        self.bytes += datagram.length;
        if (!self.firstArrival) self.firstArrival = [NSDate date];
        self.lastArrival = [NSDate date];
        if (h.frameSeq > self.maxFrameSeqSeen) self.maxFrameSeqSeen = h.frameSeq;

        // 乱序：本片 key 小于上一片的 key（同一字节流里不该出现）
        // fragIdx 现在是 uint16，不能再用 frameSeq*1000 拼 key（会撞车）。
        uint64_t key = ((uint64_t)h.frameSeq << 17) | (uint64_t)h.fragIdx;
        if (key < self.lastKey) self.reordered += 1;
        self.lastKey = key;

        if (h.fragIdx >= h.fragCount) return;
        NSNumber *seq = @(h.frameSeq);
        self.fragCountOf[seq] = @(h.fragCount);
        NSMutableData *bitmap = self.fragSeen[seq];
        if (!bitmap) {
            bitmap = [NSMutableData dataWithLength:(NSUInteger)((h.fragCount + 7) / 8)];
            self.fragSeen[seq] = bitmap;
        }
        if (h.fragIdx / 8 >= bitmap.length) return;   // 防御：位图与 fragCount 不一致
        uint8_t *bits = bitmap.mutableBytes;
        uint8_t mask = (uint8_t)(1u << (h.fragIdx % 8));
        if (bits[h.fragIdx / 8] & mask) {
            self.duplicateFragments += 1;
        } else {
            bits[h.fragIdx / 8] |= mask;
        }

        // 载荷自校验：发送端把每个字节都填成 (frameSeq & 0xff)
        if (datagram.length > P1FrameHeaderSize) {
            const uint8_t *p = (const uint8_t *)datagram.bytes + P1FrameHeaderSize;
            NSUInteger n = datagram.length - P1FrameHeaderSize;
            uint8_t expect = (uint8_t)(h.frameSeq & 0xff);
            for (NSUInteger i = 0; i < n; i++) {
                if (p[i] != expect) { self.payloadMismatch += 1; break; }
            }
        }

        // 完整性判定
        if (![self.completedSeq containsObject:seq]) {
            BOOL all = YES;
            NSUInteger need = h.fragCount;
            for (NSUInteger i = 0; i < need; i++) {
                if (!(bits[i / 8] & (uint8_t)(1u << (i % 8)))) { all = NO; break; }
            }
            if (all) {
                [self.completedSeq addObject:seq];
                self.completeFrames += 1;
            }
        }
    }
}

// 收尾统计：区分「整帧一个片都没到」与「帧到了但片不齐」，两者都要报出来。
- (void)finalizeLosses {
    @synchronized (self) {
        if (self.expectedFrames > self.fragSeen.count) {
            self.absentFrames = self.expectedFrames - self.fragSeen.count;
        }
        for (NSNumber *seq in self.fragSeen) {
            if ([self.completedSeq containsObject:seq]) continue;
            NSData *bm = self.fragSeen[seq];
            const uint8_t *bits = bm.bytes;
            NSUInteger need = self.fragCountOf[seq].unsignedIntegerValue;
            for (NSUInteger i = 0; i < need && i < 256; i++) {
                if (!(bits[i / 8] & (uint8_t)(1u << (i % 8)))) self.lostFragments += 1;
            }
        }
    }
}

@end

#pragma mark - 工具

static double NowMs(void) { return [[NSDate date] timeIntervalSince1970] * 1000.0; }

static void PrintSeparator(NSString *title) {
    printf("\n──────── %s ────────\n", title.UTF8String);
}

#pragma mark - 单阶段

// 返回 nil 表示成功，否则返回错误描述。
static NSString *RunPhase(NSString *identity, NSString *pass,
                         BOOL pinned, NSString *expectedFingerprint,
                         BOOL expectReady,
                         NSUInteger frames, NSUInteger frameBytes, NSUInteger paceMs,
                         NSString **observedFingerprint,
                         NSUInteger *outMaxDatagram,
                         M1QuicProbeReceiver *receiver) {
    M1QuicTransport *listener = [[M1QuicTransport alloc] initAsListenerOnPort:0
                                                                        alpn:@"rdp1"
                                                                identityPath:identity
                                                                identityPass:pass
                                                                  verifyPeer:NO];
    listener.delegate = receiver;
    [listener start];
    if (![listener waitUntilReadyTimeoutMs:15000]) {
        return @"listener 未在 15s 内 ready";
    }
    uint16_t port = listener.listenPort;
    printf("  listener 就绪 port=%u\n", (unsigned)port);

    M1QuicTransport *client = [[M1QuicTransport alloc] initAsClientToHost:@"127.0.0.1"
                                                                     port:port
                                                                     alpn:@"rdp1"
                                                             identityPath:nil
                                                             identityPass:nil
                                                               verifyPeer:pinned];
    if (pinned) client.expectedPeerFingerprint = expectedFingerprint;
    client.delegate = receiver;

    double t0 = NowMs();
    [client start];
    BOOL ready = [client waitUntilReadyTimeoutMs:20000];
    double handshakeMs = NowMs() - t0;

    if (!expectReady) {
        BOOL failed = (client.state == M1QuicStateFailed);
        [client cancel];
        [listener cancel];
        if (ready) return @"预期握手失败，但连接成功了（钉死没生效）";
        if (!failed) {
            return [NSString stringWithFormat:
                    @"连接既未就绪也未失败（%.0fms 后仍挂在 preparing）", handshakeMs];
        }
        printf("  握手按预期被拒（%.0fms，状态=failed）\n", handshakeMs);
        return nil;
    }
    if (!ready) {
        [client cancel];
        [listener cancel];
        return [NSString stringWithFormat:@"预期连上但失败：%@",
                client.state == M1QuicStateFailed ? @"握手失败" : @"超时"];
    }
    printf("  握手成功 %.1fms  maxDatagramPayload=%lu\n",
           handshakeMs, (unsigned long)client.maxDatagramPayload);

    if (observedFingerprint) *observedFingerprint = client.peerCertificateSHA256;
    if (outMaxDatagram) *outMaxDatagram = client.maxDatagramPayload;

    // 等对端也 ready（服务端接受连接后要完成握手才能收包）
    for (int i = 0; i < 100 && !receiver.sawReady; i++) {
        [NSThread sleepForTimeInterval:0.05];
    }

    if (frames == 0) {
        [client cancel];
        [listener cancel];
        return nil;
    }

    // 超限拒发：超过协商上限的 datagram 必须被本地拒绝，不能交给 QUIC 静默截断/丢弃
    NSError *bigErr = nil;
    NSData *tooBig = [NSMutableData dataWithLength:3000];
    BOOL bigAccepted = [client sendDatagram:tooBig error:&bigErr];
    printf("  超限拒发（3000B > %luB）: %s\n",
           (unsigned long)client.maxDatagramPayload,
           bigAccepted ? "✗ 被接受（应拒绝）" : "✓ 已拒绝");
    if (bigAccepted) return @"超限 datagram 未被拒绝";

    receiver.expectedFrames = frames;
    M1FrameSender *sender = [[M1FrameSender alloc] initWithSink:client];
    NSError *err = nil;
    double sendStart = NowMs();
    NSUInteger sent = 0;
    for (NSUInteger i = 0; i < frames; i++) {
        uint8_t fill = (uint8_t)(sender.nextFrameSeq & 0xff);
        NSMutableData *payload = [NSMutableData dataWithLength:frameBytes];
        memset(payload.mutableBytes, fill, frameBytes);
        P1FrameFlags flags = (i == 0) ? P1FrameFlagKeyframe : 0;
        if (![sender sendPayload:payload displayID:1 flags:flags error:&err]) {
            printf("  第 %lu 帧投递失败: %s\n", (unsigned long)i,
                   err.localizedDescription.UTF8String);
            break;
        }
        sent += 1;
        if (paceMs) [NSThread sleepForTimeInterval:paceMs / 1000.0];
    }
    double sendMs = NowMs() - sendStart;

    // 等尾部数据落地
    [NSThread sleepForTimeInterval:0.5];

    printf("  发送 %lu 帧 / %llu 分片 / %llu 字节，用时 %.1fms\n",
           (unsigned long)sent,
           (unsigned long long)sender.stats.fragmentsSent,
           (unsigned long long)sender.stats.bytesSent, sendMs);

    [client cancel];
    [listener cancel];
    return nil;
}

#pragma mark - main

int main(int argc, char **argv) {
    @autoreleasepool {
        NSUInteger frames = 300;
        NSUInteger frameBytes = 3000;
        NSUInteger paceMs = 5;
        NSUInteger burst = 500;
        NSString *identity = @".state/rdp-identity.p12";
        NSString *pass = @"rdpdev";
        NSString *jsonPath = nil;

        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--frames") && i + 1 < argc) frames = (NSUInteger)atoi(argv[++i]);
            else if (!strcmp(argv[i], "--frame-bytes") && i + 1 < argc) frameBytes = (NSUInteger)atoi(argv[++i]);
            else if (!strcmp(argv[i], "--pace-ms") && i + 1 < argc) paceMs = (NSUInteger)atoi(argv[++i]);
            else if (!strcmp(argv[i], "--burst") && i + 1 < argc) burst = (NSUInteger)atoi(argv[++i]);
            else if (!strcmp(argv[i], "--identity") && i + 1 < argc) identity = @(argv[++i]);
            else if (!strcmp(argv[i], "--pass") && i + 1 < argc) pass = @(argv[++i]);
            else if (!strcmp(argv[i], "--json") && i + 1 < argc) jsonPath = @(argv[++i]);
            else {
                fprintf(stderr,
                    "用法: quic_probe [--frames N] [--frame-bytes N] [--pace-ms N] [--burst N]\n"
                    "                 [--identity PATH] [--pass PWD] [--json OUT]\n");
                return 2;
            }
        }

        printf("=== M1-A 第1/2步：QUIC 数据报通道 + 指纹钉死 ===\n");
        printf("  身份=%s  帧数=%lu  每帧=%luB  节奏=%lums\n",
               identity.UTF8String, (unsigned long)frames,
               (unsigned long)frameBytes, (unsigned long)paceMs);

        NSString *fp = nil;
        NSUInteger maxDg = 0;
        int rc = 0;
        NSMutableDictionary *report = [NSMutableDictionary dictionary];
        report[@"identity"] = identity;
        report[@"frames"] = @(frames);
        report[@"frameBytes"] = @(frameBytes);

        // ── 阶段 A：不校验，读出指纹
        PrintSeparator(@"A. 不校验对端（读出 TOFU 指纹）");
        M1QuicProbeReceiver *recA = [M1QuicProbeReceiver new];
        NSString *errA = RunPhase(identity, pass, NO, nil, YES, 0, frameBytes, 0, &fp, &maxDg, recA);
        if (errA) {
            printf("  ✗ %s\n", errA.UTF8String);
            rc = 10;
        } else {
            printf("  服务端证书 SHA-256 = %s\n", fp.UTF8String ?: "(nil)");
            report[@"phaseA"] = @{@"ok": @YES, @"fingerprint": fp ?: @"", @"maxDatagram": @(maxDg)};
        }

        // ── 阶段 B：钉死指纹 + 压测
        if (rc == 0) {
            PrintSeparator(@"B. 指纹钉死 + 分片投递压测");
            M1QuicProbeReceiver *recB = [M1QuicProbeReceiver new];
            NSString *errB = RunPhase(identity, pass, YES, fp, YES, frames, frameBytes, paceMs,
                                      NULL, NULL, recB);
            [recB finalizeLosses];
            if (errB) {
                printf("  ✗ %s\n", errB.UTF8String);
                rc = 11;
                report[@"phaseB"] = @{@"ok": @NO, @"error": errB};
            } else {
                double spanMs = [recB.lastArrival timeIntervalSinceDate:recB.firstArrival] * 1000.0;
                double kbps = spanMs > 0 ? (recB.bytes * 8.0 / 1000.0) / (spanMs / 1000.0) : 0;
                printf("  收到 %lu datagram / %lu 字节\n",
                       (unsigned long)recB.datagrams, (unsigned long)recB.bytes);
                printf("  完整帧 %lu / %lu  整帧未到 %lu  缺片 %lu  重复片 %lu  乱序 %lu  载荷错 %lu\n",
                       (unsigned long)recB.completeFrames, (unsigned long)frames,
                       (unsigned long)recB.absentFrames,
                       (unsigned long)recB.lostFragments, (unsigned long)recB.duplicateFragments,
                       (unsigned long)recB.reordered, (unsigned long)recB.payloadMismatch);
                printf("  到达跨度 %.1fms  实测 %.0f kbps\n", spanMs, kbps);
                BOOL pass = (recB.completeFrames == frames) &&
                            (recB.absentFrames == 0) &&
                            (recB.lostFragments == 0) &&
                            (recB.duplicateFragments == 0) &&
                            (recB.payloadMismatch == 0);
                printf("  %s\n", pass ? "✓ 通过" : "✗ 未达标");
                if (!pass) rc = 12;
                report[@"phaseB"] = @{
                    @"ok": @(pass),
                    @"datagrams": @(recB.datagrams),
                    @"bytes": @(recB.bytes),
                    @"completeFrames": @(recB.completeFrames),
                    @"absentFrames": @(recB.absentFrames),
                    @"lostFragments": @(recB.lostFragments),
                    @"duplicateFragments": @(recB.duplicateFragments),
                    @"reordered": @(recB.reordered),
                    @"payloadMismatch": @(recB.payloadMismatch),
                    @"spanMs": @(spanMs),
                    @"kbps": @(kbps),
                };
            }
        }

        // ── 阶段 C：错误指纹必须被拒
        if (rc == 0) {
            PrintSeparator(@"C. 错误指纹必须握手失败");
            M1QuicProbeReceiver *recC = [M1QuicProbeReceiver new];
            NSString *wrong = @"0000000000000000000000000000000000000000000000000000000000000000";
            NSString *errC = RunPhase(identity, pass, YES, wrong, NO, 0, 0, 0, NULL, NULL, recC);
            if (errC) {
                printf("  ✗ %s\n", errC.UTF8String);
                rc = 13;
                report[@"phaseC"] = @{@"ok": @NO, @"error": errC};
            } else {
                printf("  ✓ 钉死生效：错误指纹被拒\n");
                report[@"phaseC"] = @{@"ok": @YES};
            }
        }

        // ── burst：短时间内连发，观察 QUIC datagram 的丢弃行为（信息性，不计入通过条件）
        if (rc == 0 && burst > 0) {
            PrintSeparator(@"D. 突发投递（信息性：观测 datagram 在拥塞窗口满时的丢弃）");
            M1QuicProbeReceiver *recD = [M1QuicProbeReceiver new];
            NSUInteger burstFrames = burst;
            NSUInteger burstBytes = 1150 - P1FrameHeaderSize;
            NSString *errD = RunPhase(identity, pass, YES, fp, YES, burstFrames, burstBytes, 0,
                                      NULL, NULL, recD);
            [recD finalizeLosses];
            if (errD) {
                printf("  ✗ %s\n", errD.UTF8String);
            } else {
                printf("  突发 %lu 帧 → 完整 %lu  整帧未到 %lu  缺片 %lu  乱序 %lu\n",
                       (unsigned long)burstFrames, (unsigned long)recD.completeFrames,
                       (unsigned long)recD.absentFrames,
                       (unsigned long)recD.lostFragments, (unsigned long)recD.reordered);
                report[@"phaseD"] = @{
                    @"ok": @YES,
                    @"sent": @(burstFrames),
                    @"complete": @(recD.completeFrames),
                    @"absentFrames": @(recD.absentFrames),
                    @"lostFragments": @(recD.lostFragments),
                    @"reordered": @(recD.reordered),
                };
            }
        }

        report[@"rc"] = @(rc);
        if (jsonPath) {
            NSData *json = [NSJSONSerialization dataWithJSONObject:report
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:NULL];
            [json writeToFile:jsonPath atomically:YES];
            printf("\nJSON 已写入 %s\n", jsonPath.UTF8String);
        }
        printf("\n退出码 %d\n", rc);
        return rc;
    }
}
