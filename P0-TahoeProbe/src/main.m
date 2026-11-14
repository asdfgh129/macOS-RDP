//
//  main.m
//  P0-TahoeProbe
//
//  在【被控端】Intel Mac / macOS 26 Tahoe 上运行的 P0 技术验证工具。
//  验证链路：CGVirtualDisplay 建 N 屏 → liveness → SCShareableContent 可见性
//            → 分辨率提升 → SCK 逐屏捕获 → VideoToolbox H.264 硬编 → 本机环回解码。
//
//  不需要 Xcode 工程、不需要签名、不需要 App bundle，build.sh 直接 clang 编译。
//

#import <Foundation/Foundation.h>
#import "CGVirtualDisplaySPI.h"
#import "ProbeUtil.h"
#import "VDManager.h"
#import "PipelineProbe.h"

#pragma mark - argv parsing

static NSDictionary *P0ParseArgs(NSArray<NSString *> *argv) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"command"] = argv.count > 1 ? argv[1] : @"probe";
    for (NSUInteger i = 2; i < argv.count; i++) {
        NSString *a = argv[i];
        if (![a hasPrefix:@"--"]) continue;
        NSString *key = [a substringFromIndex:2];
        if ([key containsString:@"="]) {
            NSArray *kv = [key componentsSeparatedByString:@"="];
            d[kv[0]] = kv[1];
            continue;
        }
        if ([key isEqualToString:@"no-encode"] || [key isEqualToString:@"direct"] ||
            [key isEqualToString:@"fresh"] || [key isEqualToString:@"capabilities"]) {
            d[key] = @YES;
        } else if (i + 1 < argv.count && ![argv[i + 1] hasPrefix:@"--"]) {
            d[key] = argv[++i];
        } else {
            d[key] = @YES;
        }
    }
    return d;
}

static int P0IntArg(NSDictionary *args, NSString *key, int fallback) {
    id v = args[key];
    if ([v respondsToSelector:@selector(intValue)]) return [v intValue];
    return fallback;
}

static NSArray<NSDictionary *> *P0ParseSpec(NSString *spec) {
    // 格式：WxHxHIDPI[,WxHxHIDPI...]  例如 1920x1080x0,2560x1440x1
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *part in [spec componentsSeparatedByString:@","]) {
        NSArray *f = [part componentsSeparatedByString:@"x"];
        if (f.count < 2) continue;
        [out addObject:@{
            @"width": @([f[0] intValue]),
            @"height": @([f[1] intValue]),
            @"hiDPI": @(f.count > 2 ? [f[2] intValue] : 0),
            @"refreshRate": @60,
        }];
    }
    return out;
}

#pragma mark - commands

