//
//  stream_session_selftest.m
//  VeilRD — 跨模块集成自检（第 4 轮）
//
//  不触碰 WindowServer / TCC：只验证 M1StreamSession 的 QUIC 建链 + 控制会话
//  + 时钟探针（A-02 采集点）在环回下真的可用。产品两端的 --serve/--connect
//  与 stream_probe 共用这份节点实现，所以这里通过等于协议层没有回退。
//

#import <Foundation/Foundation.h>
#import "M1QuicTransport.h"
#import "M1StreamSession.h"

static BOOL WaitForStreaming(M1StreamNode *node, NSTimeInterval budget) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:budget];
    while ([deadline timeIntervalSinceNow] > 0) {
        if (node.streaming && node.error == nil) return YES;
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return NO;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "用法: stream_session_selftest <identity.p12> <pass>\n");
            return 2;
        }
        NSString *identity = [NSString stringWithUTF8String:argv[1]];
        NSString *pass = [NSString stringWithUTF8String:argv[2]];
        NSError *err = nil;
        NSString *fp = M1QuicIdentityFingerprint(identity, pass, &err);
        if (fp.length == 0) {
            fprintf(stderr, "✗ 身份指纹: %s\n", err.localizedDescription.UTF8String ?: "unknown");
            return 3;
        }

        M1StreamNode *host = [M1StreamNode new];
        host.identityPath = identity;
        host.identityPass = pass;
        host.localFingerprint = fp;
        host.displayProvider = ^NSArray<NSDictionary *> *(NSDictionary *message, NSError **perr) {
            (void)message; (void)perr;
            return @[@{@"displayID": @8888, @"w": @1280, @"h": @720, @"synthetic": @YES},
                     @{@"displayID": @8889, @"w": @1280, @"h": @720, @"synthetic": @YES}];
        };
        if (![host startAsHostOnPort:0 error:&err]) {
            fprintf(stderr, "✗ host 监听: %s\n", err.localizedDescription.UTF8String ?: "unknown");
            return 4;
        }
        printf("host 监听端口 %u 指纹 %s\n", host.port, fp.UTF8String);

        M1StreamNode *client = [M1StreamNode new];
        client.expectedFingerprint = fp;
        if (![client startAsClientTo:@"127.0.0.1" port:host.port timeout:12000 error:&err]) {
            fprintf(stderr, "✗ client 握手: %s\n", err.localizedDescription.UTF8String ?: "unknown");
            [host shutdown];
            return 5;
        }
        if (!WaitForStreaming(host, 10) || ![client waitForStreamingTimeoutMs:10000]) {
            fprintf(stderr, "✗ 未进入 STREAMING: host=%d client=%d err=%s\n",
                    host.streaming, client.streaming,
                    (host.error ?: client.error).localizedDescription.UTF8String ?: "none");
            [host shutdown]; [client shutdown];
            return 6;
        }
        printf("双端 STREAMING：handshake=%.1fms 控制包 host=%llu client=%llu\n",
               client.handshakeMs, host.controlDatagrams, client.controlDatagrams);

        // 多屏：session-ready 里两块屏都要到客户端；keyframe-request 的 displayID 要原样到 Host。
        if (client.session.remoteDisplays.count != 2) {
            fprintf(stderr, "✗ session-ready 屏数=%lu（期望 2）\n",
                    (unsigned long)client.session.remoteDisplays.count);
            [host shutdown]; [client shutdown];
            return 8;
        }
        __block uint32_t kfDisplayID = 0;
        host.onKeyframeRequest = ^(uint32_t displayID) { kfDisplayID = displayID; };
        [client.session requestKeyframeForDisplay:8889 error:NULL];
        NSDate *kfDeadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while ([kfDeadline timeIntervalSinceNow] > 0 && kfDisplayID == 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        if (kfDisplayID != 8889) {
            fprintf(stderr, "✗ keyframe-request displayID=%u（期望 8889）\n", kfDisplayID);
            [host shutdown]; [client shutdown];
            return 9;
        }
        printf("多屏 displayID 回传：keyframe-request → %u OK\n", kfDisplayID);

        // A-02 时钟同步探针由客户端进入 STREAMING 后投递到主队列，这里让主队列跑起来。
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while ([deadline timeIntervalSinceNow] > 0 && client.session.timeSyncSamples == 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        printf("时钟同步样本=%lu offset=%lldus rtt=%.1fms\n",
               (unsigned long)client.session.timeSyncSamples,
               client.session.clockOffsetUs, client.session.timeSyncRttMs);
        if (client.session.timeSyncSamples == 0) {
            fprintf(stderr, "✗ A-02 时钟探针没有样本\n");
            [host shutdown]; [client shutdown];
            return 7;
        }
        printf("STREAM SESSION SELFTEST PASS\n");
        [host shutdown];
        [client shutdown];
    }
    return 0;
}
