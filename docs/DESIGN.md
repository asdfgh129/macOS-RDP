# macOS-RDP 软件设计方案

| 项 | 值 |
|---|---|
| 文档版本 | v0.2-draft |
| 日期 | 2026-11-16 |
| 状态 | **草稿，待评审**；含「待验证假设」（§2.5），定稿前须关闭 A-01 / A-02 |
| 关联工程 | `P0-TahoeProbe/`（可行性探针，Sequoia 基线已通过，见其 README §12.6） |
| 评审记录 | 无（首次起草） |

---

## 1. 引言

### 1.1 目的

为「Intel Mac + macOS 13–26（Ventura–Tahoe）无头被控端 + 非 VNC 远程桌面」产品给出可评审、可追溯、可分阶段实施的软件设计方案。本文档承接 P0 探针的实证结论，把已验证事实与待验证假设严格分开，作为后续骨架开发（M1）的唯一设计依据。

### 1.2 范围

**本期（M1–M3）覆盖**：虚拟屏管理、SCK 捕获、H.264 硬编、局域网传输、控制端解码渲染、键鼠注入、多屏会话、断线恢复、无人值守运行。

**本期不做**（列入后续相位，见 §10）：音频、剪贴板、文件传输、互联网穿透（NAT/中继）、Apple Silicon 适配、macOS 27+ 适配。

### 1.3 术语

| 术语 | 含义 |
|---|---|
| Host / 被控端 | Intel Mac，macOS **13 Ventura – 26 Tahoe**（P0 目标验证机：26.7.3），无物理显示器（无头），建虚拟屏并采集编码 |
| Client / 控制端 | Intel Mac，macOS **13 Ventura – 26 Tahoe**（P0 基线验证机：15.5 Sequoia），解码渲染并采集键鼠 |
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

- **主场景**：用户把无头 Intel Mac（Ventura–Tahoe）放在机房/角落，用另一台 Intel Mac（同范围，接 N 块物理屏）在局域网内把它当作「本机扩展桌面」使用：键鼠直接操作远端桌面，多屏一一对应，延迟接近本地。
- **运维场景**：Host 断电重启后无人值守自动恢复服务；系统安全更新后自动/手动回归验证私有 SPI 未漂移。

### 2.2 功能需求

| 编号 | 需求 | 优先级 | 验收要点 |
|---|---|---|---|
| FR-01 | Host 创建/销毁 1–N 块虚拟屏（默认 2，上限待 A-04 实测） | P0 | 每屏 online+active+SCK 可见，mode 落到目标分辨率 |
| FR-02 | 虚拟屏故障自恢复：stale 检测、identity walk、原子解除自动镜像、SPI 熔断 | P0 | 注入故障后 30s 内恢复或明确报错，绝不拖挂 WindowServer |
| FR-03 | SCK 逐屏捕获 + VideoToolbox H.264 硬编（IOSurface 零拷贝） | P0 | 1080p60 非黑帧，编码产出连续 |
| FR-04 | 局域网会话：发现、配对认证、加密传输 | P0 | 未配对设备无法连接；链路加密 |
| FR-05 | Client 解码（VT 硬解）+ Metal 渲染，N 个无边框全屏窗口落到 N 块物理屏 | P0 | 坐标变换正确（负坐标/混合缩放），首帧 < 1s |
| FR-06 | 键鼠采集与注入：`CGEventPost` + display ID 路由、中文输入法、修饰键同步 | P0 | 中文输入可用；Cmd-Tab 等系统快捷键可按策略拦截/放行 |
| FR-07 | 分辨率/屏数由控制端动态协商，Host 原地重建或 applySettings | P1 | 协商失败事务性回退，不掉会话 |
| FR-08 | 断线检测与自动重连，重连后桌面状态保持 | P1 | 拔网线 10s 恢复后会话继续 |
| FR-09 | 无人值守：自动登录 + LaunchAgent 开机自启 + 崩溃自重启 | P1 | 断电重启后 2min 内可连 |
| FR-10 | 光标独立通道（低延迟本地光标渲染） | P2 | 光标移动不依赖帧回环 |
| FR-11 | 音频转发、剪贴板同步 | P2 | 后续相位单独设计 |

### 2.3 非功能需求（量化）

