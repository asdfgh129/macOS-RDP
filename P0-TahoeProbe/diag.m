// 最小诊断：逐步读回 mode/settings/display 参数，定位 1x1 问题。
#import <Foundation/Foundation.h>
#import "CGVirtualDisplaySPI.h"
#import "ProbeUtil.h"

static void DumpKV(id obj, NSArray *keys) {
    for (NSString *k in keys) {
        @try { printf("  %s = %s\n", k.UTF8String, [[obj valueForKey:k] description].UTF8String); }
        @catch (NSException *e) { printf("  %s = <KVC fail: %s>\n", k.UTF8String, e.reason.UTF8String); }
    }
}

static void TryCombo(NSString *label, NSUInteger mw, NSUInteger mh,
                     NSUInteger maxW, NSUInteger maxH, unsigned int hiDPI, uint32_t offset) {
    printf("== %s ==\n", label.UTF8String);
    Class modeCls = VDClass(@"CGVirtualDisplayMode");
    Class setCls = VDClass(@"CGVirtualDisplaySettings");
    Class descCls = VDClass(@"CGVirtualDisplayDescriptor");
    Class dispCls = VDClass(@"CGVirtualDisplay");

    id<VD_Mode> mode = [[modeCls alloc] initWithWidth:mw height:mh refreshRate:60.0];
    printf(" mode readback (asked %zux%zu@60):\n", mw, mh);
    DumpKV(mode, @[@"width", @"height", @"refreshRate"]);

    id<VD_Settings> settings = [[setCls alloc] init];
    [settings setModes:@[mode]];
    [settings setHiDPI:hiDPI];
    printf(" settings readback (asked hiDPI=%u):\n", hiDPI);
    DumpKV(settings, @[@"modes", @"hiDPI"]);

    id<VD_Descriptor> desc = [[descCls alloc] init];
    [desc setMaxPixelsWide:(unsigned int)maxW];
    [desc setMaxPixelsHigh:(unsigned int)maxH];
    [desc setName:@"P0-DIAG"];
    [desc setSizeInMillimeters:CGSizeMake(596, 335)];
    [desc setVendorID:0x5030];
    [desc setProductID:0x5030 + offset];
    [desc setSerialNum:0x1000 + offset];
    dispatch_queue_t q = dispatch_queue_create("p0.diag", DISPATCH_QUEUE_SERIAL);
    [desc setQueue:q];
    printf(" descriptor readback:\n");
    DumpKV(desc, @[@"maxPixelsWide", @"maxPixelsHigh", @"vendorID", @"productID", @"serialNum"]);

    id<VD_Display> display = [[dispCls alloc] initWithDescriptor:desc];
    if (!display) { printf(" display nil\n"); return; }
    BOOL ok = [display applySettings:settings];
    CGDirectDisplayID did = [display displayID];
    printf(" applySettings=%d displayID=%u\n", ok, did);
    printf(" display readback:\n");
    DumpKV(display, @[@"hiDPI", @"modes", @"maxPixelsWide", @"maxPixelsHigh"]);
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(did);
    if (m) {
        printf(" CG mode: points=%zux%zu pixels=%zux%zu\n",
               CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m),
               CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m));
        CGDisplayModeRelease(m);
    }
    CGRect b = CGDisplayBounds(did);
    printf(" bounds=%s online=%d active=%d\n",
           P0RectString(b).UTF8String, CGDisplayIsOnline(did), CGDisplayIsActive(did));
    P0SleepMs(300);
}

int main(void) {
    @autoreleasepool {
        if (!VDLoadPrivateClasses()) { printf("classes missing\n"); return 1; }
        TryCombo(@"A: mode1280x800 max1920x1080 hiDPI0", 1280, 800, 1920, 1080, 0, 900);
        TryCombo(@"B: mode1920x1080 max1920x1080 hiDPI0", 1920, 1080, 1920, 1080, 0, 901);
        TryCombo(@"C: mode1920x1080 max1920x1080 hiDPI2", 1920, 1080, 1920, 1080, 2, 902);
        P0SleepMs(300);
    }
    return 0;
}