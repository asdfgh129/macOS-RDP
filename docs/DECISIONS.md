# 决策记录（Decision Log）

| 项 | 值 |
|---|---|
| 版本 | v0.1 |
| 日期 | 2026-11-17 |
| 上位文档 | `docs/DESIGN.md`（§4.3 传输、§5 模块）、`docs/PROTOCOL.md` |
| 实测结论 | 按 OS 分离记录于 `docs/RESULTS-BY-OS.md`；决策中的实测证据均须标注 OS/build |
| 状态 | **已评审通过（2026-11-18 11:20），作为 M1 基线**。D-01/D-02/D-09 已确认，PROTOCOL v1 已冻结；D-03 作废保留追溯 |

---

## D-01 帧通道传输：QUIC（Network.framework）+ 不可靠数据报

**状态**：✅ **已确认（2026-11-18 11:20 评审通过），PROTOCOL v1 已按此冻结**。

### 决定

- 控制通道：TLS 1.3 over TCP，端口 47990（不变）。
- 帧通道：**QUIC over UDP，端口 47991**，使用 **unreliable datagram（RFC 9221）** 承载分片，而非 QUIC stream。
- 实现基座：Apple `Network.framework` 原生 QUIC，不引入第三方 C 库。

### 证据（本机实测，2026-11-17）

在 macOS 26.5 SDK / `-mmacosx-version-min=13.0` 下编译并运行通过：

```
nw_parameters_create_quic(^(nw_protocol_options_t quic) {
    nw_quic_set_stream_is_datagram(quic, true);   // 不可靠数据报
    nw_quic_set_max_udp_payload_size(quic, 1200);
    nw_quic_set_idle_timeout(quic, 30000);
    nw_quic_add_tls_application_protocol(quic, "macos-rdp-v1");
});
→ quic_parameters=1  quic_stack=1  udp_parameters=1
```

`quic_options.h` 中相关接口标注 `API_AVAILABLE(macos(12.0))`，与 C-01 的 macOS 13+ 下限兼容。

### 理由

1. **语义匹配**：视频帧“可丢不可等”。QUIC stream 是可靠有序的，会重传造成延迟堆积；datagram 才是对的抽象。自研 UDP 等价，但要自己实现拥塞控制、ACK/丢包检测、路径 MTU。
2. **加密免费**：QUIC 强制 TLS 1.3，天然满足 PROTOCOL §6 的“帧通道加密”要求，省掉 Noise/DTLS 选型与密钥轮换实现。
3. **零第三方依赖**：`Network.framework` 是系统框架，不增加包体、不受 GPL 污染，也不需要维护 msquic/quiche 这类 C 库的构建。
4. **迁移成本低**：控制通道若后续也想上 QUIC，同一套 API。

### 备选与否决理由

| 方案 | 结论 | 原因 |
|---|---|---|
| 自研 UDP + AES-GCM | 备选 | 可行但工作量大：拥塞控制、重排缓冲、路径 MTU 全要自己写，M1 阶段不值得 |
| 引入 msquic / quiche | 否决 | 第三方 C 库，构建与许可成本高，系统已自带 QUIC |
| TCP 起步 | 仅作最坏情况退路 | 队头阻塞会毁掉实时性（DESIGN §4.3 已明确排除） |

### 影响与待办

- PROTOCOL §1 端口表：帧通道注明 `UDP 47991`；§6 改为“帧通道加密由 QUIC 的 TLS 1.3 提供”。
- PROTOCOL §4 分片上限 1200 需按 QUIC 头部开销复核：QUIC short header + AEAD tag 约 20–30 B，建议实际按 **1150 B** 下发分片，`P1FrameMaxPayload` 随之调整（当前实现常量 1200，改动一处）。
- **未验证**：macOS↔macOS 的 datagram 端到端互通（本轮只验证了 API 可用与参数可构造）。P2 双机联调第一件事就是跑通这个，若不通则回退“QUIC stream + 应用层丢帧”或自研 UDP。

---

## D-02 产品形态：Swift 主工程 + ObjC 桥

**状态**：✅ **已确认（2026-11-18 11:20 评审通过），PROTOCOL v1 已按此冻结**。

### 决定

- UI / 会话编排 / Metal 渲染 / 网络：**Swift**。
- 私有 SPI（`CGVirtualDisplay`）、SCK 回调、`VTCompressionSession` 属性字典、`CGEventPost` 注入：**ObjC/ObjC++**，以 framework target 暴露给 Swift。
- 同一 Xcode workspace，两个 target：`RDPKit`（ObjC，无 UI）+ `RDPApp`（Swift，UI 与生命周期）。
- P1-ClientProbe 现有的纯函数单测保持 **CLI + ObjC** 形式不变（不依赖 Xcode 工程即可跑）。

### 理由

1. **Swift 的优势区**：AppKit/SwiftUI 布局、async/await 管会话状态机、Metal 命令缓冲，Swift 代码量显著更少且更安全。
2. **ObjC 的优势区**：`CGVirtualDisplayDescriptor` 这类未公开结构体、`CGSConnectionID`、C 函数指针回调（SCK `SCStreamOutput`、VT 回调）在 ObjC 里写起来直接；这些 API 没有 Swift 友好封装，硬用 Swift 会充斥 `Unmanaged`/`withUnsafePointer`。
3. **已有资产直接搬**：P0-TahoeProbe 的 `VDManager.m` / `PipelineProbe.m` 是 ObjC，可直接进 `RDPKit`，不需要重写。

### 备选与否决理由

| 方案 | 结论 | 原因 |
|---|---|---|
| 纯 ObjC | 备选 | 完全可行，但 UI 与并发编排代码量会明显变大 |
| 纯 Swift | 否决 | 私有 SPI + C 回调的桥接噪音大，且要重写 P0 已验证的建屏代码 |
| SwiftUI 全包 | 否决 | 多屏无边框窗口落位需要 AppKit `NSWindow` 精细控制 |

### 影响

- M1 的第一步不是写业务代码，而是建 workspace + `RDPKit` target，把 P0 的 `VDManager`/`PipelineProbe` 平移进去并保持可测。
- 单测策略：`RDPKit` 内纯逻辑（协议编解码、坐标变换）继续用 CLI 单测覆盖，避免为跑测试启动 GUI。

---

## D-03 ~~display 供给策略：捕获优先 + 虚拟屏按需补齐~~

**日期**：2026-11-17　**状态**：❌ **已作废（2026-11-17，同日）** —— 由 D-04 取代

> **作废理由**：本决策把「捕获被控端物理屏」当作默认路径，属于 VNC/镜像语义，与产品定位直接冲突。
> 用户明确否决：「我所要的就是会话模式，控制端登录了，被控端就锁屏。完全不需要去捕获物理屏。」
> 保留原文仅为追溯。其中「虚拟屏不占 Intel DDI 通道、与物理屏数量解耦」的实测结论**仍然有效**。

### 决定

Host 不为每个会话预先创建虚拟屏。会话开始时的供给顺序是：

1. 枚举被控机**现有可用 display**（`SCShareableContent`）；
2. 能覆盖控制端需求的，**直接捕获，零建屏**；
3. 不足的部分，按差额创建虚拟屏补齐；
4. 会话结束**只销毁自己创建的**那些，不动物理屏。

### 证据（本机实测）

| 路径 | 建屏开销 | 首帧延迟 | 结论 |
|---|---|---|---|
| 直接捕获 2 块物理屏 | **0** | 124 / 252 ms | `pass=true`，3440×1440 与 1080×1920 均 `HAS_CONTENT` |
| 建 1 块虚拟屏 | ≈11.3 s | 416–691 ms | `pass=true` |
| 2 物理 + 4 虚拟 = 6 屏 | — | — | 全部 `online`/`active`/可捕获，与物理屏数量解耦 |

### 理由

- 建屏 11.3 秒是 §14.2 记录的最大性能隐患；「捕获优先」让绝大多数真实场景（被控机是台正常在用的机器）**根本不进入这条慢路径**，直接实现"秒连"。
- 虚拟屏的正确定位是**满足控制端提出的显示需求**，而不是"模拟被控端的物理屏"。这个定位一旦搞错，就会错误地把"被控端有几块物理屏"当成约束条件。
- `CGVirtualDisplay` 由 WindowServer 软件合成，**不占用 Intel DDI/显示管道**，因此 UHD 630 的「3 屏」限制与虚拟屏无关 —— 先前 README §13.3 的"超限"判断是错的，已划掉。

### 影响与待办

- `p0probe capture` 子命令已实现（`--display all|<id>`），作为该路径的回归入口。
- 无头机器（枚举不到任何 display）仍需虚拟屏兜底，这条路径保持不变。
- 需要额外考虑：物理屏可能**休眠或锁屏**（捕获为黑），此时应回退到虚拟屏而非报错。这是 M1 要处理的边界。

### 未解决（真正的架构分叉）

以上只解决"几块屏、能不能建"。与 Windows RDP 的本质差距是**会话隔离**：远程操作时本地屏是否可见、锁屏能否采集、能否多用户并发。这三项靠虚拟屏无法弥补，属独立课题。

---

## D-04 产品形态：独占式会话（客户端规格虚拟屏 + 被控端置黑/锁定）

**日期**：2026-11-17　**状态**：已定（用户明确要求 + Apple 官方实现佐证 + 本机能力侦察）

### 决定

产品**只做独占式会话**，不做镜像：

1. 控制端认证通过 → Host 进入**独占态**（物理屏禁用/置黑，现场不可见不可操作）；
2. 显示规格**由客户端决定**：客户端要 N 块、什么分辨率，就建 N 块 `CGVirtualDisplay`；
3. **只捕获虚拟屏**，物理屏永不进入采集链路；
4. 断开 → 销毁虚拟屏 → 恢复物理屏 → 重新锁屏。

一句话：**被控端有几块物理屏，与客户端看到什么完全无关。**

### 证据

| 来源 | 事实 |
|---|---|
| 用户需求（2026-11-17） | 明确否决 VNC 镜像；要求"控制端登入→被控端锁屏"，且不接受"被控端多屏挤到一块" |
| Apple 支持文档《Screen sharing type options》 | 高性能屏幕共享：客户端选 1–2 块虚拟屏；登录目标用户后**硬件显示器置黑**，"任何人都不能使用该 Mac"；**仅 Apple Silicon** |
| 本机 entitlement 取证 | `com.apple.private.aqua.createSession` 仅在 `loginwindow` 上 → 第三方**无法**新建并行 Aqua 会话 |
| `P0V-SessionRecon` 实测 | `SLSCopySessionList` 可调（返回真实会话）；`SLSConfigureDisplayEnabled`、`SLSConfigureDisplayMirrorOfDisplay`、`SACLockScreenImmediate`、`SLSDeviceLock` 全部存在；`CGBeginDisplayConfiguration→Cancel` 实测成功 |

### 理由

- **为什么不是多会话**：Windows RDP 是"服务端为新客户端开一个新会话"，macOS 的会话创建被 Apple 私有 entitlement 独占。第三方做到的是"同一 console 会话内独占"，这恰好满足用户要的体验（我登入，别人不能用），而**不需要**多会话并发。
- **为什么不是镜像**：镜像把被控端屏数、分辨率、隐私问题全部暴露给客户端，且体验差。Apple 自己也不这么做（HP 模式用虚拟屏 + 置黑）。**补充（2026-11-23）**：VNC/RFB 与 RDP 的延迟差别不在「采集 / 不采集」，而在采集层级、编码和缓存复用，详见 `DESIGN.md` §1.2.1。
- **为什么 Intel 上要自研**：Apple 的 HP 模式只给 Apple Silicon。Intel 上没有系统级方案，所以只能自己拼：`CGVirtualDisplay` + `SLSConfigureDisplayEnabled` + `SACLockScreenImmediate`，这三块本机已验证存在。

### 影响与待办

- FR-01 已改写为"只建虚拟屏"；新增 FR-00 独占；C-07/C-08 落为硬约束。
- 建屏 11.3 秒的性能问题**不再是"要不要建屏"的问题**，而是"必须把建屏做快或常驻复用"——因为每次会话都要建。这是 M1 的第一优先优化项。
- 待验证（A-08 / P0-V）：V-01 禁用物理屏后虚拟屏仍可捕获；V-02 锁屏态下能否建屏与采集；V-03 全部物理屏 disable 后的极限情形。
- **屏数/布局语义已由 D-05 细化**：物理屏不只是置黑，而是退出坐标空间，保证控制端只在 N 块屏内操作。
- 回退方案：若私有显示控制被 WindowServer 拒绝，用 `CGDisplayCapture` + 高窗口层遮罩，并在产品说明中标注"非绝对安全"。

---

## D-05 显示空间隔离与光标归属：控制端只应有 N 块屏，不多一块

**日期**：2026-11-17　**状态**：已定（用户明确要求 + C-09 硬约束）

### 背景（用户提出的关键质疑）

> 被控端 2 块物理屏，控制端 2 块物理屏。控制端连上后，用户到底是在 2 块屏里操作，还是在 4 块屏里操作（2 块看得见 + 2 块看不见，鼠标会滑进看不见的那 2 块）？

这个质疑指向一个**真实且致命的实现分叉**：如果只把物理屏「置黑」，它们的矩形**仍然留在 WindowServer 的全局坐标空间里**，指针照样能滑进去，用户就会在 4 块屏里找指针。镜像类产品的体验灾难有一半来自这里。

### 决定

1. **`disable` 而非「置黑」**：会话期间对每块物理屏在同一个显示配置事务（`CGBeginDisplayConfiguration` → `SLSConfigureDisplayEnabled(display, false)`）内禁用，使其**退出全局坐标空间**。置黑/遮罩只能作为 disable 失败时的降级手段，且必须同时叠加第 3 条。
2. **虚拟屏布局也由客户端定**：客户端不只报 N 块屏的分辨率，还报各屏相对原点（并排 / 上下 / 错位）。Host 在同一事务内用 `CGConfigureDisplayOrigin` 把 N 块虚拟屏排成客户端描述的形状。这样跨屏接缝的位置与控制端本地双屏一致，鼠标跨界的手感 = 本地多屏。
3. **光标归属（独立于第 1 条）**：光标不在 Host 侧用硬件指针表达。Host 侧 `CGAssociateMouseAndMouseCursorPosition(false)` 切断硬件鼠标与指针的耦合，指针位置完全由客户端输入事件驱动（每步入事件前 warp 到目标坐标，坐标恒在虚拟屏并集内）；客户端本地渲染光标。**即使 disable 被拒绝退回置黑，指针也不可能落进物理屏**。
4. **入参校验**：会话期间断言 `CGGetActiveDisplayList` 返回的集合 ⊆ 本会话虚拟屏集合，且并集矩形的宽高等于客户端声明的桌面总尺寸。不满足则不进入会话（否则就是 4 块屏）。

