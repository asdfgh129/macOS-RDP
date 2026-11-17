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
#import <IOKit/pwr_mgt/IOPMLib.h>
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
    P0Emit(@"os-policy", P0OSPolicy());
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
        NSString *clsName = kv[0];
        NSArray *sels = VDSelectorDump(clsName) ?: @[];
        NSString *sel = [r substringFromIndex:clsName.length + 1];
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
        // 注意：必须显式转 BOOL，否则 `ids != nil` 是 int，@() 会装箱成 1/0，
        // 而 README 判读表与外部脚本按 true/false 匹配（2026-11-17 已踩坑两次）
        @"screenRecordingGranted": @((BOOL)(ids != nil)),
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

// capture 子命令：**完全不建屏**，直接捕获系统里已有的 display。
// 用途：验证「捕获优先」架构 —— 被控机本来就有物理屏时，直接采它就行，
// 既没有 11 秒建屏开销，也不涉及 identity walk。
// 参数：--display all|<id>[,<id>...]  --duration N  --no-encode
static int P0CommandCapture(NSDictionary *args) {
    P0Emit(@"env", P0SystemInfo());

    NSError *err = nil;
    NSArray *ids = [PipelineProbe shareableDisplayIDsWithError:&err];
    P0Emit(@"sck", @{
        @"visibleDisplayIDs": ids ?: @[],
        @"error": err.localizedDescription ?: @"",
        @"screenRecordingGranted": @((BOOL)(ids != nil)),
    });
    if (!ids) {
        P0Error(@"屏幕录制权限未就绪");
        return 1;
    }

    NSMutableArray *targets = [NSMutableArray array];
    NSString *want = args[@"display"];
    if (!want || [want isEqualToString:@"all"]) {
        [targets addObjectsFromArray:ids];
    } else {
        for (NSString *s in [want componentsSeparatedByString:@","]) {
            NSString *t = [s stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceCharacterSet]];
            if (t.length) [targets addObject:@((unsigned int)[t longLongValue])];
        }
    }
    if (targets.count == 0) {
        P0Error(@"没有可捕获的 display");
        return 1;
    }

    int duration = P0IntArg(args, @"duration", 4000);
    BOOL withEncoder = args[@"no-encode"] ? NO : YES;
    int perDisplay = MAX(1000, duration / (int)targets.count);

    P0Emit(@"plan", @{
        @"mode": @"capture-only",
        @"targets": targets,
        @"durationMs": @(duration),
        @"withEncoder": @(withEncoder),
    });

    NSMutableArray *results = [NSMutableArray array];
    NSDate *t0 = [NSDate date];
    for (NSNumber *did in targets) {
        NSDictionary *r = [PipelineProbe captureDisplayID:did.unsignedIntValue
                                              durationMs:perDisplay
                                             withEncoder:withEncoder];
        [results addObject:r];
        P0Emit(@"capture", r);
    }
    double elapsedMs = -[t0 timeIntervalSinceNow] * 1000.0;

    BOOL allOK = YES;
    for (NSDictionary *r in results) {
        if (![r[@"ok"] boolValue] || [r[@"frames"] intValue] == 0) allOK = NO;
        if ([r[@"suspectedBlackFrames"] intValue] > [r[@"frames"] intValue] * 0.8) allOK = NO;
    }

    P0Emit(@"verdict", @{
        @"pass": @(allOK),
        @"mode": @"capture-only",
        @"displayCount": @(results.count),
        @"elapsedMs": @(llround(elapsedMs)),
        @"note": @"未创建任何虚拟屏；这是「捕获优先」路径的可行性验证",
        @"capture": results,
    });
    return allOK ? 0 : 1;
}

