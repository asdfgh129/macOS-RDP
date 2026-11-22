# macOS-RDP 软件设计方案

| 项 | 值 |
|---|---|
| 文档版本 | v1.3 |
| 日期 | 2026-11-18 |
| 状态 | **已评审通过，作为 M1 基线**（11:20 冻结，11:40 按 D-10 修订，15:35 按 D-11 补注）。A-01/A-04/A-08/A-09 已关闭（A-09 的 `loginDone=0` 场景延后 M2）；A-02（glass-to-glass 延迟）不在 M1 关键路径上，留 P2 关闭 |
| 关联工程 | `P0-TahoeProbe/`（可行性探针；Tahoe 26.5.2 建屏/捕获/编码/HiDPI 全通过，见其 README §13–§15）；`P0V-SessionRecon/`（独占会话能力侦察，见其 README）；`P1-ClientProbe/`（协议编解码 + 坐标变换） |
| 评审记录 | 无（首次起草） |
| 实测结论 | **按 OS 分离记录于 `docs/RESULTS-BY-OS.md`**；Sequoia 15.5 与 Tahoe 26.5.2 的结论禁止互相外推 |

---

## 1. 引言

### 1.1 目的

为「Intel Mac + macOS 13–26（Ventura–Tahoe）**独占式会话**远程桌面」产品给出可评审、可追溯、可分阶段实施的软件设计方案。**产品形态在 2026-11-17 明确为「会话模式」：控制端登入后被控端置黑/锁定，控制端看到的是按自己规格新建的桌面，不是被控端物理屏的镜像**（见 §2.1、D-04）。本文档承接 P0 探针的实证结论，把已验证事实与待验证假设严格分开，作为后续骨架开发（M1）的唯一设计依据。

### 1.2 范围

**本期（M1–M3）覆盖**：独占式会话生命周期（认证→解锁→建虚拟屏→物理屏置黑→断开恢复锁屏）、虚拟屏管理、SCK 捕获、H.264 硬编、局域网传输、控制端解码渲染、键鼠注入、多屏会话、断线恢复、无人值守运行。

**明确不做**：捕获被控端物理屏、把被控端多块物理屏一一映射到控制端（VNC/镜像语义）。

**本期不做**（列入后续相位，见 §10）：音频、剪贴板、文件传输、互联网穿透（NAT/中继）、Apple Silicon 适配、macOS 27+ 适配。

### 1.3 术语

| 术语 | 含义 |
|---|---|
| Host / 被控端 | Intel Mac，macOS **13 Ventura – 26 Tahoe**（P0 目标验证机：**26.5.2 / 25F84**，2026-11-17 实机复核；早前文档写的 26.7.3 未在该机复现），无物理显示器（无头），建虚拟屏并采集编码 |
| Client / 控制端 | Intel Mac，macOS **13 Ventura – 26 Tahoe**（P0 基线验证机：15.5 Sequoia，历史记录），解码渲染并采集键鼠 |
| 虚拟屏 | `CGVirtualDisplay` 私有 SPI 创建的显示器，SCK 可捕获 |
| identity | 虚拟屏的 vendor/product/serial 三元组；Tahoe 上可能被 WindowServer 缓存污染 |
| glass-to-glass | 控制端输入动作到画面回显的端到端延迟 |
| stale / poisoned | Tahoe 两类虚拟屏故障：online/active=false；identity 被永久拒绝（OpenDisplay #171/#219） |

### 1.4 参考资料

- `P0-TahoeProbe/README.md`：环境矩阵、已核实事实、崩溃事故取证、Sequoia 基线结果（§12）
- OpenDisplay PR #219 / #288、issue #171（**仅行为结论参考，GPL-3.0，不复制源码**）
- DeskPad `CGVirtualDisplayPrivate.h`、SideScreen42（MIT，selector 复核）
- SideScreen MacHost、VirtualDisplayKit（MIT，拟定产品基座）
- Apple 部署文档：macOS 26 为 Intel 最后完整支持版本，此后仅安全更新（约至 2028 秋）

---

## 2. 需求

### 2.1 角色与场景

- **主场景（独占会话）**：用户把 Intel Mac（Ventura–Tahoe）放在机房/角落，从另一台 Intel Mac 连过去。**被控端无需有屏、有几块屏都无关**：控制端登入后，被控端进入独占状态（物理屏置黑 + 锁定，现场无法使用也无法旁观），控制端按自己的规格得到 N 路桌面（客户端说几块、多大，就几块、多大），键鼠直接操作，延迟接近本地。会话结束，虚拟屏销毁、物理屏恢复、被控端重新锁屏。
- **反场景（不是产品）**：把被控端物理屏内容镜像到控制端；被控端几块屏就在控制端摆几块窗口。
- **运维场景**：Host 断电重启后无人值守自动恢复服务；系统安全更新后自动/手动回归验证私有 SPI 未漂移。

### 2.2 功能需求