### 判据（M1 必测）

| 项 | 通过条件 |
|---|---|
| 空间收缩 | 会话中 `CGGetActiveDisplayList` 只返回 N 块虚拟屏；物理屏 ID 不在列表 |
| 指针约束 | 连续 10s 向四角甩鼠标，warp 落点恒在虚拟屏矩形并集内，误差 < 1px |
| 窗口不可越界 | 会话中新建窗口、`NSWindow` 最大化、拖拽到屏幕边缘，均不会落到物理屏（space 里没有它） |
| 断开还原 | 断开后物理屏全部恢复启用、原点与主屏身份回原值、窗口位置按会话前快照还原 |

### 待验证 / 风险

- **V-01 / V-03**：一块、以及**全部**物理屏 disable 后，建屏+SCK 采集+事件注入是否仍正常。全部 disable 是 C-09 的极限情形，风险最高（WindowServer 可能判定为「无显示器」而回落到默认模式）。见 DESIGN A-08。
  - 探针已实现：`P0V-DisplayIsolation/`（`v01probe run --mode one|all`，含快照、守护进程兜底、事务死线、两阶段恢复）。
  - 2026-11-17 晚在 Sequoia 15.5 / Macmini8,1 首跑 V-03（`--mode all --watch-secs 0 --no-rebuild-test`）：**3 块物理屏全部退出 active、虚拟屏 58fps `HAS_CONTENT`、SCK 干净、指针 5/5 点 0 偏差、恢复 OK**。物理屏仍在 online 列表（Intel 上属「摘出 active 空间」而非断开）。输入注入因 `axTrusted=0` 未过；唤醒观察与重建测试未跑。V-01 尚未跑。
  - 同日 22:03 完整版（唤醒观察 20s + 重建测试）：观察期 0 次重新 enable；**重建测试创建第 2 块虚拟屏时 WindowServer SIGABRT（`canonical_mirror_master` 断言），整机注销**。根因是该 WindowServer 已有 5 个残留虚拟屏槽位。
  - 同日 22:30 复测：**这些「停放槽位」（`vendor=0xFFFFFFFF / offline / 1x1`）无法从用户态清除**。`CDVirtualDisplayDestroy` 只接受创建进程内的 client 指针；`SL2CDVirtualDisplayDestroy` 只查本进程虚拟屏表；用同一身份重建仍只复用 4128835，不会认领旧槽位；`pmset displaysleepnow` + `caffeinate -u` 两轮也只能回收「在线孤儿」。只有注销/重启会清空。
  - 因此探针改为：检测到槽位时**只自动跳过**「零物理屏下再建一块」子项（结果记 `rebuildTest.skipped=staleVirtualSlots`），V-03 核心继续，**不再要求重启机器**；`--count > 1` 需显式 `--allow-stale-slots`。
  - **对 M1 的硬性结论**：全部虚拟屏必须在禁用物理屏**之前**建齐，会话期间不新建虚拟屏；该组合（零 active 物理屏 + 槽位 + 新建屏）是平台级崩溃点，不能靠重试或清理绕过。A-08 据此记录。
  - 同日 22:15 **V-01 通过**（`--mode one --watch-secs 20`）：禁用的物理屏退出 active，虚拟屏 `HAS_CONTENT`，SCK 干净，指针逐屏采样 0 偏差且 0 次落入禁用屏，输入注入 `axTrusted=1` 通过，20s 唤醒观察 0 次重新 enable，恢复后 bounds/主屏身份精确回原值。**V-01 在 Sequoia 15.5 / Macmini8,1 关闭。** 注意：禁用一块屏期间 WindowServer 会临时重排剩余物理屏（模式/位置变化），恢复后还原；M1 窗口布局快照仍是必需项。
  - 同日 22:35 **V-03 核心完整版通过**（`--mode all --watch-secs 20`）：3 块物理屏全部退出 active、虚拟屏 60fps `HAS_CONTENT`、SCK 干净、指针逐屏 0 偏差、输入注入 `axTrusted=1` 通过、20s 唤醒观察 0 次重新 enable、恢复后 bounds/mode/主屏身份精确回原值；重建子项由预检自动跳过（`rebuildTested=false`），未再崩溃。**V-03 核心在 Sequoia 15.5 / Macmini8,1 关闭。**
  - 顺带修复：WindowServer 残留虚拟屏槽位会让新建屏继承镜像态、mode 卡死；`VDManager` 已加单屏自愈（详见 `P0-TahoeProbe/README.md` §17）。
  - **2026-11-18 Tahoe 26.5.2 新增风险**：V-01 全项 PASS；V-03 的禁屏、指针、注入、20–30s 无重新 enable、恢复全部通过，但同一状态下 **SCK 送帧多数为黑**（4 次：1 次全黑、2 次多数黑、1 次放白色 TextEdit 窗口仍全黑），而 `screencapture` 能抓到完整桌面 ⇒ 合成正常、SCK 路径异常。**C-09 的「全部物理屏退出 active」在 Tahoe 上目前不能与 SCK 采集同时成立**；M1 前必须新增替代采集对照（`CGDisplayCreateImage` / `CGWindowListCreateImage`）或启用本决定第 3 条降级。2026-11-18 后续实测：两条公开抓屏 API 在 Tahoe 零 active 物理屏下**稳定 `HAS_CONTENT`**（`minMean=37–39`、`maxVar≈1500`、0 黑采样，恢复 OK，见 `/tmp/p0v-alt-tahoe3.json` 与 `/tmp/p0v-alt-tahoe-1080.json`），可优先作为 M1 采集候选；SCK 同场景不稳定（V-03 全黑/多数黑，altprobe 中仅 2–4fps），不能再作为该场景唯一路径。并把「非绝对安全」写入产品说明。Sequoia 的 V-03 `HAS_CONTENT` 结论不可外推到 Tahoe。
- **窗口重排副作用**：物理屏被移出空间时 WindowServer 会把原在该屏的窗口搬到剩余屏；断开后**不会**自动回原位。必须会话前快照 display 布局 + 各窗口 frame，断开后还原。这是 M1 的一个独立工作项，不是"顺手就能好"的细节。
  - 已实现 `M1WindowLayout`（2026-11-22）：建屏前采集 CGWindowList 快照，恢复并销毁虚拟屏后按 `pid#windowNumber` 搬回，目标 frame 夹取到可见区；AX 未授权时只计划不搬。单测 12 条通过。Tahoe 26.5.2 独占闭环已验证（RESULTS §5.34）：该版本 WindowServer 自然恢复显示时多数窗口会自动回位（r5 `planned=0`），但强移窗口后仍由本模块复位（r6 `planned=7 restored=7`，窗口从注入的 (150,306) 回到快照 (464,131)）。⇒ 「不自动还原」是版本相关现象，本模块作为兜底保留，不能依赖系统自动还原。
- **`disable` 权限**：`SLSConfigureDisplayEnabled` 的符号可调已实测（`P0V-SessionRecon`），V-01/V-03 均已在事务内真正生效并恢复。若运行环境（非 Intel / 非 Sequoia）被 WindowServer 拒绝，走决定第 3 条 + `CGDisplayCapture` 降级。

---

## D-06 「锁屏」的确切含义：会话中不锁屏，断开后才锁屏

**日期**：2026-11-17　**状态**：已定（用户追问"现场用户此时能否点亮桌面登录"后澄清）

### 背景

用户要求"控制端登入，被控端就锁屏"。但"锁屏"在 macOS 上有两种互斥的实现，选错会使产品失效：

| 路径 | 结果 |
|---|---|
| 会话中真调 `SACLockScreenImmediate` | login window 抢走键盘焦点与前台层 → 远程客户端**只能看到锁屏界面**，注入的键鼠事件被 login window 吃掉，桌面根本用不了 |
| 只禁物理屏 + 吞本地输入，会话保持解锁 | 远程可用；现场黑屏、键鼠无效 —— 这才是 Apple 高性能屏幕共享的等价物 |

### 决定

1. **会话中 = 现场锁定，不是系统锁屏。** Aqua 会话保持解锁（自动登录后的登录态），物理屏 disable，本地 HID 输入在事件 tap 层被吞掉并上报。绝不在会话中调 `SACLockScreenImmediate`。
2. **断开后才真锁屏。** 顺序固定：销毁虚拟屏 → 恢复物理屏（原点/主屏身份按快照还原）→ `SACLockScreenImmediate`。此后现场用户可正常点亮屏幕、登录、使用。
3. **现场取回控制权：现场优先（local console wins），不依赖远程方同意。** 三级信号，逐级升强：
   - 一级（可协商）：**手势** = 按住 `Shift` ≥ 3s（可配置；事件 tap 在吞事件前即可判定）。触发后向客户端发 `localTakeover`，客户端有 **10s 缓冲**保存工作并弹提示；**缓冲结束即强制断开**，恢复物理屏 + 锁屏。客户端只能"延后一次、最多 60s"，不能否决。
   - 二级（fail-safe，无需协商）：**显示器热插拔**、**系统睡眠/唤醒事件**、**锁屏事件**这三类都视为现场介入 → 立即断开并恢复，不做缓冲。理由：这些事件已经破坏了独占态的前提（有人接触硬件），继续跑是不安全状态。
   - 三级（兜底，我们拦不住也不打算拦）：长按电源键断电。后果 = 断连 + 重启 + LaunchAgent 自动恢复。
   - 为什么要"现场优先"：物理在场是最高权限，任何威胁模型里都是。远程只是"受托使用"，被托管方必须有一条不依赖对方授权的退出路径，否则运维会直接用拔电解决，反而更糟。代价是现场可对远程做 DoS —— 但能碰到机器的人本来就能拔电，DoS 不是新增风险。
   - 高安全场景（机柜上锁、现场无人）可配置为"需客户端确认才断开"，这是**可选策略**，不是默认。
4. **产品文案边界（不得夸大）。** 可承诺：会话期间现场**看不到任何内容**、键鼠输入**不进入会话**。不可承诺：物理接触者绝对无法干扰 —— 长按电源键、直接断电、Touch ID 这些系统级/硬件级路径第三方拦不住。文档与销售话术必须一致。

### 为什么"点亮不了"是结构性的

物理屏走的是 `SLSConfigureDisplayEnabled(..., false)`，即**从显示配置里移除**，不是 `CGDisplayForceDisplaySleep` 的睡眠路径。睡眠由键鼠唤醒（HID idle 断言），而配置层移除的显示器不在空间里，键鼠事件不会触发它回来。面板因无信号而黑，现场看到的是"这台机器像关了屏"。

**但这条必须实测**（已并入 V-01）：系统在唤醒/登录/Touch ID 事件上可能重写显示配置，把显示器重新 enable。若会被重新 enable，M1 需要加看门狗（检测到物理屏回到 active list 立刻再 disable 一次）或换更强手段。

### 影响与待办

- FR-00 表述已改为"物理屏 disable + 本地输入吞掉上报，断开后才恢复并锁屏"（原文"锁屏"有歧义）。
- V-01 增加步骤：禁用期间分别按键盘、滑触控板、按 Touch ID，确认物理屏未被系统重新 enable。
- FR-09（无人值守）需覆盖"现场直接断电"：重启 → 自动登录 → LaunchAgent 拉起 → 2min 内可重连。

---

## D-07 锁屏与重连：Host 常驻登录态，不用「锁屏」当安全屏障

**日期**：2026-11-17　**状态**：⚠️ **已修订（同日）** —— "第三方无法远程登录"的判断被推翻，首选方案改为 D-08（远程登录 Path A）。本文档降级为 **兜底方案 Path B**，仅在 V-04 失败时启用。**2026-11-18 更新：Tahoe 上 V-04 四项已全过、Path A 成立，Path B 仅保留给高安全档/无凭据场景**

### 问题

被控机长时间无人操作会闲置锁屏。锁屏后：

- 前台是 loginwindow，键鼠焦点被它接管，普通 `CGEventPost` 注入的事件进不到用户桌面；
- SCK 对锁屏内容通常只能拿到黑帧（未授权的用户态进程）；
- 因此**用户态的我们**进不去 —— 但这不等于第三方整体做不到，见 D-08 的更正。

同时 D-06 说"断开后真锁屏"，与"下一次还能远程连上"直接冲突 —— 用户这一问把矛盾点出来了。

### 决定（Path B · 兜底，仅当 V-04 失败时采用）

1. **锁屏不进入会话路径。** Host 部署为"常驻登录态"：部署脚本关闭「闲置后锁屏」「唤醒需要密码」，LaunchAgent 持 `IOPMAssertionPreventUserIdleSystemSleep` + `PreventUserIdleDisplaySleep` 并周期性 `DeclareUserActive`。**必须同时防睡眠**，否则睡眠唤醒后系统要求密码，直接掉进死局。
2. **断开后进入「待机壳」，不是系统锁屏**（默认档）：不锁屏、物理屏保持黑、本地输入被吞；两种出口 —— 远程重连（直接进会话，零登录）或现场按任意键（视为二级接管信号，撤壳放行输入，得到正常桌面）。
3. **高安全档（可选，非默认）**：断开后真锁屏。前提是关闭自动登录、要求现场解锁；此时远程重连能力受限，部署文档必须明示"此档不支持无人值守重连"。
4. **不把锁屏当安全屏障，理由写进文档**：本产品 Host 必须自动登录（FR-09），而"自动登录 + 可物理接触"本身就等于"重启即得桌面"。锁屏只挡随手路过的人，挡不住有意的物理接触者。既然如此，为了这一层象征性防护牺牲无人值守的可连性，是错的取舍。真正的边界是**场地物理安全**（已写入 DESIGN §3.3）。

### 待验证（决定高安全档能否成立）

