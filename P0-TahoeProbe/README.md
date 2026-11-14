# P0-TahoeProbe

在**被控端**验证「Intel Mac + macOS 26 Tahoe + 无头虚拟屏 + 非 VNC」这条链路能否跑通的最小工程。

不涉及网络、不涉及控制端、不写产品代码。目的只有一个：**在写任何正式代码之前，把「建屏 → SCK 看见 → 抓到非黑画面 → H.264 硬编 → 本机解回」这一段唯一没有现成端到端实测记录的路径跑实。**

---

## 0. 更正后的环境矩阵，以及它推翻了什么

| | 被控端（Host / Sender） | 控制端（Client / Receiver） |
|---|---|---|
| CPU | Intel x86_64 | Intel x86_64 |
| macOS | **26 Tahoe**（当前 26.7.3，2026-11-09） | **15 Sequoia**（当前 15.8.2） |
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
├── build.sh                     clang 一键编译
├── README.md
└── src/
    ├── CGVirtualDisplaySPI.h    私有 API 的 protocol 重声明 + 运行时解析接口
    ├── ProbeUtil.h/.m           日志、JSON 输出、环境指纹、Quartz display 列表、selector dump
    ├── VDManager.h/.m           建屏 / liveness / identity walk / 保守 canvas 提升 / 销毁
    ├── PipelineProbe.h/.m       SCK 可见性 / 逐屏捕获 / 亮度判黑 / VT 能力探测 / 编码环回
    └── main.m                   probe / capabilities / verify / hold 四个子命令