| 编号 | 需求 | 优先级 | 验收要点 |
|---|---|---|---|
| FR-00 | **会话独占**：控制端认证通过后，Host 进入独占态（物理屏 disable + 本地键鼠输入被吞掉并上报），断开后恢复物理屏并进入**待机壳**（黑屏 + 吞输入，不锁屏；高安全档可配置为真锁屏，见 D-07） | P0 | 会话期间现场屏不可见内容、本地输入不进入会话；断开 5s 内恢复；现场手势可夺回控制权（D-06 §3） |
| FR-01 | **只建虚拟屏，绝不捕获物理屏**：按控制端规格建 N 块 `CGVirtualDisplay`（块数与分辨率由客户端决定），会话结束全部销毁 | P0 | 每屏 online+active+SCK 可见、mode 落到客户端目标；`capture` 的 displayID 全部为会话内新建的虚拟屏；会话期间 `CGGetActiveDisplayList` **只返回这 N 块**（C-09） |
| FR-02 | 虚拟屏故障自恢复：stale 检测、identity walk、原子解除自动镜像、SPI 熔断 | P0 | 注入故障后 30s 内恢复或明确报错，绝不拖挂 WindowServer |
| FR-03 | **主路径（D-10）**：SCK `SCStream` → IOSurface → VideoToolbox H.264 硬编；**对照/兜底**：`CGDisplayCreateImage` 抓帧 → CVPixelBuffer（Tahoe 带编码仅 4fps，作降级兜底）。D-09 曾选 CG 为主，M1-Pre 实测后由 D-10 改回 SCK | P0 | 1080p 15–30fps（D-10 修订目标）非黑帧，编码产出连续；参数按 SCK + 20fps 默认，可替换而不改上层 |
| FR-04 | 局域网会话：发现、配对认证、加密传输 | P0 | 未配对设备无法连接；链路加密 |
| FR-05 | Client 解码（VT 硬解）+ Metal 渲染，N 个无边框全屏窗口落到 N 块物理屏 | P0 | 坐标变换正确（负坐标/混合缩放），首帧 < 1s |
| FR-06 | 键鼠采集与注入：`CGEventPost` + display ID 路由、中文输入法、修饰键同步 | P0 | 中文输入可用；Cmd-Tab 等系统快捷键可按策略拦截/放行 |
| FR-07 | 分辨率/屏数/相对布局由控制端动态协商，Host 原地重建或 applySettings | P1 | 协商失败事务性回退，不掉会话；布局变化后指针约束仍成立（C-09） |
| FR-08 | 断线检测与自动重连，重连后桌面状态保持 | P1 | 拔网线 10s 恢复后会话继续 |
| FR-09 | 无人值守：自动登录 + LaunchAgent 开机自启 + 崩溃自重启 + **禁止闲置锁屏**（Host 保持登录态） | P1 | 断电重启后 2min 内可连；连续 24h 无操作后仍可直接连接（D-07） |
| FR-12 | **现场取回控制权**：现场用户可用手势力夺回机器，不依赖远程方同意 | P0 | 手势触发后 ≤10s 恢复物理屏并锁屏；远程端收到明确原因（D-06 §3） |
| FR-13 | **远程登录**：Host 处于锁屏/登录窗态时，客户端可在**虚拟屏**上看到登录界面、输密码解锁，解锁后无缝转入桌面采集 | **P0**（2026-11-18 V-04a/b/c/d 在 Tahoe 全过，已升级） | V-04a/b/c/d 全过；物理屏全程无内容泄露（C-09 仍成立） |
| FR-10 | 光标独立通道（低延迟本地光标渲染） | P2 | 光标移动不依赖帧回环 |
| FR-11 | 音频转发、剪贴板同步 | P2 | 后续相位单独设计 |

### 2.3 非功能需求（量化）

| 编号 | 指标 | 目标 | 验证方式 |
|---|---|---|---|
| NFR-01 | 采集+编码延迟 | < 30ms（1080p60） | P2 双机 spike，时间戳打点 |
| NFR-02 | glass-to-glass 总延迟 | < 50ms（局域网有线） | 双机高速摄像/输入时间戳回环 |
| NFR-03 | 帧率 | **15–30fps（D-10 修订）**，默认目标 20fps；60fps 在 Intel + 当前系统 API 下不现实，已从验收项移除 | 动态测试图案，统计掉帧；Tahoe 实测带编码 SCK 禁屏 18fps / CG 4fps |
| NFR-04 | 分辨率 | 单屏最高 4096×2304@55（H.264 High@L5.2 吞吐安全点，PR #288）；默认 1920×1080 / 2560×1440@60 | verify + 编码吞吐统计 |
| NFR-05 | Host CPU 占用 | 双屏 1080p60 编码 < 15%（QuickSync 硬编，i5-9500 级） | 长时间运行采样 |
| NFR-06 | 可用性 | 7×24 运行，WindowServer 零拖挂；任何 SPI 挂起 8s 内熔断 | 故障注入 + 72h  soak |
| NFR-07 | 安全 | 配对认证 + 全链路加密；输入注入仅限已配对会话 | 渗透自查清单 |
| NFR-08 | 可维护性 | 私有 SPI 全部 protocol 重声明 + 运行时签名校验；每次系统安全更新后回归 < 10min | probe/verify 一键回归 |

### 2.4 约束

| 编号 | 约束 | 来源 |
|---|---|---|
| C-01 | **双端适配 macOS 13 Ventura – 26 Tahoe，仅 Intel x86_64**；每台部署机器锁定具体 build（实测基线 **26.5.2/25F84**）；不追 macOS 27+（仅 Apple Silicon，Intel 不可装） | 用户需求 2026-11-16；README §0/§8/§13 |
| C-02 | 产品基座只用 MIT 组件（SideScreen MacHost / VirtualDisplayKit）；OpenDisplay GPL-3.0 仅参考行为结论，**禁止复制源码或 fork 主线** | README §10 |
| C-03 | **Host 双组件**：root LaunchDaemon（特权：显示配置/禁物理屏、登录窗捕获、定向注入、开机引导）+ 用户态 LaunchAgent（会话内：建虚拟屏、SCK 采集、编码、常规注入）。TCC 按二进制逐个授权，daemon 无 UI 会话弹不出授权框，须手动拖入授权列表或 MDM PPPC 下发 | D-08；README §3 |
| C-04 | 私有 SPI 无兼容性承诺；所有 SPI 调用必须带死线 + 熔断（P0 事故教训） | README §12 |
| C-05 | 官方高性能屏幕共享要求双端 Apple Silicon，Intel 无系统级退路；唯一硬件退路是 EDID 假插头（牺牲动态分辨率） | README §0/§8 |
| C-06 | Ventura 13 / Sonoma 14 已超出 Apple 常规安全更新窗口（以 Apple 公告为准）：可以适配，但部署文档必须提示「老版本不再收到安全补丁」的风险，由用户自担 | Apple 支持周期 |
| **C-07** | **禁止镜像语义**：不得捕获物理屏、不得把被控端屏数映射到控制端。控制端显示规格唯一来源是客户端请求 | 用户需求 2026-11-17（明确否决 VNC 模式） |
| **C-08** | **单会话模型，不做多会话并发**：macOS 的 Aqua 会话创建被 `com.apple.private.aqua.createSession` 独占（仅 loginwindow 持有），第三方无法新建并行会话。产品用「同一 console 会话内独占」实现隔离语义，**不是 Windows RDP 的多会话** | 本机 entitlement 取证，见 `P0V-SessionRecon/README.md` §1.2 |
| **C-09** | **显示空间隔离（硬约束）**：会话期间 Host 全局坐标空间**只能包含本会话的虚拟屏**。物理屏必须 `disable`（移出空间），**不得**只做「置黑 / 高窗口层遮罩但仍启用」。任何使指针可落入物理屏区域、或使窗口可被拖入物理屏区域的实现一律判不合格。屏数恒等于客户端请求数，与 Host 物理屏数量无关 | 用户需求 2026-11-17（"不能在 4 块屏里移动"）；决策见 D-05 |