| 编号 | 指标 | 目标 | 验证方式 |
|---|---|---|---|
| NFR-01 | 采集+编码延迟 | < 30ms（1080p60） | P2 双机 spike，时间戳打点 |
| NFR-02 | glass-to-glass 总延迟 | < 50ms（局域网有线） | 双机高速摄像/输入时间戳回环 |
| NFR-03 | 帧率 | 稳定 60fps（动态画面） | 动态测试图案，统计掉帧 |
| NFR-04 | 分辨率 | 单屏最高 4096×2304@55（H.264 High@L5.2 吞吐安全点，PR #288）；默认 1920×1080 / 2560×1440@60 | verify + 编码吞吐统计 |
| NFR-05 | Host CPU 占用 | 双屏 1080p60 编码 < 15%（QuickSync 硬编，i5-9500 级） | 长时间运行采样 |
| NFR-06 | 可用性 | 7×24 运行，WindowServer 零拖挂；任何 SPI 挂起 8s 内熔断 | 故障注入 + 72h  soak |
| NFR-07 | 安全 | 配对认证 + 全链路加密；输入注入仅限已配对会话 | 渗透自查清单 |
| NFR-08 | 可维护性 | 私有 SPI 全部 protocol 重声明 + 运行时签名校验；每次系统安全更新后回归 < 10min | probe/verify 一键回归 |

### 2.4 约束

| 编号 | 约束 | 来源 |
|---|---|---|
| C-01 | **双端适配 macOS 13 Ventura – 26 Tahoe，仅 Intel x86_64**；每台部署机器锁定具体 build（如 26.7.3/25Gxxx）；不追 macOS 27+（仅 Apple Silicon，Intel 不可装） | 用户需求 2026-11-16；README §0/§8 |
| C-02 | 产品基座只用 MIT 组件（SideScreen MacHost / VirtualDisplayKit）；OpenDisplay GPL-3.0 仅参考行为结论，**禁止复制源码或 fork 主线** | README §10 |
| C-03 | 必须在已登录 Aqua GUI 会话运行（LaunchAgent，非 Daemon）；TCC 屏幕录制/辅助功能授权归属父 App | README §3 |
| C-04 | 私有 SPI 无兼容性承诺；所有 SPI 调用必须带死线 + 熔断（P0 事故教训） | README §12 |
| C-05 | 官方高性能屏幕共享要求双端 Apple Silicon，Intel 无系统级退路；唯一硬件退路是 EDID 假插头（牺牲动态分辨率） | README §0/§8 |
| C-06 | Ventura 13 / Sonoma 14 已超出 Apple 常规安全更新窗口（以 Apple 公告为准）：可以适配，但部署文档必须提示「老版本不再收到安全补丁」的风险，由用户自担 | Apple 支持周期 |

### 2.5 待验证假设（定稿前必须关闭 A-01/A-02）

| 编号 | 假设 | 验证方式 | 不成立时的回退 |
|---|---|---|---|
| **A-01** | Tahoe 26.7.3 Intel 上私有 SPI 可用，identity walk + 保守 canvas→promote 能恢复 stale/poisoned | 明天真机 `run_p0.sh`，回传诊断包（README §11） | 逐 selector 重逆向；极端情况 EDID 假插头（C-05） |
| **A-02** | 双机 1080p60 采集+编码 < 30ms、总链路 < 50ms | P2 双机 spike | 降分辨率/帧率；编码参数调优；传输换 QUIC |
| A-03 | `CGEventKeyboardSetUnicodeString` 中文注入与修饰键同步在 Tahoe 可用 | P1 控制端探针 + 双机联调 | 改 IOHIDPostEvent / 输入法状态机同步 |
| A-04 | Intel+Tahoe 扩展虚拟屏上限 ≥ 2（社区经验约 4） | 真机 3/4 屏压测 | 产品规格按实测上限写死 |
| A-05 | HiDPI（2x points/pixels）与混合缩放渲染正确 | P1 渲染探针 | 本期只支持 1x，HiDPI 降级为 P2 |
| A-06 | 安全更新不破坏私有 SPI | 每次更新后 probe+verify 回归（NFR-08） | 版本锁定回滚 + 社区补丁跟进 |
| A-07 | Ventura 13 / Sonoma 14 上私有 SPI 与 Sequoia 行为一致（selector 已在 15/26/27 复核一致，13/14 未实测） | 各版本真机 probe+verify（P0-R，M3 前关闭） | OS 策略按版本加分支；个别版本不支持则从适配范围剔除并记录 |

---

## 3. 总体架构

### 3.1 架构视图