| 编号 | 内容 |
|---|---|
| V-02a | 锁屏态下 SCK 能否捕获到锁屏画面（而非黑帧） |
| V-02b | 锁屏态下 `CGEventPost` 注入的键鼠是否被 loginwindow 接受 |
| V-02c | 若能注入，用注入密码能否完成解锁（决定高安全档可行性） |

三项即 V-04 的子集（V-04a/b/c），结论并入 D-08。任一为否 → 只能走 Path B（本文档）。

### 风险

- idle 断言可能被系统策略覆盖（台式机无电池，风险低）；系统更新可能重置 `defaults` 域 → 纳入 NFR-08 回归清单。
- "待机壳"期间若发生系统睡眠，唤醒会要求密码 → 死局。防睡眠是硬要求，不是优化项。
- 遮罩壳是应用层窗口，现场可尝试 Cmd-Option-Esc 等；因此壳期间输入被吞是前提，壳本身只是视觉遮罩，不承担安全职责。

---

## D-08 远程登录（锁屏 / 登录窗）：走 root daemon，而不是"永不锁屏"

**日期**：2026-11-17　**状态**：✅ **方向已确认；2026-11-18 Tahoe 26.5.2 上 V-04a/b/c/d 全部实测通过，Path A 端到端成立（详见文末 10:52 最终结论）**；root daemon 路径仍受 TCC 与 GUI 会话归属阻挡，推荐形态为正确签名的用户态 App

### 更正：此前结论错在哪

我把两件事混成了一件：

| 命题 | 真假 |
|---|---|
| `com.apple.private.aqua.createSession` 被 `loginwindow` 独占 → 第三方不能**新建并行 Aqua 会话** | ✅ 真（本机已取证） |
| 因此第三方不能**捕获 / 注入既有的 loginwindow 会话** | ❌ 假（逻辑跳跃，无证据） |

"不能新建会话"和"不能在既有会话里拿画面、发事件"是两个完全不同的授权面。后者第三方一直在做，只是需要换一条路径。

### 三条路径的真实差别

| 方案 | 关键组件 | 权限从哪来 | 登录窗可用 |
|---|---|---|---|
| Apple 屏幕共享 | `screensharingd` / ARDAgent | Apple 私有 entitlement，系统自带 | ✅ 原生 |
| 第三方 VNC / 远程工具 | **root LaunchDaemon** + 用户态 App | 用户授予「屏幕录制 / 辅助功能」（必要时「完全磁盘访问」），或 MDM PPPC 下发 | ✅ 成熟商用 |
| 我们原方案 | 用户态 LaunchAgent | 仅用户授权给 App | ❌ 被 loginwindow 挡 |

差别不在 API 存不存在，而在**进程特权等级 + TCC 归属 + 事件投递方式**（广播 vs 定向投递到 loginwindow）。这也解释了为什么 Apple 不用授权：`screensharingd` 是系统组件；第三方要用户手动授权。

第 3 行「用户态 LaunchAgent 被 loginwindow 挡」已被 2026-11-17 晚实测推翻（见下）。修订方向：**登录窗捕获与定向注入不需要 root**，只要进程位于用户 GUI 会话且 TCC 身份正确；root 组件只在“无人登录/登录窗尚未建立用户会话”等场景才可能需要。优先把双组件收敛为 **一个正确签名的用户态 App**。

### 决定（方向）

1. Host 改为**双组件**：**root LaunchDaemon**（特权：显示配置/禁物理屏、登录窗捕获、定向注入、开机引导）+ **用户态 LaunchAgent**（会话内：建虚拟屏、SCK 采集、编码、常规注入）。C-03 已同步修订。
2. **Path A（首选）**：连接时若 Host 处于锁屏/登录窗 → daemon 接管：按客户端规格建虚拟屏 → 禁物理屏 → 捕获 loginwindow → 客户端呈现登录界面 → 注入密码 → 解锁后无缝转为用户会话的桌面采集。
3. **Path B（兜底）**：V-04 失败时退回 D-07 的"常驻登录态 + 待机壳"。
4. **安全语义因 Path A 变好**：断开后可以放心真锁屏（D-06 原方案自动恢复），下次远程登录即可，不再需要"永不锁屏"这种用安全性换可用性的妥协。

### V-04 验证计划（需要 sudo，四项都要）

| 编号 | 内容 | 判据 |
|---|---|---|
| V-04a | root daemon 在锁屏/登录窗态用 SCK 捕获 | 拿到真实登录界面而非纯黑帧 |
| V-04b | 从 daemon 向 loginwindow **定向**注入按键 | 登录窗有响应（密码框出字符、焦点移动） |
| V-04c | 注入完整密码完成解锁 | 成功进入桌面 |
| V-04d | 登录窗态下建虚拟屏 + 禁物理屏 | 登录界面渲染到虚拟屏，物理屏黑 |

四项全过 → Path A 成立，形态与 Apple 高性能屏幕共享对齐（且 Intel 上是空白）。任一失败 → 记录失败点，回 Path B，并把"远程登录"从产品承诺里删掉。

### 代价（诚实记账）

- **安装形态变重**：需要安装器 + 管理员密码 + root daemon 常驻，不再是"拖个 App 就能用"。
- **TCC 归属是硬骨头**：root daemon 没有 UI 会话，弹不出授权框，必须手动把 daemon 二进制拖进「屏幕录制 / 辅助功能 / 完全磁盘访问」列表，或用 MDM PPPC 描述文件下发。我们在 P0 已经被 responsible-process 归属坑过一次（TCC 反复失效），这次只会更难。
- 系统更新后授权可能失效 → 每次更新重跑 V-04 全套（并入 NFR-08）。
- **安全面扩大**：root daemon 是新攻击面，必须本地 socket + 签名校验 + 最小权限，禁止网络监听。

---

### 实测记录（2026-11-17 16:5x，用户态冒烟）

同一份探针二进制在**用户态 shell** 里跑 `probe` / `capture`：

```
axTrusted = 0
sckError  = null
sckDisplayIDs = [2026701824, 817925634]     # 2 块物理屏都在
capture: frames = 6, minMean ≈ 33–58        # HAS_CONTENT
session: available = 1, screenIsLocked = 0, loginDone = 1, auditID = 100001
```

两个结论：

1. **TCC 按 responsible process 记账，不是按二进制。** 这个新二进制从没被授权过，却拿到了画面 —— 因为它的父进程链（终端 / 宿主 App）已有「屏幕录制」。这解释了 daemon 为什么必须自己拿授权：它没有父进程可继承，`responsible` 就是它自己。
2. `axTrusted = 0` 说明**注入能力此时为零**，哪怕抓屏是通的。抓屏与注入是两套授权，必须分别验。

### 实测记录（2026-11-17 22:40–22:53，Sequoia 15.5 / Macmini8,1）

**root LaunchDaemon 路径失败**：安装 `/Applications/P0VRootProbe.app` 后，把 `.app`
和其可执行文件分别加入「辅助功能」「屏幕与系统录音」。系统 TCC 库出现
`auth_value=2` 条目，但都是 `client_type=1`（路径）、`csreq` 仅 40 字节 cdhash。
daemon 实测：`session.available=0`、`axTrusted=0`、SCK `6s 超时`、注入无效。
用户域 LaunchAgent 启动同一二进制时 SCK 返回
`The user declined TCCs for application, window, display capture`，说明此前的
“用户态可跑”是继承 Qoder 的 responsible-process 授权，探针自身条目未被采纳。
根因指向 **ad-hoc 签名无法生成 bundle-id 级 TCC 要求**，系统设置只能记成路径条目；
同时系统域 daemon 不在 GUI 会话，SCK 本就难以工作。

**用户会话路径通过（V-04a / V-04b）**：用继承 Qoder 授权的同一二进制，在锁屏后：

| 项 | 结果 |
|---|---|
| 锁屏截图 | 真实登录界面（头像 + 密码框 + 时间），非黑帧 |
| `capture` | `HAS_CONTENT`（注入前 1 帧 / 后 1 帧） |
| `inject`（`aa`+Return） | `INJECTION_ACCEPTED_UI_CHANGED`，152/256 格变化 |
| 注入后截图 | 密码框出现输入圆点，占位符消失 |
| `sessionAfter` | `screenIsLocked=true`（错误密码未解锁，符合预期） |

**结论**：loginwindow 不阻止用户会话进程捕获或定向注入；真正的门槛是 TCC 身份
与 GUI 会话归属，不是 root 特权。**V-04c 于 2026-11-17 决定主动跳过、记为未测**
（完整解锁需要真实凭据，留到正式签名后的产品验证）；V-04d 未实现。**Path A 的
推荐形态改为“正确签名的用户态 App + 用户授权”，root daemon 仅在无人登录场景再评估。**

**2026-11-18 Tahoe 26.5.2 追加（见 `docs/RESULTS-BY-OS.md`）**：V-04a 在用户会话路径
通过（锁屏态 `HAS_CONTENT`，17 帧、0 黑帧）；V-04b 两次判据均被污染（r1 用户手动解锁，
r2 抓屏时已解锁且 256/256 格无变化），未确认；V-04c 仍未测。

**2026-11-18 10:40 更正（撤回此前过度推论）**：此前根据 `active=false` 判定「V-02 不成立、
Path A 在 Tahoe 不成立」，已查明是**探针假阴性**：`altprobe --no-disable` 在
`waitUntilUsable`（要求 `active=true`）处提前退出，且 `run_v02_locked.sh` 用 `awk $3`
取虚拟屏 ID（实际在 `$2`），导致三路径捕获从未执行。修正探针后重测：

- 锁屏态下虚拟屏实际 `online=1 / active=1`（屏睡态与屏亮态均是）；
- 用户补充的「锁屏 2-3 秒后屏睡」是关键：屏睡时 SCK displays 变空；**先启动 `caffeinate -d`
  再锁屏**可保持屏亮，SCK 恢复 `HAS_CONTENT` 50 帧；
- 但两次截图（`/tmp/tahoe-r3-lockscreen.png`、`/tmp/tahoe-20261118-r4-lockscreen.png`）
  显示虚拟屏上只有锁屏壁纸、**没有登录框/密码框**，`CGWindowListCreateImage` 在屏亮态
  的 `HAS_CONTENT` 也是壁纸内容。

**2026-11-18 10:52 最终结论（Path A 在 Tahoe 端到端成立）**：v0.3 的「登录框未迁移」
同样是假阴性——此前探针只创建虚拟屏、**没有禁用物理屏**，登录 UI 自然留在物理屏上。
本轮在锁屏+屏亮态（先 `caffeinate -d` 再 `lock`）建 active 虚拟屏后**禁掉全部物理屏**，
两轮截图均出现完整登录界面：日期/时钟、`bemin` 头像、`Enter Password` 输入框
（`/tmp/tahoe-20261118-r5-shot.png.disabled.png`、`r6-...disabled.png`）。
无焦点对照（r6，不移光标）同样成立 → **迁移的充分条件是「零 active 物理屏」，与光标无关**。

V-04b/c 用用户授权的真实凭据（仅经 `P0V_PW` 环境变量在运行时注入，脚本/日志/文档
均无明文）干净重测两轮：`INJECTION_ACCEPTED_AND_UNLOCKED`、256/256 格变化、
`sessionAfter.screenIsLocked=false`。**V-04a/b/c/d 四项全过，Path A 成立，
不再回退 Path B**；D-07 继续保留为高安全档/无凭据场景的兜底。

**产品实现前置条件（必须写入 M1）**：
1. **必须先防显示睡眠**——锁屏后 2–3s 屏睡会让 SCK displays 变空；用
   `IOPMAssertionPreventUserIdleDisplaySleep` + `PreventUserIdleSystemSleep` 常驻断言，
   不能依赖事后唤醒；
2. **采集路径**：屏亮态 SCK/CG 双路径均可；已登录零物理屏场景 SCK 不可靠，
   优先 `CGDisplayCreateImage`，SCK 仅作对照（见 D-05）；
3. Path A 步骤收敛为：锁屏 → 建 active 虚拟屏 → 禁全部物理屏（登录 UI 自动迁移，
   无需移光标）→ 捕获呈现 → 注入凭据解锁 → 恢复物理屏转独占会话。

**遗留**：真 loginwindow 态（`loginDone=0`，未登录机器）未在本次覆盖，本次是
`loginDone=true` 的已登录用户锁屏态；开机未登录场景仍待 M1 实测。

---

## D-09 采集主路径：CGDisplayCreateImage，SCK 降为对照/兼容分支

**日期**：2026-11-18 11:20　**状态**：⚠️ **已确认但依据被 M1-Pre 实测部分修正（2026-11-18 11:30）**——路径可用性成立，但帧率目标不成立、SCK 黑帧结论需限定条件；主路径形态暂缓冻结，见文末「M1-Pre 实测更正」

### 决定

1. **主路径**：逐屏 `CGDisplayCreateImage(displayID)` 抓帧 → CVPixelBuffer → VideoToolbox H.264 硬编。
2. **SCK `SCStream` 保留**：作为对照路径与 Sequoia 15.5 兼容分支；不再作为 Tahoe 零物理屏场景的唯一采集手段。
3. **不再声称「全程零拷贝」**：公开抓屏 API 涉及位图拷贝，性能以 M1-Pre 实测为准。
4. **不阻塞方案定稿**：吞吐/帧率/CPU 实测转入 M1-Pre 验收；不达标时按 NFR-04 逐级降规格，或按 D-05 第 3 条降级，不推翻独占会话形态。

### 证据

| 场景 | SCK | `CGDisplayCreateImage` |
|---|---|---|
| Tahoe 26.5.2 + 零 active 物理屏 | 4 次中 1 次全黑、2 次多数帧黑；`altprobe` 仅 2–4fps | 1280×720 `minMean=39/maxVar=1506`、1920×1080 `minMean=37/maxVar=1562`，0 黑采样，恢复 OK |
| Tahoe 锁屏+屏亮 | 50 帧 `HAS_CONTENT` | `mean≈148/var≈1639` `HAS_CONTENT` |
| Sequoia 15.5 | V-03 60fps `HAS_CONTENT` | 未测（SCK 在该版本稳定，保留为兼容分支） |