### 2.4.1 构建与部署矩阵（Intel 13–26，双角色）

- **目标**：同一份源码在 Intel x86_64 的 **macOS 13 Ventura – 26 Tahoe** 上均可本机编译、运行；其中任一机器既能当 **host**（建虚拟屏 / 禁物理屏 / 采集编码 / 注入），也能当 **client**（收流 / 解码 / 上屏 / 键鼠采集）。这是 C-01 的落地口径，不把角色绑死在特定 OS 版本上。
- **构建基线**：所有构建脚本统一 `-mmacosx-version-min=13.0`；用新 SDK 编出的二进制可部署到 13。
- **旧 SDK 本机编译**：macOS 13 SDK 的 ScreenCaptureKit 头文件不声明 14+ 的属性/常量，仅有 `@available(macOS 14.0, *)` 运行时判断仍会编译失败。因此 14+ API 必须同时具备编译期守卫 `#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 140000`。当前落点：`M1-Skeleton/src/M1CapturePipeline.m`、`P0-TahoeProbe/src/PipelineProbe.m`、`P0V-RootDaemon/src/p0vprobe.m`。13 上走既有回退（`scale=1.0`、忽略 captureResolution），主流程不受影响。
- **采集后端门控**：13 上 SCK/SkyLight 在本机无法建流（§5.25），因此 `M1CapturePipeline` 采用双后端：13 直接使用 `CGDisplayStream`（`IOSurface→CVPixelBuffer`，复用原编码链），14+ 优先 SCK 且建流失败自动回退 CGDisplayStream；`M1_CAPTURE_BACKEND=cg|sck` 可强制指定做 A/B。CGDisplayStream 在 14 deprecated、15 obsoleted，禁止在 14+ 作为首选。13 host × Tahoe client 镜像模式全链路两轮 PASS（§5.27）。
- **验证状态口径**：26.5.2 Tahoe（host）与 15.5 Sequoia（client）已有实测记录；13.6.7 Ventura（iMac-3 / 192.168.34.213）已完成 SSH、仓库与编译环境配置。**13 host 已验证**：镜像与 `--keep-main` 虚拟屏全链路 PASS、真实输入注入 PASS、SPI 建虚拟屏 PASS、720p 约 14.8fps（§5.27/§5.28）。**锁屏态**：CGDisplayStream 仍交付黑帧，已按版本/状态门控切到 `CGDisplayCreateImage` 快照后端，13 host 锁屏下可看见登录界面并接受定向键入（14.9fps@720p，§5.29），但需保持防显示睡眠断言；真实口令解锁未测。**完整独占禁屏 / C-09**：早期两次 WindowServer 崩溃（§5.28）已定位为 ScreensharingAgent 显示流与显示重配置竞态，加 13 专属冻结窗口后 **1280×720** 真机 PASS（C-17.40、§5.30）。补测暴露边界（C-17.41、§5.31）：该机型 **1920×1080 独占**触发另一条 `layer_blit` 崩溃（与上述竞态无关、冻结规避无效），判为 OS 层边界不重试；多屏独占与独占态登录窗迁移（V-04d 等价）仍未覆盖；连续 mode-commit 后该机 WindowServer 显示栈不稳定，崩溃后须充分恢复再测。真机结论按 OS 分离记录于 `RESULTS-BY-OS.md`，禁止跨版本外推。

### 2.5 待验证假设（定稿前必须关闭 A-01/A-02）