```
┌─────────────── Host（Intel / macOS 13–26，无头）────────────────────────┐
│  SessionServer ── 控制通道(TLS/TCP)：发现/配对/协商/心跳/输入事件            │
│      │                                                                    │
│  VirtualDisplayManager ── 建屏/恢复/熔断（P0 VDManager 演进）               │
│      │ CGVirtualDisplay SPI                                               │
│  CapturePipeline ── SCK 逐屏捕获 → IOSurface                              │
│      │                                                                    │
│  VideoEncoder ── VTCompressionSession H.264 硬编 → Annex-B/AVCC           │
│      │                                                                    │
│  FrameTransport ── 帧通道(UDP/QUIC，待定 D-01)：分片/序号/关键帧请求         │
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
| 帧通道 | 编码帧分片 | UDP/QUIC（D-01 待定） | 帧可丢旧不可等旧，避免 TCP 队头阻塞毁掉延迟 |
| 光标通道（P2） | 光标位置/形状 | 并入控制通道或独立 UDP | 本地渲染光标，绕开帧回环延迟 |

### 3.3 部署视图

- Host：自动登录 + 关 FileVault + LaunchAgent（GUI 会话内）；TCC 授权给产品 App；看门狗脚本崩溃自重启。
- Client：普通 App，N 块物理屏各一个全屏窗口；辅助功能授权用于全局键鼠捕获。
- 两端均锁定具体 OS build；每次安全更新后跑回归（§7）。

### 3.4 技术选型与许可证

| 层 | 选型 | 许可证 | 说明 |
|---|---|---|---|
| 产品基座 | SideScreen MacHost + VirtualDisplayKit | MIT | 可 fork/闭源商用；保留版权声明 |
| 虚拟屏 SPI 声明 | 自研 protocol 重声明（P0 已验证） | 自有 | 参考 DeskPad（MIT）selector 名 |
| 捕获/编码/解码 | ScreenCaptureKit + VideoToolbox（系统框架） | 系统 | P0 已实证 Intel QuickSync 硬编可用 |
| 渲染 | Metal + IOSurface | 系统 | 零拷贝 |
| 传输 | 待定 D-01（候选：自研 UDP vs QUIC 库） | 需 MIT/BSD/Apache | GPL 组件一律排除 |
| 语言 | Swift 为主 + ObjC 桥（P0 的 VDManager/PipelineProbe 可近乎原样搬入） | — | 私有 SPI 留 ObjC，产品逻辑 Swift |
| 行为策略参考 | OpenDisplay PR #219/#288、issue #171 | **GPL-3.0，仅参考结论** | 合规红线见 C-02 |

### 3.5 OS 版本适配矩阵（双端通用，仅 Intel）

运行时按 `NSProcessInfo.operatingSystemVersion.majorVersion` 分流（P0 `P0OSPolicy` 已实现骨架，产品沿用并扩展）：

| 大版本 | 建屏策略 | identity | 失败重试 | 实证状态 |
|---|---|---|---|---|
| 26 Tahoe | 保守 canvas 1280×800 → SCK 可见 → promote | walk + 持久化成功 offset | 最多 4 组 | 社区已实锤坑位；真机待 A-01 |
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
| CapturePipeline | 逐屏 SCStream，IOSurface 输出，退化 mode 拒捕，start/stop 死线 | `start(displayID, config) -> FrameStream` | P0 `PipelineProbe` 演进 |
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

JSON 信令 + 二进制帧头。信令消息：`hello/capabilities`、`pair-request/pair-confirm`、`session-start{specs[]}`、`session-update{specs[]}`、`input{type,payload,displayID}`、`keyframe-request{displayID}`、`heartbeat`、`bye{reason}`。帧头：`magic | version | displayID | frameSeq | flags(keyframe) | pts | fragIdx/fragCount | payloadLen`。协议版本号从 1 起，双端协商取小。

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

SCK（IOSurface）→ VT 硬编（实时、无 B 帧、关键帧间隔 2s + 按需）→ 分片发送 → 重组 → VT 硬解 → Metal 呈现。全程零拷贝；编码吞吐看门狗发现「会话成功但无 buffer」（PR #288 陷阱）时自动降分辨率重建编码器。

### 5.4 输入路由

Client 窗口坐标 → 归一化到对应虚拟屏坐标 → 控制通道 → Host 按 displayID 用 `CGEventPost` 注入到目标屏；Quartz 左上原点与 NSScreen 左下原点的变换集中在 Renderer/InputCapture 一处实现并单测（含负坐标副屏）。中文输入走 `CGEventKeyboardSetUnicodeString`（A-03）；修饰键状态双端状态机同步，断线重连后全量复位。

### 5.5 断线与降级

心跳 1s/超时 5s 判断断线；Client 自动重连（指数退避上限 10s），Host 保持虚拟屏与桌面状态；重连后请求关键帧恢复画面。网络持续不可用 > 60s：Host 保持会话待命，不销毁桌面。编码/性能不足时按 NFR-04 安全点逐级降级（分辨率→帧率）。

---

## 6. 安全设计

- **配对认证**：首次 TOFU + 配对码（Host 本地显示/日志），之后证书绑定；未配对连接一律拒绝。
- **加密**：控制通道 TLS 1.3；帧通道加密随 D-01 选型（QUIC 自带 TLS；自研 UDP 需 Noise/DTLS 或 AES-GCM 会话密钥）。
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
| P0-T | Tahoe 真机 P0（README §11 交接清单） | 真机 verdict.pass=true，诊断包回传 | 待明天执行（A-01） |
| P0-R | Ventura/Sonoma 真机回归（probe+verify，可借测机器，与 P1 并行） | 13/14 各出基线报告（A-07 关闭） | M3 前完成 |
| P1 | 控制端探针 `P1-ClientProbe/`：硬解+Metal 渲染、N 窗口坐标、IME 注入 | §7 四项各出实证报告 | 待启动 |
| P2 | 双机联调 spike：glass-to-glass 延迟 | NFR-01/02 达标或降级结论（A-02 关闭） | 依赖 P0-T、P1 |
| **M1** | 产品骨架：MIT 基座集成 + 本文档模块划分落地 + 控制协议 v1 | 单屏会话端到端跑通（发现/配对/推流/输入） | **A-01/A-02 关闭后启动** |
| M2 | 多屏 + 完整输入（IME/修饰键/沉浸模式）+ 动态协商 | FR-05/06/07 验收 | |
| M3 | 断线重连 + 无人值守 + 安全加固 + soak | FR-08/09、NFR-06/07、72h soak | |
| M4（后续） | 光标独立通道、音频、剪贴板 | 单独设计评审 | |

**方案定稿条件**：A-01、A-02 关闭 + D-01 传输选型决策 + 本文档评审通过。在此之前 M1 只做不依赖待验证假设的准备工作（基座源码审计、协议骨架、坐标变换单测）。

---

## 9. 部署与运维

- Host 安装：自动登录 + 关 FileVault + LaunchAgent + TCC 授权引导（首启接物理屏完成授权再拔头）。
- 版本锁定：适配范围 Ventura 13 – Tahoe 26（仅 Intel）；每台部署机器记录确切 build；安全更新不关闭，但更新后强制回归（NFR-08）。**Ventura/Sonoma 已无安全补丁（C-06），部署时明确告知用户风险。**
- 降级预案：私有 SPI 被某次更新破坏且无解 → EDID 假插头（牺牲动态分辨率，C-05）。
- 诊断：一键诊断包（沿用 run_p0.sh 模式），含环境指纹、SPI 签名比对、最近会话日志；不含凭据。

---

## 10. 待决问题（评审时决策）

| 编号 | 问题 | 候选与建议 | 决策期限 |
|---|---|---|---|
| D-01 | 帧通道传输 | ① 自研 UDP（序号+分片+NACK 关键帧请求，可控但工作量大）② QUIC 库（MIT/BSD 候选，自带加密与拥塞控制，**建议**）③ TCP 起步（最简单，队头阻塞风险，仅作 M1 临时） | M1 启动前 |
| D-02 | 产品形态 | Swift App + ObjC 桥（建议，P0 代码可搬入）vs 纯 ObjC | M1 启动前 |
| D-03 | 互联网远程 | 本期仅 LAN；后续 Tailscale/WireGuard 组网 vs 自建中继 | M3 评审 |
| D-04 | 光标通道相位 | P2（FR-10），若 NFR-02 实测光标拖影明显则提前 | P2 后 |
| D-05 | 音频/剪贴板 | M4 单独设计 | M3 后 |

---

## 11. 变更记录

| 版本 | 日期 | 变更 | 作者 |
|---|---|---|---|
| v0.1-draft | 2026-11-16 | 首次起草：承接 P0 Sequoia 基线通过结论，A-01/A-02 标记为定稿前置 | Qoder 协助起草 |
| v0.2-draft | 2026-11-16 | 需求变更：双端 OS 适配范围放宽为 Ventura 13 – Tahoe 26（仅 Intel）；新增 §3.5 适配矩阵、A-07、P0-R 回归里程碑、C-06 老版本安全补丁风险提示 | Qoder 协助起草 |