//
//  extra_display.m
//  外部虚拟屏持有器（多屏独占测试用）
//
//  测试机的双物理屏场景无法构造，所以用一块「不属于被测会话」的虚拟屏
//  模拟第二块物理屏：它在独立进程里创建并长期持有，从 host 会话的视角看
//  就是一块 active、但不由本会话创建的屏 —— 独占禁屏必须把它一起关掉，
//  收尾恢复必须把它重新点亮。
//
//  用法：./extra_display --spec 800x600 --count 1 --hold-seconds 180
//  输出：EXTRA_DISPLAY_IDS=<id,...>（供脚本解析）
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <signal.h>

#import "ProbeUtil.h"
#import "VDManager.h"

static volatile sig_atomic_t gStop = 0;
static void OnSignal(int sig) { (void)sig; gStop = 1; }

static NSArray<NSDictionary *> *ParseSpec(NSString *spec) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *part in [spec componentsSeparatedByString:@","]) {
        NSArray *wh = [part componentsSeparatedByString:@"x"];
        if (wh.count < 2) continue;
        NSUInteger w = (NSUInteger)[wh[0] integerValue];
        NSUInteger h = (NSUInteger)[wh[1] integerValue];
        if (w < 320 || h < 200) continue;
        [out addObject:@{@"width": @(w), @"height": @(h), @"hiDPI": @0,
                         @"refreshRate": @60, @"name": @"VEILD-EXTRA"}];
    }
    return out;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *spec = @"800x600";
        int count = 1;
        int holdSec = 180;
        uint32_t offset = [VDManager savedIdentityOffset] + 32;  // 避开被测会话的 identity
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--spec") && i + 1 < argc) spec = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--hold-seconds") && i + 1 < argc) holdSec = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--offset") && i + 1 < argc) offset = (uint32_t)atoi(argv[++i]);
        }
        NSArray *base = ParseSpec(spec);
        if (base.count == 0) { P0Log(@"spec 非法: %@", spec); return 2; }
        NSMutableArray *configs = [NSMutableArray array];
        for (int i = 0; i < count; i++) [configs addObjectsFromArray:base];

        signal(SIGINT, OnSignal);
        signal(SIGTERM, OnSignal);

        NSDictionary *policy = P0OSPolicy();
        VDManager *mgr = [[VDManager alloc] initWithConfigs:configs
                                             identityOffset:offset
                                          conservativeFirst:[policy[@"conservativeFirst"] boolValue]];
        if (![mgr createAll]) { P0Log(@"建屏失败"); return 1; }
        BOOL ok = [mgr waitUntilUsableTimeoutMs:12000];
        if (!ok && mgr.displayIDs.count > 0) {
            P0Log(@"虚拟屏未 active，等待第二轮");
            ok = [mgr waitUntilUsableTimeoutMs:8000];
        }
        if (!ok) { P0Log(@"虚拟屏不可用"); [mgr destroyAll]; return 1; }

        P0Log(@"外部虚拟屏就绪: %@", mgr.displayIDs);
        printf("EXTRA_DISPLAY_IDS=%s\n",
               [[mgr.displayIDs componentsJoinedByString:@","] UTF8String]);
        printf("HOLD_SECONDS=%d\n", holdSec);
        fflush(stdout);

        int slept = 0;
        while (!gStop && slept < holdSec) {
            P0SleepMs(5000);
            slept += 5;
        }
        printf("DESTROYING\n");
        fflush(stdout);
        [mgr destroyAll];
        P0Log(@"已销毁外部虚拟屏，slept=%ds", slept);
    }
    return 0;
}