| 编号 | 假设 | 验证方式 | 不成立时的回退 |
|---|---|---|---|
| **A-01** | Tahoe **26.5.2 (25F84)** Intel 上私有 SPI 可用，identity walk + 保守 canvas→promote 能恢复 stale/poisoned | ✅ **已关闭**（2026-11-17 11:55）：单屏 `verify` 返回 `pass=1`、`visibility` 一次命中、`capture=HAS_CONTENT`、`identityOffset=0`（本次未触发 walk）。见 README §14 | 逐 selector 重逆向；极端情况 EDID 假插头（C-05） |
| **A-02** | 双机 1080p **15–30fps（D-10 修订）** 采集+编码 < 30ms、总链路 < 50ms；首帧 <1s 是风险项（M1-Pre 单机实测 739–1031ms） | P2 双机 spike | 降分辨率/帧率；编码参数调优；传输换 QUIC |
| A-03 | `CGEventKeyboardSetUnicodeString` 中文注入与修饰键同步在 Tahoe 可用 | P1 控制端探针 + 双机联调 | 改 IOHIDPostEvent / 输入法状态机同步 |
| A-04 | Intel+Tahoe 扩展虚拟屏上限 ≥ 2（社区经验约 4） | ✅ **已关闭 2026-11-17**：实测 **2 物理 + 4 虚拟 = 6 块 display 同时 online/active 且全部可捕获**（README §16.1）。虚拟屏走 WindowServer 软件合成，不占 Intel DDI 通道，与物理屏数量**解耦** | — |
| A-05 | HiDPI（2x points/pixels）与混合缩放渲染正确 | P1 渲染探针 | 本期只支持 1x，HiDPI 降级为 P2 |
| A-06 | 安全更新不破坏私有 SPI | 每次更新后 probe+verify 回归（NFR-08） | 版本锁定回滚 + 社区补丁跟进 |
| A-07 | Ventura 13 / Sonoma 14 上私有 SPI 与 Sequoia 行为一致（selector 已在 15/26/27 复核一致，13/14 未实测） | 各版本真机 probe+verify（P0-R，M3 前关闭） | OS 策略按版本加分支；个别版本不支持则从适配范围剔除并记录 |
| **A-08** | 独占态的物理屏可以「只对现场置黑」，且不影响虚拟屏的建屏与捕获：`SLSConfigureDisplayEnabled` 在显示配置事务内可提交 | **P0-V**：V-01 禁用**一块**物理屏后虚拟屏仍 `HAS_CONTENT`，且按键/触控板/触控 ID 等唤醒事件**不会**把物理屏重新 enable；V-03 禁用**全部**物理屏（只剩虚拟屏）后系统仍可建屏/捕获/注入输入（C-09 的极限情形，但**建屏必须在禁用物理屏之前完成**：Sequoia/Intel 实测，零 active 物理屏 + 残留槽位时新建虚拟屏会触发 WindowServer `canonical_mirror_master` 断言）；V-02 锁屏态下 a) 能否捕获到锁屏界面而非黑帧、b) 能否把键鼠注入 loginwindow、c) 能否用注入密码完成解锁。**2026-11-18 Tahoe 26.5.2：V-01 全项 PASS；V-03 的禁屏/指针/注入/20–30s 无重新 enable/恢复全通过，但 SCK 在零 active 物理屏下 4 次运行出现 1 次全黑、2 次多数帧黑、1 次白色窗口对照仍全黑；系统截图证明桌面仍在正常合成 ⇒ SCK 送帧异常，A-08 在 Tahoe 未关闭**；2026-11-18 追加（已更正）：V-02 早前 `active=false` 是探针假阴性，实际锁屏态虚拟屏 `active=1`；替代采集路径 `CGDisplayCreateImage`/`CGWindowListCreateImage` 在零 active 物理屏下稳定 `HAS_CONTENT`（见 `docs/RESULTS-BY-OS.md`） | 退化为公开 API：`CGDisplayCapture` 独占物理屏 + 高窗口层遮罩 + **强制光标接管**（D-05 §3），并把「非绝对安全」写进产品说明 |
| **A-09** | Host 在锁屏 / 登录窗态下，远程仍能拿到登录界面并完成登录（从而"断开后锁屏"与"可重连"同时成立） | **P0-V V-04a/b/c/d**（SCK 捕获登录窗、定向注入、注入密码解锁、登录窗态建虚拟屏）。见 D-08。**Sequoia 15.5 实测：V-04a/b 在用户会话进程通过（锁屏截图真实、`INJECTION_ACCEPTED_UI_CHANGED`、密码框出现输入）；root daemon 路径被 TCC 路径条目 + 无 GUI 会话挡住。** V-04c 待凭据，V-04d 未实现。**2026-11-18 10:52 最终结论：A-08 / A-09 在 Tahoe 均关闭**。V-02 假阴性已修正（探针硬闸门 + 脚本字段号），锁屏+屏亮态虚拟屏 `active=1`；禁全部物理屏后登录 UI 完整迁移到虚拟屏（截图含日期/时钟/`bemin`/密码框，有/无光标聚焦两轮均成立 ⇒ 触发条件是零物理屏）；V-04a/b/c/d 全过，V-04c 用授权凭据注入解锁 `sessionAfter.screenIsLocked=false`（凭据仅环境变量运行时注入，无明文落盘）。Path A 端到端成立，不必回 Path B。**前置**：必须防显示睡眠（锁屏 2-3s 屏睡会让 SCK displays 变空）；已登录零物理屏场景 SCK 不可靠，优先公开抓屏 API（D-05）。真 loginwindow（`loginDone=0`）**延后 M2 借测机（D-11）**，前置只读探针 `gui_session_probe` 与补测脚本 `run_loginwindow_probe.sh` 已就绪 | 四项任一失败 → 退回 Path B：Host 常驻登录态、禁闲置锁屏、"断开后锁屏"降级为可选（D-07） |

---

## 3. 总体架构

### 3.1 架构视图

```
┌─────────────── Host（Intel / macOS 13–26，无头）────────────────────────┐
│  SessionServer ── 控制通道(TLS/TCP)：发现/配对/协商/心跳/输入事件            │
│      │                                                                    │
│  VirtualDisplayManager ── 建屏/恢复/熔断（P0 VDManager 演进）               │
│      │ CGVirtualDisplay SPI                                               │
│  CapturePipeline ── SCK SCStream → IOSurface (CGDisplayCreateImage 兜底)   │
│      │                                                                    │
│  VideoEncoder ── VTCompressionSession H.264 硬编 → Annex-B/AVCC           │
│      │                                                                    │
│  FrameTransport ── 帧通道(QUIC datagram, D-01)：分片/序号/关键帧请求         │
│      ▲                                                                    │
│  InputInjector ── CGEventPost + displayID 路由 ◄── 控制通道                │
└───────────────────────────────────┬──────────────────────────────────────┘
                                    │ 局域网（有线优先）
┌───────────────────────────────────▼──────────────────────────────────────┐
│                Client（Intel / macOS 13–26，N 块物理屏）                   │
│  SessionClient ── 发现/配对/协商/重连                                      │
│  FrameReceiver ── 重组/丢帧策略/关键帧请求 ──► VideoDecoder(VT 硬解)        │
│                                                  │ IOSurface              │
│  Renderer ── Metal，N 个无边框全屏 NSWindow ↔ N 块物理屏（坐标变换）        │
│  InputCapture ── 键鼠/IME/修饰键 ──► 控制通道                              │
└──────────────────────────────────────────────────────────────────────────┘
```

### 3.2 通道划分

| 通道 | 承载 | 传输 | 理由 |
|---|---|---|---|
| 控制通道 | 配对、能力协商、输入事件、心跳、关键帧请求 | TLS/TCP（可靠） | 输入与信令不可丢 |
| 帧通道 | 编码帧分片 | **QUIC over UDP 47991（D-01 已定，见 DECISIONS.md）** | 帧可丢旧不可等旧，避免 TCP 队头阻塞毁掉延迟 |
| 光标通道（P2） | 光标位置/形状 | 并入控制通道或独立 UDP | 本地渲染光标，绕开帧回环延迟 |

### 3.3 部署视图

- Host：双组件（root LaunchDaemon + 用户态 LaunchAgent，C-03）；自动登录 + 关 FileVault；看门狗崩溃自重启；安装器负责 daemon 注册与 TCC 授权引导。
- **安全前置条件分两档**：Path A（V-04 通过，D-08）→ 断开后可真锁屏，物理安全要求回到常规水平，与 Apple 高性能屏幕共享同档；Path B（V-04 失败，D-07）→ 机器必须放在物理可信场所，且等价于一台**永不锁屏的已登录 Mac**，场地安全是唯一屏障，须写进部署文档。
- Client：普通 App，N 块物理屏各一个全屏窗口；辅助功能授权用于全局键鼠捕获。
- 两端均锁定具体 OS build；每次安全更新后跑回归（§7）。

