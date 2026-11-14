// 诊断 2：验证 run loop / 主队列 / 二次 apply 对 mode 提交的影响。
#import <Foundation/Foundation.h>
#import "CGVirtualDisplaySPI.h"
#import "ProbeUtil.h"

static void SpinRunLoop(double seconds) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static void Report(NSString *label, id<VD_Display> display) {
    CGDirectDisplayID did = [display displayID];
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(did);
    if (m) {
        printf("[%s] CG mode: points=%zux%zu pixels=%zux%zu\n", label.UTF8String,
               CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m),
               CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m));
        CGDisplayModeRelease(m);
    } else {
        printf("[%s] CG mode: nil\n", label.UTF8String);
    }
}

static id<VD_Mode> MakeMode(NSUInteger w, NSUInteger h) {
    return [[VDClass(@"CGVirtualDisplayMode") alloc] initWithWidth:w height:h refreshRate:60.0];
}

static id<VD_Settings> MakeSettings(id<VD_Mode> mode, unsigned int hiDPI) {
    id<VD_Settings> s = [[VDClass(@"CGVirtualDisplaySettings") alloc] init];
    [s setModes:@[mode]];
    [s setHiDPI:hiDPI];
    return s;
}

static id<VD_Descriptor> MakeDescriptor(uint32_t offset, dispatch_queue_t q) {
    id<VD_Descriptor> desc = [[VDClass(@"CGVirtualDisplayDescriptor") alloc] init];
    [desc setMaxPixelsWide:1920];
    [desc setMaxPixelsHigh:1080];
    [desc setName:@"P0-DIAG2"];
    [desc setSizeInMillimeters:CGSizeMake(596, 335)];
    [desc setVendorID:0x5030];
    [desc setProductID:0x5030 + offset];
    [desc setSerialNum:0x1000 + offset];
    [desc setQueue:q];
    return desc;
}

int main(void) {
    @autoreleasepool {
        if (!VDLoadPrivateClasses()) { printf("classes missing\n"); return 1; }
        Class dispCls = VDClass(@"CGVirtualDisplay");

        // D: 主队列 + 建屏后先跑 1s run loop 再 apply，apply 后再跑 2s
        {
            id<VD_Descriptor> desc = MakeDescriptor(910, dispatch_get_main_queue());
            if ([desc respondsToSelector:@selector(setTerminationHandler:)]) {
                [desc performSelector:@selector(setTerminationHandler:) withObject:^{
                    printf("[D] terminationHandler fired\n");
                }];
            }
            id<VD_Display> d = [[dispCls alloc] initWithDescriptor:desc];
            printf("[D] created displayID=%u, spinning 1s before apply\n", [d displayID]);
            SpinRunLoop(1.0);
            BOOL ok = [d applySettings:MakeSettings(MakeMode(1920, 1080), 0)];
            printf("[D] applySettings=%d, spinning 2s\n", ok);
            SpinRunLoop(2.0);
            Report(@"D after 2s", d);
        }

        // E: 自定义串行队列（与原工程一致）+ run loop 运转 + 二次 apply
        {
            dispatch_queue_t q = dispatch_queue_create("p0.diag2", DISPATCH_QUEUE_SERIAL);
            id<VD_Descriptor> desc = MakeDescriptor(911, q);
            id<VD_Display> d = [[dispCls alloc] initWithDescriptor:desc];
            SpinRunLoop(1.0);
            BOOL ok1 = [d applySettings:MakeSettings(MakeMode(1920, 1080), 0)];
            SpinRunLoop(1.0);
            Report(@"E after 1st apply", d);
            BOOL ok2 = [d applySettings:MakeSettings(MakeMode(1920, 1080), 0)];
            printf("[E] apply1=%d apply2=%d, spinning 2s\n", ok1, ok2);
            SpinRunLoop(2.0);
            Report(@"E after 2nd apply", d);
        }

        // F: 不跑 run loop，仅 usleep 3s（复现原工程行为，作对照）
        {
            dispatch_queue_t q = dispatch_queue_create("p0.diag2f", DISPATCH_QUEUE_SERIAL);
            id<VD_Descriptor> desc = MakeDescriptor(912, q);
            id<VD_Display> d = [[dispCls alloc] initWithDescriptor:desc];
            BOOL ok = [d applySettings:MakeSettings(MakeMode(1920, 1080), 0)];
            printf("[F] applySettings=%d, usleep 3s (no run loop)\n", ok);
            P0SleepMs(3000);
            Report(@"F no runloop", d);
        }
    }
    return 0;
}