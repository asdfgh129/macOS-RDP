//
//  VDManager.m
//  P0-TahoeProbe
//

#import "VDManager.h"
#import "CGVirtualDisplaySPI.h"
#import "ProbeUtil.h"

// 自定义 vendor，避开 BetterDisplay / OpenDisplay / Duet 等常用值，减少 identity 撞车。
static const uint32_t kVendorID    = 0x5030;  // 'P0'
static const uint32_t kProductBase = 0x5030;
static const uint32_t kSerialBase  = 0x1000;

@interface VDManager ()
@property (nonatomic, copy) NSArray<NSDictionary *> *configs;
@property (nonatomic, assign) uint32_t identityOffset;
@property (nonatomic, assign) BOOL conservativeFirst;
@property (nonatomic, strong) NSMutableArray<id> *heldDisplays;
@property (nonatomic, strong) NSMutableArray<id> *heldDescriptors;
@property (nonatomic, strong) NSMutableArray<dispatch_queue_t> *heldQueues;
@property (nonatomic, assign) BOOL promoted;
@end

@implementation VDManager

- (instancetype)initWithConfigs:(NSArray<NSDictionary *> *)configs
                 identityOffset:(uint32_t)offset
              conservativeFirst:(BOOL)conservativeFirst {
    self = [super init];
    if (self) {
        _configs = [configs copy];
        _identityOffset = offset;
        _conservativeFirst = conservativeFirst;
        _heldDisplays = [NSMutableArray array];
        _heldDescriptors = [NSMutableArray array];
        _heldQueues = [NSMutableArray array];
        _promoted = NO;
    }
    return self;
}

- (NSArray<id> *)displays { return [_heldDisplays copy]; }

- (NSArray<NSNumber *> *)displayIDs {
    NSMutableArray *ids = [NSMutableArray array];
    for (id<VD_Display> d in _heldDisplays) {
        [ids addObject:@([d displayID])];
    }
    return ids;
}

#pragma mark - identity persistence

+ (NSString *)identityPath {
    return [@"~/.p0_identity.json" stringByExpandingTildeInPath];
}

+ (uint32_t)savedIdentityOffset {
    NSDictionary *d = P0ReadJSON([self identityPath]);
    id v = d[@"offset"];
    return [v respondsToSelector:@selector(unsignedIntValue)] ? [v unsignedIntValue] : 0;
}

+ (BOOL)saveIdentityOffset:(uint32_t)offset error:(NSError **)error {
    NSDictionary *d = @{
        @"offset": @(offset),
        @"note": @"last vendor/product/serial identity that produced a live virtual display on this Mac",
        @"updatedAt": @([[NSDate date] timeIntervalSince1970]),
    };
    return P0WriteJSON(d, [self identityPath], error);
}

#pragma mark - settings construction

// conservative=YES 时先用 1280x800@1x 建屏，等 SCK 看到之后再提升。
// 来自 OpenDisplay PR #288：直接建大尺寸虚拟屏在 Tahoe 上可能只出现壁纸+光标。
- (NSDictionary *)effectiveConfigForIndex:(NSUInteger)i conservative:(BOOL)conservative {
    NSDictionary *cfg = _configs[i];
    if (!conservative) return cfg;
    NSUInteger w = [cfg[@"width"] unsignedIntegerValue];
    NSUInteger h = [cfg[@"height"] unsignedIntegerValue];
    if (w <= 1280 && h <= 800 && [cfg[@"hiDPI"] unsignedIntValue] == 0) return cfg;
    return @{ @"width": @1280, @"height": @800, @"hiDPI": @0,
              @"refreshRate": cfg[@"refreshRate"] ?: @60 };
}

- (id)makeSettingsForConfig:(NSDictionary *)cfg {
    Class modeCls = VDClass(@"CGVirtualDisplayMode");
    Class setCls = VDClass(@"CGVirtualDisplaySettings");
    if (!modeCls || !setCls) return nil;

    NSUInteger w = [cfg[@"width"] unsignedIntegerValue];
    NSUInteger h = [cfg[@"height"] unsignedIntegerValue];
    double rate = [cfg[@"refreshRate"] doubleValue] ?: 60.0;
    unsigned int hiDPI = [cfg[@"hiDPI"] unsignedIntValue];

    // 显式 cast 到 protocol，让编译器按声明生成正确 ABI 的 objc_msgSend，
    // 而不是对 id 做全局 selector 猜测（参数含 double/NSUInteger 时容易出错）。
    id rawMode = [modeCls alloc];
    id<VD_Mode> mode = [(id<VD_Mode>)rawMode initWithWidth:w height:h refreshRate:rate];
    if (!mode) return nil;

    id<VD_Settings> settings = [[setCls alloc] init];
    if (!VDResponds(settings, @selector(setModes:))) return nil;
    [settings setModes:@[mode]];
    if (VDResponds(settings, @selector(setHiDPI:))) [settings setHiDPI:hiDPI];
    return settings;
}