### 3.4 技术选型与许可证

| 层 | 选型 | 许可证 | 说明 |
|---|---|---|---|
| 产品基座 | SideScreen MacHost + VirtualDisplayKit | MIT | 可 fork/闭源商用；保留版权声明 |
| 虚拟屏 SPI 声明 | 自研 protocol 重声明（P0 已验证） | 自有 | 参考 DeskPad（MIT）selector 名 |
| 捕获/编码/解码 | ScreenCaptureKit + VideoToolbox（系统框架） | 系统 | P0 已实证 Intel QuickSync 硬编可用 |
| 渲染 | Metal + IOSurface | 系统 | 零拷贝 |
| 传输 | **QUIC（Network.framework 原生，D-01 已定）** | 系统框架，无第三方依赖 | GPL 组件一律排除；第三方 C 库（msquic/quiche）已否决 |
| 语言 | Swift 为主 + ObjC 桥（P0 的 VDManager/PipelineProbe 可近乎原样搬入） | — | 私有 SPI 留 ObjC，产品逻辑 Swift |
| 行为策略参考 | OpenDisplay PR #219/#288、issue #171 | **GPL-3.0，仅参考结论** | 合规红线见 C-02 |

### 3.5 OS 版本适配矩阵（双端通用，仅 Intel）

运行时按 `NSProcessInfo.operatingSystemVersion.majorVersion` 分流（P0 `P0OSPolicy` 已实现骨架，产品沿用并扩展）：

| 大版本 | 建屏策略 | identity | 失败重试 | 实证状态 |
|---|---|---|---|---|
| 26 Tahoe | 保守 canvas 1280×800 → SCK 可见 → promote | walk + 持久化成功 offset | 最多 4 组 | 已实测（26.5.2）：offset=0 直接可用，未触发 walk；**HiDPI 必须在 `initWithDescriptor:` 一次给足（事后 `applySettings` 返回 YES 但静默无效，mode 永久锁 1x）；且不得对同屏重复提交相同模式（会清屏为纯黑）**，见 README §15.2 |
| 15 Sequoia | 直建目标分辨率 + 原子 unmirror | 固定 | 失败即止（1 次） | **本机基线已通过（2026-11-16）** |
| 14 Sonoma / 13 Ventura | 同 Sequoia 最小风险路径（P0 归入 Other 分支） | 固定 | 失败即止（1 次） | 未实测，A-07 待 P0-R 回归 |

- 全版本共用：SPI 8s 死线 + 熔断、逐屏串行 mode 提交、原子 unmirror、退化 mode 拒捕、destroy settle。
- 启动即输出 `os-policy` 日志标明本机走哪条路径；未知大版本默认走最小风险路径并在日志中警告「未验证版本」。
- 控制端不建屏，OS 分流只影响解码/渲染/注入的兼容性开关；每次系统更新后两端各跑回归（NFR-08）。

---

## 4. 模块设计

### 4.1 Host 模块

| 模块 | 职责 | 关键接口（概要） | 来源/演进 |
|---|---|---|---|
| VirtualDisplayManager | 串行建屏、mode 提交等待、原子 unmirror、liveness、identity walk、8s 死线熔断 | `establish(specs) -> [DisplayHandle]` / `teardown()` / `healthEvents` | P0 `VDManager` 直接演进 |
| CapturePipeline | 逐屏 SCK `SCStream` → IOSurface（主路径 D-10）；`CGDisplayCreateImage` 抓帧 → CVPixelBuffer 为对照/兜底；退化 mode 拒捕，start/stop 死线 | `start(displayID, config) -> FrameStream` | P0 `PipelineProbe` 演进；M1-Pre 采编探针已验证两路径 |
| VideoEncoder | VTCompressionSession，实时模式，码率/关键帧间隔策略，吞吐看门狗（PR #288 黑屏陷阱） | `encode(sampleBuffer) -> EncodedFrame` | P0 编码环回演进 |
| FrameTransport | 分片、序号、发送 pacing、关键帧请求响应 | `send(frame)` / `onKeyframeRequest` | 新建 |
| InputInjector | CGEvent 注入、displayID 路由、IME unicode、修饰键状态机 | `inject(event, targetDisplay)` | 新建（A-03 验证） |
| SessionServer | 发现（Bonjour）、配对、TLS、能力协商、心跳、会话状态机 | `start(config)` / `delegate` | 新建 |
| HostWatchdog | SPI 熔断后的整体重建、崩溃自重启、日志诊断包 | — | P0 安全机制产品化 |

### 4.2 Client 模块

| 模块 | 职责 | 关键接口（概要） |
|---|---|---|
| SessionClient | 发现 Host、配对、协商（屏数/分辨率/码率）、自动重连 | `connect(host)` / `negotiate(specs)` |
| FrameReceiver | 分片重组、序号缺口检测、丢旧帧策略、关键帧请求 | `onFrame -> Decoder` |
| VideoDecoder | VTDecompressionSession + IOSurface 输出 | `decode(frame) -> CVPixelBuffer` |
| Renderer | Metal 全屏窗口组；NSScreen(左下原点)↔Quartz(左上原点) 变换、负坐标、混合缩放 | `attach(screens)` / `present(pixelBuffer)` |
| InputCapture | 全局键鼠、IME 组合串、修饰键同步、沉浸模式（Cmd-Tab 拦截策略） | `delegate -> SessionClient` |

### 4.3 控制协议（草案）

JSON 信令 + 二进制帧头（细则以 `docs/PROTOCOL.md` 为准）。信令消息：`hello/capabilities`、`pair-request/pair-confirm`、`session-start{specs[]}`、`session-update{specs[]}`、`input{type,payload,displayID}`、`keyframe-request{displayID}`、`heartbeat`、`bye{reason}`。帧头（v2，18 字节）：`magic | version | flags(keyframe/帧末分片/含SPS-PPS) | displayID | frameSeq | fragIdx(u16) | fragCount(u16) | payloadLen`。**pts 不随帧传输**（实时流按到达时间渲染，延迟统计走 `heartbeat.ts` 回环），与本文早前写的「帧头含 pts」冲突处已按 PROTOCOL 修正。协议版本号从 1 起，双端协商取小。

