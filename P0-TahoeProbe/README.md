# P0-TahoeProbe

在**被控端**验证「Intel Mac + macOS 26 Tahoe + 无头虚拟屏 + 非 VNC」这条链路能否跑通的最小工程。

不涉及网络、不涉及控制端、不写产品代码。目的只有一个：**在写任何正式代码之前，把「建屏 → SCK 看见 → 抓到非黑画面 → H.264 硬编 → 本机解回」这一段唯一没有现成端到端实测记录的路径跑实。**

---

## 0. 更正后的环境矩阵，以及它推翻了什么

| | 被控端（Host / Sender） | 控制端（Client / Receiver） |
|---|---|---|
| CPU | Intel x86_64 | Intel x86_64 |
| macOS | **26 Tahoe**（2026-11-17 实机复核：**26.5.2 / 25F84**；此前文档写的 26.7.3 未在该机上复现） | **15 Sequoia**（15.8.2，历史基线机） |
| 职责 | 建虚拟屏、捕获、编码、注入输入 | 解码、N 个全屏窗口渲染、采集输入 |

**必须作废上一轮的结论**：我说过「锁定 Intel + macOS 15 后，最大的『每年跟 Apple 私有 API 变动』风险基本消失」。被控端改成 Tahoe 之后这句话不成立了——Tahoe 恰好就是私有 API 变动最剧烈的版本。

但风险**性质**变了，不是单纯变大：

- **坏消息**：Tahoe 上 `CGVirtualDisplay` 有两个已被实锤的新故障模式（stale/offline 黑屏、poisoned display identity），而且是 Intel 能装的最后一代系统，永远等不到后续大版本修复。
- **好消息**：macOS 27 已于 2026-09-14 发布且**仅支持 Apple Silicon**，Tahoe 已退入「仅安全更新」窗口（Apple 承诺 Intel 还有约三年安全更新，预计到 2028 秋）。也就是说**不再会有功能级的 API 重构**，你要长期维护的是一个固定的、坑位已被社区完整踩过并给出补丁的版本。
- **另一个好消息**：Tahoe 的坑不是未解之谜。OpenDisplay 在 2026 年 8–9 月的 PR #219 / #288 已经把它们修掉并给了可照抄的策略，本工程直接实现了这两套策略。
- **退路被堵死**：Apple 官方高性能屏幕共享要求双端 Apple Silicon，你这台 Intel 被控端连"先用系统方案凑合"都做不到。**自研是唯一路径，没有现成基线可对照。**

所以整体判断从「锁定版本 → 低风险」修正为：**「锁定在一个已知有坑、但坑已公开且有解、且不会再变的版本」——仍然可行，但 P0 必须从"跑通"升级为"跑通 + 验证恢复机制"。**

---

## 1. 本工程依据的已核实事实

