//
//  stream_probe.m
//  M1-Skeleton
//
//  M1-A 第 4 步验收 + M1-B 第 1 步：跨进程推流落盘 / 上屏 + 输入回传。
//
//    host   : SCK 采集 → VT 编码 → M1FrameSender → QUIC datagram
//             ← input 事件 → M1InjectionPlan → M1InputInjector（record/real）
//    client : QUIC datagram → M1FrameReceiver 重组 → VT 解码 → PNG / 窗口上屏
//             窗口鼠标键盘 → 归一化 → input 事件 → 控制通道
//
//  关键点（D-14 C-14.2）：控制帧与视频帧**共用同一条 datagram 连接**，靠首字节魔数分流：
//    0x43 'C'  → M1ControlLink（seq/ACK 自建可靠性）→ M1ControlChannel → M1ControlSession
//    0x4D 'M'  → 帧分片（P1FrameMagic = 0x4D52 'MR'）→ M1FrameReceiver
//  这条分流正是 M1-C 要验证的前提：推流时 1s 心跳不能被视频帧挤掉。
//
//  用法：
//    ./stream_probe --host [--port N] [--port-file PATH] [--duration-ms N]
//                     [--display ID] [--fps N] [--inject record|real] [--out JSON]
//    ./stream_probe --client --port N --fingerprint HEX [--duration-ms N]
//                     [--outdir DIR] [--save-frames N] [--window [WxH]]
//                     [--port-file PATH] [--out JSON]
//
//    --window  : 起 NSWindow 把解码帧直接画到屏幕上，并采集鼠标/键盘回传 Host。
//    --inject  : record（默认，只记录注入计划，单机环回不干扰真实桌面）
//                real  （真 CGEventPost，双机验收用）
//
//  验收判据：
//    1. 双端到达 STREAMING，且状态序列逐条一致
//    2. 客户端解出画面帧数 > 0，且 decoded/sent ≥ 0.9
//    3. 推流期间控制通道最大到达间隔 < 3s（心跳 1s，容许 3 倍抖动）
//    4. PNG 落盘可肉眼验
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import "ProtocolCodec.h"
#import "M1QuicTransport.h"
#import "M1ControlLink.h"
#import "M1ControlChannel.h"
#import "M1ControlSession.h"
#import "M1FramePipeline.h"
#import "M1FrameReceiver.h"
#import "M1VideoEncoder.h"
#import "M1FrameView.h"
#import "M1InputInjector.h"
#import "M1SessionCoordinator.h"
#import "M1RDPDriver.h"
#import "P0VDisplayControl.h"
#import "M1StreamSession.h"

static NSString *gIdentity = @".state/rdp-identity.p12";
static NSString *gPass = @"rdpdev";



#pragma mark - 主流程


// 诊断：把传输层 / 链路层统计和控制包到达时间线打出来。
// 「心跳是否被推流挤掉」只能靠这两组数据判断——单看最大间隔无法区分
// 「发送端就没发出去」和「发出去了但在链路上丢了」。
static void AddTransportStats(NSMutableDictionary *json, M1QuicTransportStats *ts) {
    json[@"transportSent"] = @(ts.datagramsSent);
    json[@"transportReceived"] = @(ts.datagramsReceived);
    json[@"transportSendErrors"] = @(ts.sendErrors);
    json[@"transportSendQueued"] = @(ts.sendQueued);
    json[@"transportSendQueueDrops"] = @(ts.sendQueueDrops);
    json[@"transportSendInFlightMax"] = @(ts.sendInFlightMax);
    json[@"transportSendCompletionAvgMs"] = @(round(ts.sendCompletionAvgMs * 10) / 10.0);
    json[@"transportSendCompletionMaxMs"] = @(round(ts.sendCompletionMaxMs * 10) / 10.0);
}

static void PrintFlowStats(M1StreamNode *n, const char *tag) {
    M1QuicTransportStats *ts = n.streamConn.stats;
    printf("  %s 传输: sent=%llu recv=%llu sendErr=%llu queued=%llu qdrop=%llu "
           "inFlightMax=%llu txDone=%.1f/%.1fms | 链路: sent=%lu delivered=%lu "
           "retrans=%lu dup=%lu ooo=%lu acks=%lu\n",
           tag, ts.datagramsSent, ts.datagramsReceived, ts.sendErrors,
           ts.sendQueued, ts.sendQueueDrops, ts.sendInFlightMax,
           ts.sendCompletionAvgMs, ts.sendCompletionMaxMs,
           (unsigned long)n.link.sentMessages, (unsigned long)n.link.deliveredMessages,
           (unsigned long)n.link.retransmits, (unsigned long)n.link.duplicatesSeen,
           (unsigned long)n.link.heldOutOfOrder, (unsigned long)n.link.acksReceived);
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSArray<NSNumber *> *arrivals;
    @synchronized (n.controlArrivals) { arrivals = [n.controlArrivals copy]; }
    for (NSNumber *v in arrivals) [parts addObject:v.stringValue];
    printf("  %s 控制到达(ms): %s\n", tag, [parts componentsJoinedByString:@","].UTF8String);
}

// ---- P2 双机对接：本机能力自检 ----
// 为什么放在 stream_probe 里而不是单独写个工具：屏幕录制与辅助功能授权是按
// 「可执行文件的 code requirement」记的，换一个二进制查出来的结果不代表本二进制
// （已踩过：同一份源码重建后 AX 从 1 变 0）。所以必须由真正干活的那个进程自查。

// --advertise HOST[:PORT]：跨网段/NAT 时防火墙映射出来的「对外端点」。
// 只改「给客户端的三项」和 JSON 里的展示，不改本机实际监听（永远 0.0.0.0:PORT）。
// 外部端口可以与内部端口不同，客户端用 --port 单独指定映射后的端口。
static BOOL P2ParseAdvertise(NSString *spec, NSString **outHost, uint16_t *outPort) {
    if (spec.length == 0) return NO;
    NSString *h = spec;
    uint16_t p = 0;
    NSRange colon = [spec rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location != NSNotFound && colon.location + 1 < spec.length) {
        NSString *tail = [spec substringFromIndex:colon.location + 1];
        int n = atoi(tail.UTF8String);
        if (n > 0 && n <= 65535) {
            h = [spec substringToIndex:colon.location];
            p = (uint16_t)n;
        }
    }
    if (h.length == 0) return NO;
    if (outHost) *outHost = h;
    if (outPort) *outPort = p;
    return YES;
}