数据来源：`docs/RESULTS-BY-OS.md` §5、`P0V-AltCapture/README.md`；证据 `/tmp/p0v-alt-tahoe3.json`、`/tmp/p0v-alt-tahoe-1080.json`。

### 理由与代价

- 合成层正常（系统截图有完整桌面），黑帧来自 Tahoe SCK 送帧异常，不是产品形态错误；换采集 API 是最小改动面。
- 代价：`CGDisplayCreateImage` 是同步抓帧，需要按 displayID 逐屏调度并控制节奏；CPU/帧率上限必须实测，不能外推 SCK 的性能结论。
- 真 loginwindow（`loginDone=0`）态尚未覆盖，M1 补测时两条路径都要跑。

### 影响与待办

- `docs/DESIGN.md` FR-03 / §3.1 / §4.1 / §5.3 已同步；`PROTOCOL.md` 帧通道不变（采编之后仍是 QUIC datagram）。
- M1-Pre：新建采编探针，复用 `VDManager` + `P0VDisplayControl`（含守护恢复），锁定 1080p 吞吐/帧率/CPU 与黑帧判据；结果回填 `RESULTS-BY-OS.md`。

### M1-Pre 实测更正（2026-11-18 11:30，`M1-Pre-CaptureCodec/`）

三组端到端实测（`CGDisplayCreateImage → BGRA CVPixelBuffer → VT H.264 → VT 解码`）：

| 场景 | 分辨率 | 链路 verdict | 实际 fps | 抓帧 avg/p95 ms | 整机 busy |
|---|---|---|---|---|---|
| `--no-disable` | 1920×1080 | PASS | 1 | 282 / 356 | 99% |
| 禁全部物理屏 | 1920×1080 | PASS | 4 | 125 / 168 | 99% |
| 禁全部物理屏 | 1280×720 | PASS | 7 | 95 / 124 | 77% |

全部 0 黑帧、0 编码错误、编解码计数一致、恢复 OK。**两点必须记入决策**：

1. **路径可用性确认**：D-09 选的链路在零物理屏下端到端成立，0 黑帧，恢复可靠 —— 决策方向上仍然正确。
2. **性能目标不成立**：`CGDisplayCreateImage` 抓帧固定成本 95–282ms，是绝对瓶颈；720p 仅降到 95ms，说明不是像素拷贝而是系统级同步成本。**1080p60 / <30ms 达不到，差 4–8 倍**；整机 busy 77–99% 而本进程仅 0.14–0.21 核，开销在 WindowServer 合成侧。
3. ~~**SCK 55fps**~~ **（11:35 撤销）**：该读数来自 `withEncoder:NO`（`encodedFrames=0`、首帧 847ms），是 SCK 按内容变化送帧的假象。`--sck-only` 带编码环回复测的真实帧率：SCK 禁屏 **18fps**、不禁屏 2fps；`CGDisplayCreateImage` 禁屏 4fps。详见 `RESULTS-BY-OS.md` §5.2。**这是本项目第三次「静态 SCK fps 不可当结论」的陷阱，已拦下。**

**D-10（2026-11-18 11:40 用户确认）：B + C 组合，已定** ——

1. **SCK 回主路径**：`SCStream → IOSurface → VideoToolbox H.264`，`CGDisplayCreateImage` 降为兜底/对照。依据：`--sck-only` 禁屏带编码 18fps、0 黑帧、原生零拷贝，相对优于 `CGDisplayCreateImage` 的 4fps。
2. **目标帧率下调到 15–30fps**：NFR-03 由「稳定 60fps」修订为「15–30fps（Tahoe/Intel 实测档）」，产品文案与 NFR-04 安全点同步更新。60fps 在 Intel + 当前系统 API 下不现实，不再作为验收项。
3. **流水线并行（原 D-10-A）不进 M1 关键路径**：作为 M1 完成后的独立优化验证，不阻塞骨架与单屏端到端。

### 影响

- `docs/DESIGN.md` FR-03 / 架构图 / §4.1 / §5.3 采集主路径改回 SCK；NFR-03 帧率目标修订；`PROTOCOL.md` 不变（帧率不在协议层）。
- M1 骨架**不依赖帧率的部分**（会话编排、显示隔离、输入注入、配对协商）立即开工；帧管线模块接口预留，参数（码率/关键帧间隔/帧率）按 SCK + 20fps 默认，后续优化可替换而不改上层。
- 首帧延迟 739–1031ms 与 NFR「首帧 <1s」的差距记入 FR-05 验收风险，双机联调（P2）时重点实测；不因该项阻塞 M1 骨架。

---

## D-11 真 loginwindow（`loginDone=0`）补测：延后到 M2 借测机

**日期**：2026-11-18 15:30　**状态**：✅ 已定（用户选 B）
**归属**：D-08 遗留项 / `DESIGN.md` A-09 的最后一块未覆盖场景

### 决策

该项**不在主力机（Macmini8,1）上执行**，推迟到 M2 的独立借测机完成。主力机继续用于 M1 帧管线与骨架开发，不承担需要登出中断会话的测试。

### 为什么不在主力机做

1. **必须登出**：真 loginwindow 态只能在「已登出、停在登录框」时出现，会关闭全部 app、中断当前会话。
2. **SSH 场景有已知架构障碍**：Sequoia 15.5 实测记录（`DESIGN.md` A-09）—— root daemon 路径被「TCC 路径条目 + 无 GUI 会话」双重阻挡。SSH 起的 root 进程不在 Aqua session，`CGDisplayCreateImage` 会返回全黑。要绕过需 `launchctl bsexec` 挂进 loginwindow 会话或装 LoginWindow 域 launchd job，属需要现场反复试的活，不适合在主力机上反复登出登入。
3. **收益与风险不匹配**：即便成功，结论也只是把 A-09 的适用范围从「已登录锁屏态」扩到「未登录登录窗态」；不影响 M1 已开工的任何模块。

### 已备好的执行资产（M2 直接用）

| 资产 | 路径 | 作用 |
|---|---|---|
| 前置只读探针 | `P0V-SessionRecon/gui_session_probe.m` | 判定是否在 GUI 会话、逐屏抓帧算 luma、输出 `READY_FOR_LOGINWINDOW_PROBE` / `NOT_IN_GUI_SESSION` / `GUI_BUT_NO_CONTENT`，**不改任何显示配置** |
| 补测脚本 | `P0V-SessionRecon/run_loginwindow_probe.sh` | 守卫 `loginDone=0` → 自动 preflight → 不在 GUI 会话时遍历 `loginwindow` pid 逐个 `bsexec` 并**自动重入自身** → `caffeinate` 防屏睡 → 建 1280×720 虚拟屏 + 禁全部物理屏 + 截图采集 → 恢复 |

关键设计：preflight 把「不在 GUI 会话」和「在会话但 TCC 拒绝抓屏」分开报（exit 10 vs 11），避免在借测机上把 TCC 授权问题误判成 API 不可用——这是本项目历史上踩过的假阴性类型。

### M2 借测机执行流程

1. 借测机接入项目目录（`/Volumes/Data/Code/macOS-RDP` 可读），构建 `p0vprobe` 与 `altprobe`；
2. 开启远程登录（`sudo systemsetup -setremotelogin on`），**从另一台机器 SSH 试连确认可达**；
3. 手动登出到登录框（`loginDone=0`）；
4. SSH 进入后 `sudo bash P0V-SessionRecon/run_loginwindow_probe.sh`；
5. 看 `disabled` 阶段截图是否出现用户名/密码框；结果回填 `RESULTS-BY-OS.md` 并关闭 A-09 遗留。

### 影响

- `DESIGN.md` A-09 行注明「`loginDone=0` 延后 M2，脚本与前置探针已就绪」；
- M1 里程碑不受阻塞，A-08/A-09 在 `loginDone=1` 锁屏态的结论继续有效；
- 若 M2 实测失败（loginwindow 态下虚拟屏拿不到登录 UI），触发 D-07 回退：Host 常驻登录态、禁闲置锁屏。

---

## D-12 禁屏兜底硬约束：无「就绪握手」不得改显示配置

**日期**：2026-11-18 16:20　**状态**：✅ 已定（事故驱动，不可协商）
**归属**：`P0VDisplayControl` 守护 / `M1RDPDriver` 会话 / `pipeline_kiosk_probe`

### 事故

`pipeline_kiosk_probe` 首次禁屏实测后，物理屏全黑、无法唤醒、无法回到系统，用户只能强制重启。

### 根因（四处叠加，缺一不可）

1. **守护进程是死胎**：`P0VStartGuardian` 只负责 `posix_spawn` 自身再带 `--guardian`，但探针的 `main`
   没有处理这个参数 → 子进程打印用法后 exit(2)，父进程却按「已 spawn = 有兜底」继续禁屏。
   **兜底从头到尾不存在。**
2. **快照顺序错**：快照在 `createVirtualDisplays` 之后拍，虚拟屏被写进快照并成为 main；
   恢复时先按虚拟屏还原拓扑，随后 `destroyAll` 把它销毁 → 物理屏留在错误原点（与恢复阶段
   反复出现「布局缺口 / commit=0」的现象一致）。
3. **零显示**：探针传 `keepIDs:@[]`，驱动把「active 减去 keep」全禁，连刚建好的虚拟屏一起关掉。
   系统没有任何 active display，没有画面也没有落点，唤醒事件无处生效。
4. **安全检查失效**：C-09 判据是 `active ⊆ 会话虚拟屏`，空集恒真 → 零显示被当成「隔离完美」放行。

另外 `@finally` 是唯一恢复路径，而 `SIGINT/SIGTERM/SIGHUP` 的默认动作是直接终止进程，
`@finally` 不会执行 —— 用户 Ctrl+C 或关终端窗口，物理屏就永久留在禁用态。

### 约束（全部为强制项）

| 编号 | 约束 | 落地 |
|---|---|---|
| C-12.1 | 禁屏前必须有「守护就绪握手」：守护写 `<snapshot>.guardian-ready`，父进程 3s 内等到才允许禁屏 | `P0VStartGuardian` / `P0VRunGuardian` |
| C-12.2 | 宿主二进制必须自行实现 `--guardian <snapshot> --parent-pid <pid>` 并转调 `P0VRunGuardian` | 各探针 `main` 第一段 |
| C-12.3 | 快照必须在创建任何虚拟屏**之前**拍，并作为本会话唯一恢复依据 | `M1RDPDriver.prepareSessionShieldError:` |
| C-12.4 | 禁屏 keep 集合必须含本会话虚拟屏；禁屏后自检 active 非空，为空即回滚 | `snapshotAndDisablePhysicalExcept:` |
| C-12.5 | C-09 判定必须拒绝空 active（零显示比泄漏更严重） | `M1IsolationViolation()` |
| C-12.6 | 恢复必须覆盖信号与卡死两条非正常出口 | 自管道线程 + 看门狗（时长+120s） |
| C-12.7 | 守护兜底恢复后，额外禁用不属于快照的 P0 虚拟屏（孤儿槽位） | `P0VDisableOrphanVirtualDisplays()` |

### 验证

- `tests/guardian_handshake_test.m`（负向）：宿主不实现 `--guardian` 时 `P0VStartGuardian`
  必须返回 NO，错误信息明确指向缺失实现 —— 这是把事故成因钉成回归测试。
- `pipeline_kiosk_probe --preflight`：只跑「快照 → 守护握手 → 撤盾」，不碰显示配置，
  1 秒内给出「有没有兜底」的确定答案；失败即禁止禁屏。
- 单测 120 断言全过（新增 `violation-empty-active-rejected` 等 5 项）。

### 影响

- 任何新探针只要调用 `P0VStartGuardian` 就自动受握手约束，忘记实现 `--guardian` 会**禁屏失败**而不是黑屏；
- 真实禁屏实测的标准前置动作变为「先 `--preflight`，通过再跑」，写入 `M1-Skeleton/README.md`。

---

## D-13 传输层落地形态：Network.framework QUIC datagram flow + 指纹钉死

**状态**：已实现并实测（2026-11-18，Tahoe / Intel 本机环回）。

### 背景

D-01 只定了「帧通道用 QUIC unreliable datagram」，没定在 macOS 上怎么实现。开工前存在
一个关键未知：Network.framework 是否会暴露 RFC 9221 datagram frame —— 若不暴露，就只能
退回裸 UDP 自建加密/握手，工作量与安全风险都会上一个台阶。

### 事实核对（先查 SDK 再写代码）

在 `Network.framework/Headers/quic_options.h` 中确认以下符号存在，均为 macOS 13.0+：

| 符号 | 用途 |
|---|---|
| `nw_quic_set_stream_is_datagram` / `nw_quic_get_stream_is_datagram` | 把连接标记为 QUIC datagram flow（每连接仅一条） |
| `nw_quic_set_max_datagram_frame_size` | 声明本端愿接收的单帧上限 |
| `nw_quic_get_stream_usable_datagram_frame_size(metadata)` | 握手后查询**协商出来的**可用载荷上限 |
| `nw_quic_stream_type_datagram` | stream type 枚举 |

⇒ 「Network.framework 不支持 QUIC datagram」的判断**不成立**，D-01 可按原设计实现，
TLS 1.3 由 QUIC 自带，无需自建加密层。

### 决策

| 编号 | 决策 | 落点 |
|---|---|---|
| C-13.1 | 帧通道 = Network.framework QUIC datagram flow；一次 `nw_connection_send(..., is_complete=true)` 即一个 datagram 边界 | `M1QuicTransport.sendDatagram:error:` |
| C-13.2 | TLS 身份用自签 p12（`gen_quic_identity.sh` 生成，`.state/` gitignore）；叶子证书 SHA-256 小写 hex 即 TOFU 指纹 | `peerCertificateSHA256` |
| C-13.3 | 指纹钉死由 `expectedPeerFingerprint` + verify block 实现；**不符时必须主动 `nw_connection_cancel`** | `M1QuicTransport.m` verify block |
| C-13.4 | 超过协商上限的 datagram 本地直接拒绝，不交给 QUIC 截断 | `sendDatagram:error:` 前置检查 |
| C-13.5 | 帧发送必须按帧节奏/拥塞窗口投递，禁止瞬时突发 | 见下方实测 |

