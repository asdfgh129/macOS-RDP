// 诊断 3：单屏直建后，轮询 online/active/bounds/mode/镜像/SCK 可见性随时间的变化。
// 目的：判定 Sequoia 上 mode 提交后 active=false 是「仍在激活」还是「结构性状态」。
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import "CGVirtualDisplaySPI.h"
#import "ProbeUtil.h"

static BOOL SCKSees(CGDirectDisplayID did) {
    __block BOOL found = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *c, NSError *e) {
        for (SCDisplay *d in c.displays) if (d.displayID == did) found = YES;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return found;
}

int main(void) {
    @autoreleasepool {
        if (!VDLoadPrivateClasses()) { printf("classes missing\n"); return 1; }
        Class dispCls = VDClass(@"CGVirtualDisplay");
        uint32_t offset = 6;  // 全新 identity，避开刚销毁的组

        id<VD_Descriptor> desc = [[VDClass(@"CGVirtualDisplayDescriptor") alloc] init];
        [desc setMaxPixelsWide:1920];
        [desc setMaxPixelsHigh:1080];
        [desc setName:@"P0-DIAG3"];
        [desc setSizeInMillimeters:CGSizeMake(596, 335)];
        [desc setVendorID:0x5030];
        [desc setProductID:0x5030 + offset];
        [desc setSerialNum:0x1000 + offset];
        dispatch_queue_t q = dispatch_queue_create("p0.diag3", DISPATCH_QUEUE_SERIAL);
        [desc setQueue:q];

        id<VD_Display> d = [[dispCls alloc] initWithDescriptor:desc];
        CGDirectDisplayID did = [d displayID];
        printf("created displayID=%u, settle 500ms then apply 1920x1080\n", did);
        P0SleepMs(500);
        id<VD_Mode> mode = [[VDClass(@"CGVirtualDisplayMode") alloc] initWithWidth:1920 height:1080 refreshRate:60.0];
        id<VD_Settings> s = [[VDClass(@"CGVirtualDisplaySettings") alloc] init];
        [s setModes:@[mode]];
        [s setHiDPI:0];
        BOOL ok = [d applySettings:s];
        printf("applySettings=%d\n", ok);

        BOOL unmirrored = NO;
        for (int i = 0; i < 30; i++) {
            P0SleepMs(500);
            // 一旦确认被自动镜像，尝试用 CGConfigureDisplayMirrorOfDisplay(null) 解除镜像
            if (!unmirrored && CGDisplayIsInMirrorSet(did)) {
                CGDisplayConfigRef cfg = NULL;
                CGError e1 = CGBeginDisplayConfiguration(&cfg);
                CGError e2 = cfg ? CGConfigureDisplayMirrorOfDisplay(cfg, did, kCGNullDirectDisplay) : -1;
                CGError e3 = cfg ? CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession) : -1;
                printf(">> unmirror attempt: begin=%d mirrorOf=%d complete=%d\n", e1, e2, e3);
                unmirrored = YES;
            }
            CGRect b = CGDisplayBounds(did);
            CGDisplayModeRef m = CGDisplayCopyDisplayMode(did);
            size_t mw = m ? CGDisplayModeGetWidth(m) : 0;
            size_t mh = m ? CGDisplayModeGetHeight(m) : 0;
            if (m) CGDisplayModeRelease(m);
            printf("t=%4.1fs online=%d active=%d bounds=%s mode=%zux%zu mirrorSet=%d mirrors=%u sck=%d\n",
                   (i + 1) * 0.5,
                   CGDisplayIsOnline(did), CGDisplayIsActive(did),
                   P0RectString(b).UTF8String, mw, mh,
                   CGDisplayIsInMirrorSet(did), CGDisplayMirrorsDisplay(did),
                   SCKSees(did));
            fflush(stdout);
        }

        printf("destroying\n");
        d = nil;
        desc = nil;
        P0SleepMs(1500);
        printf("done\n");
    }
    return 0;
}