// 本机可对接的 IPv4（排除回环与 169.254 自分配地址）。
static NSArray<NSString *> *P2LANAddresses(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    struct ifaddrs *head = NULL;
    if (getifaddrs(&head) != 0) return out;
    for (struct ifaddrs *p = head; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        if (!(p->ifa_flags & IFF_UP) || (p->ifa_flags & IFF_LOOPBACK)) continue;
        char buf[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *sin = (struct sockaddr_in *)p->ifa_addr;
        if (!inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) continue;
        NSString *ip = [NSString stringWithUTF8String:buf];
        if ([ip hasPrefix:@"169.254."]) continue;   // 自分配地址，跨机基本连不通
        [out addObject:[NSString stringWithFormat:@"%@(%s)", ip, p->ifa_name]];
    }
    freeifaddrs(head);
    return out;
}

// 返回 0 = 就绪。输出 `[preflight] k=v` 行，脚本只认最后那行 ok=。
static int P2RunPreflight(NSString *role, BOOL needAX, NSString *advertise) {
    BOOL ax = AXIsProcessTrusted();
    BOOL capture = CGPreflightScreenCaptureAccess();
    uint32_t activeCount = 0;
    CGGetActiveDisplayList(0, NULL, &activeCount);

    CFDictionaryRef sess = CGSessionCopyCurrentDictionary();
    NSDictionary *sd = (__bridge_transfer NSDictionary *)sess;
    BOOL locked = [sd[@"CGSSessionScreenIsLocked"] boolValue];
    BOOL onConsole = sd.count > 0 && [sd[@"kCGSSessionOnConsoleKey"] boolValue];
    BOOL asleep = CGDisplayIsAsleep(CGMainDisplayID());

    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    if (!onConsole) [fails addObject:@"不在控制台 GUI 会话（SSH 里跑不了采集/上屏）"];
    if (locked)     [fails addObject:@"屏幕已锁定：SCK 拿不到 display，窗口也收不到输入"];
    if (asleep)     [fails addObject:@"显示器已睡眠：先 caffeinate -d -u"];
    if (activeCount == 0) [fails addObject:@"没有 active 显示器"];
    if ([role isEqualToString:@"host"]) {
        if (!capture) [fails addObject:@"缺屏幕录制授权（系统设置→隐私与安全性→屏幕录制）"];
        if (needAX && !ax) [fails addObject:@"缺辅助功能授权（--inject real 需要）"];
    }

    printf("[preflight] role=%s\n", role.UTF8String);
    printf("[preflight] ax=%d capture=%d locked=%d asleep=%d onConsole=%d active=%u\n",
           (int)ax, (int)capture, (int)locked, (int)asleep, (int)onConsole, activeCount);
    printf("[preflight] proto frameHeaderVersion=%u headerSize=%lu maxPayload=%lu\n",
           (unsigned)P1FrameHeaderVersion, (unsigned long)P1FrameHeaderSize,
           (unsigned long)P1FrameMaxPayload);
    for (NSString *ip in P2LANAddresses()) printf("[preflight] ip=%s\n", ip.UTF8String);
    if (advertise.length) printf("[preflight] advertise=%s\n", advertise.UTF8String);
    else printf("[preflight] advertise=（未设置；跨网段请传 --advertise 公网IP[:映射端口]）\n");
    for (NSString *f in fails) printf("[preflight] fail=%s\n", f.UTF8String);
    printf("[preflight] ok=%d\n", fails.count == 0 ? 1 : 0);
    return fails.count == 0 ? 0 : 1;
}

static void PrintUsage(void) {
    fprintf(stderr,
        "用法:\n"
        "  stream_probe --host [--port N] [--port-file PATH] [--duration-ms N]\n"
        "                    [--display ID] [--fps N] [--out JSON] [--spec WxH]\n"
        "                    [--width N] [--height N]       # 编码输出尺寸（镜像模式降分辨率用）\n"
        "                    [--keep-main]               # 诊断：保留物理主屏，不满足 C-09\n"
        "                    [--mirror]                  # 诊断：采物理主屏（默认是按客户端规格建虚拟屏+禁物理屏）\n"
        "                    [--sim-loss PCT] [--sim-reorder PCT] # 发送端丢片/乱序模拟\n"
        "                    [--advertise HOST[:PORT]]   # 跨网段/NAT：防火墙映射后的对外端点\n"
        "                    [--wait-ms N]               # host 等客户端 / client 等 STREAMING（默认 15000；0 = 一直等）\n"
        "  stream_probe --preflight host|client [--inject real] [--advertise HOST[:PORT]]\n"
        "                                                        # 本机能力自检\n"
        "  stream_probe --client --connect IP --port N --fingerprint HEX [--duration-ms N]\n"
        "                    [--outdir DIR] [--save-frames N] [--out JSON]\n"
        "                    [--window [WxH]] [--spec WxH] [--keep-front] [--input-synth \"X,Y;X,Y;...\"]\n"
        "                    [--manual SECS] [--handshake-ms N]   # 握手超时默认 12000\n"
        "  --input-synth: 进程内合成鼠标移动（内容坐标，左上原点），\n"
        "                 用于驱动端没有辅助功能授权、无法投递系统事件时。\n"
        "  --manual:      不造事件，改为给出「立刻动鼠标」的提示（响铃 3 声 + 窗口标题 +\n"
        "                 倒计时日志），由真人去操作，SECS 秒后提示停手。\n");
}

// 手动驱动提示：自动化里驱动不了「真人动鼠标」这一跳——真光标要么被前台应用抢走，
// 要么打进 letterbox 黑边。这里反过来：代码只负责给出无歧义的开始/结束信号，
// 由人真的去操作。信号三路冗余（响铃 / 窗口标题 / 日志）：操作的人可能在看窗口
// 而不看终端，也可能终端被滚屏淹没。
static void M1StartManualCue(NSWindow *win, M1FrameView *view,
                             M1ControlSession *session, int secs) {
    static BOOL started = NO;
    if (started || secs <= 0 || !win || !view) return;  // 首帧回调与兜底定时器都会调，只认第一次
    started = YES;

    for (int i = 0; i < 3; i++) NSBeep();
    win.title = [NSString stringWithFormat:
                 @"▶▶ 现在动鼠标：点一下窗口，在画面里左右划 %d 秒", secs];
    printf("\n[manual] ================ 开始：现在动鼠标 ================\n");
    printf("[manual] ① 先点一下这个客户端窗口（要它成为前台应用，否则系统不投递移动事件）\n");
    printf("[manual] ② 在画面区域里左右慢慢划，别停在上下黑边上\n");
    printf("[manual] ③ %d 秒后自动结束（再响一声），窗口标题里有倒计时\n", secs);
    printf("[manual] =====================================================\n");
    fflush(stdout);

    for (int s = 1; s <= secs; s++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            int left = secs - s;
            // 实测反应延迟有 7s 左右（第一轮 18s 里前 7s 采集一直是 0 条）：
            // 一条都没收到就每 5 秒再提醒一次，别让人错过那三声。
            BOOL idle = (view.inputEventsEmitted == 0);
            if (idle && left > 0 && (s % 5) == 0) {
                NSBeep(); NSBeep();
                printf("[manual] （还没收到任何移动——点一下窗口，在里面划两下）\n");
            }
            win.title = [NSString stringWithFormat:@"%@▶▶ 动鼠标（剩 %d 秒）· 已采集 %lu 条",
                         idle ? @"？" : @"", left, (unsigned long)view.inputEventsEmitted];
            printf("[manual] 剩 %2d 秒 · 窗口采集 %lu 条 · 已上行 %lu 条\n", left,
                   (unsigned long)view.inputEventsEmitted,
                   (unsigned long)session.inputEventsSent);
            fflush(stdout);
            if (left <= 0) {
                NSBeep();
                win.title = @"✓ 时间到，可以停手了（等收尾统计）";
                printf("[manual] ================ 时间到，停手 ================\n");
                fflush(stdout);
            }
        });
    }
}