C-13.3 的理由是实测出来的：只让 verify block `complete(false)` 时，QUIC 不会立刻进入
`failed`，客户端会一直吊在 `preparing`（实测 20s 仍无结论），上层无法向用户解释「为什么连不上」。
主动取消后拒绝在 12–25ms 内完成，并带出「期望/实际」指纹前缀。

### 实测结论（详见 `RESULTS-BY-OS.md` §5.5）

- 协商上限 1497B；1150B 分片留 23% 余量，安全。
- 2ms 节奏 400 帧：1200/1200 分片、1,219,200B **零丢失零重复零乱序零载荷错**，9.6 Mbps。
- **瞬时突发 1200 分片（7ms 内发完）：523 整帧丢失 = 43.6%**，零重复零乱序（纯拥塞丢弃）。
  ⇒ 发送侧必须按 `targetFps` 节奏投递；这也是 PROTOCOL §4「缺口→请求关键帧」存在的实证依据。
- 握手 p50 ≈ 17ms（10 次 13–84ms），偶发 6–11s 离群，疑为 QUIC Initial 重传退避，列入待查。

### 未决

- ~~偶发 6–11s 握手离群（UX 上等于「连接中卡住」），需在接控制通道前定位~~
  → **已定位并修复**：不是 QUIC Initial 重传退避，而是 p12 私钥的 keychain ACL 触发
  securityd 授权阻塞，`SecKeyCreateSignature` 卡在 `mach_msg`，服务端发不出
  `CertificateVerify`，客户端永停 `preparing` 且**无错误码**。修复后 13.5–19.3ms 稳定，
  10 轮无离群。详见 `RESULTS-BY-OS.md` §5.6 NEG-02。
- 双向并发（客户端也发输入帧）时 datagram flow 的单流特性是否成为瓶颈，待 M1-C 验证。

---

## D-14 控制通道的可靠性：datagram 之上自建 M1ControlLink

**状态**：已实现并实测（2026-11-18，Tahoe / Intel 本机环回）。

### 背景

M1-A 第 3 步要把 8 态状态机 + 控制帧（4B 长度前缀 + JSON）送上真实连接，并要求
「双端状态序列逐条一致、粘包/拆包在真 socket 上仍正确」。控制消息不能丢、不能乱序，
而 D-13 定的帧通道是**不可靠** datagram，所以先要回答：可靠性从哪来。

曾经的做法是开一条 QUIC 普通（非 datagram）流来承载控制消息，并把「本机 stream 模式
握不上手」当作既成事实写进了本节初稿。**该事实是错的**：那个现象与 stream/datagram
无关，是 NEG-02 的签名阻塞造成的（`M1_QUIC_FORCE_STREAM=1` 复核：stream 模式握手
64.6ms / 80.4ms 正常完成）。本节的立论已按真实约束重写。

### 事实

| 编号 | 事实 | 依据 |
|---|---|---|
| F-14.1 | 一个 `nw_connection` 只承载**一条** QUIC 流；SDK 不暴露 `nw_quic_create_stream` | `quic_options.h` 符号清单 + 实测 |
| F-14.2 | 故「可靠流 + 不可靠 datagram 共存于一条连接」在 Network.framework 上做不到 | 由 F-14.1 推出 |
| F-14.3 | 要一条可靠流，就得**再开一条连接** = 第二次握手、第二个端口、第二个指纹 | 由 F-14.1 推出 |
| F-14.4 | datagram 上自建 seq/ACK/重传在环回可用且稳定：控制帧 2–3 条/会话，零丢零重 | §5.6 |

### 决策

| 编号 | 决策 | 落点 |
|---|---|---|
| C-14.1 | 控制消息**走同一条 datagram 连接**，可靠性由 `M1ControlLink` 自建：14B 头（magic `'C'`/ver/kind/flags/seq/ack/payloadLen）+ 累计 ACK + 有界重传 | `M1ControlLink.m` |
| C-14.2 | 帧通道与控制通道**共用一个 datagram flow**，靠魔数分流：帧片 `'M'`(0x4D)、控制 `'C'`(0x43) | `M1FrameSender` / `M1ControlLink` |
| C-14.3 | 控制载荷上限 1200B（14+1200=1214 < 1497 协商下限），超长控制消息在 `M1ControlLink` 上层就报错，不做分片 | `M1ControlLinkMaxPayload` |
| C-14.4 | 重传默认 250ms × 8 次，耗尽即 `M1ControlLinkErrorUnacked` 让会话失败，不做无限重试 | `M1ControlLink` |
| C-14.5 | 分帧仍是 4B 大端长度前缀 + JSON，跑在 link 之上，与 PROTOCOL §3 一致 | `M1ControlChannel` |
| C-14.6 | **一个 p12 只导入一次，且导入到进程私有临时钥匙串**（见 NEG-02），否则握手会无错误码地永久卡住 | `M1CopyIdentity` |

选 C-14.1 而不选「第二条连接跑 stream」的理由：本产品是单端口单连接模型（一次握手、
一个 TOFU 指纹、一处 NAT 穿透），而控制消息量极小（每会话 2–3 条 + 1s 心跳），
自带 14B 头 + 重传的代价远低于维护第二条连接的生命周期与第二个端口的可达性。

### 代价与边界

- 如果 M2/M3 出现「大块、必须有序、必须可靠」的控制数据（例如文件传输、剪贴板同步），
  不该继续往 `M1ControlLink` 上叠：那时按 C-14.3 的边界另起一条 QUIC stream 连接更合适，
  代价是双握手。**这是一个明确的后续复核点**，不是禁止项。
- datagram 单流共享意味着控制帧和视频帧争同一个拥塞窗口。**已实测（2026-11-18，§5.7）**：
  1920×1080 20fps 推流下，两端控制心跳最大到达间隔 1033 / 1046 ms ≈ 心跳间隔本身，
  推流没有挤掉控制通道。但有一个前提条件必须写进实现约束——**收包回调里不能做重活**：
  帧重组/解码、PNG 编码若同步跑在 `nw_connection` 收包队列上，会直接把控制帧堵住
  （实测单次阻塞 1092 ms → 心跳断 4.5 s）。客户端实现必须把帧处理整体丢到独立队列。
  待复测：M1-C 双向并发（客户端也发输入帧）时的表现。

### 实现与验证

`M1MessageSink`（seam）← `M1ControlLink`（可靠性）← `M1ControlChannel`（分帧）←
`M1ControlSession`（8 态语义 + TOFU/配对码 + 心跳）。验收数据见 `RESULTS-BY-OS.md` §5.6：
5/5 轮、两进程通过、148 断言全过、握手 13.5–19.3ms。
C-14.2 的「共用一条连接」在 §5.7 做了跨进程推流验证：112 帧零丢弃、控制间隔 1033ms。

---

## D-15 VT 会话预热：把进程内一次性初始化挪出关键路径

**状态**：已实现并实测（2026-11-18，Tahoe / Intel 本机双进程环回）。

### 背景

M1-A 第 5 步要把首帧延迟打下来。原计划是「收到 SPS/PPS 就建解码会话，不等关键帧」，
复核后发现该前提不成立：H.264 的参数集本来就和关键帧同一个 sample buffer 出来，
没有提前窗口；`M1FrameReceiver` 也早已在拿到参数集时立刻建会话。

### 事实

| 编号 | 事实 | 依据 |
|---|---|---|
| F-15.1 | VT 会话的首次创建在**进程内是一次性**开销：首次解码 260–1110 ms / 首次编码 343–1377 ms，同进程第二次起 13–63 ms | `/tmp` 独立测量程序 + `RESULTS-BY-OS.md` §5.8 |
| F-15.2 | 该开销**与码流参数无关**：用不含 SPS/PPS 的裸 `CMVideoFormatDescriptionCreate(H264,w,h)` 也能建出解码会话并吃满这笔开销 | §5.8 表第 3 行 |
| F-15.3 | 该开销随系统冷热浮动（框架冷加载时最坏 1.1–1.5 s），不可预测 | 同上 |
| F-15.4 | 预热与首帧采集**抢资源时反而更差**：USER_INITIATED 下实测首帧 1814 ms > 不预热 1421 ms | §5.8 |

### 决策

| 编号 | 决策 | 落点 |
|---|---|---|
| C-15.1 | 两端各提供一个**进程级预热**入口，建一个空转会话立刻销毁，`dispatch_once` 保证一次、线程安全 | `+[M1VideoEncoder prewarm]` / `+[M1FrameReceiver prewarmDecoder]` |
| C-15.2 | 预热**不依赖真实码流/分辨率**，解码侧用裸 format desc 即可（F-15.2） | 同上 |
| C-15.3 | 预热必须跑在 **UTILITY 及以下**的后台队列，不能与握手/首帧采集同级（F-15.4） | `stream_probe` main |
| C-15.4 | 预热是**可选优化**，不得成为正确性前提：`M1_NO_PREWARM=1` 必须能完整跑通（用于 A/B 与排障） | 同上 |
| C-15.5 | 判定预热是否生效，看**两端建会话耗时**（确定性），不看端到端首帧延迟（被 SCK 出帧时机主导，噪声极大） | `decoderCreateMs` / `encoderSessionCreateMs` |
| C-15.6 | `-stop` 必须幂等且可并发：先把资源摘成快照再释放，禁止在同一指针上二次 `CFRelease` | `M1VideoEncoder` / `M1FramePipeline` |

### 代价与边界

- 预热本身要花掉那 0.3–1.5 s，只是挪到了「等客户端接入 / 握手」的空档里。若未来出现
  「进程起来就立刻推流、没有空档」的形态（例如常驻服务预建管线），预热要改成随管线
  生命周期复用，而不是每次进流前现预热。
- A/B 实测（3 轮 × 2 组，1920×1080）：解码建会话 271 → 60 ms，编码建会话 406 → 56 ms，
  端到端首帧 1140 → 783 ms。首帧延迟的中位数收益远小于两项建会话收益之和，因为该列
  被 SCK「只在画面变化时出帧」主导（静止桌面 2.4–3.1 fps vs 活跃 21.8 fps）。
- 预热只解决「首次初始化」，不解决「换分辨率重建会话」。分辨率变化仍走
  `rebuildFormatDescriptionWithParamSets:` 的重建分支，那一段未做预热。
- 帧头分片位宽不足的问题已按 **D-16** 修掉（v2，单帧上限 286 KB → 75 MB）。

---

## D-16 帧头 v2：分片序号扩到 16 位

**状态**：已实现并实测（2026-11-18，Tahoe）。

### 背景

D-15 验证时发现：3440×1440 的关键帧会超过 v1 帧头的分片上限，整帧发不出去
（`too many fragments (>255)`），客户端只能等下一个关键帧（2 s 间隔），
实测首帧 4069 ms。

### 事实

| 编号 | 事实 | 依据 |
|---|---|---|
| F-16.1 | v1 帧头 `fragIdx/fragCount` 各 1 字节 ⇒ 单帧上限 255×1150 ≈ 286 KB | `ProtocolCodec.m` 原实现 |
| F-16.2 | 3440×1440 关键帧会超过该上限，且**整帧**被拒（不是降级） | §5.8 实测 4069 ms / `sendFail=1` |
| F-16.3 | `CGDirectDisplayID` 实测可达 `0x78CD0400`（2026701824），**不能压成 16 位** | 本机 `CGGetActiveDisplayList` |

### 决策

| 编号 | 决策 | 落点 |
|---|---|---|
| C-16.1 | 帧头升 **v2**：18 字节，`fragIdx/fragCount` 用 uint16，单帧上限 65535 片 ≈ 75 MB | `P1FrameHeader` / `P1Pack/UnpackFrameHeader` |
| C-16.2 | `payloadLen` 上限保持 1150，分片预算不变（18+1150=1168 < 1497），**不动 MTU** | `P1FrameMaxPayload` |
| C-16.3 | 帧头版本独立于控制通道 JSON 的 `v`：新增 `P1FrameHeaderVersion`，控制协议仍为 v1 | `ProtocolCodec.h` |
| C-16.4 | v1 帧头一律 `BadVersion` **拒收**，不做双版本兼容：双端始终同版本构建，回退只会掩盖问题 | `P1UnpackFrameHeader` |
| C-16.5 | 排除「`displayID` 压 16 位保持 16B」方案（F-16.3） | — |

### 代价与边界

- 帧头 +2 字节，每片净载荷少 2 字节（1150 不变，故是头部预算多占 2B，仍远低于 1497）。
- **新旧二进制不兼容**：改完后所有链接 `ProtocolCodec` 的产物（六个探针 + RDPApp）必须重建，
  混跑会全部 `BadVersion` 失败。
- 上限从 286 KB 提到 75 MB 后，「分片过多」实际上不该再出现；`M1FramePipeline` 的
  连续失败告警保留，但语义从「分辨率太高」改为「编码器可能输出了损坏的超大帧」。
- 仍未处理：单帧越大，丢一片就整帧作废的代价越高。v2 只是解除了格式限制，
  并没有解决「大关键帧对丢包敏感」——那是 M1-C 的链路质量/前向纠错议题。

---

## D-17 M1-B 客户端上屏与输入回传

**状态**：已实现 + 单测通过（2026-11-18）；端到端验证待解锁执行。

### 背景

M1-A 打通了跨进程推流，但客户端只会把解码帧写成 PNG——能证明「画面正确」，
证明不了「能用」。M1-B 补两件事：画面实时上屏、键鼠操作回到主机。

### 事实

| 编号 | 事实 | 依据 |
|---|---|---|
| F-17.1 | 协议 §3.1 早已冻结 `input` 消息，`P1InputCodec` 也完整（构造/校验/限速），但 `M1ControlSession` 的分发里把它**静默忽略** | 原代码注释「其余类型（input / keyframe-*）属帧通道阶段」 |
| F-17.2 | `P1InputCodec.P1MakeInputMessage` 把 `displayID` 放在 `event` 内；`PROTOCOL.md` §3.1 写在消息层 | 两处读法不一致 |
| F-17.3 | 锁屏时 `SCShareableContent.displays` 为空，SCK 采集直接失败 | §5.9 实测 `该 displayID 不在 SCShareableContent.displays 中` |
| F-17.4 | AppKit 视图原点在左下，协议 y=0 在顶边 | 坐标必须翻 y，否则上下颠倒 |

### 决策