---

## 5. 关键流程

### 5.1 会话建立

发现 → TLS 握手 → 配对（首次：Host 显示配对码，Client 输入，TOFU 绑定证书）→ 能力协商（屏数、分辨率、HiDPI、码率上限）→ Host 建屏 → 逐屏 SCK 可见确认 → 开始推流 → Client 首帧渲染。任一步失败带明确错误码，Host 侧事务性回退。

### 5.2 建屏与故障恢复（P0 实证策略产品化）

1. 逐屏串行：init → 500ms settle → apply → 等 mode 提交（10s 死线，每 2s 限次补 apply）→ 下一块；
2. 全部提交后**单事务原子解除全部自动镜像**（Sequoia 实证；Tahoe 待 A-01、Ventura/Sonoma 待 A-07 复核）；
3. liveness 持续监测 online+active+bounds+mirrorSet；Tahoe 上 stale → identity walk（serial/product 同步游走，持久化成功 offset）；
4. 任何 SPI 调用 8s 无响应 → 全局熔断，停止一切重配置 IPC，上报 watchdog 整体重建；**绝不重试捶打已挂起的 WindowServer**；
5. Tahoe 走保守 canvas 1280×800 → SCK 可见 → promote 到目标，失败事务性回退。

### 5.3 帧管线

主路径（D-10）：SCK `SCStream` → IOSurface → VT 硬编（实时、无 B 帧、关键帧间隔 2s + 按需）→ 分片发送 → 重组 → VT 硬解 → Metal 呈现，全程零拷贝。`CGDisplayCreateImage` → CVPixelBuffer 为对照/兜底（涉及位图拷贝）。编码吞吐看门狗发现「会话成功但无 buffer」（PR #288 陷阱）时自动降分辨率重建编码器。

> **M1-Pre 实测与 D-10（2026-11-18）**：两条链路端到端都成立（0 黑帧、编解码一致），但带编码真实帧率 `CGDisplayCreateImage` 1–7fps / SCK 2–18fps，均达不到 60fps；无编码时 SCK 的「55fps」是按内容送帧假象。**D-10 已定：SCK 回主路径 + 目标帧率下调 15–30fps，流水线并行留作 M1 后优化**。帧管线接口预留、参数按 SCK + 20fps 默认，上层不随之改动。详见 `DECISIONS.md` D-10 与 `RESULTS-BY-OS.md` §5.1/§5.2。

### 5.4 输入路由

Client 窗口坐标 → 归一化到对应虚拟屏坐标 → 控制通道 → Host 按 displayID 用 `CGEventPost` 注入到目标屏；Quartz 左上原点与 NSScreen 左下原点的变换集中在 Renderer/InputCapture 一处实现并单测（含负坐标副屏）。中文输入走 `CGEventKeyboardSetUnicodeString`（A-03）；修饰键状态双端状态机同步，断线重连后全量复位。

### 5.5 断线与降级

心跳 1s/超时 5s 判断断线；Client 自动重连（指数退避上限 10s），Host 保持虚拟屏与桌面状态；重连后请求关键帧恢复画面。网络持续不可用 > 60s：Host 保持会话待命，不销毁桌面。编码/性能不足时按 NFR-04 安全点逐级降级（分辨率→帧率）。

---

## 6. 安全设计

- **配对认证**：首次 TOFU + 配对码（Host 本地显示/日志），之后证书绑定；未配对连接一律拒绝。
- **加密**：控制通道 TLS 1.3；帧通道由 QUIC 的 TLS 1.3 提供（D-01 已定），不再自研 AES-GCM/DTLS。
- **注入边界**：InputInjector 只接受已认证会话的事件；事件速率限制；Host 本地可一键断开所有会话。
- **最小权限**：TCC 仅屏幕录制+辅助功能；不请求多余权限；配对凭据存 Keychain。
- **审计日志**：会话建立/断开、配对、熔断事件落本地日志，诊断包不含凭据。

---

## 7. 测试与验收

| 层 | 内容 | 通过准则 |
|---|---|---|
| 单元 | 坐标变换（负坐标/混合缩放）、协议编解码、identity 游走、状态机 | 覆盖率核心模块 ≥ 80% |
| 集成（单机环回） | P0 verify 全链路：建屏→捕获→编码→解码 | pass=true，0 黑帧，0 编码错误（已达成于 Sequoia） |
| 真机矩阵 | Host/Client 各覆盖 13/14/15/26（Intel）；重点组合 Tahoe Host × Sequoia Client 全量测试，其余版本组合至少 probe+verify 回归（P0-R）；1/2/N 屏；1x/2x；故障注入（stale、poisoned、SPI 挂起、断网） | FR-01/02/08 验收要点全过 |
| 性能 | P2 spike：NFR-01/02/03/05 | 达标或触发降级预案并记录 |
|  soak | 72h 双屏连续运行 | 无内存泄漏、无 WindowServer 异常、CPU 达标 |
| 回归触发 | **每次系统安全更新后**两端各跑 probe+verify（<10min） | spi-signature-check missing=[]，verify pass |

验收总准则：FR P0 项全过 + NFR-01/02/06/07 达标 + A-01/A-02 关闭。

---

## 8. 里程碑与出口准则