- (id)makeDescriptorForIndex:(NSUInteger)i config:(NSDictionary *)cfg {
    Class cls = VDClass(@"CGVirtualDisplayDescriptor");
    if (!cls) return nil;

    id<VD_Descriptor> desc = [[cls alloc] init];
    if (!desc) return nil;

    NSUInteger w = [cfg[@"width"] unsignedIntegerValue];
    NSUInteger h = [cfg[@"height"] unsignedIntegerValue];
    unsigned int hiDPI = [cfg[@"hiDPI"] unsignedIntValue];
    uint32_t scale = hiDPI ? 2 : 1;
    uint32_t offset = _identityOffset;

    if (VDResponds(desc, @selector(setName:))) {
        [desc setName:[NSString stringWithFormat:@"P0-VD%lu-%ux%u",
                       (unsigned long)i + 1, (unsigned)w, scale]];
    }
    // 关键：HiDPI 时 descriptor 用像素尺寸，settings.modes 用 points 尺寸。
    if (VDResponds(desc, @selector(setMaxPixelsWide:))) [desc setMaxPixelsWide:(unsigned int)w * scale];
    if (VDResponds(desc, @selector(setMaxPixelsHigh:))) [desc setMaxPixelsHigh:(unsigned int)h * scale];
    if (VDResponds(desc, @selector(setSizeInMillimeters:))) [desc setSizeInMillimeters:CGSizeMake(596, 335)];

    // identity walk：serial 与 product 同步游走，绕开 WindowServer 缓存的坏 identity。
    if (VDResponds(desc, @selector(setVendorID:)))   [desc setVendorID:kVendorID];
    if (VDResponds(desc, @selector(setProductID:)))  [desc setProductID:kProductBase + offset];
    if (VDResponds(desc, @selector(setSerialNum:)))  [desc setSerialNum:kSerialBase + (uint32_t)i + offset];

    dispatch_queue_t q = dispatch_queue_create("p0.vd.termination", DISPATCH_QUEUE_SERIAL);
    [self.heldQueues addObject:q];
    if (VDResponds(desc, @selector(setQueue:))) [desc setQueue:q];

    return desc;
}

#pragma mark - create / destroy

- (BOOL)createAll {
    if (!VDLoadPrivateClasses()) {
        P0Error(@"CGVirtualDisplay* 私有类解析失败，Tahoe 上可能已改类名或迁移 framework");
        P0Log(@"请运行 `p0probe probe` 查看 selector dump 与系统信息");
        return NO;
    }
    Class displayCls = VDClass(@"CGVirtualDisplay");
    if (!displayCls) return NO;

    BOOL allOK = YES;
    for (NSUInteger i = 0; i < _configs.count; i++) {
        NSDictionary *targetCfg = _configs[i];
        NSDictionary *initialCfg = [self effectiveConfigForIndex:i conservative:_conservativeFirst];

        // descriptor 的 maxPixels* 描述「这块屏的最大像素能力」，必须用目标尺寸一次给足；
        // settings.modes 才是当前工作模式，先用保守 canvas，等 SCK 看见后再 applySettings 提升。
        // 若 descriptor 也按 1280x800 给，之后提升 mode 会被 maxPixels 卡住。
        id desc = [self makeDescriptorForIndex:i config:targetCfg];
        id settings = [self makeSettingsForConfig:initialCfg];
        if (!desc || !settings) { P0Error(@"屏 #%lu descriptor/settings 构造失败", (unsigned long)i + 1); allOK = NO; break; }

        id rawDisplay = [displayCls alloc];
        id<VD_Display> display = [(id<VD_Display>)rawDisplay initWithDescriptor:desc];
        if (!display) {
            P0Error(@"屏 #%lu initWithDescriptor: 返回 nil（identity 可能被拒绝）", (unsigned long)i + 1);
            allOK = NO;
            break;
        }
        BOOL applied = [display applySettings:settings];
        CGDirectDisplayID did = [display displayID];

        // 顺序很重要：必须先把对象存进数组，绝不能让 ARC 在作用域末尾释放，
        // CGVirtualDisplay 实例一释放，虚拟显示器立刻从 WindowServer 注销。
        [self.heldDisplays addObject:display];
        [self.heldDescriptors addObject:desc];

        P0Emit(@"create", @{
            @"index": @(i),
            @"displayID": @(did),
            @"applySettings": @(applied),
            @"requestedPoints": [NSString stringWithFormat:@"%@x%@", initialCfg[@"width"], initialCfg[@"height"]],
            @"targetPoints": [NSString stringWithFormat:@"%@x%@", targetCfg[@"width"], targetCfg[@"height"]],
            @"hiDPI": initialCfg[@"hiDPI"] ?: @0,
            @"conservative": @(_conservativeFirst),
            @"identityOffset": @(_identityOffset),
            @"vendorID": @(kVendorID),
            @"productID": @(kProductBase + _identityOffset),
            @"serialNum": @(kSerialBase + (uint32_t)i + _identityOffset),
        });
        if (!applied) allOK = NO;
    }

    if (!allOK) [self destroyAll];
    return allOK;
}