static NSData *JSONData(NSDictionary *dict) {
    return [NSJSONSerialization dataWithJSONObject:dict
                                           options:NSJSONWritingPrettyPrinted
                                             error:NULL];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        // ★ 守护模式必须最先处理：P0VStartGuardian 用同一个二进制 re-exec。
        //   缺这一段时守护子进程会打印用法后退出，父进程却以为有兜底——
        //   2026-11-18 的黑屏事故就是这么来的（见 pipeline_kiosk_probe 同段注释）。
        if (argc > 1 && strcmp(argv[1], "--guardian") == 0) {
            NSString *snap = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : nil;
            pid_t parent = 0;
            for (int i = 3; i + 1 < argc; i++) {
                if (strcmp(argv[i], "--parent-pid") == 0) parent = atoi(argv[i + 1]);
            }
            if (!snap || parent <= 0) return 3;
            return P0VRunGuardian(snap, parent);
        }

        setvbuf(stdout, NULL, _IOLBF, 0);   // 后台运行 + 被回收时不丢日志
        BOOL hostMode = NO, clientMode = NO;
        uint16_t port = 0;
        NSString *portFile = nil;
        NSString *outPath = nil;
        NSString *outdir = nil;
        NSString *fingerprint = nil;
        int durationMs = 5000;
        // 跨网段/NAT 下 QUIC Initial 可能被防火墙拖慢或丢一次；15s/12s 是同网段
        // 基线值，改成可配置，避免「映射其实通了但等待窗口太短」的假失败。
        uint32_t waitMs = 15000;
        uint32_t handshakeTimeoutMs = 12000;
        int fps = 20;
        CGDirectDisplayID displayID = CGMainDisplayID();
        NSUInteger saveFrames = 5;
        double bpp = 0.12;
        int32_t outW = 0, outH = 0;
        BOOL windowMode = NO;
        double windowW = 1280, windowH = 720;
        NSString *injectMode = nil;   // nil / record / real
        NSString *synthSpec = nil;    // "X,Y;X,Y" 内容坐标（左上原点）
        BOOL windowTop = NO;
        BOOL keepFront = NO;
        int manualSecs = 0;           // >0：不造事件，改为提示真人动鼠标 SECS 秒
        NSString *connectHost = @"127.0.0.1";   // 双机时改成对端的公网/跨网段地址
        NSString *advertiseSpec = nil;          // host 对外端点（NAT/防火墙映射后）
        NSString *preflightRole = nil;          // host / client：只做本机能力自检后退出
        int32_t specW = 0, specH = 0;           // 客户端请求的推流规格（host 建虚拟屏用）
        BOOL exclusive = YES;                   // host：默认按客户端规格建虚拟屏并禁物理屏（D-04/D-08）
        BOOL keepMain = NO;                      // 诊断：保留物理主屏，不满足 C-09
        double simLossPct = 0, simReorderPct = 0; // host 发送端故障注入

        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--host")) hostMode = YES;
            else if (!strcmp(argv[i], "--client")) clientMode = YES;
            else if (!strcmp(argv[i], "--port") && i + 1 < argc) port = (uint16_t)atoi(argv[++i]);
            else if (!strcmp(argv[i], "--port-file") && i + 1 < argc)
                portFile = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--duration-ms") && i + 1 < argc) durationMs = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--fps") && i + 1 < argc) fps = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--display") && i + 1 < argc)
                displayID = (CGDirectDisplayID)strtoul(argv[++i], NULL, 10);
            else if (!strcmp(argv[i], "--out") && i + 1 < argc)
                outPath = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--outdir") && i + 1 < argc)
                outdir = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--save-frames") && i + 1 < argc)
                saveFrames = (NSUInteger)atoi(argv[++i]);
            else if (!strcmp(argv[i], "--fingerprint") && i + 1 < argc)
                fingerprint = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--identity") && i + 1 < argc)
                gIdentity = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--pass") && i + 1 < argc)
                gPass = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--bpp") && i + 1 < argc) bpp = atof(argv[++i]);
            else if (!strcmp(argv[i], "--width") && i + 1 < argc) outW = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--height") && i + 1 < argc) outH = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--inject") && i + 1 < argc)
                injectMode = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--input-synth") && i + 1 < argc)
                synthSpec = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--manual") && i + 1 < argc)
                manualSecs = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--spec") && i + 1 < argc) {
                int w = 0, h = 0;
                if (sscanf(argv[++i], "%dx%d", &w, &h) == 2 && w > 0 && h > 0) {
                    specW = w; specH = h;
                }
            }
            else if (!strcmp(argv[i], "--exclusive")) exclusive = YES;
            else if (!strcmp(argv[i], "--mirror")) exclusive = NO;  // 诊断：采物理主屏（旧默认）
            else if (!strcmp(argv[i], "--keep-main")) keepMain = YES;
            else if (!strcmp(argv[i], "--sim-loss") && i + 1 < argc)
                simLossPct = atof(argv[++i]);
            else if (!strcmp(argv[i], "--sim-reorder") && i + 1 < argc)
                simReorderPct = atof(argv[++i]);
            else if (!strcmp(argv[i], "--connect") && i + 1 < argc)
                connectHost = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--advertise") && i + 1 < argc)
                advertiseSpec = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--wait-ms") && i + 1 < argc)
                waitMs = (uint32_t)atoi(argv[++i]);
            else if (!strcmp(argv[i], "--handshake-ms") && i + 1 < argc)
                handshakeTimeoutMs = (uint32_t)atoi(argv[++i]);
            else if (!strcmp(argv[i], "--preflight")) {
                preflightRole = (i + 1 < argc && argv[i + 1][0] != '-')
                              ? [NSString stringWithUTF8String:argv[++i]] : @"host";
            }
            else if (!strcmp(argv[i], "--keep-front")) {
                // 自动化验证用：WindowServer 只把 mouseMoved 投给「前台应用」，
                // 窗口 visible/key/active 全 1 也可能被别的 App 抢回前台
                // （实测脚本跑的时候 frontmost=Chrome，一条 move 都收不到）。
                keepFront = YES;
            }
            else if (!strcmp(argv[i], "--window-top")) {
                // 自动化验证用：把客户端窗口抬到浮动层，避免测试期间被别的
                // 应用窗口盖住——窗口一旦被遮，WindowServer 就不投递 mouseMoved。
                windowTop = YES;
            }
            else if (!strcmp(argv[i], "--window")) {
                windowMode = YES;
                // 可选 --window 1600x900；不给就 1280x720。
                if (i + 1 < argc && strchr(argv[i + 1], 'x') && isdigit(argv[i + 1][0])) {
                    int w = 0, h = 0;
                    if (sscanf(argv[++i], "%dx%d", &w, &h) == 2 && w > 0 && h > 0) {
                        windowW = w; windowH = h;
                    }
                }
            }
            else { PrintUsage(); return 1; }
        }
        if (preflightRole) {
            return P2RunPreflight(preflightRole, [injectMode isEqualToString:@"real"], advertiseSpec);
        }
        if (!hostMode && !clientMode) { PrintUsage(); return 1; }

        // 进程级 VT 预热：与后面的握手并发进行。首次会话初始化实测 0.3~1.5s，
        // 不预热就整段压在首帧延迟上。按角色只预热本端要用的那一侧，
        // 避免主机/客户端两个方向混在一起测不出各自收益。
        // 用 UTILITY：预热本身不急，不能和握手/首帧采集抢 CPU（i5 上实测会反噬）。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (hostMode) [M1VideoEncoder prewarm];
            else          [M1FrameReceiver prewarmDecoder];
        });

        if (hostMode) {
            NSError *err = nil;
            NSString *localFp = M1QuicIdentityFingerprint(gIdentity, gPass, &err);
            if (localFp.length == 0) {
                printf("✗ 读不到身份指纹: %s\n",
                       err.localizedDescription.UTF8String ?: "unknown");
                return 3;
            }

            M1StreamNode *host = [M1StreamNode new];
            host.identityPath = gIdentity;
            host.identityPass = gPass;
            host.localFingerprint = localFp;
            host.fps = fps;
            host.simLossPct = simLossPct;
            host.simReorderPct = simReorderPct;

            __block M1SessionCoordinator *exclusiveCoordinator = nil;
            __block CGDirectDisplayID virtualDisplayID = 0;
            __block NSUInteger virtualW = 0, virtualH = 0;
            __block BOOL exclusiveEnded = NO;
            // C-09 / 恢复证据：随 host.json 落盘，供 summary 与现场核对。
            __block M1RDPDriver *exclusiveDriver = nil;
            __block NSArray<NSNumber *> *exclusiveDisplayIDs = nil;  // 本会话新建的虚拟屏
            __block NSArray<NSNumber *> *exclusiveActiveIDs = nil;   // 禁屏后 active 屏
            __block NSString *exclusiveC09Status = @"not-started";  // verified / skipped-keep-main
            __block NSString *exclusivePhaseAtReady = nil;          // 建屏后的会话阶段
            __block BOOL exclusiveRecoveryOK = YES;
            __block NSDictionary *exclusiveWindowRestore = nil;     // 窗口布局搬回摘要

            // 独占会话（P2.2）：在 session-start 到达时同步建虚拟屏/禁物理屏，
            // 让 session-ready 带的是真实 displayID；失败会回 session-error 并结束会话。
            if (exclusive) {
                printf("独占会话模式：session-start 到达后建虚拟屏%s\n",
                       keepMain ? "（诊断：保留物理主屏，不满足 C-09）" : "并禁用全部物理屏");
                host.displayProvider = ^NSArray<NSDictionary *> *(NSDictionary *message, NSError **perr) {
                    NSArray *specs = message[@"specs"];
                    if (![specs isKindOfClass:[NSArray class]] || specs.count == 0) {
                        if (perr) *perr = [NSError errorWithDomain:@"streamprobe" code:6
                            userInfo:@{NSLocalizedDescriptionKey: @"session-start 缺 specs"}];
                        return nil;
                    }
                    NSMutableArray<NSDictionary *> *conv = [NSMutableArray array];
                    for (NSDictionary *sp in specs) {
                        NSNumber *w = sp[@"w"], *h = sp[@"h"];
                        if (![w isKindOfClass:[NSNumber class]] || ![h isKindOfClass:[NSNumber class]]) continue;
                        [conv addObject:@{ @"width": w, @"height": h }];
                    }
                    if (conv.count == 0) {
                        if (perr) *perr = [NSError errorWithDomain:@"streamprobe" code:6
                            userInfo:@{NSLocalizedDescriptionKey: @"session-start 缺可用宽度/高度"}];
                        return nil;
                    }
                    // 保留 driver 引用：C-09 校验结果（active 屏快照）在它身上，
                    // session-start 之后才能读到；json 收尾时统一落盘。
                    exclusiveDriver = [M1RDPDriver new];
                    M1SessionCoordinator *coord =
                        [[M1SessionCoordinator alloc] initWithDriver:exclusiveDriver];
                    coord.locksScreenOnEnd = NO;   // 探针连续测量；锁屏会打断远程操作
                    if (keepMain) coord.extraKeepDisplayIDs = @[ @(CGMainDisplayID()) ];
                    NSError *startErr = nil;
                    if (![coord startWithSpecs:conv needsLogin:NO credential:nil error:&startErr]) {
                        // Coordinator 内部已做 best-effort 恢复；这里只清引用，避免误触发
                        // endExclusive 对未成功的会话再恢复一次。
                        exclusiveDriver = nil;
                        if (perr) *perr = startErr;
                        return nil;
                    }
                    NSArray<NSNumber *> *ids = coord.createdDisplayIDs;
                    if (ids.count == 0) {
                        NSError *endErr = nil;
                        [coord endSessionError:&endErr];
                        exclusiveDriver = nil;
                        if (perr) *perr = [NSError errorWithDomain:@"streamprobe" code:6
                            userInfo:@{NSLocalizedDescriptionKey: @"建屏成功但没有 displayID"}];
                        return nil;
                    }
                    exclusiveCoordinator = coord;
                    exclusiveEnded = NO;   // 新一次会话：上一轮失败时已置 YES
                    exclusiveRecoveryOK = YES;
                    exclusiveDisplayIDs = [ids copy];
                    exclusiveActiveIDs = [exclusiveDriver.lastActiveDisplayIDs copy] ?: @[];
                    // keepMain 保留了物理主屏，Coordinator 明确跳过 C-09；不能谎报已校验。
                    exclusiveC09Status = keepMain ? @"skipped-keep-main" : @"verified";
                    exclusivePhaseAtReady = M1HostSessionPhaseName(coord.phase);
                    virtualDisplayID = ids.firstObject.unsignedIntValue;
                    virtualW = [conv.firstObject[@"width"] unsignedIntegerValue];
                    virtualH = [conv.firstObject[@"height"] unsignedIntegerValue];
                    NSMutableArray<NSDictionary *> *displays = [NSMutableArray array];
                    for (NSUInteger i = 0; i < ids.count; i++) {
                        NSNumber *w = i < conv.count ? conv[i][@"width"] : @0;
                        NSNumber *h = i < conv.count ? conv[i][@"height"] : @0;
                        [displays addObject:@{ @"displayID": ids[i], @"w": w, @"h": h,
                                               @"synthetic": @NO }];
                    }
                    printf("  [独占] 虚拟屏就绪 ids=%s  phase=%s  physicalDisabled=%s\n",
                           [[displays valueForKey:@"displayID"] componentsJoinedByString:@","].UTF8String,
                           exclusivePhaseAtReady.UTF8String,
                           keepMain ? "保留主屏" : "是");
                    printf("  [独占] C-09=%s  禁屏后 active=%s\n",
                           exclusiveC09Status.UTF8String,
                           [[exclusiveActiveIDs description] UTF8String] ?: "[]");
                    fflush(stdout);
                    return displays;
                };
            }

            // onAttemptFailed 由 host 持有，里面又会调 endExclusive：
            // 两个 block 都通过 weakHost 上锁，避免 host → block → host 环。
            __weak M1StreamNode *weakHost = host;
            void (^endExclusive)(void) = ^{
                M1StreamNode *syncHost = weakHost;
                if (!syncHost) return;
                @synchronized (syncHost) {
                    if (exclusiveEnded || !exclusiveCoordinator) return;
                    exclusiveEnded = YES;
                    M1SessionCoordinator *coord = exclusiveCoordinator;
                    exclusiveCoordinator = nil;
                    NSError *endErr = nil;
                    exclusiveRecoveryOK = [coord endSessionError:&endErr];
                    exclusiveWindowRestore = [exclusiveDriver.lastWindowRestoreSummary copy];
                    if (!exclusiveRecoveryOK) {
                        printf("  [独占] 恢复失败: %s\n",
                               endErr.localizedDescription.UTF8String ?: "unknown");
                    } else {
                        printf("  [独占] 已恢复物理屏并销毁虚拟屏\n");
                    }
                    exclusiveDriver = nil;
                    fflush(stdout);
                }
            };
            // 无限等待模式：单次接入失败后清掉独占显示状态，下一次 session-start
            // 会重建虚拟屏；不要把上一次失败的 displayID 带进下一次采集。
            host.onAttemptFailed = ^{
                M1StreamNode *host = weakHost;
                if (!host) return;
                @synchronized (host) {
                    endExclusive();
                    virtualDisplayID = 0;
                    virtualW = 0; virtualH = 0;
                    exclusiveDisplayIDs = nil;
                    exclusiveActiveIDs = nil;
                    exclusivePhaseAtReady = nil;
                    if (exclusive) exclusiveC09Status = @"attempt-failed-recovered";
                }
            };

            if (![host startAsHostOnPort:port error:&err]) {
                printf("✗ listener 启动失败: %s\n", err.localizedDescription.UTF8String);
                return 3;
            }
            printf("host 监听端口 %u\n", host.port);
            printf("  证书指纹 %s\n", localFp.UTF8String);
            // 双机对接要人工把这三项抄到另一台机器上，单独打一块免得漏。
            // 跨网段时这里必须是「防火墙映射后的对外地址」，而不是本机内网 IP。
            NSString *advHost = nil;
            uint16_t advPort = 0;
            BOOL advertised = P2ParseAdvertise(advertiseSpec, &advHost, &advPort);
            NSArray<NSString *> *ips = P2LANAddresses();
            NSString *innerIP = ips.count ? [ips.firstObject componentsSeparatedByString:@"("].firstObject
                                          : @"127.0.0.1";
            printf("\n===== 给客户端的三项（跨网段填映射后的地址）=====\n");
            printf("  IP   : %s\n", advertised ? advHost.UTF8String : innerIP.UTF8String);
            printf("  端口 : %u\n", advertised && advPort ? advPort : host.port);
            printf("  指纹 : %s\n", localFp.UTF8String);
            printf("=============================================\n");
            printf("本机实际监听: %s:%u（%s）\n", innerIP.UTF8String, host.port,
                   advertised ? "NAT 后面；对外请用上面三项" : "同网段可直接用");
            if (advertised && advPort && advPort != host.port)
                printf("外部端口 %u → 内部端口 %u：防火墙/路由器上必须已有这条 UDP 映射\n",
                       advPort, host.port);
            printf("\n");

            if (portFile.length > 0) {
                NSString *payload = [NSString stringWithFormat:@"%u\n%@\n", host.port, localFp];
                [payload writeToFile:portFile atomically:YES
                            encoding:NSUTF8StringEncoding error:NULL];
            }

            printf("等待客户端接入…\n");
            if (![host waitForStreamingTimeoutMs:waitMs]) {
                printf("✗ %us 内未进入 STREAMING: %s\n", waitMs / 1000, (const char *)
                       host.error.localizedDescription.UTF8String ?: "无客户端");
                // session-start 已到但握手未完成时，displayProvider 可能已建好虚拟屏并禁了
                // 物理屏；这里不恢复会把机器留在黑屏态（守护只在进程异常退出时兜底）。
                endExclusive();
                [host shutdown];
                return 4;
            }
            printf("双端已 STREAMING，开始推流（%d ms / %d fps）\n", durationMs, fps);
            CGDirectDisplayID captureID = virtualDisplayID ? virtualDisplayID : displayID;
            if (exclusive) {
                printf("  采集目标：虚拟屏 displayID=%u（请求规格 %lux%lu，%s）\n",
                       captureID, (unsigned long)virtualW, (unsigned long)virtualH,
                       keepMain ? "物理主屏仍可见" : "物理屏已禁用");
            }

            M1FramePipelineConfig *cfg = [M1FramePipelineConfig new];
            cfg.targetFps = fps;
            cfg.bitsPerPixel = bpp;
            cfg.outputWidth = outW;
            cfg.outputHeight = outH;
            {
                const char *cr = getenv("M1_CAPTURE_RESOLUTION");
                if (cr) {
                    if (!strcasecmp(cr, "best")) cfg.captureResolution = 1;
                    else if (!strcasecmp(cr, "nominal")) cfg.captureResolution = 2;
                    else cfg.captureResolution = atoi(cr) > 0 ? atoi(cr) : 0;
                }
            }
            __block int errCount = 0;
            __block M1FramePipeline *pipe =
                [[M1FramePipeline alloc] initWithDisplayID:captureID
                                                    config:cfg
                                                      sink:host
                                                   onError:^(NSError *e) {
                    errCount += 1;
                    if (errCount <= 3) printf("  [管线错误] %s\n",
                                              e.localizedDescription.UTF8String);
                }];
            // 跨公网下行实测 ~2–3% 随机丢片：IDR 72 片时几乎每帧都缺片，
            // 被「整帧齐全才交付」放大成反复等待关键帧。
            // P2.1 起缺片优先走定向补片（frame-nack），整帧副本默认关掉：
            // 副本会推高在途带宽，反而让补片和在途 IDR 一起堵在拥塞窗口里。
            {
                const char *kc = getenv("M1_FRAG_COPIES_KEY");
                const char *pc = getenv("M1_FRAG_COPIES_P");
                NSUInteger kCopies = (NSUInteger)MAX(1, kc ? atoi(kc) : 1);
                NSUInteger pCopies = (NSUInteger)MAX(1, pc ? atoi(pc) : 1);
                pipe.sender.keyframeCopies = kCopies;
                pipe.sender.pframeCopies = pCopies;
                const char *cacheEnv = getenv("M1_FRAG_CACHE");
                NSUInteger cacheFrames = cacheEnv ? (NSUInteger)MAX(0, atoi(cacheEnv)) : 64;
                pipe.sender.fragmentCacheFrames = cacheFrames;
                printf("  分片冗余：关键帧 %lu 份 / P 帧 %lu 份；补片缓存 %lu 帧\n",
                       (unsigned long)kCopies, (unsigned long)pCopies,
                       (unsigned long)cacheFrames);
            }
            if (![pipe start:&err]) {
                printf("✗ 管线启动失败: %s\n", err.localizedDescription.UTF8String);
                endExclusive();
                [host shutdown];
                return 5;
            }
            printf("  采集尺寸 %dx%d\n", pipe.pixelWidth, pipe.pixelHeight);
            // keyframe-request 落到编码器：下一帧强制 IDR。
            // 900ms 合并窗口：客户端的重试/多请求不应把在途 IDR 冲掉。
            __block CFAbsoluteTime lastForcedKeyframe = 0;
            host.onKeyframeRequest = ^(uint32_t displayID) {
                (void)displayID;   // 单管线探针：忽略屏号
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (now - lastForcedKeyframe < 0.9) return;
                lastForcedKeyframe = now;
                [pipe requestKeyframe];
            };
            // frame-nack 落到分片缓存：只重发客户端缺的那几片。
            // 未命中缓存（超出窗口/缓存关闭）就什么都不做——客户端补片窗口到期后
            // 自己会改走 keyframe-request，不需要在这里重复判定。
            __block uint64_t nackRepaired = 0, nackMissed = 0, nackFragments = 0;
            __block uint64_t nackWholeFrames = 0;
            host.onFrameNack = ^(uint32_t displayID, uint32_t frameSeq,
                                 uint16_t fragCount, NSIndexSet *indices) {
                (void)displayID;   // 单管线探针：忽略屏号
                (void)fragCount;
                NSError *rsErr = nil;
                NSUInteger n;
                if (indices.count == 0) {
                    // 客户端整帧零分片：重发缓存里的全部分片。
                    nackWholeFrames += 1;
                    n = [pipe.sender resendAllFragmentsForFrameSeq:frameSeq error:&rsErr];
                } else {
                    n = [pipe.sender resendFragmentsForFrameSeq:frameSeq
                                                        indices:indices error:&rsErr];
                }
                if (n > 0) { nackRepaired += 1; nackFragments += n; }
                else { nackMissed += 1; }
            };

            // ---- 输入回传（M1-B）----
            // record 是默认档：单机环回时 Host 和 Client 是同一个桌面，
            // 真注入会把光标从这个窗口移走、甚至点中别的 app，验证反而失真。
            M1RecordingEventSink *recorder = nil;
            M1InputInjector *injector = nil;
            __block NSUInteger injectFails = 0;
            __block NSUInteger injectOK = 0;
            // 真注入时用光标位移证明「主机真的被动了」，不是只收到了计划。
            CGPoint cursorStart = CGPointZero, cursorEnd = CGPointZero;
            {
                CGEventRef c = CGEventCreate(NULL);
                if (c) { cursorStart = CGEventGetLocation(c); CFRelease(c); }
            }
            if (injectMode.length > 0) {
                id<M1EventSink> sink = nil;
                if ([injectMode isEqualToString:@"real"]) {
                    sink = [M1CGEventSink new];
                } else if ([injectMode isEqualToString:@"record"]) {
                    recorder = [M1RecordingEventSink new];
                    sink = recorder;
                } else {
                    printf("✗ 未知 --inject 模式：%s（只支持 record / real）\n",
                           injectMode.UTF8String);
                    [pipe stop];
                    endExclusive();
                    [host shutdown];
                    return 1;
                }
                // 目标 rect 用被采集那块屏的 Quartz bounds：
                // CGDisplayBounds 的原点在主屏左上、y 向下，与协议 y=0 在上一致。
                CGRect targetRect = CGDisplayBounds(captureID);
                injector = [[M1InputInjector alloc] initWithSink:sink];
                injector.targetDisplayRect = targetRect;
                host.onInputEvent = ^(NSDictionary *event) {
                    NSError *injErr = nil;
                    if (![injector injectEvent:event error:&injErr]) injectFails += 1;
                    else injectOK += 1;
                };
                printf("  输入注入 %s，目标 rect=(%.0f,%.0f %.0fx%.0f)\n",
                       injectMode.UTF8String, targetRect.origin.x, targetRect.origin.y,
                       targetRect.size.width, targetRect.size.height);
            } else {
                printf("  输入注入未启用（--inject record|real 可开启）\n");
            }

            // 对端 bye 之后立即停管线：否则继续往死连接投递，只会把 sendFailures 刷大。
            __block BOOL stopped = NO;
            host.onSessionClosed = ^{
                if (stopped) return;
                stopped = YES;
                printf("  [host] 对端关闭会话，停止推流\n");
                [pipe stop];
                endExclusive();
            };

            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:durationMs / 1000.0];
            double pipelineStartMs = M1StreamNowMs();
            double firstSentMs = 0;
            while (!stopped && [deadline timeIntervalSinceNow] > 0) {
                if (firstSentMs == 0 && pipe.nextFrameSeq > 0) {
                    firstSentMs = M1StreamNowMs();
                    printf("  首帧发出：管线启动后 %.0f ms（采集首帧 %.0f ms）\n",
                           firstSentMs - pipelineStartMs, pipe.stats.firstFrameLatencyMs);
                }
                [NSThread sleepForTimeInterval:0.01];
            }
            [pipe stop];
            [host flushSimulatedHeld];
            endExclusive();

            M1FramePipelineStats *ps = pipe.stats;
            printf("\n--- host 结果 ---\n");
            printf("  %s\n", ps.summary.UTF8String);
            printf("  实际尺寸 %dx%d  nextFrameSeq=%u\n",
                   pipe.pixelWidth, pipe.pixelHeight, pipe.nextFrameSeq);
            printf("  控制包 %llu / 帧包 %llu / 未分流 %llu\n",
                   host.controlDatagrams, host.frameDatagrams, host.unroutedDatagrams);
            printf("  控制通道最大到达间隔 %.0f ms（出现在推流 %.0f ms 处）\n",
                   host.maxControlGapMs, host.maxGapAtOffsetMs);
            if (injectMode.length > 0) {
                M1ControlSession *hs = host.session;
                printf("  输入：收到 %lu / 丢弃 %lu / 拒绝 %lu / 注入失败 %lu"
                       "（注入计划 %lu 条）\n",
                       (unsigned long)hs.inputEventsReceived,
                       (unsigned long)hs.inputEventsDropped,
                       (unsigned long)hs.inputEventsRejected,
                       (unsigned long)injectFails,
                       (unsigned long)recorder.postCount);
                CGEventRef c1 = CGEventCreate(NULL);
                if (c1) { cursorEnd = CGEventGetLocation(c1); CFRelease(c1); }
                printf("  注入成功 %lu 次；光标 (%.0f,%.0f) → (%.0f,%.0f)，位移 %.0f px\n",
                       (unsigned long)injectOK,
                       cursorStart.x, cursorStart.y, cursorEnd.x, cursorEnd.y,
                       hypot(cursorEnd.x - cursorStart.x, cursorEnd.y - cursorStart.y));
                NSArray<NSDictionary *> *plans = recorder.plans;
                NSUInteger show = MIN(plans.count, (NSUInteger)6);
                for (NSUInteger i = 0; i < show; i++) {
                    NSDictionary *pl = plans[i];
                    if ([pl[@"kind"] isEqualToString:@"mouse"]) {
                        printf("    #%lu mouse %s %s @ (%.0f, %.0f)\n",
                               (unsigned long)i + 1,
                               [pl[@"button"] UTF8String], [pl[@"action"] UTF8String],
                               [pl[@"x"] doubleValue], [pl[@"y"] doubleValue]);
                    } else if ([pl[@"kind"] isEqualToString:@"key"]) {
                        printf("    #%lu key keyCode=%d unicode=%s\n",
                               (unsigned long)i + 1,
                               [pl[@"keyCode"] intValue],
                               [pl[@"unicode"] UTF8String] ?: "");
                    } else if ([pl[@"kind"] isEqualToString:@"scroll"]) {
                        printf("    #%lu scroll dx=%.1f dy=%.1f\n",
                               (unsigned long)i + 1,
                               [pl[@"dx"] doubleValue], [pl[@"dy"] doubleValue]);
                    } else {
                        printf("    #%lu flags=0x%llx\n", (unsigned long)i + 1,
                               [pl[@"flags"] unsignedLongLongValue]);
                    }
                }
            }
            printf("  会话形态: %s  采集 displayID=%u\n",
                   exclusive ? (keepMain ? "独占（保留主屏）" : "独占（禁物理屏）") : "镜像主屏",
                   captureID);
            printf("  关键帧请求：收到 %lu 次\n",
                   (unsigned long)host.session.keyframeRequestsReceived);
            printf("  补片请求：收到 %lu 次（整帧 %llu），命中重发 %llu 帧/%llu 片，未命中 %llu\n",
                   (unsigned long)host.session.frameNacksReceived,
                   nackWholeFrames, nackRepaired, nackFragments, nackMissed);
            if (simLossPct > 0 || simReorderPct > 0) {
                printf("  注入故障：丢片 %llu 个，乱序交换 %llu 次（%.1f%% / %.1f%%）\n",
                       host.simFragmentsDropped, host.simReordered, simLossPct, simReorderPct);
            }
            PrintFlowStats(host, "host");
            printf("  状态序列: %s\n", [host.stateLog componentsJoinedByString:@" → "].UTF8String);

            NSMutableDictionary *json = [NSMutableDictionary dictionary];
            json[@"role"] = @"host";
            json[@"port"] = @(host.port);
            json[@"streamDurationMs"] = @(durationMs);
            if (advertiseSpec.length) json[@"advertisedEndpoint"] = advertiseSpec;
            json[@"streaming"] = @(host.streaming);
            json[@"stateLog"] = host.stateLog;
            json[@"pixelWidth"] = @(pipe.pixelWidth);
            json[@"pixelHeight"] = @(pipe.pixelHeight);
            json[@"framesSent"] = @(ps.framesSent);
            json[@"framesEncoded"] = @(ps.framesEncoded);
            json[@"framesCaptured"] = @(ps.framesCaptured);
            json[@"fragmentsSent"] = @(ps.fragmentsSent);
            json[@"fragCopiesKey"] = @(pipe.sender.keyframeCopies);
            json[@"fragCopiesP"] = @(pipe.sender.pframeCopies);
            json[@"fragCacheFrames"] = @(pipe.sender.fragmentCacheFrames);
            json[@"fragmentsResent"] = @(pipe.sender.fragmentsResent);
            json[@"payloadBytes"] = @(ps.payloadBytesSent);
            json[@"keyframes"] = @(ps.keyframes);
            json[@"sendFailures"] = @(ps.sendFailures);
            json[@"encodeFailures"] = @(ps.encodeFailures);
            json[@"framesDroppedBeforeEncoder"] = @(ps.framesDroppedBeforeEncoder);
            json[@"firstFrameLatencyMs"] = @(round(ps.firstFrameLatencyMs));
            json[@"payloadBytes"] = @(ps.payloadBytesSent);
            json[@"controlDatagrams"] = @(host.controlDatagrams);
            json[@"frameDatagrams"] = @(host.frameDatagrams);
            json[@"maxControlGapMs"] = @(round(host.maxControlGapMs));
            json[@"sessionMode"] = exclusive ? (keepMain ? @"exclusive-keep-main" : @"exclusive")
                                             : @"mirror";
            json[@"captureDisplayID"] = @(captureID);
            if (exclusive) {
                json[@"virtualDisplayIDs"] = exclusiveDisplayIDs ?: @[];
                json[@"activeDisplayIDsAfterDisable"] = exclusiveActiveIDs ?: @[];
                json[@"c09Status"] = exclusiveC09Status;
                json[@"sessionPhase"] = exclusivePhaseAtReady ?: @"";
                json[@"sessionRecovered"] = @(exclusiveRecoveryOK);
                json[@"sessionEnded"] = @(exclusiveEnded);
                if (exclusiveWindowRestore) {
                    json[@"windowLayoutRestore"] = exclusiveWindowRestore;
                }
            }
            json[@"keyframeRequestsReceived"] = @(host.session.keyframeRequestsReceived);
            json[@"frameNacksReceived"] = @(host.session.frameNacksReceived);
            json[@"frameNackWholeFrames"] = @(nackWholeFrames);
            json[@"frameNacksRepaired"] = @(nackRepaired);
            json[@"frameNackFragmentsResent"] = @(nackFragments);
            json[@"frameNacksMissed"] = @(nackMissed);
            AddTransportStats(json, host.streamConn.stats);
            json[@"simLossPct"] = @(simLossPct);
            json[@"simReorderPct"] = @(simReorderPct);
            json[@"simFragmentsDropped"] = @(host.simFragmentsDropped);
            json[@"simReordered"] = @(host.simReordered);
            if (injectMode.length > 0) {
                json[@"injectMode"] = injectMode;
                json[@"inputReceived"] = @(host.session.inputEventsReceived);
                json[@"inputDropped"] = @(host.session.inputEventsDropped);
                json[@"inputRejected"] = @(host.session.inputEventsRejected);
                json[@"inputInjectFails"] = @(injectFails);
                json[@"inputInjected"] = @(injectOK);
                json[@"cursorStart"] = @[ @(round(cursorStart.x)), @(round(cursorStart.y)) ];
                json[@"cursorEnd"] = @[ @(round(cursorEnd.x)), @(round(cursorEnd.y)) ];
                json[@"cursorMovedPx"] = @(round(hypot(cursorEnd.x - cursorStart.x,
                                                       cursorEnd.y - cursorStart.y)));
                json[@"inputPlans"] = recorder.plans ?: @[];
            }
            if (outPath.length > 0) {
                NSData *d = JSONData(json);
                if (d) [d writeToFile:outPath atomically:YES];
            }
            [host shutdown];
            return (ps.framesSent > 0) ? 0 : 2;
        }

        // ---- client ----
        if (port == 0 || fingerprint.length == 0) {
            fprintf(stderr, "✗ --client 需要 --port 与 --fingerprint\n");
            return 1;
        }
        if (outdir.length == 0) {
            outdir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"m1-stream-%d", (int)getpid()]];
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:outdir
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:NULL];

        // 窗口模式：先建 NSWindow，保证首帧一到就能上屏（渲染本身在独立队列，
        // 帧到了先排队，run loop 起来后立即贴图）。
        M1FrameView *frameView = nil;
        __block NSUInteger synthPosted = 0;   // 进程内合成鼠标事件的投递次数（收尾时进 JSON）
        __block BOOL closedByUser = NO;
        NSWindow *frameWindow = nil;
        if (windowMode) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            NSRect content = NSMakeRect(0, 0, windowW, windowH);
            frameWindow = [[NSWindow alloc]
                initWithContentRect:content
                          styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                     NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                            backing:NSBackingStoreBuffered
                              defer:NO];
            frameWindow.title = [NSString stringWithFormat:
                @"macOS-RDP 客户端 %d×%d（Esc 退出）", (int)windowW, (int)windowH];
            frameWindow.releasedWhenClosed = NO;
            // 不设这个，NSWindow 默认不投递 mouseMoved（tracking area 之外的那条路）。
            frameWindow.acceptsMouseMovedEvents = YES;
            frameView = [[M1FrameView alloc] initWithFrame:content];
            frameWindow.contentView = frameView;
            [frameWindow center];
            if (windowTop) frameWindow.level = NSFloatingWindowLevel;
            [frameWindow makeKeyAndOrderFront:nil];
            [[NSNotificationCenter defaultCenter]
                addObserverForName:NSWindowWillCloseNotification
                            object:frameWindow
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                closedByUser = YES;
                [NSApp stop:nil];
            }];
            printf("窗口已打开 %dx%d（Esc 或关窗退出）\n", (int)windowW, (int)windowH);
        }

        M1StreamClientNode *client = [M1StreamClientNode new];
        client.expectedFingerprint = fingerprint;
        client.fps = fps;
        if (specW > 0 && specH > 0) {
            client.requestedSpecs = @[ @{ @"w": @(specW), @"h": @(specH),
                                          @"hidpi": @NO, @"refresh": @60 } ];
            printf("请求 host 规格 %dx%d\n", specW, specH);
        }
        client.outdir = outdir;
        client.saveFrames = saveFrames;
        if (frameView) {
            __weak M1FrameView *weakView = frameView;
            __weak M1StreamClientNode *weakClient = client;
            __block BOOL printedAnchors = NO;
            client.onPixelBuffer = ^(uint32_t displayID, CVPixelBufferRef pb,
                                     uint32_t seq, uint64_t capturedAtUs) {
                (void)displayID;   // 单窗口探针：只绑第一块屏
                [weakView presentPixelBuffer:pb capturedAtUs:capturedAtUs];
                // 首帧到了才有 videoSize，才能算「画面中心」的全局坐标。
                // 驱动端不能拿「屏幕中心」当「画面中心」：窗口内容里视频是按比例
                // letterbox 的，屏幕中心很可能落在黑边上，而黑边按设计不产生输入
                // （踩过：真光标驱动 4 次，视图收到 8 个 mouseMoved，主机 0 条）。
                if (printedAnchors || weakView.videoSize.width <= 0) return;
                printedAnchors = YES;
                CGRect vr = weakView.videoRect;              // 视图坐标
                NSPoint c = NSMakePoint(NSMidX(vr), NSMidY(vr));
                NSScreen *scr = frameWindow.screen ?: NSScreen.mainScreen;
                CGFloat topY = NSMaxY(scr.frame);
                NSPoint win = [weakView convertPoint:c toView:nil];
                NSPoint sCenter = [frameWindow convertPointToScreen:win];
                NSPoint winL = [weakView convertPoint:NSMakePoint(NSMidX(vr) - 200, NSMidY(vr)) toView:nil];
                NSPoint winR = [weakView convertPoint:NSMakePoint(NSMidX(vr) + 200, NSMidY(vr)) toView:nil];
                NSPoint sL = [frameWindow convertPointToScreen:winL];
                NSPoint sR = [frameWindow convertPointToScreen:winR];
                printf("  [anchors] center=(%.0f,%.0f) left=(%.0f,%.0f) right=(%.0f,%.0f) "
                       "videoW=%.0f\n",
                       sCenter.x, topY - sCenter.y, sL.x, topY - sL.y,
                       sR.x, topY - sR.y, vr.size.width);
                // 首帧真的上屏了才喊人动手：先等 0.8s 让首次 CA 提交完成，
                // 否则窗口还在「启动中」，最早几下移动会被吞掉（实测）。
                if (manualSecs > 0) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        M1StartManualCue(frameWindow, weakView, weakClient.session, manualSecs);
                    });
                }
            };
        }

        NSError *err = nil;
        printf("连接 %s:%u\n", connectHost.UTF8String, port);
        if (![client startAsClientTo:connectHost port:port timeout:handshakeTimeoutMs error:&err]) {
            printf("✗ 握手失败: %s\n", err.localizedDescription.UTF8String);
            return 3;
        }
        printf("握手完成 %.1f ms\n", client.handshakeMs);
        if (![client waitForStreamingTimeoutMs:waitMs]) {
            printf("✗ %us 内未进入 STREAMING: %s\n", waitMs / 1000, (const char *)
                   client.error.localizedDescription.UTF8String ?: "unknown");
            return 4;
        }
        printf("已 STREAMING，接收 %d ms\n", durationMs);
        if (frameView) {
            NSDictionary *remoteDisplay = client.session.remoteDisplays.firstObject;
            frameView.displayID = [remoteDisplay[@"displayID"] unsignedIntValue];
            printf("  目标屏 displayID=%u（w=%d h=%d），开始捕获窗口输入\n",
                   frameView.displayID,
                   [remoteDisplay[@"w"] intValue], [remoteDisplay[@"h"] intValue]);

            __block NSUInteger winSent = 0, winSendFail = 0;
            frameView.onInputEvent = ^(NSDictionary *event) {
                NSError *sendErr = nil;
                if ([client.session sendInputEvent:event error:&sendErr]) winSent += 1;
                else winSendFail += 1;
            };
            frameView.onCloseRequest = ^{ closedByUser = YES; [NSApp stop:nil]; };

            if (manualSecs > 0) {
                // 兜底：万一一帧都没解出来（黑屏/解码失败），25s 后也把提示打出来，
                // 否则执行的人会一直干等一个永远不来的信号。
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    M1StartManualCue(frameWindow, frameView, client.session, manualSecs);
                });
            }

            // 合成鼠标驱动：这台机器上由 agent 拉起的命令行工具没有「辅助功能」授权
            // （AXIsProcessTrusted=0）。实测 CGWarpMouseCursorPosition 能改光标位置，
            // 但窗口一条 mouseMoved 都收不到（连本地事件监听都是 0），CGEventPost 的
            // 合成事件同样被丢弃。此时改用 NSEvent 在进程内投递：走的是同一条
            // NSWindow sendEvent → hitTest → M1FrameView.mouseMoved: 分发路径，
            // 只差「系统把物理事件交给 App」这一跳，其余全链路（坐标换算→协议编码→
            // 传输→主机解析→注入计划）都是真的。
            if (synthSpec.length > 0) {
                NSArray<NSString *> *pairs = [synthSpec componentsSeparatedByString:@";"];
                for (NSUInteger k = 0; k < pairs.count; k++) {
                    NSString *item = [pairs[k] stringByTrimmingCharactersInSet:
                                      [NSCharacterSet whitespaceCharacterSet]];
                    double sx = 0, sy = 0;
                    if (sscanf(item.UTF8String, "%lf,%lf", &sx, &sy) != 2) continue;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(1200 + (int64_t)k * 350) * NSEC_PER_MSEC),
                                   dispatch_get_main_queue(), ^{
                        if (closedByUser) return;
                        // 内容坐标（左上原点）→ 窗口坐标（左下原点）
                        NSPoint win = NSMakePoint(sx, windowH - sy);
                        NSEvent *ev = [NSEvent mouseEventWithType:NSEventTypeMouseMoved
                                                        location:win
                                                   modifierFlags:0
                                                       timestamp:[NSProcessInfo processInfo].systemUptime
                                                    windowNumber:frameWindow.windowNumber
                                                         context:nil
                                                     eventNumber:0
                                                      clickCount:0
                                                        pressure:0];
                        [frameWindow sendEvent:ev];
                        synthPosted += 1;
                        printf("  [synth] mouseMoved 内容(%.0f,%.0f) → 窗口(%.0f,%.0f)\n",
                               sx, sy, win.x, win.y);
                    });
                }
            }

            // 到点自动收尾。stop: 之后必须再投一个事件，否则 run loop 可能还挂在等事件上。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)durationMs * (int64_t)NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if (!closedByUser) [NSApp stop:nil];
                [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                                    location:NSZeroPoint
                                               modifierFlags:0
                                                   timestamp:0
                                                windowNumber:0
                                                     context:nil
                                                     subtype:0
                                                       data1:0
                                                       data2:0]
                         atStart:NO];
            });

            // 激活必须发生在事件循环跑起来之后：在 run 之前调 activateIgnoringOtherApps:
            // 常常不生效，窗口拿不到 key，keyDown 也收不到（M1-B 实测踩过）。
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSApp activateIgnoringOtherApps:YES];
                [frameWindow makeKeyAndOrderFront:nil];
            });
            if (keepFront) {
                // 每 300ms 重抢一次前台。注意别动 window.level：实测把窗口设成
                // NSFloatingWindowLevel 之后反而一条 mouseMoved 都收不到。
                dispatch_source_t tick = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                                dispatch_get_main_queue());
                dispatch_source_set_timer(tick, dispatch_time(DISPATCH_TIME_NOW, 0),
                                          300ull * NSEC_PER_MSEC, 30ull * NSEC_PER_MSEC);
                dispatch_source_set_event_handler(tick, ^{
                    if (![NSApp isActive]) [NSApp activateIgnoringOtherApps:YES];
                    if (!frameWindow.isKeyWindow) [frameWindow makeKeyAndOrderFront:nil];
                });
                dispatch_resume(tick);
            }
            // 定位「窗口收不到事件」时要看的三件事：窗口是否可见、是否被遮住、是不是 key。
            for (NSNumber *delayMs in @[@800, @2500]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)delayMs.integerValue * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    if (windowTop) {
                        // 持续保持前台：实测有别的应用会把激活抢回去，一旦本进程
                        // 不是 active，WindowServer 就不往这个窗口投 mouseMoved
                        // （窗口看起来仍是 visible/key，只有 active 变了）。
                        static dispatch_source_t ticker;
                        if (!ticker) {
                            ticker = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                            dispatch_get_main_queue());
                            dispatch_source_set_timer(ticker,
                                dispatch_time(DISPATCH_TIME_NOW, 0), 500ull * NSEC_PER_MSEC,
                                50ull * NSEC_PER_MSEC);
                            dispatch_source_set_event_handler(ticker, ^{
                                [NSApp activateIgnoringOtherApps:YES];
                                [frameWindow makeKeyAndOrderFront:nil];
                            });
                            dispatch_resume(ticker);
                        }
                    }
                    NSRect f = frameWindow.frame;
                    printf("  [窗口 +%dms] visible=%d key=%d active=%d occluded=%d "
                           "frame=(%.0f,%.0f %.0fx%.0f) screen=%dx%d\n",
                           delayMs.intValue,
                           (int)frameWindow.isVisible, (int)frameWindow.isKeyWindow,
                           (int)[NSApp isActive],
                           (int)((frameWindow.occlusionState & NSWindowOcclusionStateVisible) == 0),
                           f.origin.x, f.origin.y, f.size.width, f.size.height,
                           (int)[NSScreen mainScreen].frame.size.width,
                           (int)[NSScreen mainScreen].frame.size.height);
                });
            }

            [NSApp run];
            printf("窗口收尾（%s）——上屏 %lu 帧，丢 %lu 帧；输入发出 %lu / 失败 %lu\n",
                   closedByUser ? "用户关闭" : "到时",
                   (unsigned long)frameView.framesRendered,
                   (unsigned long)frameView.framesDropped,
                   (unsigned long)winSent, (unsigned long)winSendFail);
        } else {
            [NSThread sleepForTimeInterval:durationMs / 1000.0];
        }

        [client flushFrames];
        [client flushSaves];
        M1FrameReceiverStats *rs = client.receiver.stats;
        double recvSpan = (client.lastFrameMs > client.firstFrameMs)
                          ? (client.lastFrameMs - client.firstFrameMs) : 0;
        double decodeFps = (recvSpan > 0) ? (rs.framesDecoded - 1) / (recvSpan / 1000.0) : 0;

        printf("\n--- client 结果 ---\n");
        printf("  receiver: datagrams=%llu completed=%llu decoded=%llu dropped=%llu "
               "discardedFrags=%llu decodeFail=%llu keyReq=%llu keyReqSent=%llu "
               "repair=%llu repairSent=%llu repairRtt=%.0fms/%llu awaitKeyframe=%.0fms "
               "kfRtt=%.0fms/%llu malformed=%llu\n",
               rs.datagramsReceived, rs.framesCompleted, rs.framesDecoded,
               rs.framesDropped, rs.fragmentsDiscarded, rs.decodeFailures,
               rs.keyframeRequests, client.keyframeRequestsSent,
               rs.repairRequests, client.repairRequestsSent,
               rs.repairRttMs, rs.repairRttSamples,
               rs.awaitingKeyframeMs, rs.keyframeRequestRttMs,
               rs.keyframeRequestRttSamples, rs.malformedDatagrams);
        printf("  丢帧归因: 关键帧 %llu / P帧 %llu  分片丢弃去向: %s\n",
               rs.droppedKeyframes, rs.droppedPFrames, rs.discardBreakdown.UTF8String);
        printf("  重组状态: %s\n", rs.debugState.UTF8String);
        for (NSString *detail in rs.recentDropDetails) {
            printf("    丢帧: %s\n", detail.UTF8String);
        }
        double firstFrameLatency = (client.firstFrameMs > 0 && client.streamStartMs > 0)
            ? client.firstFrameMs - client.streamStartMs : 0;
        printf("  解码尺寸 %dx%d  解码帧率 %.1f fps  首帧延迟 %.0f ms\n",
               client.decodedWidth, client.decodedHeight, decodeFps, firstFrameLatency);
        // P2.2 判据：独占模式下 host 按 client 请求的规格建虚拟屏，解码尺寸必须一致。
        // 镜像模式不建屏，请求规格仅作记录，所以这里只打印、不参与判定（判定在 p2.sh summary）。
        if (specW > 0 && specH > 0) {
            BOOL specMatch = (client.decodedWidth == specW && client.decodedHeight == specH);
            printf("  规格断言: 请求 %dx%d / 解码 %dx%d → %s%s\n", specW, specH,
                   client.decodedWidth, client.decodedHeight, specMatch ? "PASS" : "FAIL",
                   specMatch ? "" : "（若 host 是镜像模式，此项不参与判定）");
        }
        printf("  解码器：进程预热 %.0f ms，真实建会话 %.0f ms\n",
               rs.decoderPrewarmMs, rs.decoderCreateMs);
        printf("  控制包 %llu / 帧包 %llu / 未分流 %llu\n",
               client.controlDatagrams, client.frameDatagrams, client.unroutedDatagrams);
        printf("  帧队列单次处理最长 %.0f ms（推流 %.0f ms 处）\n",
               client.maxAcceptBlockMs, client.maxAcceptBlockAtMs);
        printf("  控制通道最大到达间隔 %.0f ms（出现在推流 %.0f ms 处）\n",
               client.maxControlGapMs, client.maxGapAtOffsetMs);
        PrintFlowStats(client, "client");
        printf("  状态序列: %s\n", [client.stateLog componentsJoinedByString:@" → "].UTF8String);
        if (frameView) {
            printf("  上屏：%lu 帧（积压丢 %lu / 无 surface %lu / 跳过 %lu 不可见），"
                   "单帧渲染最近 %.1f ms / 峰值 %.1f ms，p50 %.1f / p95 %.1f ms\n",
                   (unsigned long)frameView.framesRendered,
                   (unsigned long)frameView.renderDropped,
                   (unsigned long)frameView.renderFailed,
                   (unsigned long)frameView.framesSkippedOccluded,
                   frameView.lastRenderMs, frameView.maxRenderMs,
                   frameView.renderP50Ms, frameView.renderP95Ms);
            BOOL hasOffset = client.session.hasClockOffset;
            double offsetMs = hasOffset ? (double)client.session.clockOffsetUs / 1000.0 : 0;
            double p50 = frameView.presentLatencyP50Ms + offsetMs;
            double p95 = frameView.presentLatencyP95Ms + offsetMs;
            double last = frameView.lastPresentLatencyMs + offsetMs;
            double maxLat = frameView.maxPresentLatencyMs + offsetMs;
            if (frameView.presentLatencySamples == 0) {
                printf("  capture→render：无样本（帧头未携带采集时间戳）\n");
            } else if (!hasOffset) {
                printf("  capture→render：样本 %lu，时钟差未同步，"
                       "原始 p50 %.1f / p95 %.1f / 最大 %.1f ms（含两端墙钟偏差）\n",
                       (unsigned long)frameView.presentLatencySamples,
                       frameView.presentLatencyP50Ms, frameView.presentLatencyP95Ms,
                       frameView.maxPresentLatencyMs);
            } else {
                printf("  capture→render：样本 %lu，主机时钟差 %+.1f ms"
                       "（RTT %.1f ms / %lu 样本），p50 %.1f / p95 %.1f / 最近 %.1f / 最大 %.1f ms\n",
                       (unsigned long)frameView.presentLatencySamples, offsetMs,
                       client.session.timeSyncRttMs, (unsigned long)client.session.timeSyncSamples,
                       MAX(0.0, p50), MAX(0.0, p95), MAX(0.0, last), MAX(0.0, maxLat));
            }
            printf("  渲染队列：pending 峰值 %lu，入队等待峰值 %.1f ms，主线程贴层等待峰值 %.1f ms\n",
                   (unsigned long)frameView.maxPendingRenders,
                   frameView.maxQueueWaitMs, frameView.maxMainWaitMs);
            printf("  输入：窗口采集 %lu 条 → 发出 %lu / 丢弃 %lu / 拒绝 %lu\n",
                   (unsigned long)frameView.inputEventsEmitted,
                   (unsigned long)client.session.inputEventsSent,
                   (unsigned long)client.session.inputEventsDropped,
                   (unsigned long)client.session.inputEventsRejected);
        }
        printf("  已保存 PNG %lu 张 → %s\n",
               (unsigned long)client.savedPaths.count, outdir.UTF8String);
        for (NSString *p in client.savedPaths) printf("    %s\n", p.lastPathComponent.UTF8String);

        NSMutableDictionary *json = [NSMutableDictionary dictionary];
        json[@"role"] = @"client";
        json[@"streamDurationMs"] = @(durationMs);
        json[@"streaming"] = @(client.streaming);
        json[@"stateLog"] = client.stateLog;
        json[@"handshakeMs"] = @(round(client.handshakeMs * 10) / 10.0);
        json[@"datagrams"] = @(rs.datagramsReceived);
        json[@"framesCompleted"] = @(rs.framesCompleted);
        json[@"framesDecoded"] = @(rs.framesDecoded);
        json[@"framesDropped"] = @(rs.framesDropped);
        json[@"droppedKeyframes"] = @(rs.droppedKeyframes);
        json[@"droppedPFrames"] = @(rs.droppedPFrames);
        json[@"dropDetails"] = rs.recentDropDetails ?: @[];
        json[@"fragmentsDiscarded"] = @(rs.fragmentsDiscarded);
        json[@"discardBreakdown"] = rs.discardBreakdown ?: @"";
        json[@"reassemblerState"] = rs.debugState ?: @"";
        json[@"awaitingKeyframeMs"] = @(round(rs.awaitingKeyframeMs));
        json[@"decodeFailures"] = @(rs.decodeFailures);
        json[@"keyframeRequests"] = @(rs.keyframeRequests);
        json[@"keyframeRequestsSent"] = @(client.keyframeRequestsSent);
        json[@"keyframeRequestFailures"] = @(client.keyframeRequestFailures);
        json[@"repairRequests"] = @(rs.repairRequests);
        json[@"repairRequestsSent"] = @(client.repairRequestsSent);
        json[@"repairWholeFrameRequests"] = @(client.repairWholeFrameRequests);
        json[@"frameNacksSent"] = @(client.session.frameNacksSent);
        json[@"repairRttMs"] = @(round(rs.repairRttMs));
        json[@"repairRttSamples"] = @(rs.repairRttSamples);
        json[@"keyframeRequestRttMs"] = @(round(rs.keyframeRequestRttMs));
        json[@"keyframeRequestRttSamples"] = @(rs.keyframeRequestRttSamples);
        json[@"malformed"] = @(rs.malformedDatagrams);
        json[@"decodedWidth"] = @(client.decodedWidth);
        json[@"decodedHeight"] = @(client.decodedHeight);
        if (specW > 0 && specH > 0) {
            json[@"requestedWidth"] = @(specW);
            json[@"requestedHeight"] = @(specH);
            json[@"specMatch"] = @(client.decodedWidth == specW && client.decodedHeight == specH);
        }
        // 即使 client 没传 --spec，session-ready 也带了 host 实际建的屏规格；
        // 独占会话据此核对「解码尺寸 = 本次会话真实规格」，避免不传 --spec 时无判据。
        NSDictionary *effectiveDisplay = client.session.remoteDisplays.firstObject;
        int effectiveW = [effectiveDisplay[@"w"] intValue];
        int effectiveH = [effectiveDisplay[@"h"] intValue];
        if (effectiveW > 0 && effectiveH > 0) {
            json[@"effectiveWidth"] = @(effectiveW);
            json[@"effectiveHeight"] = @(effectiveH);
            json[@"effectiveSpecMatch"] = @(client.decodedWidth == effectiveW &&
                                            client.decodedHeight == effectiveH);
        }
        json[@"decodeFps"] = @(round(decodeFps * 10) / 10.0);
        json[@"timeSyncOffsetUs"] = @((long long)client.session.clockOffsetUs);
        json[@"timeSyncRttMs"] = @(round(client.session.timeSyncRttMs * 10) / 10.0);
        json[@"timeSyncSamples"] = @(client.session.timeSyncSamples);
        json[@"hasClockOffset"] = @(client.session.hasClockOffset);
        json[@"lastDecodeLatencyMs"] = @(round(rs.lastDecodeLatencyMs * 10) / 10.0);
        json[@"firstFrameLatencyMs"] = @(round(firstFrameLatency));
        json[@"decoderPrewarmMs"] = @(round(rs.decoderPrewarmMs));
        json[@"decoderCreateMs"] = @(round(rs.decoderCreateMs));
        json[@"controlDatagrams"] = @(client.controlDatagrams);
        json[@"frameDatagrams"] = @(client.frameDatagrams);
        json[@"maxControlGapMs"] = @(round(client.maxControlGapMs));
        json[@"maxGapAtOffsetMs"] = @(round(client.maxGapAtOffsetMs));
        @synchronized (client.controlArrivals) {
            json[@"controlArrivals"] = [client.controlArrivals copy];
        }
        json[@"savedPNGs"] = @(client.savedPaths.count);
        if (frameView) {
            json[@"windowed"] = @YES;
            json[@"framesRendered"] = @(frameView.framesRendered);
            json[@"renderDropped"] = @(frameView.framesDropped);
            json[@"renderDroppedBacklog"] = @(frameView.renderDropped);
            json[@"renderFailed"] = @(frameView.renderFailed);
            json[@"maxPendingRenders"] = @(frameView.maxPendingRenders);
            json[@"renderP50Ms"] = @(round(frameView.renderP50Ms * 10) / 10.0);
            json[@"renderP95Ms"] = @(round(frameView.renderP95Ms * 10) / 10.0);
            json[@"maxRenderQueueWaitMs"] = @(round(frameView.maxQueueWaitMs * 10) / 10.0);
            json[@"maxRenderMainWaitMs"] = @(round(frameView.maxMainWaitMs * 10) / 10.0);
            json[@"renderSkippedOccluded"] = @(frameView.framesSkippedOccluded);
            json[@"lastRenderMs"] = @(round(frameView.lastRenderMs * 10) / 10.0);
            json[@"maxRenderMs"] = @(round(frameView.maxRenderMs * 10) / 10.0);
            BOOL hasOffset = client.session.hasClockOffset;
            double offsetMs = hasOffset ? (double)client.session.clockOffsetUs / 1000.0 : 0;
            json[@"presentLatencySamples"] = @(frameView.presentLatencySamples);
            json[@"captureToRenderClockCorrected"] = @(hasOffset);
            BOOL latHasSamples = frameView.presentLatencySamples > 0;
            json[@"captureToRenderP50Ms"] = @(latHasSamples ? round(MAX(0.0, frameView.presentLatencyP50Ms + offsetMs) * 10) / 10.0 : 0.0);
            json[@"captureToRenderP95Ms"] = @(latHasSamples ? round(MAX(0.0, frameView.presentLatencyP95Ms + offsetMs) * 10) / 10.0 : 0.0);
            json[@"captureToRenderLastMs"] = @(latHasSamples ? round(MAX(0.0, frameView.lastPresentLatencyMs + offsetMs) * 10) / 10.0 : 0.0);
            json[@"captureToRenderMaxMs"] = @(latHasSamples ? round(MAX(0.0, frameView.maxPresentLatencyMs + offsetMs) * 10) / 10.0 : 0.0);
            json[@"inputEmitted"] = @(frameView.inputEventsEmitted);
            json[@"inputSynthPosted"] = @(synthPosted);
            json[@"inputDriver"] = manualSecs > 0 ? @"manual"
                                 : (synthSpec.length > 0 ? @"synth" : @"physical");
            json[@"manualSecs"] = @(manualSecs);
            json[@"inputSent"] = @(client.session.inputEventsSent);
            json[@"inputDropped"] = @(client.session.inputEventsDropped);
            json[@"inputRejected"] = @(client.session.inputEventsRejected);
        }
        AddTransportStats(json, client.streamConn.stats);
        json[@"outdir"] = outdir;
        if (outPath.length > 0) {
            NSData *d = JSONData(json);
            if (d) [d writeToFile:outPath atomically:YES];
        }

        NSString *verdict = @"FAIL";
        NSMutableArray *notes = [NSMutableArray array];
        if (!client.streaming) [notes addObject:@"未到 STREAMING"];
        if (rs.framesDecoded == 0) [notes addObject:@"没解出任何画面"];
        if (client.savedPaths.count == 0 && !frameView) [notes addObject:@"没有 PNG 落盘"];
        if (frameView && frameView.framesRendered == 0) [notes addObject:@"窗口一帧都没贴上"];
        if (client.maxControlGapMs > 3000) {
            [notes addObject:[NSString stringWithFormat:@"控制通道最大间隔 %.0fms 超 3s（疑似被推流挤掉）",
                              client.maxControlGapMs]];
        }
        if (client.unroutedDatagrams > 0) {
            [notes addObject:[NSString stringWithFormat:@"%llu 个包魔数不认识",
                              client.unroutedDatagrams]];
        }
        if (notes.count == 0) verdict = @"PASS";
        printf("  判定: %s\n", verdict.UTF8String);
        for (NSString *n in notes) printf("    · %s\n", n.UTF8String);

        [client shutdown];
        return [verdict isEqualToString:@"PASS"] ? 0 : 2;
    }
}