| 阶段 | 内容 | 出口准则 | 状态 |
|---|---|---|---|
| P0 | 被控端链路探针（Sequoia 基线） | verify pass（双屏+编码环回） | **已完成 2026-11-16** |
| P0-T | Tahoe 真机 P0（README §11 交接清单） | 真机 verdict.pass=true，诊断包回传 | ✅ **建屏/捕获/编码/HiDPI/多屏容量 全部通过 2026-11-17**（`encode_rc=0 hidpi_rc=0`；2 物理+4 虚拟=6 屏在线，README §14–§16）。注：§16.2「捕获优先」结论已作废（镜像语义，见 D-04） |
| **P0-V** | **独占会话能力验证**：物理屏 disable 后可与虚拟屏共存且不被唤醒事件重新 enable（V-01）、全部物理屏 disable 的极限情形（V-03）、锁屏态下建屏与采集（V-02） | A-08 关闭：`SLSConfigureDisplayEnabled` 在事务内提交成功且虚拟屏仍 `HAS_CONTENT` | 侦察已完成（`P0V-SessionRecon/`）；root daemon 探针已就绪（`P0V-RootDaemon/`，TCC 待人工授权）；**V-01 已通过（Sequoia 15.5：禁用一块屏，虚拟屏 `HAS_CONTENT`、SCK 干净、指针逐屏 0 偏差且不入禁用屏、输入注入通过、20s 唤醒观察 0 次重新 enable、恢复精确）。V-03 核心已完整通过（3 块全禁、60fps `HAS_CONTENT`、SCK 干净、指针 0 偏差、输入注入通过、20s 唤醒观察 0 次重新 enable、恢复精确）；但重建测试（零物理屏下创建第 2 块虚拟屏）触发 WindowServer `canonical_mirror_master` 断言崩溃，根因是 WindowServer 的 5 个停放槽位（`0xFFFFFFFF/offline/1x1`）。已实测该槽位**无法从用户态清除**（`CDVirtualDisplayDestroy` 只收进程内 client、`SL2CDVirtualDisplayDestroy` 只查本进程表、同身份重建不复用旧槽位、休眠/唤醒只回收在线孤儿），注销/重启是唯一路径。探针改为检测槽位后**自动跳过该子项**、V-03 核心照常执行，不再要求重启；`--count > 1` 需 `--allow-stale-slots`。**M1 据此加硬约束：全部虚拟屏必须在禁用物理屏之前建齐，会话期间不得新建虚拟屏。** V-02 未开始；V-04a/b 已在用户会话路径通过（锁屏真实可捕获、注入被 loginwindow 接受），root daemon 路径因 TCC 路径条目 + 无 GUI 会话失败，V-04c 按决定记为未测（主动跳过，留待正式签名后验证）、V-04d 未实现，Path A 形态改为“正确签名的用户态 App + 用户授权”；M1 会话层开工前必须关闭 V-02 与 V-04c/d**。2026-11-18 在 Tahoe 26.5.2 重建 `v01probe` 并完成只读 `probe` + `--dry-run`：SCK 可见 2 物理屏、私有符号可解析、虚拟屏建屏与 `HAS_CONTENT` 通过（6 个停放槽位仍在，单块建屏不受影响）；**AX 授权后 2026-11-18 实测：V-01 全项 PASS；V-03 显示隔离机制全通过但 SCK 在零 active 物理屏下送帧不稳定（4 次中 1 次全黑、2 次多数帧黑、白色窗口对照仍全黑，系统截图证明桌面正常合成）。A-08 在 Tahoe 未关闭，需先验证替代采集路径或按 D-05 降级** |
| P0-R | Ventura/Sonoma 真机回归（probe+verify，可借测机器，与 P1 并行） | 13/14 各出基线报告（A-07 关闭） | M3 前完成 |
| P1 | 控制端探针 `P1-ClientProbe/`：硬解+Metal 渲染、N 窗口坐标、IME 注入 | §7 四项各出实证报告 | 协议层（输入编解码/状态机/1150B 分片）2026-11-18 完成，140 断言全过；**硬解+Metal 渲染、A-03 IME 双机实证未做** |
| P2 | 双机联调 spike：glass-to-glass 延迟 | NFR-01/02 达标或降级结论（A-02 关闭） | 依赖 P0-T、P1 |
| **M1** | 产品骨架：MIT 基座集成 + 本文档模块划分落地 + 控制协议 v1 | 单屏会话端到端跑通（发现/配对/推流/输入） | **已评审通过、可开工（2026-11-18 11:20）**。A-01/A-04/A-08/A-09 已关闭，D-01/D-02/D-09 已定；A-02 不在 M1 关键路径上。先做 M1-Pre 采编链路验证，再落骨架 |
| M2 | 多屏 + 完整输入（IME/修饰键/沉浸模式）+ 动态协商 | FR-05/06/07 验收 | |
| M3 | 断线重连 + 无人值守 + 安全加固 + soak | FR-08/09、NFR-06/07、72h soak | |
| M4（后续） | 光标独立通道、音频、剪贴板 | 单独设计评审 | |

**方案定稿条件（已满足，11:40 按 D-10 更新）**：D-01 传输选型（QUIC datagram）、D-02 工程形态（Swift + ObjC 桥）、采集主路径（D-09 → **D-10 修订为 SCK 主 + CG 兜底**）均已决策，本文档评审通过；A-01/A-04/A-08/A-09 已关闭。**A-02 从定稿前置移出**，改为 P2 双机联调验收项——M1 骨架与单屏端到端不依赖延迟数据，可立即开工；帧率目标已按 D-10 下调至 15–30fps，与实测能力对齐。

---

## 9. 部署与运维

- Host 安装：自动登录 + 关 FileVault + LaunchAgent + TCC 授权引导（首启接物理屏完成授权再拔头）。
- 版本锁定：适配范围 Ventura 13 – Tahoe 26（仅 Intel）；每台部署机器记录确切 build；安全更新不关闭，但更新后强制回归（NFR-08）。**Ventura/Sonoma 已无安全补丁（C-06），部署时明确告知用户风险。**
- 降级预案：私有 SPI 被某次更新破坏且无解 → EDID 假插头（牺牲动态分辨率，C-05）。
- 诊断：一键诊断包（沿用 run_p0.sh 模式），含环境指纹、SPI 签名比对、最近会话日志；不含凭据。

---

## 10. 决策索引与未决问题

决策编号以 `docs/DECISIONS.md` 为准：D-01 帧通道（QUIC datagram）、D-02 工程形态（Swift + ObjC 桥）、D-03 已作废、D-04 独占式会话、D-05 显示空间隔离、D-06 锁屏语义、D-07 Path B 兜底、D-08 远程登录 Path A、D-09 采集主路径（部分被 D-10 修订）、D-10 帧管线（SCK 主路径 + 15–30fps）。下表只列**尚未决策**的问题，用 Q-xx 编号以免与 D-xx 冲突。

| 编号 | 问题 | 候选与建议 | 决策期限 |
|---|---|---|---|
| Q-01 | 互联网远程 | 本期仅 LAN；后续 Tailscale/WireGuard 组网 vs 自建中继 | M3 评审 |
| Q-02 | 光标通道相位 | P2（FR-10），若 NFR-02 实测光标拖影明显则提前 | P2 后 |
| Q-03 | 音频/剪贴板 | M4 单独设计 | M3 后 |
| Q-04 | 采编参数锁定 | D-10 已定：SCK 主路径 + 15–30fps；码率/关键帧间隔按 SCK + 20fps 默认，P2 双机实测后微调 | D-10 已定，参数留 P2 微调 |