| 来源 | 结论 | 本工程对应实现 |
|---|---|---|
| [OpenDisplay PR #219](https://github.com/peetzweg/opendisplay/pull/219) | Tahoe 上 stale 虚拟屏 `CGDisplayBounds` 非空但 `IsOnline`/`IsActive` 均为 false，不出现在 `SCShareableContent`，捕获全黑；修复要求 liveness 判据**同时**检查 online + active，并换新 product ID 重建 | `VDManager.liveness` 的 `usable = online && active && boundsNonEmpty`；identity walk |
| [OpenDisplay issue #171](https://github.com/peetzweg/opendisplay/issues/171) / [PR #288](https://github.com/peetzweg/opendisplay/pull/288) | Tahoe 26.5.2 上 WindowServer 会记住被污染的 vendor/product/serial 组合，虚拟屏永不出现在 `SCShareableContent`，跨重启、重装、删 `com.apple.windowserver.displays.plist` 都不恢复；改一个字节的 `productID` 立刻恢复。#288 的最终方案是**放弃该 identity、换新 serial + product ID 重试、持久化成功 offset**，无需注销或重启 | `VDManager.makeDescriptorForIndex` 同步游走 serial/product，`P0EstablishDisplays` 的 identity walk + `~/.p0_identity.json` 持久化 |
| 同上 PR #288 | 直接以大尺寸建虚拟屏可能只得到「壁纸 + 光标」；解法是**先用保守 canvas 建立稳定 identity，等 SCK 看见后再原地 applySettings 提升，失败则事务性回退**；另外 H.264 High@L5.2 有吞吐上限，5K 请求会让 VideoToolbox 返回成功却不产出 buffer（黑屏），安全点是 4096×2304@55 | 默认 `conservativeFirst`：descriptor 给目标像素上限、settings 先 1280×800，可见后 promote；`--direct` 可跳过做对照 |
| [DeskPad `CGVirtualDisplayPrivate.h`](https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h) + [SideScreen42 在 macOS 27.0.1 的 runtime 复核](https://github.com/Okle42/SideScreen42) | 四个私有类的 selector/属性名在 macOS 15 / 26 / 27 上一致，到 27 仍存在 | `CGVirtualDisplaySPI.h` 的 protocol 声明 + `probe` 子命令在目标机上重新 dump 比对 |
| [Apple 部署文档](https://support.apple.com/zh-cn/guide/deployment/depd567c9ffa/web) / macOS 26 更新记录 | macOS 26 是 Intel 的最后一个完整支持版本；26.7.1 修过一个 CoreGraphics 漏洞（CVE-2026-86950，曾被定向利用）；此后只有安全更新 | 见第 8 节版本锁定策略 |
| [BetterDisplay README](https://github.com/meshameer/BetterDisplay) | v3.x 只支持到 Sequoia，**完整 Tahoe 26 支持需要 v4.x pre-release** | 侧面印证 Tahoe 上虚拟屏生态确有变动 |

另有一条对 Intel 的关键旁证：PR #288 的验证记录里包含 **unsigned universal Release 构建（arm64 + x86_64）** 与 **macOS receiver Debug x86_64 在 Intel iMac 上的实跑**，说明这条 Swift/ObjC 管线的 x86_64 路径是通的；缺的只是「Intel + Tahoe + 建屏侧」这一格。

---

## 2. 工程形态与文件

刻意做成**纯 Objective-C 命令行工具**，而不是 Xcode App：

- 不需要 `.xcodeproj`、不需要签名、不需要公证、不需要 App bundle，拷过去 `bash build.sh` 就能编译；
- P0 只关心系统层能力，GUI 反而会引入 AppKit run loop、窗口生命周期等噪声；
- 后续做正式 App 时，`VDManager.m` 与 `PipelineProbe.m` 可以几乎原样搬进 Swift 工程（暴露成 ObjC 桥接头即可）。

私有 API 用 **`@protocol` 声明 + `NSClassFromString` 运行时解析**，不声明 `@interface`。原因是私有类的 `OBJC_CLASS_$_...` 符号不保证导出，直接写 `@interface` 会在链接期挂掉；protocol 方式只生成 `objc_msgSend`，零链接依赖，且每个 setter 都有 `respondsToSelector` 保护。

```
P0-TahoeProbe/
├── build.sh                     clang 一键编译（按 OS 大版本提示走哪条路径）
├── run_p0.sh                    一键运行 + 诊断回收（Tahoe 才跑 --direct 对照）
├── check_static.py              跨平台静态自检（编码/括号/声明实现/参数一致性）
├── diag.m / diag2.m             2026-11-14 事故取证与 apply 吞掉对照实验（证据保留）
├── diag3.m / diag4.m            2026-11-16 自动镜像发现与双屏顺序对照实验（证据保留）
├── README.md
└── src/
    ├── CGVirtualDisplaySPI.h    私有 API 的 protocol 重声明 + 运行时解析接口
    ├── ProbeUtil.h/.m           日志、JSON 输出、环境指纹、OS 版本策略 P0OSPolicy、Quartz display 列表、selector dump
    ├── VDManager.h/.m           逐屏串行建屏 / mode 提交等待 / liveness / identity walk / 保守 canvas 提升 / SPI 超时熔断 / 销毁
    ├── PipelineProbe.h/.m       SCK 可见性 / 逐屏捕获 / 亮度判黑 / VT 能力探测 / 编码环回
    └── main.m                   probe / capabilities / verify / hold 四个子命令 + 按 OS 分流的建屏编排
```

---

## 3. 前置条件（被控端 Tahoe）

1. **记录确切 build**：`sw_vers` 输出（2026-11-17 实测被控机为 `26.5.2 / 25F84`）。后面每次系统安全更新后都要重跑一次本工程。
2. `xcode-select --install` 装 Command Line Tools。
3. **TCC 授权**：命令行工具的屏幕录制权限归属**父进程**，也就是你启动它的那个终端。给 `Terminal.app` 或 `iTerm` 在「系统设置 → 隐私与安全性 → 屏幕录制」打勾，**授权后完全退出终端再重开**（屏幕录制授权需要进程重启才生效）。辅助功能同理（`CGEventPost` 后续 spike 才用，可一并先授）。

   > ⚠️ **2026-11-17 实测新增**：`p0probe` 是**完全没有代码签名**的裸二进制（`codesign -dv` 报 "code object is not signed at all"）。实测「授权成功 → 改代码 → `bash build.sh` 重建 → 再跑」后，`sck-before.screenRecordingGranted` 立刻回落到 `0`，报 `The user declined TCCs`。也就是说**每次重建都会让已有授权失效**，而 `run_p0.sh` 默认会先重建再跑——这会让一键流程在第一步就假失败。
   >
   > 两个规避办法（任选）：
   > - 首次编译后，后续一律用 `P0_NO_BUILD=1 bash run_p0.sh`，避免无谓重建；
   > - 更稳的做法：把屏幕录制授权给**终端 App 本身**（`Terminal.app` / `iTerm`），由它在会话内启动 `p0probe`，这样二进制身份变化不影响授权。授权后仍需完全退出终端再重开。
4. **必须在已登录的 Aqua GUI 会话里、在桌面的终端窗口中运行，不要 ssh 过去跑。** LaunchDaemon / SSH 上下文里虚拟屏能创建但不 attach 到 WindowServer，表现就是全黑。无人值守场景最终要配自动登录 + 关 FileVault + LaunchAgent（不是 Daemon），但 P0 阶段先手工在 GUI 里跑。
5. 首次建议**接一块物理显示器**完成授权，再拔掉验证无头行为。
6. **关掉 Sidecar / BetterDisplay / Duet / 其他虚拟屏工具**。issue #171 的触发条件正是「用了 Sidecar 再切回来」，污染源就是 display identity 缓存；这些工具同时跑会让结果无法归因。

---

## 4. 运行

```bash
cd P0-TahoeProbe
bash build.sh

# 第 1 步：环境与私有 API 签名（不建屏，最安全，先跑这个）
./p0probe probe --capabilities

# 第 2 步：完整 P0 链路（默认 2 块屏：1920x1080 + 2560x1440，各捕获 2 秒）
./p0probe verify

# 第 3 步：对照实验，跳过保守 canvas，直接以目标分辨率建屏
./p0probe verify --direct

# 建屏后保持 60 秒不退出，方便在「系统设置 → 显示器」里核对排列/分辨率/拖窗口
./p0probe hold --hold-seconds 60

# HiDPI 单独验证（descriptor 自动用 2 倍像素、mode 用 points）
./p0probe verify --spec 1920x1080x1,2560x1440x0
```

常用参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `--spec WxHxHIDPI[,...]` | `1920x1080x0,2560x1440x0` | 屏幕数量、分辨率、是否 HiDPI |
| `--duration MS` | 4000 | 捕获总时长，按屏数平分，每屏最少 1000ms |
| `--no-encode` | 关 | 只验证捕获，跳过 VideoToolbox |
| `--direct` | 关 | 强制直建目标分辨率、跳过保守 canvas（Tahoe 上作 PR #288 对照；Sequoia 默认本就直建） |
| `--fresh` | 关 | 忽略 `~/.p0_identity.json`，从 offset 0 开始试 |
| `--offset N` | 上次的成功值 | 指定 identity 起始偏移（仅 Tahoe identity walk 用） |
| `--max-retries N` | Tahoe 4 / 其它 1 | 建屏失败最多重试几组（2026-11-14 事故后下调，限制热插拔压力） |
| `--visibility-timeout MS` | 5000 | 等虚拟屏出现在 `SCShareableContent` 的超时 |

**OS 自动分流**：探针启动时用 `NSProcessInfo` 读系统大版本，`probe` / `verify` 都会先打一条 `os-policy` JSON 说明本机走哪条路径——

- **Tahoe 26**：保守 canvas→promote、identity walk、offset 持久化（stale / poisoned identity 全套 workaround），`max-retries` 默认 4。
- **Sequoia 15**：直建目标分辨率、固定 identity、失败即止，`max-retries` 默认 1。这是本机实证过的基线路径（见 12.5），**不把 Tahoe 的 workaround 套在 Sequoia 上**。
- **其它版本**：走与 Sequoia 相同的最小风险路径，结论仅供参考。

`--direct` / `--offset` / `--max-retries` 仍可手动覆盖默认。无论哪条路径，SPI 8s 死线 + 挂起熔断、逐屏 mode 提交等待、退化 mode 拒捕这些安全机制都生效。

每行 stdout 都是单行 JSON（`stage` 字段标识阶段），日志走 stderr，可直接分离：

```bash
./p0probe verify > run.jsonl 2> run.log
```

最终结果同时写入 `./p0_result.json`，进程退出码 0 = 通过。

---

## 5. 判读标准

| stage | 通过条件 | 不通过说明什么 |
|---|---|---|
| `env` | `arch == x86_64` | 跑错机器了（本工程面向 Intel） |
| `os-policy` | `osName` 与本机一致（Tahoe / Sequoia） | 版本探测异常；核对 `family` 决定走哪条建屏路径 |
| `spi` | `allClassesResolved == true` | Tahoe 上私有类改名/迁移 framework，需重新逆向 |
| `spi-signature-check` | `missing == []` | selector 漂移，要按 dump 结果改 `CGVirtualDisplaySPI.h` |
| `sck-before` | `screenRecordingGranted == true` | 终端没拿到屏幕录制权限，后面全是假失败 |
| `encoder-capabilities` | `H264-Main` 在 1920×1080 / 2560×1440 上 `supported=true` 且 `hardwareAccelerated=true` | Intel 硬编不可用，只能软编，延迟目标要重定 |
| `create` | N 条，`applySettings=true`，displayID 非 0 | `initWithDescriptor:` 被拒 → identity 被污染 |
| `mode-commit` | 每屏 `ok=true`（逐屏串行提交） | 该屏 mode 未落地；createAll 会中止，不再建下一块 |
| `unmirror` | `ok=true`，随后 `liveness` 里 `mirrorSet=0` | 自动镜像未解除（镜像态 active=false、SCK 不可见），见 12.6 |
| `liveness` | 每条 `online=true, active=true, usable=true, mirrorSet=0` | Tahoe stale display（bounds 非空但 offline）；Sequoia 自动镜像（见 12.6） |
| `mode-wait` | `ok=true`，实际 mode 已落到请求的 points 尺寸 | applySettings 异步提交未完成（15.5 实测 1-3 秒）；停在 1×1 属退化态，禁止捕获 |
| `visibility` | `ok=true` 且 `seen` 包含全部 `wanted` | **最关键的 Tahoe 判据**；Tahoe 失败会触发 identity walk，Sequoia 失败即止 |
| `promote` | `ok=true` 且 `modePoints` 变成目标分辨率 | 仅 Tahoe 保守路径；提升后掉屏会自动回退保守 canvas 并标记 |
| `capture` | `verdict=HAS_CONTENT`、`frames>0`、`fps≈55-60`、`suspectedBlackFrames` 远小于 frames | `NO_FRAMES_TCC_OR_STALE` 或 `MOSTLY_BLACK` |
| `capture` 编码部分 | `encodedFrames>0`、`keyFrames>0`、`encodeErrors=0`、`decodedFrames>0` | 编码器不产出 buffer（PR #288 的吞吐上限问题） |
| `verdict` | `pass=true`（含 `targetResolutionReached=true`） | 按下面决策树定位；`reason=WINDOWSERVER_SPI_TIMEOUT` 时**立即停测**，见第 12 节 |

**判黑阈值已按色彩范围修正（2026-11-17）**：捕获输出格式是 `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`，视频范围下 Y∈[16,235]，**纯黑是 16 而不是 0**。旧实现用「Y 均值 < 8 且方差 < 4」判黑，在任何视频范围帧上都不可能命中，等于把 `MOSTLY_BLACK` 判据关掉了——真黑屏会被判成 `HAS_CONTENT`（假通过）。现改为 `Y < 16 + 4 且方差 < 4`。**因此 §12.6 里历史结论的「0 黑帧」不构成有效证据**，需要在新版二进制上重测。

**P0 通过的定义**：两块虚拟屏都满足 `online+active+SCK 可见`，**mode 实际落到目标分辨率**，捕获到非黑画面且帧率接近 60，H.264 编码与环回解码都产出帧。`encodeEnqueueP50Ms` 只反映入队开销，**不是**端到端延迟，端到端要等双机 spike 再测。

---

## 6. 失败决策树

```
sck-before 拿不到 displays
  └→ 给终端授屏幕录制 → 完全退出终端重开 → 重跑

create 的 initWithDescriptor: 返回 nil / applySettings=false
  └→ identity 被污染，identity walk 会自动换组；加大 --max-retries

liveness: bounds 非空但 online/active=false
  └→ PR #219 的 stale display。工程会销毁重建，不要复用该 displayID

visibility: 一直 ok=false，换 identity 后恢复
  └→ 命中 PR #288 的 poisoned identity，这属于「已验证的恢复机制生效」，
     把成功 offset 记进部署文档，正式产品里必须实现同样的持久化重试

visibility 始终 ok=false，所有 identity 都失败
  └→ 检查是否从 SSH/LaunchDaemon 启动（必须 Aqua GUI 会话）
     检查是否同时开着 Sidecar / BetterDisplay / Duet
     再试 --direct 与更小 spec（1280x800x0）缩小变量

capture 帧数为 0
  └→ SCK 没绑上：确认 SCShareableContent 此刻仍列着该 displayID
     绝不要回退到 CGDisplayStream（macOS 15 起对虚拟屏返回 nil，假成功不回调）

capture 有帧但 MOSTLY_BLACK
  └→ 用 hold 命令保持虚拟屏，在 GUI 里看它是否只显示壁纸+光标
     若是 → PR #288 的 saved-display-state 问题，保持默认 conservativeFirst
     换 --direct 对比，确认保守建屏策略在你的机型上是否必要

encodedFrames=0 但捕获正常
  └→ 看 encoder-capabilities 是否超出 H.264 L5.2 吞吐；降到 1080p 再试
```

---

## 7. 控制端（Intel / Sequoia 15）还要单独验证什么

**本工程不覆盖控制端。** 它是纯解码渲染侧，不建屏、不编码，风险最低，但 P0 仍需补四项：

1. `VTDecompressionSession` + IOSurface → Metal 在本机环回的出帧与首帧延迟；
2. N 个无边框全屏 `NSWindow` 分别落到 N 块物理屏，验证 `NSScreen`（左下原点）与 Quartz（左上原点）的坐标变换，尤其副屏负坐标与混合缩放；
3. `CGEventPost` 注入 + display ID 路由，中文输入法（`CGEventKeyboardSetUnicodeString`）、修饰键状态同步、Cmd-Tab 沉浸模式拦截；
4. 双机 1080p60 的 glass-to-glass 延迟（目标：采集+编码 < 30ms，总链路 < 50ms）。

Sequoia 15 与 Tahoe 26 都还在安全更新窗口内，**两端每次系统更新后都要各跑一次本工程（控制端跑 `capabilities` 即可）**。

---

## 8. 版本锁定策略

- 被控端锁到**具体 build**（2026-11-17 实测为 `26.5.2 / 25F84`），写进部署文档，不要只写 "macOS 26"。
- **不要关闭安全更新**（Tahoe 26.7.1 修的是已被定向利用的 CoreGraphics 漏洞），但每次安全更新后必须重跑 `probe` + `verify` 做回归——CoreGraphics 二进制变了，私有 SPI 就可能漂。
- Intel 不会再有功能级大版本，所以不需要为 macOS 27/28 预留适配分支；这与 Apple Silicon 上每年追私有 API 的维护模型完全不同。
- 保留一个降级预案：若某个 26.x 安全更新把私有 SPI 改坏且无解，最后手段是接 EDID 假插头（硬件虚拟显示器），但那会牺牲「由控制端动态决定分辨率」。

---

## 9. 已知未覆盖 / 后续

- 无网络传输、无认证加密、无拥塞控制、无光标分离通道、无音频、无剪贴板、无键盘注入——都是 P0 之后的事。
- 未验证 >2 块虚拟屏的上限（Tahoe + Intel 上需要实测，社区经验值约 4 块扩展屏）。
- 未验证 120/144Hz，代码里固定 60Hz。
- 亮度判黑只是 8×8 网格采样，深色壁纸会误报，务必结合 `hold` 在 GUI 里肉眼确认。
- 若首次编译报 SDK 差异（尤其 `SCStreamConfiguration` / `VTCompressionPropertyKey_*` 在新 SDK 上的可用性），把报错贴回来改；这份骨架是在 Windows 侧按 Tahoe SDK 公开接口写的，未在真机编译过。

---

## 10. 与许可证的关系

本工程是独立写的验证代码，只**参考**了以下项目的公开技术结论，未复制其源码：

- DeskPad（MIT）、VirtualDisplayKit（MIT）：私有 API 声明的 selector 名称；
- SideScreen42：macOS 27 上的 runtime 签名复核；
- OpenDisplay（**GPL-3.0**）：PR #219 / #288 / issue #171 里的**行为结论与修复策略**。

> 注意：策略思路不受版权约束，但**如果要直接 fork OpenDisplay 主线做产品，会触发 GPL-3.0 传染**。正式产品的主基座仍建议 SideScreen MacHost（MIT）+ VirtualDisplayKit（MIT），详见上一轮选型结论。

---

## 11. 上机交接清单（Windows 侧准备完毕，2026-11-14）

工程全部在 Windows 侧写成，**尚未在真机编译过**。上 Mac 前已把「第一次 `bash build.sh` 就报错」和「授权 / 会话导致的假失败」两类风险尽量压掉；剩下唯一不可消除的，是 Tahoe SDK 真实头文件的差异。

### 11.1 拷过去的文件

直接把工作区里的 `P0-TahoeProbe.zip` 拷到被控端解压即可（U 盘 / 网盘 / `scp` 都行，注意第 11.2 节说的是**不要 ssh 执行**，拷文件不受影响）。工作区根目录已初始化 git 仓库并做了初始提交；若想保留提交历史，也可以整目录拷过去（含 `.git`）。`.gitattributes` 已强制所有 shell / ObjC 文件用 LF，避免 Windows 的 `core.autocrlf` 把 `build.sh` 转成 CRLF 后在 Mac 上跑不起来。

```
P0-TahoeProbe/
├── build.sh           clang 一键编译（已加环境输出与源文件完整性检查）
├── run_p0.sh          ★ 一键跑完全部探针并打包诊断结果
├── check_static.py    非 Mac 侧静态自检（在 Mac 上也能跑）
├── README.md
└── src/ …（8 个 Objective-C 文件）
```

### 11.2 开机前的准备（顺序不能乱）

1. `sw_vers` 记下**确切 build**（2026-11-17 实测被控机为 `26.5.2 / 25F84`）写进部署文档；以后每次安全更新都要重跑本工程。
2. `xcode-select --install` 装 Command Line Tools。
3. **关掉 Sidecar / BetterDisplay / Duet / 其他虚拟屏工具**——issue #171 的污染源正是它们留下的 display identity 缓存，同时开着会让结果无法归因。
4. 首次**先接一块物理显示器**：给 `Terminal.app` 授「屏幕录制」+「辅助功能」，然后 **⌘Q 完全退出终端再重开**（TCC 需要进程重启才生效）。命令行工具的权限归属**父进程即终端**，不是 `p0probe`。
5. **在已登录桌面的 Terminal 窗口里跑，绝对不要 ssh**。Aqua 会话之外虚拟屏不 attach 到 WindowServer，表现是全黑；`hold` 也看不到屏。

### 11.3 跑

```bash
cd P0-TahoeProbe
bash run_p0.sh
```

依次执行：环境采集 → `bash build.sh` → `probe --capabilities`（不建屏）→ `verify`（按 OS 自动选路）→ `verify --direct`（对照，**仅 Tahoe**；Sequoia 默认本就直建，自动跳过）→ 汇总 → 打包。

可选环境变量：`P0_QUICK=1` 跳过对照；`P0_RUN_HOLD=60` 额外保持 60 秒供肉眼核对排列 / 分辨率；`P0_EXTRA="--fresh --max-retries 12"` 透传；`P0_NO_BUILD=1` 改完代码只重跑。

**带回来的只有一个文件**：`p0-diag-<时间戳>.tar.gz`（同目录）。内含 `SUMMARY.txt`、`environment.txt`、编译 stdout/stderr、每一步的 `.jsonl` / `.stderr.log` / `.rc`、`p0_result.*.json`，以及 `~/.p0_identity.json` 的副本。拷回 Windows 侧工作区即可，不用手贴大段日志。

### 11.4 判读顺序

先看 `SUMMARY.txt` 的四个字段，不对就停，别往下看 `verdict`：

| 先看 | 不对怎么办 |
|---|---|
| `BUILD_OK` | = 0 → 只需回传 `build.stderr.log`，按 SDK 报错改声明，别急着跑探针 |
| `GUI_SESSION` | ≠ Aqua → 回桌面终端重跑，其余结论全部作废 |
| `sck-before` 的 `screenRecordingGranted` | false → 授权 + 完全重启终端，后面全是假失败 |
| `spi-signature-check.missing` | 非空 → selector 漂移，按 `probe.jsonl` 的 dump 改 `CGVirtualDisplaySPI.h` |

然后看 `verdict.pass`，细则见第 5、6 节。`verify_direct` 只是对照组：默认策略通过、对照失败，恰好证明保守 canvas 在你的机型上是必需的。

### 11.5 本轮在 Windows 侧已修的问题（不依赖真机即可确定）

| 问题 | 不修的后果 | 处理 |
|---|---|---|
| `VTSessionCopyProperty` 的 out 参数用 `CFBooleanRef *` | incompatible-pointer-types 警告 | 改 `CFTypeRef` + `CFGetTypeID` 校验 |
| `encodePixelBuffer:pts:` 只在 @implementation 内定义 | 不同 clang 版本可能报「未声明 selector」 | 补类扩展声明 |
| `NSStringFromCGRect` 依赖 framework 组合 | 可能链接不到实现 | 换成自写 `P0RectString()` |
| `dispatch_queue_t` 未显式引入 | `setQueue:` 声明处可能 unknown type | 显式 `#import <dispatch/dispatch.h>` |
| VT 编解码回调持非 retained `__bridge` refCon，sink 可能被提前释放 | 异步回调打野指针 → 随机崩溃 | `objc_precise_lifetime` + 返回前 `shutdown()`（等异步帧排空再 invalidate） |
| `P0DisplayList` 只遍历 displayID 1..64 | 虚拟屏 ID 是任意 32 位数，`displays-after` 会整块漏掉 | 改为 `CGGetOnlineDisplayList` + `CGGetActiveDisplayList` 合并去重 |
| `dlopen` 只写绝对路径 | Tahoe 把部分框架放进 Cryptexes，路径可能失效 → 误判「私有类不存在」 | 加 dyld 按名查找形式 + `objc_getClass` 兜底 |
| `verify` 的 `sck-before` 缺 `screenRecordingGranted` | 与第 5 节判读表对不上 | 补字段 |
| 编译无环境输出、无源文件检查 | 报错时缺上下文，来回多一轮 | `build.sh` 输出 OS/build/arch/SDK/CLANG 并检查 SOURCES |
| 换行符 / BOM | CRLF 会让 `bash build.sh` 直接失败 | `check_static.py` 检查；当前 7/7 通过，全部 UTF-8 无 BOM、纯 LF |

`python check_static.py` 目前 7/7 通过：编码换行、括号配对、C 函数声明→实现、ObjC 方法声明→实现、build.sh SOURCES、README/main.m 参数一致性、无禁用 API 残留。以后在非 Mac 侧改完代码，先跑它再打包。

### 11.6 仍然只能靠真机回答的（2026-11-17 已复核对账）

| 问题 | 状态 |
|---|---|
| Tahoe SDK / CLT 版本带来的编译差异 | ✅ **已关闭**：SDK 26.5 + Xcode 26.5 上 `build.sh` 零警告编译通过 |
| `spi-signature-check` 在 Intel Tahoe 上的 selector 结果 | ✅ **已关闭**：26.5.2 Intel 上 `missing=[]`，四个私有类全部可解析 |
| Intel 上 H.264 是否真 `hardwareAccelerated`、HEVC 可用性 | ✅ **已关闭**：H.264 Baseline/Main/High 与 HEVC Main 在 1080p/1440p/4K 全部 `supported=1` 且 `hardwareAccelerated=1`；**且已实测真实产出编码帧**（§15.1：`encodedFrames>0`、`encodeErrors=0`） |
| HiDPI 虚拟屏能否产出 2× 像素流 | ✅ **已关闭**（2026-11-17 15:22）：`modePoints=1280x720` / `modePixels=2560x1440` / `rasterScale=2`。前提是 descriptor 一次给足像素能力（§15.2 F-4） |
| `visibility` / `capture` 是否踩中 stale display 或 poisoned identity，成功的 `identityOffset` | ✅ **已关闭**（2026-11-17 11:55 实测）：`visibility` 一次命中，`seen` 中同时出现虚拟屏与两块物理屏；**未触发 identity walk**，成功 `identityOffset = 0`；`capture` 判定 `HAS_CONTENT`。详见 §14 |

### 11.7 控制端为什么还没写

第 7 节的四项（VTDecompression→IOSurface→Metal 环回、N 个无边框全屏 `NSWindow` 与坐标变换、CGEvent 注入与中文输入 / Cmd-Tab、双机 1080p60 glass-to-glass 延迟）建议**等被控端 P0 通过之后**再落代码。现在写等于再堆一份从未编译过的代码，而且它强依赖被控端真实产出的码流格式与 display ID 分配方式。等诊断包回来按真实参数写，一次成型。

### 11.8 建议的下一步顺序

1. 被控端跑 `bash run_p0.sh` → 回传 `p0-diag-*.tar.gz`；
2. 按诊断包修编译 / selector / identity 问题，直到 `verdict.pass = true`；
3. 补控制端 P0 四项（可另开 `P1-ClientProbe/`）；
4. 双机联调，测 1080p60 glass-to-glass 延迟（目标：采集+编码 < 30ms）；
5. 才进入正式产品骨架（SideScreen MacHost MIT / VirtualDisplayKit MIT）的落地。

## 12. Sequoia 真机基线与 WindowServer 崩溃事故（2026-11-14）

### 12.1 基线结果（历史记录：Macmini8,1 / i5-9500 / UHD 630 / macOS 15.5 24F74）

- 编译修了三处：`PipelineProbe.m` 方法声明结构、`main.m` 对 `id` 用点语法、`build.sh` 补 `-framework IOKit`。
- `spi-signature-check.missing = []`：15.5 Intel 上全部私有 selector 与重声明一致。
- `encoder-capabilities`：H.264 Baseline/Main/High 与 HEVC Main 在 1080p/1440p/4K 全部可建会话且 `hardwareAccelerated = true`（UHD 630 QuickSync）。Intel 硬编这一最大不确定性**已排除**。
- **关键实测发现**：`applySettings:` 是**异步提交**（本机约 1–3s），attach 期间的第一个 apply 可能被吞掉——ObjC 侧读回的 width/height 全对，但 `CGDisplayCopyDisplayMode` 停在 **1×1**。此时启动 SCK 捕获得到 `Start stream failed`。修复：建屏后等 500ms 再 apply；新增 `waitUntilModeMatchesTimeoutMs:`（6s 死线，中途补一次 apply），mode 未落地不进捕获；`captureDisplayID:` 对 <2×2 的退化 mode 直接拒捕。
- 本机 `CGDisplayIsOnline/IsActive` 对不存在的 ID 也返回 true（会枚举出 64 块幽灵屏），`P0DisplayList` 改为以 bounds 非空为准。

### 12.2 崩溃事故：两次 WindowServer 看门狗重启（强制注销）

两次 `verify` 执行均导致黑屏闪烁 → WindowServer 被看门狗杀掉 → 用户被注销、所有进程终止。取证（`/Library/Logs/DiagnosticReports/WindowServer-2026-11-14-221946.ips` / `-222256.ips`，bug_type 409 `userspace_watchdog_timeout`）：

- 挂起栈：`SkyLight → CoreDisplay → SkyLight → 内核等待`，即**显示重配置的同步 SPI IPC 卡死**，系统侧没有超时兜底；
- 两次 crash 里 `p0probe` 都活着，主线程 `TH_WAIT`、turnstile 阻塞在 WindowServer 上，另一线程挂在 `com.apple.VirtualDisplayListener` 队列；
- 两次 `displayState` 均为 **OFF**。

**时间线复核（2026-11-14，本机屏幕全程常亮，用户确认未休眠）：**

| 事件 | 时刻 | 证据 |
|---|---|---|
| verify 第 1 次（pid 3818） | 22:13:58 → 22:14:04 | `verify.jsonl`：1×1 退化 mode，`Start stream failed`，verdict pass=0 后正常退出 |
| WindowServer 崩溃 #1 | 22:19:46 | `.ips`：p0probe pid **4592**（另一次运行）主线程阻塞在 WindowServer(pid 155) |
| verify 第 2 次（pid 6144） | 22:21:56 起 | `verify2.jsonl`：22:21:58 建屏 → 22:22:09 已 `active=false`、两块屏 mode 串号成 2560×1440 |
| WindowServer 崩溃 #2 | 22:22:56 | `.ips`：p0probe pid **6144** 与 verify2 完全对应，距启动恰好 60s |

**关键更正：`displayState=OFF` 是 WindowServer 挂起的「结果」，不是「诱因」。** 此前把它归因为「显示器休眠期间重配置触发死锁」是错的——用户确认屏幕常亮，且 verify2 在启动后 **13 秒**（22:22:09）就已出现 `active=false`、mode 串号这类显示管线损坏迹象，远早于任何空闲休眠可能发生的时刻。黑屏闪烁从测试一开始就出现，是显示重配置把 WindowServer 拖挂的直接表现。IOKit 防休眠断言因此降级为「排除额外变量的防御性措施」，不是事故修复本身。

旧代码的四个缺陷叠加放大了事故：

1. **SPI 调用无超时**：`initWithDescriptor:` / `applySettings:` 同步等 WindowServer，挂起即无限等；
2. **无全局熔断**：挂起后仍按 identity walk 连续重试（默认 9 次），每次 destroy 再 release 又是同步 IPC，反复捶打已挂死的 WindowServer——verify2 在 22:22:09 已见显示损坏，却仍在 22:22:10 继续换 identity 建屏；
3. **两块屏并发处于未提交态**：两个 1×1 虚拟屏同时 attach、mode 串号，并发重配置把小问题放大成挂起；
4. **1×1 退化 mode 照样送 SCK 捕获**，且 `startCapture` 失败路径不 stopCapture，留下悬空 stream。

### 12.3 已落地的安全修复（2026-11-14 落地，2026-11-16 已按 12.4 协议重跑验证）

| 修复 | 位置 | 作用 |
|---|---|---|
| SPI 8s 死线 + `windowServerHung` 全局熔断 | `VDManager.m` `P0CallSPIWithTimeout` | init/apply 放到工作线程，超时立即置位；所有建屏/重试路径见位即整体中止 |
| 挂起时 destroyAll 跳过 release | `VDManager.m` | 不再向已挂死的 WindowServer 发同步 IPC（进程退出由系统回收） |
| **逐屏串行建屏**：每块屏 mode 提交后才建下一块 | `VDManager.m` `createAll` / `waitModeForIndex:` | 消除两块屏并发未提交态（事故日志里的 mode 串号 / active=false） |
| mode 提交等待 + 退化 mode 拒捕 | `VDManager.m` / `PipelineProbe.m` | 1×1 不再进捕获，消灭 `Start stream failed` 这一崩溃前兆 |
| destroy 前 settle 300ms→1500ms；重试上限按 OS 下调 | `VDManager.m` / `main.m` | 降低重配置频率与总 IPC 次数 |
| IOKit 防显示休眠断言 + 唤醒声明（**防御性**） | `main.m`（verify/hold 全程持有，三个返回路径都释放） | 排除休眠这一额外变量；非事故根因修复 |
| startCapture 失败路径 best-effort stopCapture | `PipelineProbe.m` | 不留悬空 stream |
| verdict 细分失败环节 + `targetResolutionReached` | `main.m` | `WINDOWSERVER_SPI_TIMEOUT` / `CREATE` / `LIVENESS` / `MODE_COMMIT` / `VISIBILITY` / `WALK` 可区分；pass 必须 mode 真落到目标分辨率 |
| **OS 版本自动分流** | `ProbeUtil.m` `P0OSPolicy` / `main.m` | Sequoia 不再套用 Tahoe workaround，见 12.5 |

### 12.4 安全重跑协议（2026-11-16 已按此执行并通过，见 12.6）

1. 确保显示器亮着、接物理屏，系统设置里临时把「关闭显示器」设为「永不」；
2. 先最小化试跑：`./p0probe verify --spec 1920x1080x0 --no-encode --fresh`（单屏、不编码、全新 identity）；
3. 通过后再跑完整默认双屏 + 编码；
4. **任何一次出现 `WINDOWSERVER_SPI_TIMEOUT`、屏幕闪烁或风扇异常，立即停测**，不要重试；
5. 本机重跑建议带 `--fresh`（2026-11-16 已验证 offset 0 可正常建屏并通过完整链路）；
6. 本机只是 Sequoia 基线冒烟，**Tahoe 结论仍以被控端真机为准**（第 11 节流程不变）。

### 12.5 OS 版本自适应（Sequoia 基线 vs Tahoe 目标）

探针不再把 Tahoe 的 workaround 无差别套在所有系统上。`P0OSPolicy()`（`ProbeUtil.m`）用 `NSProcessInfo.operatingSystemVersion.majorVersion` 判定版本族，`probe` / `verify` 启动即打 `os-policy` JSON：

| 策略 | Tahoe 26 | Sequoia 15 / 其它 |
|---|---|---|
| 建屏尺寸 | 保守 canvas 1280×800 → promote 到目标 | **直建目标分辨率**（单次 apply） |
| identity | walk（vendor/product/serial 游走）+ 持久化成功 offset | **固定 identity**，不 walk、不持久化 |
| 失败重试 | 最多 4 组（stale/poisoned 恢复机制） | **失败即止**（最多 1 次），不向异常 WindowServer 继续施压 |
| `--direct` 对照 | 有意义（A/B PR #288） | 默认本就直建，`run_p0.sh` 自动跳过对照 |

**为什么 Sequoia 直建是安全的**：本机 diag2 受控实验（`diag2.m`）——

- **D**（主队列 + 建屏后跑 1s run loop 再 apply）：2s 后 mode = **1920×1080**，单次 apply 即提交；
- **F**（串行队列、不跑 run loop、立即 apply + usleep 3s）：mode = **1920×1080**，同样单次提交；
- **E**（串行队列 + 二次 apply）：第一次 apply 后仍 1×1，第二次才落到 1920×1080 —— 证明「首个 apply 可能被 attach 吞掉」，用 mode 提交等待 + 中途补一次 apply 兜底即可。

而两次 WindowServer 事故恰恰都发生在**保守 canvas→promote** 路径（两次 apply、两块屏并发未提交）。Sequoia 直建把每块屏的重配置 IPC 从 2 次降到 1 次，配合逐屏串行提交，显著降低把 WindowServer 拖挂的概率。

**全版本共用的安全机制**（不随 OS 分流关闭）：SPI 8s 死线 + 挂起熔断、逐屏 mode 提交等待、退化 mode 拒捕、destroy settle、失败路径 stopCapture。Tahoe 真机跑时会自动识别为 26 并切回保守 canvas + identity walk 全套路径，无需改代码。

### 12.6 安全重跑通过：自动镜像根因与原子解除（2026-11-16）

按 12.4 协议重跑，**全程无闪烁、无挂起、销毁干净，完整双屏 + H.264 链路两次通过**。过程与结论：

1. **终审补漏**：`startCapture` 5s 超时但 error=nil 时会被误判为成功 → 超时分支强制 stopCapture 并返回失败（`PipelineProbe.m`）。
2. **最小单屏安全失败暴露新根因**：1920×1080 mode 已提交，但 `active=false`、SCK 不可见 → `LIVENESS_FAILED`。`diag3.m` 证实：**Sequoia 在 mode 提交后会把虚拟屏自动镜像到物理屏**（`mirrorSet=1`），镜像态 `active=false` 且从 `SCShareableContent` 消失。用 `CGConfigureDisplayMirrorOfDisplay(cfg, did, kCGNullDirectDisplay)` 解除后恢复扩展模式，15s 稳定无反弹。
3. **双屏顺序陷阱**（`diag4.m` 三组对照）：
   - A（不解除镜像）：两块屏 mode 都能提交，但都被镜像到同一块物理屏；
   - B（先解 #1 镜像再建 #2）：**#2 的 apply 被 WindowServer 吞掉，mode 永卡 1×1**，补 apply 无效；且 #1 之后会反弹回镜像态；
   - C（全部 mode 提交后，单事务原子解除两块屏镜像）：一次生效，10s 无反弹，双屏 `active=1`。
4. **落地修复**（`VDManager.m` / `ProbeUtil.m`）：`createAll` 全部 mode 提交后 `unmirrorAll` 单事务原子解除；liveness 等待中限频（≥1s）补救反弹；promote/rollback 后统一原子解除；mode 等待 6s→10s（`P0OSPolicy.modeWaitMs`），中途补 apply 改为每 2s 限次；`liveness` 增加 `mirrorSet` 字段。unmirror 同样走 8s 死线 + 熔断，**全版本通用**（虚拟屏必须是扩展模式才能被 SCK 捕获）。

**重跑结果**（本机 Sequoia 15.5，静态检查 7/7；判黑阈值在 2026-11-17 修正，见 §5 说明，表中「0 黑帧」按新阈值需重测）：

| 测试 | 结果 |
|---|---|
| 单屏 1920×1080 无编码（offset 7） | pass：73 帧 `HAS_CONTENT`，0 黑帧，首帧 504ms |
| 单屏 2560×1440 无编码（offset 10） | pass：65 帧 `HAS_CONTENT`，0 黑帧，首帧 335ms |
| 双屏 + H.264（offset 12） | **pass**：21/21、41/41 帧编码→环回解码全成功，keyFrames 各 1，0 编码错误，0 黑帧 |
| 双屏 + H.264（`--fresh`，offset 0 复测） | **pass**：默认 identity 可复现，排除「offset 0 已污染」的担忧 |

注：桌面静止内容下捕获帧率 10–20fps 属正常（SCK 只在画面变化时产帧），判黑与编解码指标才是 P0 判据；§5 的 ≈60fps 需要动态画面，留给后续 spike 验证。

## 13. Tahoe 26.5.2 Intel 真机复核（2026-11-17）

在**被控机本机**（Macmini8,1 / i5-9500 / UHD 630 / x86_64 / macOS **26.5.2 (25F84)** / SDK 26.5 / Xcode 26.5）上做了不建屏的全部前置复核，并顺带修掉四处代码缺陷。**verify 尚未执行**（原因见 13.4）。

### 13.1 已关闭的前置风险

| 项 | 结果 |
|---|---|
| 编译 | `bash build.sh` 零警告通过（此前「唯一剩下的第一轮风险」据此关闭） |
| 私有类解析 | `allClassesResolved=true`（四个类都在 CoreGraphics/SkyLight 里） |
| selector 签名 | `spi-signature-check.missing=[]` |
| 编码器档位 | H.264 Baseline/Main/High + HEVC Main，1080p/1440p/4K 全 `supported=1` / `hardwareAccelerated=1` |
| 屏幕录制 TCC | 授权后 `screenRecordingGranted=1`，`visibleDisplayIDs` 能列出两块物理屏 |
| 静态自检 | `python3 check_static.py` 7/7 |

### 13.2 本轮修掉的代码缺陷

| # | 缺陷 | 影响 | 修复 |
|---|---|---|---|
| 1 | **判黑阈值与色彩范围不匹配**：捕获用 `420YpCbCr8BiPlanarVideoRange`，黑电平是 Y=16，旧代码按 `Y<8` 判黑 | 在任何视频范围帧上都不可能命中 → `MOSTLY_BLACK` 判据实际失效 → **真黑屏会被判成 `HAS_CONTENT`（假通过）** | 阈值改为 `Y < 16+4` 且 `方差 < 4`，并把黑电平提取为具名常量 |
| 2 | `physicalCores` 用 `sysctlbyname` 字符串方式读 `hw.physicalcpu`（int32） | env 里输出 `"\u0006"` 这类垃圾值，机型指纹不可用 | 新增 `P0SysctlInt()`，同时补 `logicalCores`；实测输出 6/6 |
| 3 | `isLoggedInGUI` 用 `getuid() != 0` 判断 | 对任何非 root 进程恒为真，等于没有判据；而 §11.4 把它当第二道闸门 | 改用 `CGSessionCopyCurrentDictionary() != NULL`，实测 `true` |
| 4 | `SCStreamConfiguration.width/height` 直接赋 `SCDisplay.width/height`（点） | HiDPI(2x) 虚拟屏会被降采样成半分辨率再编码，A-05 测到的不是 HiDPI 流 | 乘 `pointPixelScale`（`@available(macOS 14.0, *)` 保护）、按 H.264 要求取偶数，结果里增 `rasterScale` |

改完重新编译零警告、`check_static.py` 7/7、`probe` 复跑正常。

### 13.3 在这台机器上跑 verify 的额外风险（必须先读）

1. ~~**UHD 630 最多同时驱动 3 块显示器 → 加虚拟屏会超限**~~ ❌ **该结论错误，2026-11-17 15:40 实测推翻，见 §16**。
   UHD 630 的「3 屏」是**硬件输出接口（DDI/pipe）数量**限制，即能接几个物理显示器；而 `CGVirtualDisplay` 走 WindowServer **软件合成**，不占用硬件输出通道。实测 **2 块物理屏 + 4 块虚拟屏 = 6 块同时 online，全部 active 且全部可捕获**（`pass=true`）。因此**不需要拔物理屏**，先前"双屏测试要先拔一块"的建议作废。
   （保留的原判据：建屏仍是全局显示重配置，风险来自 WindowServer 而非屏数，§12.4 协议继续有效。）
2. **26.5.2 正好是 issue #171「毒化 identity」的原始复现版本**。社区在该版本上的结论是：`CGVirtualDisplay` 建的屏会永久不出现在 `SCShareableContent`，跨重启不恢复，只有换 identity 能救——也就是本工程 `identityWalk` 的适用场景。**expect identity walk 会被触发，不要把它当成失败**；成功的 `offset` 会被写进 `~/.p0_identity.json`，那正是要回传的证据。
3. **本机 build 落后于安全补丁**：26.6.1 才修的 CVE-2026-65400（屏幕共享免凭据认证绕过）在本机上未打。产品自身不走 Apple 屏幕共享，但被控机长期在线，建议 A-01 收尾后升级到 26.7.x 再跑一次回归（NFR-08 本来就要求每次更新后回归）。
4. **每次重建二进制都会让屏幕录制授权失效**（见 §3 第 3 条的实测记录）。若 verify 前改过代码，先重新授权再跑，否则 `sck-before` 会假失败。

### 13.4 为什么本轮没跑 verify

`verify` 会真实建虚拟屏、触发全局显示重配置，存在把 WindowServer 拖挂（看门狗强杀、强制注销，见 §12.2）的真实风险。按 §12.4 协议，这一步需要**人在物理屏前、显示器不进入休眠**，并在出现 `WINDOWSERVER_SPI_TIMEOUT` / 闪屏时立即停手。属于需要人工确认的破坏性操作，等确认后按 §12.4 的单屏最小面开跑：

```bash
P0_NO_BUILD=1 bash run_p0.sh          # 已编译过，跳过重建以保住 TCC 授权
# 或更保守：先单屏不编码
./p0probe verify --spec 1920x1080x0 --no-encode --fresh
```

## 14. A-01 实测结果：单虚拟屏通过（2026-11-17 11:55）

**结论：`verdict.pass = 1`。P0 的硬门禁在 Tahoe 26.5.2 / Intel Macmini8,1 上通过。**

执行命令（最小面：1 块虚拟屏、不编码）：

```bash
./p0probe verify --spec 1920x1080x0 --no-encode --fresh
# 退出码 0；日志 diag-min-20261117-115549/verify-min.log
```

### 14.1 判定结果

| 字段 | 值 | 判读 |
|---|---|---|
| `verdict.pass` | `1`（旧版输出；已改为 `true`） | 通过 |
| `allCaptured` / `targetResolutionReached` | `true` / `true` | 目标 1920×1080 达到且被采到 |
| `noBlackFrames` / `suspectedBlackFrames` | `true` / `0` | 阈值修正后仍无黑帧，**这次才是有证据效力的判黑结论** |
| `capture.verdict` | `HAS_CONTENT` | `minLumaMean=151`、`maxLumaVariance=1275`，画面有内容 |
| `identityOffset` | **0** | offset 0 直接成功，`~/.p0_identity.json` 已写入 `offset: 0` |
| `visibility` | 一次命中（`attempt=0`） | `seen` 同时包含虚拟屏 `4128835` 与两块物理屏 |
| identity walk | **未触发** | 26.5.2 本次**没有**出现 issue #171 的毒化 identity |

### 14.2 建屏链路各阶段耗时（同一日志时间戳）

| 阶段 | 耗时 | 说明 |
|---|---|---|
| `create` | 0.52 s | ~20528/20528/serial 4096，`conservative=true`，先建 1280×800 画布 |
| `create` → `mode-commit` | **6.41 s** | 最慢的一环 |
| `mode-wait` → `visibility` | 0.71 s | 模式稳定后立即可见 |
| `applySettings`（→1920×1080） | 0.02 s | 模式切换本身很快 |
| `applySettings` → `promote` | **3.89 s** | 次慢 |
| `create` → `promote`（可用的屏） | **≈11.3 s** | 端到端“拿到一块能用的虚拟屏” |
| `create` → `verdict`（含 4 s 采集） | ≈19.5 s | |

⚠️ **产品含义**：会话建立时“建屏”这一跳要 11 秒，远不能支撑“秒连”。M1 必须优先优化这两处 6.4 s / 3.9 s 的等待（先查是不是固定 sleep / 轮询间隔导致），或者做成**常驻虚拟屏 + 会话间复用**。这是本轮最有价值的负面数据。

### 14.3 三个必须记录的新发现

**F-1（真 bug，影响 HiDPI 判断）**：请求 `hiDPI=0`，但 `liveness` / `mode-wait` 回报 `reportedHiDPI=2`，而同一行 `modePoints` 与 `modePixels` 都是 `1280x800`（并非 2 倍 backing）。说明 **SPI 回报的 hiDPI 标志不可信**，A-05 判 HiDPI 必须用 `CGDisplayCopyDisplayMode` 的 **`CGDisplayModeGetPixelWidth/Height`**，不能读这个字段。`verdict.modes[]` 已按此实现（`hiDPIRequested` 为真时要求 `modePixels == 2 × requestedPoints`，`pixelsOK` 单独给判据）。

**F-2（代码缺陷，已修 2026-11-17 12:00）**：`withEncoder=false` 时 `verdict.encoderProducedFrames` 仍为 `true`（无条件写死的值），会让“编码产出帧”这条判据在任何不编码的运行里都被误认为已验证。已改为 `withEncoder ? @(encodedOK) : [NSNull null]`；同时修掉 `verdict.next` 只按 `allCaptured && noBlack` 判断、可能在实际 `pass=0` 时仍输出“P0 通过”的矛盾，并新增 `modes[]` 输出每个屏的 `modePoints/modePixels/pointsOK/pixelsOK`。

**F-3（判读陷阱）**：`fps=9`（4000 ms 收到 39 帧）**不能**当作管线帧率能力。虚拟屏上是静态桌面，SCK 按内容变化送帧，静态场景本就会掉帧。要测真实帧率必须喂动图（播放视频 / 拖窗口），因此 **A-05 的 60fps 结论本轮不成立，需运动场景重测**。同理 `firstFrameLatencyMs=416` 只是在静态屏上“等第一帧变化”的延迟，不等于首帧链路延迟。

### 14.4 与 issue #171 的关系（预期需要修正）

此前据社区结论预期 26.5.2 会 poison identity，实测**未复现**。差异可能来自条件不同：本次是**先授权屏幕录制、再建屏**，而 issue 的复现路径多在“建屏时 TCC 未就绪 / 建屏后再授权”。因此结论应写成：**26.5.2 在 TCC 就绪的前提下 identityOffset=0 可用；毒化场景仍需专门构造复现**，不能据此宣布 identity walk 无用（`os-policy` 仍保留 `identityWalk=true`）。

### 14.5 尚未覆盖的面

- ~~**H.264 实际编码**~~：已于同日 15:15 补测通过（§15.1）。
- ~~`--direct` 对照（Tahoe 上跳过保守 canvas 的 A/B）~~：已于 15:20 完成，正是它定位出 F-4（§15.2）。
- ~~**双虚拟屏**~~：已于 §16.1 实测 2 物理 + 4 虚拟共 6 屏同时在线；V-03 的「只剩虚拟屏再建一块」由 `P0V-DisplayIsolation` 覆盖（待现场执行）。
- 运动场景帧率 / glass-to-glass 延迟（§15.3 显示静态场景的 `P95` 波动达 20 倍，不可用）。

## 15. A-01 补测：编码面 + HiDPI 面（2026-11-17 15:15–15:22）

**结论：`encode_rc=0 hidpi_rc=0`，两面同时通过。`run_batch.sh` 一条命令跑完，两个 verdict 均 `pass=true`。**

### 15.1 结果

| 面 | spec | 结论 | 关键数据 |
|---|---|---|---|
| 编码面 | `1920x1080x0` | ✅ pass | `encodedFrames=19`、`encodeErrors=0`、`decodedFrames=19`、`keyFrames=1` |
| HiDPI 面 | `1280x720x1` | ✅ pass | `modePixels=2560x1440` / `modePoints=1280x720`、`pixelsOK=true`、`raster=2560x1440`、`rasterScale=2` |

这两条关闭了 §11.6 最后剩下的一半：**H.264 不只是 `hardwareAccelerated=1` 的静态能力，而是真实产出了编码帧**；**HiDPI 虚拟屏真实产出了 2× 像素流**（2560×1440 而非降采样的 1280×720）。

### 15.2 本轮抓到的两个新缺陷（都已修复）

**F-4（严重，架构级）：HiDPI 在 `initWithDescriptor:` 时固化，事后改不动。**

`effectiveConfigForIndex:conservative:` 在保守 canvas 阶段把 `hiDPI` 抹成 0（建 1280×800@1x），之后 `promoteToTarget` 想提升到 1280×720@2x 时，`applySettings:` **返回 YES 但静默无效**，mode 永久停在 `1280x720 / 1280x720`（`pixelsOK=false`）。

对照实验（同一台机、同一版本、同一 spec）：

| 路径 | modePoints | modePixels | 捕获栅格 | verdict |
|---|---|---|---|---|
| 保守 canvas（旧） | 1280×720 | **1280×720** | 1280×720 | pass=false |
| `--direct`（跳过保守） | 1280×720 | **2560×1440** | 2560×1440 | pass=true |
| 保守 canvas（修复后） | 1280×720 | **2560×1440** | 2560×1440 | pass=true |

修法：保守 canvas **只缩「点」尺寸，绝不动 `hiDPI`**；且当目标本身已 ≤1280×800 时直接返回目标（不缩水）。
**产品含义**：M1 里若要让用户选 Retina 虚拟屏，descriptor 必须一次给足像素能力，不存在“先小后大”的降级路径。

**F-5（严重，静默黑屏）：对同一块屏重复提交相同模式的 `applySettings` 会把桌面清成纯黑且不重绘。**

修复 F-4 后立刻暴露：`1280x720x1` 走保守路径时，保守 cfg 已等于目标，`promoteToTarget` 仍重复 apply 了一次同尺寸模式 → 捕获得到 `minLumaMean=16`（正是视频范围黑电平）、`maxLumaVariance=0`、53/53 帧被判黑；而同样规格走 `--direct` 是 `mean=151`。

修法：`promoteToTarget` 增加幂等判断 —— 若所有屏的保守 cfg 与目标 cfg 完全一致（尺寸 + hiDPI），跳过 apply 并直接返回 `YES`，日志输出「保守 canvas 已等于目标，跳过重复 applySettings（避免清屏）」。

**为什么这条值得写进文档**：`applySettings` 返回 YES 却把屏搞黑，是典型的"成功返回值不代表成功副作用"，任何依赖返回值做判据的代码都会漏掉。

### 15.3 性能信号（必须如实记录，不要当成结论）

| 轮次 | 编码 `P95` | 帧数/4s |
|---|---|---|
| 15:15 首次 | **40.9 ms** | 28 |
| 15:22 复跑 | **793.7 ms** | 19 |

P95 相差近 20 倍。可能原因：静态桌面下 SCK 按内容变化送帧，样本量小（19–28 帧）导致分位数不稳；也可能真有瞬时卡顿。**当前不足以判断编码器性能，A-02 与 M1 的帧率结论必须在运动场景（播放视频/拖窗口）下重测**，这与 §14.3 F-3 的结论一致。

### 15.4 工程流程解锁：重建不再毁授权

之前每次 `build.sh` 重建都会让屏幕录制授权失效（§13.3 第 4 条）。本轮验证：**把 WorkBuddy 加入屏幕录制白名单后，授权委托给责任进程**，因此

- 全新路径 + 全新 identifier 的二进制（`/tmp/p0x`, `com.p0.brandnew`）也能直接抓屏；
- 本轮共重建 3 次，每次重建后 `screenRecordingGranted` 均为 `true`。

含义：**代码修改 → 重建 → 立即实测的循环不再需要人工重新授权**，后续所有真机测试都可以自动跑。

**但有一个前提已固化进 `build.sh`**：二进制必须带 ad-hoc 签名。实测踩到过一次 —— 只跑编译没重签，`codesign -dv` 显示 `code object is not signed at all`，授权立刻回落为 `false`（因为**未签名的二进制连"委托给责任进程"都不成立**，直接报 `The user declined TCCs`，很难与"授权没给"区分）。

现在 `build.sh` 在链接成功后自动执行：

```bash
codesign --force --sign - --identifier "com.p0.tahoeprobe" --timestamp=none ./p0probe
```

所以以后只需 `bash build.sh`，不必再手动签名。若看到「警告：ad-hoc 签名失败」，先解决签名再跑 verify，否则 TCC 必然假失败。

## 16. display 容量与「捕获优先」路径（2026-11-17 15:40）

> ⚠️ **本章 §16.2 / §16.3 的「捕获优先」结论已于同日作废**（属 VNC/镜像语义，与产品定位冲突）。
> 产品形态改为**独占式会话**：只建虚拟屏、物理屏置黑/锁定、绝不捕获物理屏。见 `docs/DECISIONS.md` D-04 与 `P0V-SessionRecon/README.md`。
> 本章仍然有效的部分：**§16.1 —— 虚拟屏与物理屏在 WindowServer 层解耦（2 物理 + 4 虚拟 = 6 屏同时在线）**，
> 它是"客户端要几块就给几块"的直接依据。

触发原因：一个合理的架构质疑 ——「RDP 里控制端不需要知道被控端有几块屏，为什么 macOS 需要？被控端插 3 块屏岂不是建不了虚拟屏？」。实测结果**推翻了本工程此前的一个错误推论**，并把架构方向理清了。

### 16.1 实测：虚拟屏数量与物理屏数量完全解耦

| 实验 | 在线 display 总数 | 结果 |
|---|---|---|
| 2 物理 + 1 虚拟 | 3 | pass |
| 2 物理 + 2 虚拟 | **4** | pass，两块虚拟屏均 `HAS_CONTENT` |
| 2 物理 + **4 虚拟** | **6** | pass，四块虚拟屏均 `active` 且均采到内容 |

`CGVirtualDisplay` 由 WindowServer **软件合成**，不申请 Intel 的 DDI/显示管道。UHD 630 的「最多 3 屏」是**物理输出接口数量**（能插几个显示器），与虚拟屏无关。

**结论：被控机插 3 块、4 块物理屏，照样可以再建 N 块虚拟屏。** 产品多显示器路线不受硬件屏数限制，先前 §13.3 第 1 条的"超限"判断是错的（已划掉）。

### 16.2 「捕获优先」路径：有屏就直接采，别建屏

新增 `p0probe capture` 子命令：**完全不建屏**，直接捕获系统已有 display。

```
$ ./p0probe capture --display all --duration 3000
pass = true, mode = capture-only, displayCount = 2, elapsedMs = 5152
  2026701824  3440x1440  HAS_CONTENT  firstFrame=124ms
  817925634   1080x1920  HAS_CONTENT  firstFrame=252ms
```

三条供给路径对比：

| 路径 | 建屏开销 | 首帧延迟 | 适用场景 |
|---|---|---|---|
| **捕获现有物理屏** | **0** | **124–252 ms** | 被控机有屏且在唤醒状态 |
| 建 1 块虚拟屏 | ≈11.3 s | 416–691 ms | 无头机器（无任何 display） |
| 建 N 块虚拟屏 | ≈11.3 s × N | 同量级 | 控制端要求 N 路，被控端无对应物理屏 |

**这直接回答了 §14.2 记录的「建屏 11.3 秒」性能问题：大多数真实场景根本不需要建屏。** 被控机是台正常工作机时，物理屏就在那儿，捕获即可，零开销、秒连。

### 16.3 架构结论：虚拟屏的定位被搞错了

先前隐含的假设是「虚拟屏用来**模拟被控端的物理屏**」，于是被控端有几块屏、能不能建屏成了约束。这是把 **VNC/镜像模型** 和 **RDP/会话模型** 混在了一起。

正确的定位是：**虚拟屏用来满足「控制端提出的显示需求」，与被控端物理屏无关。**

- 控制端说「我要 2 路 1920×1080」→ 被控端就提供 2 个 display 对象；
- 这 2 个对象可以是 2 块物理屏，也可以是 2 块虚拟屏，还可以混合；
- 命令行的 `--spec` 本来就是「客户端想要什么」而不是「机器有什么」，方向一开始就是对的。

因此产品逻辑应为：

```
1. 控制端协商出 N 路需求
2. 枚举被控端可用 display
3. 有 → 直接捕获（0 开销）
4. 不足 → 按差额建虚拟屏补齐
5. 会话结束 → 只销毁自己建的那些
```

### 16.4 仍存在的真实差距：镜像 vs 会话隔离

以上解决的是"几块屏、能不能建"，但**这不是本项目与 RDP 的最大差距**。

| 能力 | Windows RDP | 本方案（SCK + CGVirtualDisplay） |
|---|---|---|
| 客户端决定分辨率/屏数 | ✅ | ✅（`--spec`，已实测） |
| 屏数不受物理硬件限制 | ✅ | ✅（§16.1，已实测 6 屏） |
| **远程操作时本地屏不可见** | ✅ 控制台锁定 | ❌ **物理屏现场直播** |
| **锁屏状态下仍可远程采集** | ✅ | ❌ TCC/内容保护阻断 |
| 多用户并发会话 | ✅ 独立 session | ❌ 只有 console session |

后三项是**会话隔离**能力，属于「镜像模型」与「会话模型」的根本差异，靠虚拟屏无法弥补。若产品定位是无人值守远程办公（隐私、锁屏可用），需单独立项验证 macOS 的虚拟会话能力（Fast User Switching 是"切换"不是"并发"；私有 SkyLight virtual session 未公开、跨版本易碎）。**这是待决策的架构分叉，不是当前 P0 能回答的问题。**

## 17. 残留虚拟屏槽位导致建屏卡死（Sequoia 15.5 / Macmini8,1，2026-11-17 21:10）

> 环境标注：本章结论来自 **Sequoia 15.5（Macmini8,1 / i5-9500）**，不是 Tahoe 机。
> 修复本身按 `conservative` 分流，Tahoe 保守 canvas→promote 路径不受影响；Tahoe 上
> 是否也存在槽位复用问题尚未验证。

现象：`p0probe verify --spec 1280x720x0` 连续失败在 `MODE_COMMIT`。新建屏拿到
`displayID=4128835`，状态却是 `online=1 active=0 mirror=1`、`bounds={0,0,1920,1080}`、
`mode=2560x1440`（points 与 pixels 都是 2560x1440），`applySettings` 返回 YES 但
10s 内 mode 永不提交。换 identity（`--offset 7`）无效。

根因：本机 WindowServer 保留了 5 个已注销虚拟屏的槽位（4128831–4128835）。它们
offline 时表现为 `1x1`、bounds 在 `5472..5476` 的停车位；但新建屏**复用最近释放的
4128835** 时会继承该槽位的镜像态，mode 一直报告旧 master 的 2560x1440。这不是
identity 缓存问题，identity walk 绕不开。

对照实验（独立最小程序）：

| 动作 | active | mirror | mode |
| --- | --- | --- | --- |
| 建屏 + apply | 0 | 1 | 2560×1440 |
| 单事务 `CGConfigureDisplayMirrorOfDisplay(kCGNullDirectDisplay)` | **1** | **0** | **1280×720** |
| 再显式 `CGConfigureDisplayWithDisplayMode` | 1 | 0 | 1280×720 |

修法（`VDManager waitModeForIndex:`）：**单屏、非 Tahoe 保守路径**下，建屏 2s 后若
仍 `CGDisplayIsInMirrorSet` 且 mode 不匹配，提前调用一次 `unmirrorAll`（之后 mode 在
1s 内提交）。多屏保持原有「全部 mode 提交后再统一解除镜像」顺序，因为 15.5 实测过
「先解除 #1 再建 #2 会吞掉 #2 的 apply」的顺序陷阱；Tahoe 保守 canvas→promote 路径
也不动。

验证：修复后 `p0probe verify --spec 1280x720x0` 与
`P0V-DisplayIsolation/v01probe run --dry-run` 均通过（mode 1280×720、SCK 可见、
`HAS_CONTENT`）。残留槽位本身在正常注销后仍会留在 SLS 列表里。

**槽位能否从用户态清掉（2026-11-17 22:30 复测）**：不能。`CDVirtualDisplayDestroy`
只接受创建进程内的 client 指针，`SL2CDVirtualDisplayDestroy` 只查本进程虚拟屏表；
换用 `0xFFFFFFFF` 身份重建仍只复用 4128835；`pmset displaysleepnow` + `caffeinate -u`
两轮也没有回收离线槽位（该方法只能回收「在线孤儿」）。只有注销/重启会清空。
因此 `P0V-DisplayIsolation` 改成：检测到槽位时只自动跳过「零物理屏下再建一块」子项，
不再中止整个 V-03，也不要求用户重启；详见该工程 README。

**后续事故（同日 22:03，同一台 Sequoia 机）**：在已有 5 个残留槽位的 WindowServer 里
一次创建第 2 块虚拟屏（V-03 重建测试），WindowServer 在
`DisplaySet::create → PKGDisplay::PKGDisplay → canonical_mirror_master` 的
`WSCanonicalMirrorMasterForDisplayDevice` 断言处 SIGABRT，整机注销。第 1 块创建安全。
修复方向：多屏必须在禁用物理屏之前建齐；不要在该状态下补建。
22:35 用新预检重跑 V-03 核心（`--mode all --watch-secs 20`）：重建子项自动跳过，
其余判据全过（含 20s 唤醒观察 0 次重新 enable、输入注入），恢复精确，`label=PASS`。