// 建屏 + visibility。策略按 OS 版本分流（P0OSPolicy）：
//  - Tahoe(26)：保守 canvas→promote、identity walk、offset 持久化（stale/poisoned workaround）；
//  - Sequoia(15) 及其它：直建目标分辨率、固定 identity、失败即止，不做 Tahoe 专属重试。
// 成功返回已持有的 VDManager；失败返回 nil，outReason 给出失败环节。
// outHung=YES 表示 WindowServer 疑似挂起：调用方必须立即结束进程，不得再发任何 SPI。
static VDManager * _Nullable P0EstablishDisplays(NSArray<NSDictionary *> *configs,
                                                  NSDictionary *args,
                                                  uint32_t *outOffset,
                                                  BOOL *outHung,
                                                  NSString * _Nullable * _Nullable outReason) {
    NSDictionary *policy = P0OSPolicy();
    BOOL walk = [policy[@"identityWalk"] boolValue];
    BOOL conservative = args[@"direct"] ? NO : [policy[@"conservativeFirst"] boolValue];
    uint32_t base = args[@"fresh"] ? 0 : (walk ? (uint32_t)[VDManager savedIdentityOffset] : 0);
    if (args[@"offset"]) base = (uint32_t)P0IntArg(args, @"offset", 0);
    int maxRetries = P0IntArg(args, @"max-retries", [policy[@"maxRetries"] intValue]);
    int visTimeout = P0IntArg(args, @"visibility-timeout", 5000);
    int modeWaitMs = [policy[@"modeWaitMs"] intValue];

    P0Log(@"OS 策略：%@（macOS %@）→ conservativeFirst=%d identityWalk=%d maxRetries=%d",
          policy[@"osName"], policy[@"osMajor"], conservative, walk, maxRetries);

    NSString *reason = @"IDENTITY_WALK_EXHAUSTED";
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
        uint32_t offset = walk ? base + (uint32_t)attempt : base;
        P0Log(@"建屏尝试 %d/%d，offset=%u%@", attempt + 1, maxRetries + 1, offset,
              walk ? @"（vendor/product/serial 同步游走）" : @"（固定 identity）");

        VDManager *mgr = [[VDManager alloc] initWithConfigs:configs
                                            identityOffset:offset
                                         conservativeFirst:conservative];
        if (![mgr createAll]) {
            BOOL hung = mgr.windowServerHung;
            [mgr destroyAll];
            if (hung) { if (outHung) *outHung = YES; return nil; }
            reason = @"CREATE_FAILED";
            if (!walk) break;   // 非 Tahoe：不做 identity 重试，避免向异常 WindowServer 继续施压
            continue;
        }

        if (![mgr waitUntilUsableTimeoutMs:3000]) {
            P0Error(@"online/active 检查未通过");
            P0Emit(@"liveness", @{ @"attempt": @(attempt), @"detail": [mgr liveness] });
            [mgr destroyAll];
            reason = @"LIVENESS_FAILED";
            if (!walk) break;
            continue;
        }
        P0Emit(@"liveness", @{ @"attempt": @(attempt), @"detail": [mgr liveness] });

        // createAll 已逐屏等过 mode 提交，这里是双保险（promote 后还会再查一次）。
        if (![mgr waitUntilModeMatchesTimeoutMs:modeWaitMs conservative:conservative]) {
            if (mgr.windowServerHung) { if (outHung) *outHung = YES; return nil; }
            P0Error(@"mode 未提交到请求尺寸");
            [mgr destroyAll];
            reason = @"MODE_COMMIT_FAILED";
            if (!walk) break;
            continue;
        }
        P0Emit(@"mode-wait", @{ @"attempt": @(attempt), @"ok": @YES, @"detail": [mgr liveness] });

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
            P0Error(@"虚拟屏未出现在 SCShareableContent");
            [mgr destroyAll];
            reason = @"VISIBILITY_FAILED";
            if (!walk) break;
            continue;
        }

        if (walk && [policy[@"persistIdentity"] boolValue]) {
            NSError *saveErr = nil;
            [VDManager saveIdentityOffset:offset error:&saveErr];
            if (saveErr) P0Error(@"identity offset 持久化失败: %@", saveErr.localizedDescription);
        }
        if (outOffset) *outOffset = offset;

        // 保守 canvas → 目标分辨率（仅 Tahoe 默认路径）；失败则事务性回退。
        if (conservative) {
            if ([mgr promoteToTarget]) {
                BOOL modeOK = [mgr waitUntilModeMatchesTimeoutMs:modeWaitMs conservative:NO];
                BOOL stillVisible = [PipelineProbe waitForDisplayIDs:mgr.displayIDs
                                                         timeoutMs:3000 lastSeen:NULL];
                BOOL stillUsable = [mgr waitUntilUsableTimeoutMs:2000];
                P0Emit(@"promote", @{ @"ok": @(modeOK && stillVisible && stillUsable),
                                      @"modeCommitted": @(modeOK),
                                      @"stillVisible": @(stillVisible),
                                      @"stillUsable": @(stillUsable),
                                      @"detail": [mgr liveness] });
                if (!modeOK || !stillVisible || !stillUsable) {
                    P0Error(@"提升分辨率后虚拟屏丢失或 mode 未提交，回退到保守 canvas（PR #288 的事务性回退）");
                    [mgr rollbackToConservative];
                    [mgr waitUntilModeMatchesTimeoutMs:modeWaitMs conservative:YES];
                    [PipelineProbe waitForDisplayIDs:mgr.displayIDs timeoutMs:3000 lastSeen:NULL];
                }
            } else {
                P0Error(@"applySettings 提升失败，保持保守 canvas");
                [mgr rollbackToConservative];
                [mgr waitUntilModeMatchesTimeoutMs:modeWaitMs conservative:YES];
            }
        }
        if (mgr.windowServerHung) { if (outHung) *outHung = YES; return nil; }
        return mgr;
    }
    if (outReason) *outReason = reason;
    return nil;
}