---

## 11. 变更记录

| 版本 | 日期 | 变更 | 作者 |
|---|---|---|---|
| v0.1-draft | 2026-11-16 | 首次起草：承接 P0 Sequoia 基线通过结论，A-01/A-02 标记为定稿前置 | Qoder 协助起草 |
| v0.2-draft | 2026-11-16 | 需求变更：双端 OS 适配范围放宽为 Ventura 13 – Tahoe 26（仅 Intel）；新增 §3.5 适配矩阵、A-07、P0-R 回归里程碑、C-06 老版本安全补丁风险提示 | Qoder 协助起草 |
| v0.3-draft | 2026-11-17 | 环境事实校正：被控机实测 build 由 26.7.3 更正为 **26.5.2 / 25F84**（影响 §1.3、C-01、A-01、§8 P0-T 状态）；A-01 由「待明天执行」更新为「前置已就绪、待跑 verify」 | WorkBuddy 协助核对 |
| v0.4-draft | 2026-11-17 | A-01 关闭：Tahoe 26.5.2 单屏 `verify` 通过（`pass=1`、offset=0、未触发 walk）；P0-T 标为单屏通过，双屏+编码待补；新增建屏耗时 11.3s 的性能风险与 M1 优化项（见 README §14） | WorkBuddy 协助核对 |
| v0.5-draft | 2026-11-17 | 编码面与 HiDPI 面通过（`encode_rc=0 hidpi_rc=0`）；新增两条硬约束：**HiDPI 必须在 `initWithDescriptor:` 一次给足（事后 `applySettings` 静默无效）**、**不得对同屏重复提交相同模式（会清屏为纯黑）**；P0-T 仅剩双虚拟屏未测；协议 D-01/D-02 已定 | WorkBuddy 协助核对 |
| v0.6-draft | 2026-11-17 | **架构修正**：实测 2 物理+4 虚拟=6 屏在线，虚拟屏不占 Intel DDI 通道 → 推翻「UHD 630 三屏上限会卡住虚拟屏」的错误推论，A-04 关闭；新增 **D-03 捕获优先**（有物理屏则 0 建屏直接采，首帧 124ms）并据此改写 FR-01；明确与 RDP 的本质差距是「会话隔离」而非「屏数」 | WorkBuddy 协助核对 |
| v0.7-draft | 2026-11-17 | **产品形态澄清（用户纠正）**：目标是独占式会话，不是 VNC 镜像 —— 新增 FR-00 独占、改写 FR-01 为「只建虚拟屏、绝不捕获物理屏」、新增 C-07 禁止镜像 / C-08 单会话模型、A-08 物理屏置黑假设、P0-V 里程碑；作废 D-03 捕获优先 | WorkBuddy 协助核对 |
| v0.8-draft | 2026-11-18 | Tahoe 环境巡检：`v01probe` 重建 + `probe`/`--dry-run` 通过（AX 未授权，禁屏实测待做）；P1 协议层补齐输入事件编解码、会话状态机、1150B 分片上限，单测 140 断言全过 | WorkBuddy 协助核对 |
| v0.9-draft | 2026-11-18 | Tahoe V-01 全项 PASS；V-03 显示隔离机制通过但 SCK 在零 active 物理屏下送不稳定（系统截图有内容、SCK 帧多黑/全黑，白色窗口对照仍全黑），A-08 在 Tahoe 未关闭，新增替代采集路径验证或 D-05 降级的前置工作 | WorkBuddy 协助核对 |
| v1.0-draft | 2026-11-18 | 建立 `docs/RESULTS-BY-OS.md` 按 OS 分离结论；Tahoe V-02 不成立（锁屏态虚拟屏 `active=false`）、V-04a 通过、V-04b 未确认、V-04c 未测、V-04d 不成立；`CGDisplayCreateImage`/`CGWindowListCreateImage` 在零 active 物理屏下稳定可用，SCK 不稳定。Path A 在 Tahoe 不成立，M1 采集层改以公开抓屏 API 为候选 | WorkBuddy 协助核对 |
| v1.1-draft | 2026-11-18 10:52 | **Path A 在 Tahoe 端到端成立，A-08/A-09 关闭**：两轮（聚焦/不聚焦）禁全部物理屏后登录 UI 完整迁移到虚拟屏 → 触发条件是零物理屏；V-04b/c 用授权凭据干净重测通过（解锁成功，凭据仅运行时环境变量注入、无明文落盘）。FR-13 达到 P0；M1 前置：常驻防显示睡眠断言，采集优先公开 API（D-05），真 loginwindow 态待 M1 补测 | WorkBuddy 协助核对 |
| v1.1 | 2026-11-18 11:20 | **评审通过、冻结为 M1 基线**：D-01/D-02 由提议转确认，新增 D-09 采集主路径（`CGDisplayCreateImage`）；FR-03/架构图/模块表/§5.3 同步；A-02 从定稿前置移出、改 P2 验收；M1 可开工，先做 M1-Pre 采编链路验证 | 用户确认 + WorkBuddy 落文档 |
| v1.2 | 2026-11-18 11:40 | **D-10 修订**：M1-Pre 实测两路径带编码仅 4–18fps，D-09 主路径改回 SCK、`CGDisplayCreateImage` 降兜底；NFR-03 帧率 60fps → 15–30fps（默认 20fps）；A-02 首帧延迟风险记入；FR-03/架构图/§4.1/§5.3/方案定稿条件同步 | 用户确认 + WorkBuddy 落文档 |
| v1.3 | 2026-11-18 15:35 | **D-11 补注**：A-09 遗留的 `loginDone=0` 真登录窗场景延后到 M2 借测机，主力机不承担需登出中断会话的测试；新增只读前置探针 `P0V-SessionRecon/gui_session_probe.m`（GUI 会话判定 + 抓屏 luma）与改造后的 `run_loginwindow_probe.sh`（preflight + 自动 bsexec 重入）。仅补注，M1 基线内容不变 | 用户选 B + WorkBuddy 落文档 |