- (void)destroyAll {
    P0Log(@"销毁 %lu 块虚拟屏（对象释放即注销）", (unsigned long)_heldDisplays.count);
    [self.heldDisplays removeAllObjects];
    [self.heldDescriptors removeAllObjects];
    [self.heldQueues removeAllObjects];
    _promoted = NO;
    // 给 WindowServer 一点时间处理注销，否则立刻重建可能命中同一个 stale identity。
    P0SleepMs(300);
}

- (BOOL)applyConfiguredDimsConservative:(BOOL)conservative {
    BOOL allOK = YES;
    for (NSUInteger i = 0; i < _heldDisplays.count; i++) {
        NSDictionary *cfg = [self effectiveConfigForIndex:i conservative:conservative];
        id settings = [self makeSettingsForConfig:cfg];
        id<VD_Display> display = _heldDisplays[i];
        BOOL ok = settings ? [display applySettings:settings] : NO;
        P0Emit(@"applySettings", @{
            @"index": @(i),
            @"displayID": @([display displayID]),
            @"points": [NSString stringWithFormat:@"%@x%@", cfg[@"width"], cfg[@"height"]],
            @"hiDPI": cfg[@"hiDPI"] ?: @0,
            @"ok": @(ok),
        });
        if (!ok) allOK = NO;
    }
    return allOK;
}

- (BOOL)promoteToTarget {
    if (!_conservativeFirst) return YES;
    BOOL ok = [self applyConfiguredDimsConservative:NO];
    _promoted = ok;
    return ok;
}

- (BOOL)rollbackToConservative {
    BOOL ok = [self applyConfiguredDimsConservative:YES];
    _promoted = NO;
    return ok;
}

#pragma mark - liveness

- (NSArray<NSDictionary *> *)liveness {
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < _heldDisplays.count; i++) {
        id<VD_Display> d = _heldDisplays[i];
        CGDirectDisplayID did = [d displayID];
        CGRect bounds = CGDisplayBounds(did);
        BOOL online = CGDisplayIsOnline(did);
        BOOL active = CGDisplayIsActive(did);
        BOOL boundsOK = !CGRectIsEmpty(bounds);

        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(did);
        NSString *points = @"(nil)";
        NSString *pixels = @"(nil)";
        if (mode) {
            points = [NSString stringWithFormat:@"%zux%zu", CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode)];
            pixels = [NSString stringWithFormat:@"%zux%zu", CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode)];
            CGDisplayModeRelease(mode);
        }

        [out addObject:@{
            @"index": @(i),
            @"displayID": @(did),
            @"online": @(online),
            @"active": @(active),
            @"bounds": P0RectString(bounds),
            @"boundsNonEmpty": @(boundsOK),
            @"usable": @(online && active && boundsOK),
            @"modePoints": points,
            @"modePixels": pixels,
            @"reportedHiDPI": @([d hiDPI]),
        }];
    }
    return out;
}

- (BOOL)allUsable {
    for (NSDictionary *d in [self liveness]) {
        if (![d[@"usable"] boolValue]) return NO;
    }
    return _heldDisplays.count > 0;
}

- (BOOL)waitUntilUsableTimeoutMs:(int)timeoutMs {
    int elapsed = 0;
    while (elapsed < timeoutMs) {
        if ([self allUsable]) return YES;
        P0SleepMs(100);
        elapsed += 100;
    }
    P0Emit(@"liveness-timeout", @{
        @"timeoutMs": @(timeoutMs),
        @"detail": [self liveness],
    });
    return NO;
}

@end
