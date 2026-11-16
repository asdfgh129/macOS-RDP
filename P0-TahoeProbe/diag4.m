// 诊断 4：双屏串行建屏，第二块屏 mode 卡 1x1 的对照实验。
// 用法: diag4 <unmirror0|1> <settleMs before apply#2>
// A: diag4 0 500   —— 不解除 #1 镜像，看 #2 是否仍卡 1x1
// B: diag4 1 2000  —— 解除 #1 镜像 + 长 settle，看 #2 是否恢复
#import <Foundation/Foundation.h>
#import "CGVirtualDisplaySPI.h"
#import "ProbeUtil.h"

static void PrintState(const char *tag, CGDirectDisplayID did) {
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(did);
    size_t mw = m ? CGDisplayModeGetWidth(m) : 0;
    size_t mh = m ? CGDisplayModeGetHeight(m) : 0;
    if (m) CGDisplayModeRelease(m);
    printf("%s did=%u online=%d active=%d mode=%zux%zu mirrorSet=%d mirrors=%u\n",
           tag, did, CGDisplayIsOnline(did), CGDisplayIsActive(did), mw, mh,
           CGDisplayIsInMirrorSet(did), CGDisplayMirrorsDisplay(did));
    fflush(stdout);
}

static id<VD_Settings> MakeSettings(NSUInteger w, NSUInteger h) {
    id<VD_Mode> mode = [[VDClass(@"CGVirtualDisplayMode") alloc] initWithWidth:w height:h refreshRate:60.0];
    id<VD_Settings> s = [[VDClass(@"CGVirtualDisplaySettings") alloc] init];
    [s setModes:@[mode]];
    [s setHiDPI:0];
    return s;
}

static id<VD_Display> MakeDisplay(uint32_t offset, uint32_t serialIdx, NSUInteger w, NSUInteger h,
                                  dispatch_queue_t q, CGDirectDisplayID *outDid) {
    id<VD_Descriptor> desc = [[VDClass(@"CGVirtualDisplayDescriptor") alloc] init];
    [desc setMaxPixelsWide:(unsigned)w];
    [desc setMaxPixelsHigh:(unsigned)h];
    [desc setName:@"P0-DIAG4"];
    [desc setSizeInMillimeters:CGSizeMake(596, 335)];
    [desc setVendorID:0x5030];
    [desc setProductID:0x5030 + offset];
    [desc setSerialNum:0x1000 + serialIdx + offset];
    [desc setQueue:q];
    id<VD_Display> d = [[VDClass(@"CGVirtualDisplay") alloc] initWithDescriptor:desc];
    *outDid = [d displayID];
    return d;
}

static void Unmirror(CGDirectDisplayID did) {
    CGDisplayConfigRef cfg = NULL;
    CGError e1 = CGBeginDisplayConfiguration(&cfg);
    CGError e2 = cfg ? CGConfigureDisplayMirrorOfDisplay(cfg, did, kCGNullDirectDisplay) : -1;
    CGError e3 = cfg ? CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession) : -1;
    printf(">> unmirror #1: begin=%d mirrorOf=%d complete=%d\n", e1, e2, e3);
    fflush(stdout);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL doUnmirror = argc > 1 ? atoi(argv[1]) : 0;
        int settle2 = argc > 2 ? atoi(argv[2]) : 500;
        if (!VDLoadPrivateClasses()) { printf("classes missing\n"); return 1; }
        uint32_t offset = 11;  // 全新 identity
        dispatch_queue_t q = dispatch_queue_create("p0.diag4", DISPATCH_QUEUE_SERIAL);

        CGDirectDisplayID did1 = 0, did2 = 0;
        id<VD_Display> d1 = MakeDisplay(offset, 0, 1920, 1080, q, &did1);
        printf("created #1 did=%u, settle 500ms then apply 1920x1080\n", did1);
        P0SleepMs(500);
        printf("apply#1=%d\n", [d1 applySettings:MakeSettings(1920, 1080)]);

        // 等 #1 mode 提交（最多 8s），期间按需解除镜像
        BOOL unmirrored = NO;
        for (int i = 0; i < 16; i++) {
            P0SleepMs(500);
            if (doUnmirror == 1 && !unmirrored && CGDisplayIsInMirrorSet(did1)) {
                Unmirror(did1);
                unmirrored = YES;
            }
            CGDisplayModeRef m = CGDisplayCopyDisplayMode(did1);
            BOOL committed = m && CGDisplayModeGetWidth(m) == 1920;
            if (m) CGDisplayModeRelease(m);
            if (committed) break;
        }
        PrintState("#1 committed", did1);

        printf("settle %dms then create #2\n", settle2);
        P0SleepMs(settle2);
        id<VD_Display> d2 = MakeDisplay(offset, 1, 2560, 1440, q, &did2);
        printf("created #2 did=%u, settle 500ms then apply 2560x1440\n", did2);
        P0SleepMs(500);
        printf("apply#2=%d\n", [d2 applySettings:MakeSettings(2560, 1440)]);

        // 观察 #2 20s，每 3s 补一次 apply；按需解除 #2 镜像
        BOOL unmirrored2 = NO;
        for (int i = 0; i < 20; i++) {
            P0SleepMs(1000);
            if (doUnmirror == 1 && !unmirrored2 && CGDisplayIsInMirrorSet(did2)) {
                Unmirror(did2);
                unmirrored2 = YES;
            }
            if (i > 0 && i % 3 == 0) {
                CGDisplayModeRef m = CGDisplayCopyDisplayMode(did2);
                BOOL ok = m && CGDisplayModeGetWidth(m) == 2560;
                if (m) CGDisplayModeRelease(m);
                if (!ok) printf("re-apply#2=%d\n", [d2 applySettings:MakeSettings(2560, 1440)]);
            }
            char tag[32];
            snprintf(tag, sizeof(tag), "t=%2ds #2", i + 1);
            PrintState(tag, did2);
        }
        PrintState("final #1", did1);

        // 变体 2：两块屏都提交后，单事务原子解除全部镜像，再观察 10s 是否反弹
        if (doUnmirror == 2) {
            CGDisplayConfigRef cfg = NULL;
            CGError e1 = CGBeginDisplayConfiguration(&cfg);
            CGError e2 = cfg ? CGConfigureDisplayMirrorOfDisplay(cfg, did1, kCGNullDirectDisplay) : -1;
            CGError e3 = cfg ? CGConfigureDisplayMirrorOfDisplay(cfg, did2, kCGNullDirectDisplay) : -1;
            CGError e4 = cfg ? CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession) : -1;
            printf(">> atomic unmirror both: begin=%d m1=%d m2=%d complete=%d\n", e1, e2, e3, e4);
            for (int i = 0; i < 10; i++) {
                P0SleepMs(1000);
                char tag[32];
                snprintf(tag, sizeof(tag), "post=%2ds #1", i + 1);
                PrintState(tag, did1);
                snprintf(tag, sizeof(tag), "post=%2ds #2", i + 1);
                PrintState(tag, did2);
            }
        }

        printf("destroying\n");
        d2 = nil; d1 = nil;
        P0SleepMs(1500);
        printf("done\n");
    }
    return 0;
}