| 编号 | 决策 | 落点 |
|---|---|---|
| C-17.1 | 输入走**现有控制通道**，不开新通道：1000 event/s 上限对键鼠足够，且已经有 seq/ACK 可靠性 | `M1ControlSession sendInputEvent:` |
| C-17.2 | 输入只在 **STREAMING 态**收发；非 STREAMING 一律**静默丢弃并计数**，不 `failWith`——高频路径上丢几条不该把会话判死 | `sendInputEvent:` / `handleInput:` |
| C-17.3 | `displayID` 发送时**两处都带**，接收时 event 内缺失回落到消息层（F-17.2） | `M1ControlSession.m` |
| C-17.4 | 上屏用 `CIContext → IOSurface → layer.contents`（零拷贝），不用 `AVSampleBufferDisplayLayer`：后者要喂压缩 sample，会绕开 `M1FrameReceiver` 的解码统计 | `M1FrameView` |
| C-17.4b | **不用 `createCGImage` 贴图**：每帧一次 GPU→CPU 回读（3440×1440 BGRA=19.8 MB），实测 0.5–0.9 s/帧；改 `render:toCVPixelBuffer:` 后 10.4 ms/帧 | `M1FrameView presentPixelBuffer:` |
| C-17.5 | 画面转换在独立串行队列，只把 `layer.contents` 赋值回主线程；积压 >2 帧丢新帧 | `M1FrameView presentPixelBuffer:` |
| C-17.6 | letterbox 几何与坐标反算**共用同一组纯函数**（`M1AspectFitRect` / `M1NormalizedPointFromViewPoint`），避免「看到的」与「点到的」错位；落在黑边上的事件不产生输入 | `M1InputLogic` |
| C-17.7 | `keyUp` 不单独发：协议 `key` 无 down/up 位，Host 侧本就成对注入 | `M1FrameView keyUp:` |
| C-17.8 | 单机环回默认 `--inject record`（`M1RecordingEventSink`），真注入需显式 `--inject real` | `stream_probe` |
| C-17.9 | 修饰键走**状态同步**（变化时发全量 `flags`），不逐事件带 flags | `M1FrameView syncModifierStateIfNeeded` |
| C-17.10 | 视图构造时后台跑一次 16×16 空转转换，预热 `CIContext`——首次转换实测 623 ms，之后 3.3 ms，与 D-15 的 VT 会话同类 | `M1FrameView warmUpRenderPath` |
| C-17.12 | 窗口不可见（`occlusionState` 不含 Visible）时**不贴帧**并计入 `framesSkippedOccluded`：否则 `layer.contents` 赋值会被 CA 合成阻塞 0.3–3 s，把渲染队列堵死 | `M1FrameView` |
| C-17.13 | tracking area 用 `NSTrackingActiveAlways`（不能用 `...InKeyWindow`）+ 显式 `acceptsMouseMovedEvents=YES`：CLI 起的 App 常常拿不到 key window | `M1FrameView` / `stream_probe` |
| C-17.11 | 上屏正确性用**离屏自检**（喂已知图案、采样 `layer.contents`）而非只靠肉眼截图：颜色通道反转在截图里不容易发现 | `tools/render_selftest.m` |
| C-17.14 | 端到端驱动分流：`cursor_move ax` 判定 `AXIsProcessTrusted`，有授权用真光标（`physical`），没有则客户端用 `--input-synth` 进程内投 `NSEvent`（`synth`）。无授权时光标位移动得动但 `mouseMoved` 一条都不到，只看光标会误判成客户端没采集 | `verify_m1b.sh` / `stream_probe` |
| C-17.15 | 同一 `NSEvent` 会因「hit-test 视图 + tracking area owner 同体」被投两次，按**时间戳 + 窗口内坐标**去重，避免每次移动发 2 条上行 | `M1FrameView mouseMoved:` |
| C-17.16 | 第三种驱动 `--manual SECS`：代码只发「现在动鼠标」的信号（响 3 声 + 窗口标题倒计时 + `[manual]` 横幅），由真人操作。理由：`physical` 需要「窗口前台且人不碰鼠标」的窗口期、`synth` 缺 OS 投递一跳，而这一跳只有真鼠标能覆盖。判据放宽为「横向跨度 ≥ 画面宽 10%」，不判落点。实测人的反应延迟约 7 s ⇒ 未收到任何事件时每 5 s 再提醒一次 | `stream_probe --manual` / `verify_m1b.sh M1B_DRIVER=manual` |
| C-17.17 | 服务端监听必须显式指定端口（`nw_listener_create_with_port`）：`nw_listener_create(params)` 会忽略 init 传入的 port，实测 `--port 46600` 实际监听 61174。单机靠 `--port-file` 传端口不暴露，跨机（防火墙、人工抄写）必须固定 | `M1QuicTransport start` |
| C-17.18 | 跨机联调以 `--inject real` 为准，判据包含「主机光标位移 > 0」（`cursorMovedPx`）：`inputReceived` 只证明收到了事件，不证明 CGEventPost 真的生效（无 AX 授权时会静默失败） | `stream_probe` host 汇总 / `P2-Dual/p2.sh summary` |
| C-17.19 | glass-to-glass 不在没有测量手段时下结论。现有打点只覆盖「采集→编码→发出」与「收到→解码→上屏」，缺显示扫描与单程时延；三条候选测量路线见 `docs/P2-CHECKLIST.md` §7 | P2 延迟验收 |
| C-17.20 | 跨网段/NAT 联调时 host **只开一个入站 UDP 端口**（46600，或映射后的外部端口），不开 TCP；`--advertise HOST[:PORT]` 只改「给客户端的三项」展示、不改本地监听，外部端口与内部端口可不同，由 client 的 `--port` 指定。分片 18+1150=1168B，整包约 1.2 KB < 1500 MTU，不产生 IP 分片 | `stream_probe --advertise` / `P2-Dual/p2.sh P2_ADVERTISE` / `docs/P2-CHECKLIST.md` §1.1 |
| C-17.21 | 控制端换成 Sequoia 15.5 那台时，两端必须同一 commit 且各自本地构建（部署目标 13.0）；client 侧无 TCC 前置，host 侧仍需屏幕录制+辅助功能。`--inject real` 的 CGEventPost 授权按二进制 code requirement 记，`stream_probe` 用固定签名标识 `com.m1.pipeline`，重编不掉授权 | `build_stream_probe.sh` / `docs/P2-CHECKLIST.md` §3 || C-17.21 | 控制端换成 Sequoia 15.5 那台时，两端必须同一 commit 且各自本地构建（部署目标 13.0）；client 侧无 TCC 前置，host 侧仍需屏幕录制+辅助功能。`--inject real` 的 CGEventPost 授权按二进制 code requirement 记，`stream_probe` 用固定签名标识 `com.m1.pipeline`，重编不掉授权 | `build_stream_probe.sh` / `docs/P2-CHECKLIST.md` §3 |
| C-17.22 | 跨网段必须放宽等待窗口：host 等客户端 15s、client 握手 12s 都是同网段基线值，NAT/防火墙下容易假失败。`--wait-ms` / `--handshake-ms`（`P2_WAIT_MS` / `P2_HANDSHAKE_MS`）可配，本轮建议 60000/30000 | `stream_probe` / `p2.sh` |
| C-17.23 | 从 host 本机经公网 IP 回环连自己失败**不能作为映射失效的证据**（NAT 通常不支持 hairpin）；本环境 UDP 出向 STUN 也超时，无法从内侧确认。唯一判据是另一网段 client 实际握手 | `docs/P2-CHECKLIST.md` §1.1 |
| C-17.24 | 远程 SSH 接入**不引入第三方软件**，用系统自带 sshd：开「远程登录」+ `authorized_keys` + 一条 **TCP 映射**（建议外部 46601 → 192.168.10.23:22）。§1.1 的 UDP 46600 规则对 SSH 无效，这是「UDP 通了 SSH 连不上」的根因。加固只写 `/etc/ssh/sshd_config.d/200-p2-automation.conf`，`harden` 在 `authorized_keys` 为空时拒绝执行 | `P2-Dual/enable_ssh.sh` / `docs/SSH-SETUP.md` |
| C-17.25 | SSH 会话不在 Aqua 会话，`stream_probe` 的 SCShareableContent/CGEventPost 依赖 WindowServer；远程驱动 host 必须用 `launchctl asuser 501 sudo -u bemin` 包一层（`P2-Dual/gui-run.sh`）。TCC 授权弹窗无法从 SSH 应答，首次仍需在 GUI/屏幕共享里点掉 | `P2-Dual/gui-run.sh` / `docs/SSH-SETUP.md` §6 |
| C-17.26 | `--wait-ms 0`（`P2_WAIT_MS=0`）表示**无限等待**对端接入，host 可无人值守；实现用 10s 切片等待，每片打印「仍在等待对端…已等 Ns」，避免长时间无日志被误判为卡死。此时 `p2.sh` 把 `caffeinate` 提到 86400s，否则等一会儿屏睡就没帧 | `stream_probe` / `P2-Dual/p2.sh` |
| C-17.27 | 单客户端模型必须能**重新接入**：入站连接失败/取消时由子对象把父对象 `acceptedConnection` 置 nil（`parentListener` 弱引用 + `rearmParentListener`）。否则第一次握手失败后，后续所有重试都被 `nw_connection_cancel` 掉，表现为 host「一直在等、client 一直连不上」 | `src/M1QuicTransport.m` |
| C-17.28 | 连接失败日志必须带 domain+code+系统描述（`M1DescribeNWError`，含 tls 域）并与入站对端地址一起打印；只有 `-9858` 这种裸码无法定位是 TLS、MTU 还是被 RST | `src/M1QuicTransport.m` / `stream_probe.m` |
| C-17.29 | `p2.sh host` 启动前检查端口占用：p2.sh 被杀不会带走 `stream_probe` 子进程，残留进程会让下一次启动报 `监听失败：48` | `P2-Dual/p2.sh` |
| C-17.30 | 跨网段联调**两端必须同一 commit 且各自重建**：本轮上一次 `-9858` 与本轮成功之间的唯一实质差异就是 client 侧更新到同一 commit，握手即通过。排障顺序应先对齐 commit，再查 TLS/MTU | `docs/P2-CHECKLIST.md` §3 / 本轮 v0.29 |
| C-17.31 | P2.2 的「client 解码尺寸 = 请求规格」判据**只对独占会话成立**：client 用 `--spec WxH`（`P2_SPEC`）请求，host 在 `session-start` 里据此建虚拟屏；镜像模式不建屏、解码物理屏原始尺寸，尺寸不符不算失败。client JSON 记 `requestedWidth/Height/specMatch`，`p2.sh summary` 仅在 `sessionMode` 以 `exclusive` 开头时据此判 FAIL；`specMatch` 缺失按 FAIL 处理以强制两端 commit 对齐 | `stream_probe.m` / `P2-Dual/p2.sh` / `docs/P2-CHECKLIST.md` §4 |
| C-17.32 | `render_selftest` 的 letterbox 期望矩形必须用**独立公式**算，不能调被测的 `M1AspectFitRect`（自证循环）。档位至少覆盖两种受限方向：16:9 源在近 16:9 视图里**高度顶满**、超宽 3440×1440 在同样视图里**宽度顶满**。耗时是离屏纯转换基线（不含窗口合成），作回归护栏而非上屏性能结论，性能结论只认跨机 client `lastRenderMs` | `M1-Skeleton/tools/render_selftest.m` / 本轮 v0.33 |
| C-17.33 | 独占会话一旦建屏/禁屏成功，**所有退出路径都必须走 `endExclusive`**：握手超时、未知 `--inject`、无限等待模式下单次接入失败各有一条早退分支，漏掉就把机器留在黑屏态（守护只在异常退出时兜底）。`--wait-ms 0` 的单次失败要清掉 `virtualDisplayID` 再等下一次，避免拿旧 ID 采集 | `stream_probe.m` / 本轮 v0.34 |
| C-17.34 | C-09 不能只在日志里口头声明：`keep-main` 由 Coordinator 明确跳过校验，`c09Status` 必须是 `skipped-keep-main`；全禁模式只有 `startWithSpecs` 通过才记 `verified`。host JSON 同时落 `virtualDisplayIDs/activeDisplayIDsAfterDisable/sessionPhase/sessionRecovered`，`p2.sh summary` 对 `exclusive` 缺证据判 FAIL | `stream_probe.m` / `P2-Dual/p2.sh` / 本轮 v0.34 |
| C-17.35 | `p2.sh summary` 的解码门禁按场景分层：LAN 0% ≥0.98、LAN 0.1% ≥0.90、WAN（有 `advertisedEndpoint`）≥0.85、注入 ≥1% 只记趋势；另加帧丢弃 <5%、等待关键帧占比 <10%（以 `streamDurationMs` 为分母）、`keyframeRequestsSent>0` 而主机未收到则 FAIL。阈值仍是结构性判据，延迟结论另算 | `P2-Dual/p2.sh` / 本轮 v0.34 |
| C-17.36 | 独占会话即使 client 没传 `--spec`，也要用 `session-ready` 里 host 实际建的屏规格（`effectiveWidth/Height/effectiveSpecMatch`）核对解码尺寸；显式 `--spec` 优先。这样「不传参数跑独占」也有规格判据，而不是静默跳过 | `stream_probe.m` / `P2-Dual/p2.sh` / 本轮 v0.34 |
| C-17.37 | `keyframeRequestRttMs` 的口径是「本轮**首个成功过线**的 keyframe-request → 后续关键帧完整重组到达」，不含 VT 解码/上屏；同一等待周期的重复请求不重置起点，否则 1s 重试会把 RTT 越测越短。限流/发送失败不计时；周期关键帧无请求时不产生样本。只作观测，不设门禁 | `M1FrameReceiver.{h,m}` / `stream_probe.m` / `P2-Dual/p2.sh` / 本轮 v0.35 |
| C-17.38 | 目标平台为 **Intel x86_64 / macOS 13 Ventura – 26 Tahoe，双端均可当 host 或 client**（沿用 C-01）。所有构建保持 `-mmacosx-version-min=13.0`；14+ 的 SCK API 必须同时有 `@available(macOS 14.0, *)` 与 `#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 140000` 两道守卫，使只有 CLT 14.3.1 / 13.3 SDK 的机器也能本机编译。13 上仅关闭 HiDPI/采集分辨率增强，主流程不变；13 的 host 独占会话仍待真机回归（A-07），不得把「可编译」写成「已验证」 | `docs/DESIGN.md` §2.4.1 / `M1CapturePipeline.m` / `PipelineProbe.m` / `p0vprobe.m` |
| C-17.39 | 采集后端按**版本 + 能力**门控，不做全局替换：13 直接用 `CGDisplayStream`（本机 SCK/SkyLight `1003 The stream is nil` 为 OS 层故障），14+ 先用 SCK，content 获取 / addStreamOutput / startCapture 任一失败即回退 CGDisplayStream。两后端共用 `M1CaptureOutput` 的 `CVPixelBuffer` 出口，编码/分片/传输层零改动；`CGDisplayStream` 在 14 deprecated、15 obsoleted，故仅在回退路径保留，13/26 SDK 双编译并加局部 deprecation 抑制。诊断用 `M1_CAPTURE_BACKEND=cg|sck` 可强制。13 host 镜像与 `--keep-main` 虚拟屏全链路、真实输入注入、720p ~14.8fps 已 PASS（§5.27/§5.28）。**锁屏态专用第三条后端**：CGDisplayStream 在锁屏且屏亮时仍交付黑帧，`CGDisplayCreateImage` 能看到登录界面；故按 `CGSessionCopyCurrentDictionary()` 的锁屏键自动切到 `M1CGImageSource` 定时快照（BGRA CVPixelBuffer → 同一 `M1CaptureOutput`），解锁后恢复首选后端，`M1_CAPTURE_BACKEND=cgimage` 可强制；必须同时持有防显示睡眠断言（`M1RDPDriver` 已有 IOPM 断言）。13 锁屏 × Tahoe client 看见登录界面 + 定向键入已 PASS（§5.29）。完整独占禁屏/C-09 的阻塞已由 C-17.40 解决（§5.30） | `M1CapturePipeline.{h,m}` / `docs/RESULTS-BY-OS.md` §5.26–5.30 |
| C-17.40 | **macOS 13 独占会话的 WindowServer 崩溃是 ScreensharingAgent 显示流竞态，不是禁屏 API 不可用**：崩溃栈为 `DisplayStreamStateSW::CopyFrame → CGXDisplayStreamStart → _XDisplayStreamStart`（20:38/20:41）或 `layer_blit_byte_ANY`（22:10，守卫放得太晚），均发生在虚拟屏 mode 提交 / 禁屏重配置窗口。13 上用按进程 basename 精确匹配的 `SIGSTOP`/`SIGCONT` 短暂冻结 `ScreensharingAgent`，窗口**从 `createVirtualDisplays` 的 `createAll` 之前开始，到禁屏事务提交 + 1s settle 后结束**（只覆盖禁屏事务的版本实测无效）；建屏失败、keep 为空、无需禁屏、恢复物理屏与 guardian 异常兜底都必须解冻。`M1_C09_QUIESCE_SS=0` 可关闭，26/Tahoe 不生效；不卸载/禁用屏幕共享服务，冻结期间屏幕共享短暂停顿。13 host × 26 client LAN 720p15 实测 C-09 `verified`、active 仅虚拟屏、WindowServer 未重启、物理屏与 5900 均恢复，`p2.sh summary` PASS（§5.30） | `M1RDPDriver.m` / `P0VDisplayControl.{h,m}` / `docs/RESULTS-BY-OS.md` §5.30 |
| C-17.41 | **C-09 剩余边界按 OS 分离收敛，不与 C-17.40 混淆**：Ventura 13 / iMac-3 上 1280×720 独占 C-09 稳定 PASS，但 ① 1920×1080 独占的 mode-commit 后 WindowServer 崩在 `layer_blit_byte_ARGB8_ARGB8_RGB8`（SIGBUS），与已修的 `CopyFrame` 竞态是两条独立问题，`M1_C09_QUIESCE_SS` 无效——判为该机型 OS 层边界，1080p 独占不重试、不外推；② 建屏 mode-commit（约 1.4–1.6s）会阻塞控制通道 ACK，8×250ms 重传窗口踩线可使客户端提前放弃（健康态 r3 未触发）；③ 连续 mode-commit 使 WindowServer 显示栈累积不稳定，崩溃后重启的 WS 进程在后续 720p 建屏时再次崩于 `layer_blit_byte_ANY`——真机纪律：崩溃后须充分恢复再测，不可连续重试。独占态 Path A（V-04d 等价）与多屏独占仍未覆盖。`P2_SAVE_FRAMES` 仅为 harness 可选参数，产品代码未动 | `docs/RESULTS-BY-OS.md` §5.31 |
| C-17.42 | **健康态独占全链路 PASS，且「连续建屏必崩」结论被修正**：iMac 充分恢复后 13 host × 26 client 1280×720 独占 C-09 再次全链路 PASS（C-09=verified、511 帧解出/0 丢弃、8 张 PNG、WS PID 未变），说明 C-17.41③ 的累积不稳定不必然，真机纪律仍为「崩溃后充分恢复再测」但不得据此否定健康态结果。建屏阻塞 ACK 用两个默认关闭的诊断开关 `M1_CTRL_RETRY_MS`/`M1_CTRL_MAX_ATTEMPTS` 缓解（r4 设 500ms×16，控制到达间隔 1018ms 未踩线）。**独占态 Path A（V-04d 等价）根因从「OS 崩溃」改为「API 上下文限制」**：`SACLockScreenImmediate` 必须在 Aqua/GUI session 调用（SSH 进程调用静默无效），且在物理屏全禁的独占态下不生效——r4 独占态 lock 返回 ok 但 `screenIsLocked` 仍 false、登录 UI 未呈现；镜像模式 §5.29 成功是因物理屏仍在。⇒ 独占态要成立需另找锁屏/登录窗触发路径（Tahoe V-04d 由「零 active 物理屏」自动触发，13 上是否自动发生未验证）。产品代码未动 | `docs/RESULTS-BY-OS.md` §5.32 |
| C-17.43 | **挂起判定必须有界，且 Path A 的失效变量是调用上下文不是独占态**：①`P0VPerformTransactionV` 的收敛判据 `verify()` 本身就是 WindowServer IPC，真挂起时会永久阻塞，导致「8s 软死线 + 12s 宽限」永远走不完、熔断不触发——改为 `P0VProbeVerify`：把探活 IPC 与 verify 放进**同一个 1s 有界窗口**，窗口内无响应即判 `ws-unresponsive` 并立即熔断，不等满宽限。口径：`wsfreeze`（WS 不可响应）实测 8.3–9.3s 熔断，满足 NFR-06；`hang`（WS 正常但事务线程卡死）20s（8s+12s）熔断，是为兼容真机 8.3–10.0s 慢提交付的代价，两者都不会无限阻塞。故障注入用 `P0V_FAULT_TX=hang\|wsfreeze`（事务线程不返回且不提交配置，物理屏不受影响），不以人工冻结 WindowServer 做验收（会连带崩显示栈）。三机（26/14/13）normal 0.01–0.02s、wsfreeze 9.26–9.27s、hang 20.15–20.19s，熔断后新事务 code 10 即时拒绝。②**纠正 C-17.42 的 Path A 结论**：把调用上下文固定在 Aqua（GUI Terminal）后，独占态（active 仅会话虚拟屏）`SACLockScreenImmediate` 返回 0 且 `screenIsLocked=1`，1280×720 截图完整呈现登录界面（头像/密码框），推流未中断——原 r4 失败是 wrapper 不在 Aqua session，与独占态无关。③新边界：锁屏态（`loginDone=1` 且 secure input 生效）下 `CGEventPostToPid` 键入被丢弃，远端解锁需 HID 级或认证插件；登录窗态（`loginDone=0`）键入仍成立（§5.29）。④多屏独占的判定不能用单物理屏外推：用「1 物理 + 1 外部虚拟屏（独立进程持有）」验证禁屏集合 = active − 本会话虚拟屏、打开关两块、收尾两块都恢复；双物理屏的 mode-commit 时序仍未覆盖 | `P0V-DisplayIsolation/src/P0VDisplayControl.m`、`Scripts/tests/{tx-breaker,multi-display,patha}`、`docs/RESULTS-BY-OS.md` §5.49 |