```

---

## 3. 前置条件（被控端 Tahoe）

1. **记录确切 build**：`sw_vers` 输出（例如 26.7.3 / 25Gxxx）。后面每次系统安全更新后都要重跑一次本工程。
2. `xcode-select --install` 装 Command Line Tools。
3. **TCC 授权**：命令行工具的屏幕录制权限归属**父进程**，也就是你启动它的那个终端。给 `Terminal.app` 或 `iTerm` 在「系统设置 → 隐私与安全性 → 屏幕录制」打勾，**授权后完全退出终端再重开**（屏幕录制授权需要进程重启才生效）。辅助功能同理（`CGEventPost` 后续 spike 才用，可一并先授）。
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
| `--direct` | 关 | 跳过保守 canvas，直接按目标分辨率建屏（对照 PR #288） |
| `--fresh` | 关 | 忽略 `~/.p0_identity.json`，从 offset 0 开始试 |
| `--offset N` | 上次的成功值 | 指定 identity 起始偏移 |
| `--max-retries N` | 8 | identity walk 最多换几组 |
| `--visibility-timeout MS` | 5000 | 等虚拟屏出现在 `SCShareableContent` 的超时 |

每行 stdout 都是单行 JSON（`stage` 字段标识阶段），日志走 stderr，可直接分离：

```bash
./p0probe verify > run.jsonl 2> run.log
```

最终结果同时写入 `./p0_result.json`，进程退出码 0 = 通过。

---

## 5. 判读标准

| stage | 通过条件 | 不通过说明什么 |
|---|---|---|
| `env` | `arch == x86_64`，`osVersion` 以 26. 开头 | 跑错机器了 |
| `spi` | `allClassesResolved == true` | Tahoe 上私有类改名/迁移 framework，需重新逆向 |
| `spi-signature-check` | `missing == []` | selector 漂移，要按 dump 结果改 `CGVirtualDisplaySPI.h` |
| `sck-before` | `screenRecordingGranted == true` | 终端没拿到屏幕录制权限，后面全是假失败 |
| `encoder-capabilities` | `H264-Main` 在 1920×1080 / 2560×1440 上 `supported=true` 且 `hardwareAccelerated=true` | Intel 硬编不可用，只能软编，延迟目标要重定 |
| `create` | N 条，`applySettings=true`，displayID 非 0 | `initWithDescriptor:` 被拒 → identity 被污染 |
| `liveness` | 每条 `online=true, active=true, usable=true` | Tahoe stale display（bounds 非空但 offline） |
| `visibility` | `ok=true` 且 `seen` 包含全部 `wanted` | **最关键的 Tahoe 判据**；失败会触发 identity walk |
| `promote` | `ok=true` 且 `modePoints` 变成目标分辨率 | 提升后掉屏，工程会自动回退保守 canvas 并标记 |
| `capture` | `verdict=HAS_CONTENT`、`frames>0`、`fps≈55-60`、`suspectedBlackFrames` 远小于 frames | `NO_FRAMES_TCC_OR_STALE` 或 `MOSTLY_BLACK` |
| `capture` 编码部分 | `encodedFrames>0`、`keyFrames>0`、`encodeErrors=0`、`decodedFrames>0` | 编码器不产出 buffer（PR #288 的吞吐上限问题） |
| `verdict` | `pass=true` | 按下面决策树定位 |

**P0 通过的定义**：两块虚拟屏都满足 `online+active+SCK 可见`，捕获到非黑画面且帧率接近 60，H.264 编码与环回解码都产出帧。`encodeEnqueueP50Ms` 只反映入队开销，**不是**端到端延迟，端到端要等双机 spike 再测。

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

Sequoia 15.8.2 与 Tahoe 26.7.3 都还在安全更新窗口内，**两端每次系统更新后都要各跑一次本工程（控制端跑 `capabilities` 即可）**。

---

## 8. 版本锁定策略

- 被控端锁到**具体 build**（如 26.7.3 / 25Gxxx），写进部署文档，不要只写 "macOS 26"。
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

1. `sw_vers` 记下**确切 build**（例如 26.7.3 / 25Gxxx）写进部署文档；以后每次安全更新都要重跑本工程。
2. `xcode-select --install` 装 Command Line Tools。
3. **关掉 Sidecar / BetterDisplay / Duet / 其他虚拟屏工具**——issue #171 的污染源正是它们留下的 display identity 缓存，同时开着会让结果无法归因。
4. 首次**先接一块物理显示器**：给 `Terminal.app` 授「屏幕录制」+「辅助功能」，然后 **⌘Q 完全退出终端再重开**（TCC 需要进程重启才生效）。命令行工具的权限归属**父进程即终端**，不是 `p0probe`。
5. **在已登录桌面的 Terminal 窗口里跑，绝对不要 ssh**。Aqua 会话之外虚拟屏不 attach 到 WindowServer，表现是全黑；`hold` 也看不到屏。

### 11.3 跑

```bash
cd P0-TahoeProbe
bash run_p0.sh
```

依次执行：环境采集 → `bash build.sh` → `probe --capabilities`（不建屏）→ `verify`（默认保守 canvas）→ `verify --direct`（对照）→ 汇总 → 打包。

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

### 11.6 仍然只能靠真机回答的

- Tahoe SDK / CLT 版本带来的编译差异（唯一剩下的第一轮风险）；
- `spi-signature-check` 在 Intel Tahoe 26.7.x 上的真实 selector 结果；
- `visibility` / `capture` 是否踩中 stale display 或 poisoned identity，以及成功的 `identityOffset`；
- Intel 上 H.264 是否真的 `hardwareAccelerated`，HEVC 是否可用。

### 11.7 控制端为什么还没写

第 7 节的四项（VTDecompression→IOSurface→Metal 环回、N 个无边框全屏 `NSWindow` 与坐标变换、CGEvent 注入与中文输入 / Cmd-Tab、双机 1080p60 glass-to-glass 延迟）建议**等被控端 P0 通过之后**再落代码。现在写等于再堆一份从未编译过的代码，而且它强依赖被控端真实产出的码流格式与 display ID 分配方式。等诊断包回来按真实参数写，一次成型。

### 11.8 建议的下一步顺序

1. 被控端跑 `bash run_p0.sh` → 回传 `p0-diag-*.tar.gz`；
2. 按诊断包修编译 / selector / identity 问题，直到 `verdict.pass = true`；
3. 补控制端 P0 四项（可另开 `P1-ClientProbe/`）；
4. 双机联调，测 1080p60 glass-to-glass 延迟（目标：采集+编码 < 30ms）；
5. 才进入正式产品骨架（SideScreen MacHost MIT / VirtualDisplayKit MIT）的落地。