static int P0CommandProbe(NSDictionary *args) {
    NSDictionary *env = P0SystemInfo();
    P0Emit(@"env", env);
    P0Log(@"OS %@ / %@ / %@ / parent=%@", env[@"osVersion"], env[@"arch"],
          env[@"model"], env[@"parentApp"]);

    if (![env[@"arch"] isEqualToString:@"x86_64"]) {
        P0Log(@"提示：本工程面向 Intel 被控端，当前是 %@，结果仅作参考", env[@"arch"]);
    }

    BOOL loaded = VDLoadPrivateClasses();
    P0Emit(@"spi", @{
        @"allClassesResolved": @(loaded),
        @"modeSels": VDSelectorDump(@"CGVirtualDisplayMode") ?: @[],
        @"settingsSels": VDSelectorDump(@"CGVirtualDisplaySettings") ?: @[],
        @"descriptorSels": VDSelectorDump(@"CGVirtualDisplayDescriptor") ?: @[],
        @"displaySels": VDSelectorDump(@"CGVirtualDisplay") ?: @[],
    });

    // 与 macOS 15/27 上核对过的签名比对，把缺失项直接列出来。
    NSArray *required = @[
        @"CGVirtualDisplayMode:initWithWidth:height:refreshRate:",
        @"CGVirtualDisplaySettings:setModes:", @"CGVirtualDisplaySettings:setHiDPI:",
        @"CGVirtualDisplayDescriptor:setMaxPixelsWide:", @"CGVirtualDisplayDescriptor:setMaxPixelsHigh:",
        @"CGVirtualDisplayDescriptor:setVendorID:", @"CGVirtualDisplayDescriptor:setProductID:",
        @"CGVirtualDisplayDescriptor:setSerialNum:", @"CGVirtualDisplayDescriptor:setName:",
        @"CGVirtualDisplayDescriptor:setQueue:",
        @"CGVirtualDisplay:initWithDescriptor:", @"CGVirtualDisplay:applySettings:",
        @"CGVirtualDisplay:displayID:",
    ];
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *r in required) {
        NSArray *kv = [r componentsSeparatedByString:@":"];
        NSArray *sels = VDSelectorDump(kv[0]) ?: @[];
        NSString *sel = [r substringFromIndex:kv[0].length + 1];
        // 属性 getter（如 displayID）无尾冒号，setter / init 有，两种都接受。
        NSString *alt = [sel hasSuffix:@":"] ? [sel substringToIndex:sel.length - 1] : sel;
        if (![sels containsObject:sel] && ![sels containsObject:alt]) [missing addObject:r];
    }
    P0Emit(@"spi-signature-check", @{ @"missing": missing, @"ok": @(missing.count == 0) });
    if (missing.count) P0Error(@"以下 selector 在目标系统上缺失，需要更新本地重声明：%@", missing);

    P0Emit(@"displays-before", @{ @"list": P0DisplayList() });

    NSError *err = nil;
    NSArray *ids = [PipelineProbe shareableDisplayIDsWithError:&err];
    P0Emit(@"sck-before", @{
        @"error": err.localizedDescription ?: @"",
        @"visibleDisplayIDs": ids ?: @[],
        @"screenRecordingGranted": @(ids != nil),
    });
    if (!ids) {
        P0Error(@"屏幕录制权限未就绪。请给「%@」在 系统设置 → 隐私与安全性 → 屏幕录制 授权，然后重开终端。",
                env[@"parentApp"]);
    }

    if (args[@"capabilities"]) P0Emit(@"encoder-capabilities", [PipelineProbe encoderCapabilities]);
    return loaded ? 0 : 1;
}

static int P0CommandCapabilities(void) {
    P0Emit(@"env", P0SystemInfo());
    P0Emit(@"encoder-capabilities", [PipelineProbe encoderCapabilities]);
    return 0;
}