### 代价与边界

- 上屏路径是 `CIContext → IOSurface → layer.contents`（零拷贝），离屏实测 10.4 ms/帧
  @3440×1440、1.1 ms@640×360；更早的 `createCGImage` 版本单帧 0.5–0.9 s，已废弃。
- `CIContext` 首次转换 623 ms 属全系统 GPU 管线冷启动，预热只能在进程内提前，
  跨进程/重启后仍需再付一次。
- 客户端不做本地节流：1000 Hz 鼠标会先把控制通道塞满再被 Host 丢弃。M1-C 再改。
- 环回时窗口会被自己采集进去，出现「画中画递归」，是预期现象。
- 端到端判据已通过（`synth` 驱动，2026-11-19 早晨：29 帧上屏 + 3 次移动的 x 全部落在
  预期位置）。**`physical` 驱动与主机真注入未验证**：两者都要求宿主进程
  `AXIsProcessTrusted=1`，属授权前置而非代码问题，列入双机验收。
  若单机无法稳定解锁，判据并入双机验收（届时窗口在另一台机器上）。

---

## D-18 项目命名：Veil Remote Desktop（简称 VeilRD）

**日期**：2026-11-23　**状态**：已定（用户确认）

### 决定

- 正式名：**Veil Remote Desktop**
- 简称：**VeilRD**
- 中文名：**帷幕远程桌面**
- 定位语：**远端熄屏，眼前如本地——为 Intel Mac 打造的独占式远程桌面**

### 理由

- **一眼懂用途**：名字里保留 Remote Desktop，不需要背景知识就知道是远程桌面工具；纯意象名（如只叫 Veil）牺牲了可发现性。
- **一眼懂差异**：Veil 表示「把被控端物理屏遮住，只在客户端升起按客户端规格定制的虚拟桌面」，直接区别于 VNC 镜像（C-07）与 Windows RDP 多会话（C-08）。
- **不用 `VeilRDP`**：RDP 会被读成微软协议或多会话实现，与本项目单会话模型冲突。

### 影响与边界

- 人类可读文档标题（`DESIGN.md` / `PROTOCOL.md` / `RESULTS-BY-OS.md`）与项目自称改为 VeilRD；`DESIGN.md` §1.1 / §1.3 / 变更记录同步。
- **本次不改名**：仓库目录与路径占位（`<macOS-RDP>`、`~/macOS-RDP`）、代码标识符 / 类名 / 二进制名、既有钥匙串条目 `CN=macOS-RDP M1 dev`。改名会破坏构建脚本、实测资产与证书匹配，收益仅为文案；若后续要统一 CLI / 产品二进制名，另立决策并配套迁移。
- 各子工程 README 保持组件名（P0-TahoeProbe、M1-Skeleton 等），不强行改成 VeilRD。

---

## D-19 源码分层归位与兼容软链

**日期**：2026-11-23　**状态**：已执行（第 2 轮工程骨架）

### 决定

- 把 `M1-Skeleton/src/` 的 23 个模块物理迁到 `Packages/RDPKit/Sources/{Common,Capture,Codec,Frame,Transport,Control,Display,Input}/`，把 `P1-ClientProbe/src/` 的 4 个模块迁到 `Packages/ProtocolCodec/Sources/`；`.h`/`.m` 同目录放置，裸文件名 `#import` 不变。
- Xcode 三个 target 的文件引用改指向 `Packages/` 真实路径，`HEADER_SEARCH_PATHS` 补齐各分层目录；PBXGroup 按 Apps / Packages / Probes 与 RDPKit 子层组织。
- 旧 `src/` 路径保留为**相对软链**（不是副本），覆盖全部 53 个文件（45 个 RDPKit + 8 个 ProtocolCodec）；12 个既有构建脚本与双机 runbook 路径不改。

### 理由

- 分层按职责而非按历史探针目录：采集、编码、帧通道、传输、控制、显示、输入各自独立，便于后续拆库与替换后端（C-10 / D-10）。
- 真机验收仍在进行，脚本与 runbook 里满是 `cd ~/macOS-RDP/<dir>` 与 `src/` 相对路径；此时硬切路径会让测试资产失效，收益不抵风险。软链让「物理归位」和「路径兼容」同时成立。

### 影响与边界

- 软链是**过渡兼容层**：P2 延迟验收结束后统一迁移脚本与 runbook 路径，再删除软链；在此之前禁止向旧 `src/` 目录新增文件，新增模块必须写进 `Packages/`。
- 本轮不改任何算法、类名、构建参数与测试断言；未跑双机真机，符合开发与测试分离约定。
- 验收线：三个 target `BUILD SUCCEEDED`，`M1-Skeleton/build_tests.sh` 与 `P1-ClientProbe/build_tests.sh` 断言数不回退，M1-Skeleton 推流探针仍能从旧路径构建。

---

## D-20 产品入口归位与静态库分层

**日期**：2026-11-23　**状态**：已执行（第 3 轮工程骨架）

### 决定

- `VeilRD.xcodeproj` 由三个「壳 + 探针入口」target 改为五个 target：`RDPKit`、`ProtocolCodec` 为静态库，daemon / agent / client 为可执行入口，通过 target 依赖与 Frameworks phase 链接两库。
- 三个入口的物理源码归位：`P0V-RootDaemon/src/p0vprobe.m` → `Apps/HostDaemon/Sources/main.m`；`RDPApp/Sources/main.swift` 与桥接头 → `Apps/Client/Sources/`；`Apps/HostAgent/Sources/main.m` 从纯逻辑演示改成实际消费采集/编码/会话/输入模块。
- 新增 `Tests/integration_selftest.sh`，由 `Scripts/test.sh` 聚合：构建全部 target 后运行三个入口的纯逻辑自检。
- 旧 p0vprobe 与 Swift 壳路径保留相对软链；`RDPApp/build.sh` 扩充模块与框架以继续可用。

### 理由

- 第 2 轮只解决「源码放哪」，产物仍是探针入口；第 3 轮把产品目录与编译产物对齐，避免骨架长期停留在占位态。
- 静态库把「可复用逻辑」与「可执行入口」在构建层分开，后续替换采集后端或客户端渲染时不必重编入口依赖图。
- 默认自检不碰 WindowServer / 网络，保持开发与真机测试分离；真实采集只在显式 `--capture` 下启用。