static int P0CommandVerify(NSDictionary *args, BOOL hold) {
    NSString *spec = args[@"spec"] ?: @"1920x1080x0,2560x1440x0";
    NSArray *configs = P0ParseSpec(spec);
    int duration = P0IntArg(args, @"duration", 4000);
    int holdSeconds = P0IntArg(args, @"hold-seconds", 60);
    BOOL withEncoder = !args[@"no-encode"];

    // 防御性措施：测试期间保持显示管线活跃。注意 2026-11-14 事故复盘已确认
    // displayState=OFF 是 WindowServer 挂起的结果而非诱因（当时屏幕常亮），
    // 这里只是排除休眠这一额外变量，不是事故修复本身。
    IOPMAssertionID displayAssertion = kIOPMNullAssertionID;
    IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep,
                                kIOPMAssertionLevelOn,
                                CFSTR("P0-TahoeProbe: keep displays awake during virtual display test"),
                                &displayAssertion);
    IOPMAssertionID activityAssertion = kIOPMNullAssertionID;
    IOPMAssertionDeclareUserActivity(CFSTR("P0-TahoeProbe verify"), kIOPMUserActiveLocal,
                                     &activityAssertion);

    NSDictionary *policy = P0OSPolicy();
    P0Emit(@"env", P0SystemInfo());
    P0Emit(@"os-policy", policy);
    P0Emit(@"plan", @{
        @"spec": spec,
        @"displays": configs,
        @"durationMs": @(duration),
        @"withEncoder": @(withEncoder),
        @"conservativeFirst": @(args[@"direct"] ? NO : [policy[@"conservativeFirst"] boolValue]),
        @"identityWalk": policy[@"identityWalk"],
        @"identityPath": [VDManager identityPath],
    });

    NSError *tccErr = nil;
    NSArray *before = [PipelineProbe shareableDisplayIDsWithError:&tccErr];
    P0Emit(@"sck-before", @{
        @"visibleDisplayIDs": before ?: @[],
        @"error": tccErr.localizedDescription ?: @"",
        @"screenRecordingGranted": @((BOOL)(before != nil)),  // 与 README 第 5 节判读表对齐
    });
    if (!before) {
        P0Error(@"屏幕录制权限未就绪，先运行 `p0probe probe` 并按提示授权");
        if (displayAssertion != kIOPMNullAssertionID) IOPMAssertionRelease(displayAssertion);
        if (activityAssertion != kIOPMNullAssertionID) IOPMAssertionRelease(activityAssertion);
        return 1;
    }

    if (withEncoder) P0Emit(@"encoder-capabilities", [PipelineProbe encoderCapabilities]);

    uint32_t usedOffset = 0;
    BOOL hung = NO;
    NSString *failReason = nil;
    VDManager *mgr = P0EstablishDisplays(configs, args, &usedOffset, &hung, &failReason);
    if (!mgr) {
        P0Emit(@"verdict", @{
            @"pass": @NO,
            @"reason": hung ? @"WINDOWSERVER_SPI_TIMEOUT" : (failReason ?: @"IDENTITY_WALK_EXHAUSTED"),
            @"detail": hung
                ? @"SPI 同步调用超时，WindowServer 疑似挂起：已立即中止，未再重试。请检查系统状态（必要时重启）后再测"
                : @"建屏链路未通过，见 reason 字段定位环节（CREATE/LIVENESS/MODE_COMMIT/VISIBILITY/WALK）",
        });
        if (displayAssertion != kIOPMNullAssertionID) IOPMAssertionRelease(displayAssertion);
        if (activityAssertion != kIOPMNullAssertionID) IOPMAssertionRelease(activityAssertion);
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

    // 通过判据必须包含「达到目标分辨率」：promote 失败回退后捕获仍可能成功，
    // 但那只是保守 canvas 跑通，不代表目标分辨率可用（README 第 5 节）。
    // hiDPI 判定不能读 descriptor 的 hiDPI 字段：2026-11-17 实测请求 hiDPI=0 却回报 2，
    // 而 modePoints == modePixels，说明该字段只是"支持 2x"的能力位。必须看真实像素尺寸。
    BOOL targetReached = YES;
    NSMutableArray *modeChecks = [NSMutableArray array];
    for (NSUInteger i = 0; i < configs.count && i < mgr.displayIDs.count; i++) {
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(mgr.displayIDs[i].unsignedIntValue);
        NSUInteger w = [configs[i][@"width"] unsignedIntegerValue];
        NSUInteger h = [configs[i][@"height"] unsignedIntegerValue];
        BOOL wantHiDPI = [configs[i][@"hiDPI"] boolValue];
        NSUInteger pw = m ? CGDisplayModeGetPixelWidth(m) : 0;
        NSUInteger ph = m ? CGDisplayModeGetPixelHeight(m) : 0;
        BOOL pointsOK = m && CGDisplayModeGetWidth(m) == w && CGDisplayModeGetHeight(m) == h;
        BOOL pixelsOK = !wantHiDPI || (pw == w * 2 && ph == h * 2);
        if (!(pointsOK && pixelsOK)) targetReached = NO;
        [modeChecks addObject:@{
            @"displayID": mgr.displayIDs[i],
            @"hiDPIRequested": @(wantHiDPI),
            @"requestedPoints": [NSString stringWithFormat:@"%lux%lu", (unsigned long)w, (unsigned long)h],
            @"modePoints": m ? [NSString stringWithFormat:@"%zux%zu",
                                CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m)] : @"(nil)",
            @"modePixels": m ? [NSString stringWithFormat:@"%zux%zu", pw, ph] : @"(nil)",
            @"pointsOK": @(pointsOK),
            @"pixelsOK": @(pixelsOK),
        }];
        if (m) CGDisplayModeRelease(m);
    }

    BOOL passed = allCaptured && noBlack && targetReached && (!withEncoder || encodedOK);

    NSDictionary *summary = @{
        @"pass": @(passed),
        @"allCaptured": @(allCaptured),
        @"noBlackFrames": @(noBlack),
        @"targetResolutionReached": @(targetReached),
        @"modes": modeChecks,
        // 不编码时这条判据没有任何意义：输出 null，避免被误读成"编码链路已验证"
        @"encoderProducedFrames": withEncoder ? @(encodedOK) : [NSNull null],
        @"identityOffset": @(usedOffset),
        @"displays": mgr.displayIDs,
        @"capture": captureResults,
        @"next": passed
            ? @"P0 通过：继续做 CGEvent 坐标注入 spike 与双机 P2P glass-to-glass 延迟"
            : @"P0 未通过：按 verdict 字段定位是 TCC / stale identity / 黑屏 / 编码器哪一环",
    };
    P0Emit(@"verdict", summary);
    NSError *werr = nil;
    P0WriteJSON(summary, @"p0_result.json", &werr);
    P0Log(@"结果已写入 ./p0_result.json");

    [mgr destroyAll];
    if (displayAssertion != kIOPMNullAssertionID) IOPMAssertionRelease(displayAssertion);
    if (activityAssertion != kIOPMNullAssertionID) IOPMAssertionRelease(activityAssertion);
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
        } else if ([cmd isEqualToString:@"capture"]) {
            rc = P0CommandCapture(args);
        } else if ([cmd isEqualToString:@"verify"]) {
            rc = P0CommandVerify(args, NO);
        } else if ([cmd isEqualToString:@"hold"]) {
            rc = P0CommandVerify(args, YES);
        } else {
            fprintf(stderr,
                "P0-TahoeProbe — Intel Mac 虚拟屏 P0 验证（自动识别 Tahoe 26 / Sequoia 15 并分流）\n\n"
                "  p0probe probe  --capabilities              环境与私有 API 签名探测\n"
                "  p0probe capabilities                       仅探测 VideoToolbox 编码档位\n"
                "  p0probe capture [--display all|ID,ID] [--duration 4000] [--no-encode]\n"
                "                                             捕获现有屏，不建屏（捕获优先路径验证）\n"
                "  p0probe verify [--spec 1920x1080x0,2560x1440x0]\n"
                "                 [--duration 4000] [--no-encode] [--direct]\n"
                "                 [--offset N] [--fresh] [--max-retries N]\n"
                "                 [--visibility-timeout 5000]   完整 P0 链路\n"
                "  p0probe hold   --hold-seconds 60 [...]       建屏后保持，便于在 GUI 核对\n\n"
                "spec 格式：WxHxHIDPI，多屏用逗号分隔；HIDPI=1 时 descriptor 自动用 2 倍像素。\n"
                "OS 策略：Tahoe 26 默认保守 canvas+identity walk（max-retries 4）；\n"
                "         Sequoia 15 及其它默认直建目标分辨率、固定 identity（max-retries 1）。\n");
            rc = 0;
        }
        return rc;
    }
}