// 建屏 + visibility + identity walk。成功返回一个已持有的 VDManager，失败返回 nil。
static VDManager * _Nullable P0EstablishDisplays(NSArray<NSDictionary *> *configs,
                                                  NSDictionary *args,
                                                  uint32_t *outOffset) {
    uint32_t base = args[@"fresh"] ? 0 : (uint32_t)[VDManager savedIdentityOffset];
    if (args[@"offset"]) base = (uint32_t)P0IntArg(args, @"offset", 0);
    int maxRetries = P0IntArg(args, @"max-retries", 8);
    BOOL direct = [args[@"direct"] boolValue];
    int visTimeout = P0IntArg(args, @"visibility-timeout", 5000);

    for (int attempt = 0; attempt <= maxRetries; attempt++) {
        uint32_t offset = base + (uint32_t)attempt;
        P0Log(@"identity 尝试 %d/%d，offset=%u (vendor/product/serial 同步游走)",
              attempt + 1, maxRetries + 1, offset);

        VDManager *mgr = [[VDManager alloc] initWithConfigs:configs
                                            identityOffset:offset
                                         conservativeFirst:!direct];
        if (![mgr createAll]) { [mgr destroyAll]; continue; }

        if (![mgr waitUntilUsableTimeoutMs:3000]) {
            P0Error(@"online/active 检查未通过 —— Tahoe stale display 特征，换 identity 重建");
            P0Emit(@"liveness", @{ @"attempt": @(attempt), @"detail": [mgr liveness] });
            [mgr destroyAll];
            continue;
        }
        P0Emit(@"liveness", @{ @"attempt": @(attempt), @"detail": [mgr liveness] });

        NSArray *seen = nil;
        BOOL visible = [PipelineProbe waitForDisplayIDs:mgr.displayIDs
                                             timeoutMs:visTimeout
                                              lastSeen:&seen];
        P0Emit(@"visibility", @{
            @"attempt": @(attempt),
            @"wanted": mgr.displayIDs,
            @"seen": seen ?: @[],
            @"ok": @(visible),
        });
        if (!visible) {
            P0Error(@"虚拟屏未出现在 SCShareableContent —— 命中 Tahoe 的 poisoned identity，换一组重建");
            [mgr destroyAll];
            continue;
        }

        NSError *saveErr = nil;
        [VDManager saveIdentityOffset:offset error:&saveErr];
        if (saveErr) P0Error(@"identity offset 持久化失败: %@", saveErr.localizedDescription);
        if (outOffset) *outOffset = offset;

        // 保守 canvas → 目标分辨率；失败则事务性回退。
        if (!direct) {
            if ([mgr promoteToTarget]) {
                BOOL stillVisible = [PipelineProbe waitForDisplayIDs:mgr.displayIDs
                                                         timeoutMs:3000 lastSeen:NULL];
                BOOL stillUsable = [mgr waitUntilUsableTimeoutMs:2000];
                P0Emit(@"promote", @{ @"ok": @(stillVisible && stillUsable),
                                      @"stillVisible": @(stillVisible),
                                      @"stillUsable": @(stillUsable),
                                      @"detail": [mgr liveness] });
                if (!stillVisible || !stillUsable) {
                    P0Error(@"提升分辨率后虚拟屏丢失，回退到保守 canvas（PR #288 的事务性回退）");
                    [mgr rollbackToConservative];
                    [PipelineProbe waitForDisplayIDs:mgr.displayIDs timeoutMs:3000 lastSeen:NULL];
                }
            } else {
                P0Error(@"applySettings 提升失败，保持保守 canvas");
                [mgr rollbackToConservative];
            }
        }
        return mgr;
    }
    return nil;
}