### 影响与边界

- 本轮不改协议、不新增真机结论；QUIC 收流与真实窗口上屏仍在 `stream_probe`，未并入 `VeilRD` 客户端入口。
- `RDPKit` 静态库包含全部 22 个 `.m`，`ProtocolCodec` 含 4 个；三个入口只编自己的 main 文件。
- 验收：五个 target 构建成功；M1 291 断言、P1 全 PASS、跨模块自检 PASS；`build_stream_probe.sh`、`RDPApp/build.sh`、`P0V-RootDaemon/build.sh` 仍可从软链构建。
- 打包 / 签名 / plist / TCC 说明仍未做，留待 P2 后的真机验收。

---

## D-21 共享流会话节点层与产品端直接对连

**日期**：2026-11-23　**状态**：已执行（第 4 轮工程骨架）

### 决定

- 把 `M1-Skeleton/stream_probe.m` 内的 QUIC / 控制链路 / 会话状态机 / 重组解码节点抽成共享模块 `Packages/RDPKit/Sources/Session/M1StreamSession.{h,m}`，新增 `RDPKit/Sources/Session` 分层与 `M1StreamNode`、`M1StreamClientNode` 两个类；探针改为消费该模块（探针只保留 CLI、独占显示、窗口与输入装配）。
- `veild-host-agent --serve` 实现真实 QUIC 监听 + 会话协商 + 独占建屏 + 采集推流 + 输入回传（keyframe / frame-nack 一并接线），可与客户端直接对连。`VeilRD --connect` 实现 QUIC 收流 → `M1FrameReceiver` 重组解码 → `M1FrameView` 上屏 → 归一化输入回传；`--selftest` 保留为无网络自检。
- 节点层把身份路径 / 口令 / ALPN 从探针全局变量改成实例属性（默认与探针一致），A-02 时钟同步探针仍在客户端进入 STREAMING 后发出，采集点未变。
- 新增 `Tests/stream_session_selftest.m`：环回建链 + 控制会话 + 时钟探针自检，不需要屏幕录制 / 辅助功能授权；由 `Tests/integration_selftest.sh` 编译并运行。
- 把 `VeilRD.xcodeproj` 的生成脚本收进仓库 `Scripts/generate_xcodeproj.py`；新增模块必须改生成器再重跑，不手改 pbxproj。RDPKit 静态库增加 Session 层与三个平台源文件（`P0VDisplayControl` / `VDManager` / `ProbeUtil`），供 `M1RDPDriver` 解析符号。

### 理由

- D-20 后两个产品入口仍只跑自检，真实端到端链路只在探针里；若直接把 1900 行探针复制进产品会形成两份协议实现，后续修 bug 必然漂移。
- 抽层后「会话如何建链、控制帧如何优先、丢片如何补」只有一份实现；探针作为诊断入口保留原有 CLI 与真机判据，产品入口可复用而不复制。
- 环回自检能在纯开发轮次证明协议层没有回退，不必等到夜间真机；它刻意不采集、不注入，不与「开发测试分离」冲突。

### 影响与边界

- **未跑双机真机**：`--serve` / `--connect` 的对连尚未在两台物理机上做采集→上屏→注入验收；本轮只验证环回建链与既有单测，真机按约定放夜间，结论按 OS 分离写入 `RESULTS-BY-OS.md`。
- 探针 CLI 与真机判据不变；`M1-Skeleton/build_stream_probe.sh` 增加 Session 源与头文件路径，旧双机 runbook 命令不动。
- 验收：5 个 target 构建成功；M1 291 断言 / P1 全 PASS / 跨模块自检 PASS；环回自检双端 STREAMING、控制包 5/5、时钟样本 ≥1；三套旧构建脚本仍成功；56 条兼容软链无悬空。
- 打包 / 签名 / plist / TCC 说明、钥匙串 CN 统一仍未做，留待 P2 后的真机验收。

---

## D-22 多屏：按 displayID 的接收器/帧序号/控制路由

**日期**：2026-11-23　**状态**：已执行（M2 多屏，FR-01/FR-05）

### 决定

- **帧层不改格式**：v3 帧头已带 32 位 `displayID`，多屏只改变消费方式——Client 按帧头
  `displayID` 把 datagram 分流到各自串行帧队列，每屏一个 `M1FrameReceiver`（各自重组、解码、
  请求关键帧/补片）；Host 每块虚拟屏一条 `M1FramePipeline`，`frameSeq` 各自从 0 起。
- **控制面贯通 displayID**：`keyframe-request` / `frame-nack` 载荷新增 `displayID`，
  `M1ControlSession` 委托与 `M1StreamSession` host 回调都带该参数；限流表由单个时间戳改成
  `displayID → 时间` 字典（关键帧 300ms/屏、补片 5ms/屏）。
- **兼容语义**：Client 侧 `displayID=0` 在写线时回落到 `session-ready` 首屏（旧调用方行为不变）；
  Host 侧 0 表示全部管线（旧单屏客户端），未知非 0 ID 忽略并计数。
- **规格上限**：`capabilities.maxDisplays` 由 1 提到 8；`session-start.specs.count > 8` 回
  `SPEC_UNSUPPORTED/recoverable:false`，避免无界建屏。
- **输入按屏**：`M1InputInjector.displayRects` 用每块推流屏的 `CGDisplayBounds` 换算归一化坐标；
  多屏下未知 displayID 的鼠标事件拒绝注入（其它类型回落默认屏）。
- **产品入口**：`veild-host-agent --serve` 独占模式为全部虚拟屏各建管线并聚合 JSON（顶层字段保留，
  新增 `displays[]`）；`VeilRD --connect` 支持重复/逗号分隔的 `--spec`/`--window`，每屏一窗，
  `M1FrameView` 绑定 displayID，输入按所在窗口的屏回传。

### 理由

- `P1FrameReassembler` 内部锁定单个 `activeDisplay`，天然是「单屏重组器」。与其把它改成跨屏状态机，
  不如按屏各建一个实例：缺口判据、补片缓存、解码器状态都保持既有单屏语义，回归风险最小。
- 各屏独立序号空间后，某块屏丢帧不会让其它屏的序号判据误判；限流按屏独立，一块屏的静止/抖动
  不会饿死另一块屏的关键帧请求。
- 帧头与控制消息都只加字段、不改布局，探针/旧单屏路径可继续按 0 语义工作。

### 影响与边界

- **真机多屏已验证（2026-11-24）**：Tahoe 26.5.2 host × Sequoia 15.5 client（WAN，2×1280×720@15，`3e18538`），keep-main 与全独占两档均 PASS——keep-main client 138/138 解码上屏、`c09=skipped-keep-main`；独占 `c09=verified`、client 981/981 解码上屏、0 丢帧、窗口布局 7/7 恢复、物理屏在位。详见 `RESULTS-BY-OS.md` §5.39；输入按屏注入仍由单测覆盖，真机未操作。
- 多屏的带宽/CPU 预算未做门禁：每屏 20fps 编码目标，合计速率受同一 QUIC 发送窗口与节拍约束；
  发送队列满时按 `sendDatagram:error:` 现有语义丢帧，不新增跨屏优先级。
- PNG 证据文件在多屏时命名为 `frame-d<displayID>-NNN.png`；单屏维持原名。
- 验收：五 target 构建成功；M1/P1 单测全 PASS（含新增 `kf-displayid-preserved` /
  `nack-displayid-preserved` / `inject-multi-*`）；`stream_session_selftest` 双屏会话 PASS。

---

## D-23 M2 动态协商（FR-07）与完整输入（FR-06）

**日期**：2026-11-24　**状态**：已执行（M2 收尾）

### 决定

- **换屏不改状态机**：新增 `session-update`（C→H）/ `session-update-result`（H→C）两条消息，
  只在 STREAMING 内有效；失败回 `ok:false` 而**不结束会话**。不引入新状态，旧端遇到未知 type
  直接忽略（控制通道既有语义），协议升 v1.4。
- **Host 事务顺序固定为「先建新、验可见、再销毁旧」**：`M1RDPDriver replaceVirtualDisplays:`
  用独立 `VDManager` 建齐新屏并逐个确认在 active list，才销毁旧屏；任一步失败只销毁新屏，
  旧屏与旧管线原样保留。协调器在换屏后隔离校验（C-09）失败时自动回滚旧规格；
  `HostAgent` 侧的管线重建同序（retire 旧管线 → 建新 → 失败则重启旧管线并回滚规格）。
- **Client 重绑而不是重连**：结果 OK 后 `DisplayRouter.reset()` + 按新屏表重建/关闭窗口，
  会话、解码器注册表、控制通道全部不动；结果失败保持原窗口与解码器。
- **IME 走「提交文本」而非按键重放**：`M1FrameView` 实现完整 `NSTextInputClient`，
  本地组字用 CATextLayer 子层显示（主 `layer.contents` 每帧被画面覆盖，不能复用），
  `insertText:` 以新增的 `kind:"text"` 事件发送整串文本（≤256 UTF-16）；Host 用 keyCode 0
  承载 unicode 整串注入，目标应用按文本插入，不在 Host 端重走输入法。Cmd/Ctrl/Opt 组合
  一律视为快捷键，不发 unicode。
- **修饰键按 HID 逐键迁移**：Host 对 `flags` 事件不再只发全量掩码，而是按 caps(57)/shift(56)/
  ctrl(59)/opt(58)/cmd(55) 逐键补 `flagsChanged`（先释放后按下）；未知位回落全量掩码。
  非 flags 事件发送前先对齐修饰键状态，避免远端残留 Cmd 把后续按键变成快捷键。
- **沉浸模式纯客户端**：`Cmd+Opt+F` 切换每屏一个 borderless 窗口 + `presentationOptions`
  自动隐藏 Dock/菜单栏，退出时恢复窗口样式与 frame；不改协议、不动 Host。

### 理由

- 不新增状态、失败不动会话，是「远程桌面正在用」场景的最低破坏原则：换屏是增强操作，
  不能因为一次 8K 越界请求把整个连接掀翻。
- 先建后拆与 C-09 的守卫口径一致（「任何时刻至少一块可用显示」）；回滚路径只有一条
  （重新应用旧规格），可测试、可审计。
- 文本直传避免「客户端输入法 → 按键序列 → 主机输入法」的双重组字，中日韩输入在
  主机端不依赖其输入法状态；快捷键在客户端拦截也符合本地直觉。
- 逐键修饰迁移修复了「全量掩码在真实 HID 层不生效」的兼容问题，且对旧 Host 兼容
  （全量掩码仅作未知位的兜底）。

### 影响与边界

- `--update-at MS --update-spec WxH`（可重复/逗号）供诊断与真机验证；产品 UI 暂未暴露入口。
- `M1ControlSession` 规格校验上限：1..8 屏、边长 2..8192，与 capabilities 一致；
  `session-start` 与 `session-update` 共用该校验。
- 换屏后新屏的 `frameSeq` 从 0 起、`displayID` 全新，客户端必须等新关键帧（结果回包后
  路由器清空旧视图即满足）。
- 验收：单测 341 项全 PASS（新增 `upd-*` 14 项、`plan-text-*` 5 项、`mod-*` 6 项）；
  五 target 构建成功。真机结论见 `RESULTS-BY-OS.md` §5.42（FR-07 keep-main 2→1 与 FR-06
  真机文本注入均 PASS；沉浸模式真机目测待补）。

---

## 附：协议实现进度（2026-11-17）

| 模块 | 状态 | 测试 |
|---|---|---|
| 控制通道帧（4B 长度前缀 + JSON） | ✅ 完成 | 含粘包/逐字节拆包/零长度前缀/坏版本等 18 项 |
| 帧头 16B pack/unpack | ✅ 完成 | 字节序、magic、fragIdx 越界、payloadLen 上限等 9 项 |
| 分片 / 重组 / 丢帧判据 | ✅ 完成 | 3000B→3 片、seq 缺口、中间片先到、双屏交错等 12 项 |
| 输入事件编解码（§3.1） | ✅ 完成（2026-11-18） | 鼠标/键/滚动/flags 四类、IME unicode、修饰键全量状态、1000 event/s 限速（超限只丢 move/scroll）；34 项断言 |
| 信令状态机（§2） | ✅ 完成（2026-11-18） | 8 态迁移表、STREAMING 输入门控、SUSPENDED→NEGOTIATED 重连、CLOSED 终态；37 项断言 |
| QUIC 数据报端到端 | ✅ 完成（2026-11-18，本机环回） | `quic_probe`；协商上限 1497B、1150B 分片零丢零乱序；突发丢 43.6% |
| 分片上限 1150 B | ✅ 完成（2026-11-18） | `P1FrameMaxPayload` 由 1200 下调为 1150，帧头校验与分片器共用，单测含头空间校验 |
| 输入回传（input 收发 + 注入） | ✅ 代码完成（2026-11-18） | `sendInputEvent:` / `didReceiveInputEvent:` + `M1FrameView` 采集 + `M1InputInjector` 注入；单测 193 项全过，端到端待解锁 |
| 帧头 v2（分片序号 16 位） | ✅ 完成（2026-11-18） | 18B 帧头，单帧上限 65535 片；400 片大帧重组逐字节一致、256 片合法、65536 片仍拒发；3440×1440 推流 `sendFail=0` |
| 控制通道可靠性（datagram 上自建） | ✅ 完成（2026-11-18） | `M1ControlLink`：14B 头、累计 ACK、250ms×8 重传、乱序持有、去重；`control_probe` 实 socket 验证 |
| 控制通道分帧 + 会话语义 | ✅ 完成（2026-11-18） | `M1ControlChannel` + `M1ControlSession`：8 态、TOFU/配对码、心跳、synthetic 显示占位；148 断言全过 |

代码：`P1-ClientProbe/src/ProtocolCodec.{h,m}`、`P1InputCodec.{h,m}`、`P1SessionState.{h,m}`；
测试 `P1-ClientProbe/tests/test_protocol.m`、`test_input.m`、`test_session.m`，
运行 `cd P1-ClientProbe && bash build_tests.sh`（当前 140 个断言全过、零警告）。