static int P0CommandVerify(NSDictionary *args, BOOL hold) {
    NSString *spec = args[@"spec"] ?: @"1920x1080x0,2560x1440x0";
    NSArray *configs = P0ParseSpec(spec);
    int duration = P0IntArg(args, @"duration", 4000);
    int holdSeconds = P0IntArg(args, @"hold-seconds", 60);
    BOOL withEncoder = !args[@"no-encode"];

    P0Emit(@"env", P0SystemInfo());
    P0Emit(@"plan", @{
        @"spec": spec,
        @"displays": configs,
        @"durationMs": @(duration),
        @"withEncoder": @(withEncoder),
        @"conservativeFirst": @(!args[@"direct"]),
        @"identityPath": [VDManager identityPath],
    });

    NSError *tccErr = nil;
    NSArray *before = [PipelineProbe shareableDisplayIDsWithError:&tccErr];
    P0Emit(@"sck-before", @{
        @"visibleDisplayIDs": before ?: @[],
        @"error": tccErr.localizedDescription ?: @"",
        @"screenRecordingGranted": @(before != nil),  // 与 README 第 5 节判读表对齐
    });
    if (!before) {
        P0Error(@"屏幕录制权限未就绪，先运行 `p0probe probe` 并按提示授权");
        return 1;
    }

    if (withEncoder) P0Emit(@"encoder-capabilities", [PipelineProbe encoderCapabilities]);

    uint32_t usedOffset = 0;
    VDManager *mgr = P0EstablishDisplays(configs, args, &usedOffset);
    if (!mgr) {
        P0Emit(@"verdict", @{
            @"pass": @NO,
            @"reason": @"IDENTITY_WALK_EXHAUSTED",
            @"detail": @"所有 identity 均无法让虚拟屏同时满足 online/active 与 SCShareableContent 可见",
        });
        return 1;
    }

    P0Emit(@"displays-after", @{ @"list": P0DisplayList() });

    if (hold) {
        P0Log(@"保持 %d 秒。现在可在另一台 Mac 或本机「系统设置 → 显示器」核对：", holdSeconds);
        P0Log(@"  1) 是否出现 %lu 块 P0-VD* 虚拟屏；2) 排列与分辨率；3) 是否能拖窗口过去", (unsigned long)configs.count);
        P0SleepMs(holdSeconds * 1000);
    }

    NSMutableArray *captureResults = [NSMutableArray array];
    for (NSNumber *did in mgr.displayIDs) {
        int displayCount = (int)mgr.displayIDs.count;
        int perDisplay = MAX(1000, duration / MAX(1, displayCount));
        NSDictionary *r = [PipelineProbe captureDisplayID:did.unsignedIntValue
                                              durationMs:perDisplay
                                             withEncoder:withEncoder];
        [captureResults addObject:r];
        P0Emit(@"capture", r);
    }

    BOOL allCaptured = captureResults.count == configs.count;
    BOOL noBlack = YES, encodedOK = YES;
    for (NSDictionary *r in captureResults) {
        if (![r[@"ok"] boolValue] || [r[@"frames"] intValue] == 0) allCaptured = NO;
        if ([r[@"suspectedBlackFrames"] intValue] > [r[@"frames"] intValue] * 0.8) noBlack = NO;
        if (withEncoder && [r[@"encodedFrames"] intValue] == 0) encodedOK = NO;
    }

    NSDictionary *summary = @{
        @"pass": @(allCaptured && noBlack && (!withEncoder || encodedOK)),
        @"allCaptured": @(allCaptured),
        @"noBlackFrames": @(noBlack),
        @"encoderProducedFrames": @(encodedOK),
        @"identityOffset": @(usedOffset),
        @"displays": mgr.displayIDs,
        @"capture": captureResults,
        @"next": allCaptured && noBlack
            ? @"P0 通过：继续做 CGEvent 坐标注入 spike 与双机 P2P glass-to-glass 延迟"
            : @"P0 未通过：按 verdict 字段定位是 TCC / stale identity / 黑屏 / 编码器哪一环",
    };
    P0Emit(@"verdict", summary);
    NSError *werr = nil;
    P0WriteJSON(summary, @"p0_result.json", &werr);
    P0Log(@"结果已写入 ./p0_result.json");

    [mgr destroyAll];
    return [summary[@"pass"] boolValue] ? 0 : 1;
}

#pragma mark - main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray *argvNS = [[NSProcessInfo processInfo] arguments];
        NSDictionary *args = P0ParseArgs(argvNS);
        NSString *cmd = args[@"command"];

        P0Log(@"P0-TahoeProbe  command=%@", cmd);

        int rc = 0;
        if ([cmd isEqualToString:@"probe"]) {
            rc = P0CommandProbe(args);
        } else if ([cmd isEqualToString:@"capabilities"]) {
            rc = P0CommandCapabilities();
        } else if ([cmd isEqualToString:@"verify"]) {
            rc = P0CommandVerify(args, NO);
        } else if ([cmd isEqualToString:@"hold"]) {
            rc = P0CommandVerify(args, YES);
        } else {
            fprintf(stderr,
                "P0-TahoeProbe — Intel Mac / macOS 26 Tahoe 虚拟屏 P0 验证\n\n"
                "  p0probe probe  --capabilities              环境与私有 API 签名探测\n"
                "  p0probe capabilities                       仅探测 VideoToolbox 编码档位\n"
                "  p0probe verify [--spec 1920x1080x0,2560x1440x0]\n"
                "                 [--duration 4000] [--no-encode] [--direct]\n"
                "                 [--offset N] [--fresh] [--max-retries 8]\n"
                "                 [--visibility-timeout 5000]   完整 P0 链路\n"
                "  p0probe hold   --hold-seconds 60 [...]       建屏后保持，便于在 GUI 核对\n\n"
                "spec 格式：WxHxHIDPI，多屏用逗号分隔；HIDPI=1 时 descriptor 自动用 2 倍像素。\n");
            rc = 0;
        }
        return rc;
    }
}
