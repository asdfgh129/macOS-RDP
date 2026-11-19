# P2 下一阶段实施计划（2026-11-19 跨公网实测后拟定）

依据：`docs/RESULTS-BY-OS.md` §5.13（含补测 C/D）与 `docs/P2-CHECKLIST.md`。
本轮已确认：跨公网链路（握手/控制/视频/解码/上屏/输入回传）结构成立，Tahoe 26.5.2 host × Sequoia 15.5 client。
本文件只回答一件事：**下一步先做什么、做到什么程度算完成**。

---

## 1. 实测暴露的三个缺口

| # | 缺口 | 证据 | 影响 |
|---|---|---|---|
| G1 | 接收端严格按序重组，丢/乱一片即整帧作废，且**不发关键帧请求**，只能等 host 每 2s 的周期关键帧 | `P1FrameReassembler` 在 `fragIdx` 不连续时立即 `needsKeyframe`（`P1-ClientProbe/src/ProtocolCodec.m:302-333`）；client 的 `onNeedKeyframe` 只加计数（`M1-Skeleton/stream_probe.m:404-408`），wire 上没有 `keyframe-request`；host 侧 `M1VideoEncoder requestKeyframe` 已可用 | 跨公网 720p15 只解出 **136/443（0.31）**，3440×1440 只解出 **7/391（0.02）**；丢包只是一片，停顿却是一个关键帧周期 |
| G2 | P2 工具绕过会话层：host 采物理主屏，client 开普通窗口 | host 默认 `CGMainDisplayID()`（`M1-Skeleton/stream_probe.m:632`）；`M1SessionCoordinator`/`M1RDPDriver` 的建虚拟屏+禁物理屏只被 `pipeline_kiosk_probe` 使用 | 控制端看到的是**物理屏镜像**，不是按客户端规格新建的桌面；与 FR-00/FR-01、C-07 不一致 |
| G3 | 高质量档渲染吃满：Sequoia 3440×1440 单帧 84.7ms；1080p 也接近 20fps 预算 | Run A/C 的 `lastRenderMs` 84.7 / 峰值 199.5；720p 档 16.6–83.8ms 波动 | 高分辨率档在客户端先卡死；与 G1 独立，不能混在一起归因 |
| G4 | 指标口径有误导 | `framesDropped` 在等关键帧期间按 **datagram** 累加（`M1-Skeleton/src/M1FrameReceiver.m:208`），出现 1559 > 443 | 失败表/阈值容易被误读，回归时无法判断是真丢帧还是等待期计数 |

---

## 2. 阶段与顺序

**顺序：P2.1 可靠性 → P2.2 会话形态 → P2.3 渲染/指标收尾。**
理由：P2.1 是协议层小改动、收益最大，且不改显示层就能验证；P2.2 会引入私有 SPI、禁物理屏与 TCC/A-08 变量，若与 G1 同期做，失败原因无法归因。P2.3 只在 P2.2 需要 1080p 档时才成为门槛。

### P2.1 视频可靠性：乱序容错 + 关键帧请求（第一优先）

| 步骤 | 内容 | 文件 |
|---|---|---|
| 1.1 | `P1FrameReassembler` 改按帧缓存：每帧 `fragIdx` 位图 + 分片暂存，允许乱序/重复/交错到达；整帧齐才交付 | `P1-ClientProbe/src/ProtocolCodec.{h,m}` |
| 1.2 | 帧截止时间（默认 120ms，可配）：超时才判丢帧、置 `needsKeyframe`；同时淘汰旧帧，内存上限 2–4 帧在飞。真丢片仍不可解码 → 必须请求关键帧，**不假装能恢复** | 同上 |
| 1.3 | 打通 `keyframe-request`：client 在 `onNeedKeyframe` 发送 `{"type":"keyframe-request","displayID":N}`（限速 ≥300ms），host 收到后 `[pipeline requestKeyframe]`；`M1ControlSession` 增加该消息分发与 delegate | `M1-Skeleton/src/M1ControlSession.{h,m}`、`stream_probe.m` |
| 1.4 | 指标修正：`framesDropped` 只计帧；新增 `fragmentsDiscarded`、`awaitingKeyframeMs`、`keyframeRequestRttMs`，`p2.sh summary` 用帧口径 | `M1FrameReceiver.{h,m}`、`stream_probe.m`、`P2-Dual/p2.sh` |
| 1.5 | 可重复验证：host 增加 `--sim-loss PCT [--sim-reorder PCT]`（发出前按 PRNG 丢弃/延迟），环回即可复现 WAN 行为；补单测（乱序、重复、缺尾片、超时、跨帧交错、换屏、请求限速） | `stream_probe.m`、`M1-Skeleton/tests` |

**完成判据（2026-11 按实测修订）**

无 FEC/分片重传时，一帧的存活率随分片数指数衰减：720p IDR ≈360 分片、P 帧 ≈50 分片。
环回实测（Sequoia 15.5 / Macmini8,1，1280×720，捕获上限 ≈7.5fps）：

| 丢片率 | 解码/发出 | 说明 |
|---|---|---|
| 0% | 83/83 = 1.00 | 基线 |
| 0.1% | 107/112 = 0.955 | 稳定，P2.1 门禁 |
| 1% | 15/112 = 0.13 | 任一 P 帧丢片即触发重新取 IDR；IDR 存活率 ≈2.7%，恢复靠反复重试 |
| 5% | 0/117 | IDR 存活率 ≈1e-8，不可达 |

- 单测全过（含新增重组/乱序/重复/超时/限速用例）。
- 环回 720p15/30s：**0% ≥0.98、0.1% ≥0.90**；`awaitingKeyframeMs` 占比 <10%；请求确实到达编码器（host key 计数 > 周期基线）。
- 1% 与 5% 只作趋势记录，不作门禁；5% 的 0.95 判据在无 FEC 下不可实现，已删除。
- 跨公网 720p15/30s：解码/发出 **≥0.85**（前提是端到端丢片率 ≲0.1%），`sendFailures=0`，控制间隔 <3s。
- 1% 档要达标需 FEC 或分片重传，单列为 P2.1-FEC 候选，见 §3。
- 3440×1440 档不再出现 0.02 级崩塌（目标 ≥0.5；该档渲染上限另见 P2.3）。

### P2.2 会话形态：host 建虚拟屏、禁物理屏，接入传输（回答"为什么是镜像"）

| 步骤 | 内容 | 文件 |
|---|---|---|
| 2.1 | `stream_probe --host --spec WxH [--exclusive]`：走 `M1SessionCoordinator` 建虚拟屏→禁物理屏→C-09 校验→用返回的 displayID 建 `M1FramePipeline`；结束恢复物理屏。默认仍为 `--mirror`（采物理主屏），保住现有诊断路径 | `stream_probe.m`、`M1SessionCoordinator.{h,m}` |
| 2.2 | 客户端把请求规格随 `session-start{specs[]}` 发出，窗口按比例 letterbox；不建任何本地虚拟屏（设计上虚拟屏在被控端） | `stream_probe.m`、`M1ControlSession.m` |
| 2.3 | 前置冒烟：两台机分别跑 `pipeline_kiosk_probe`（本机、无网络），确认建屏/禁屏/采集/恢复；Tahoe 先用 `--keep-main` 半禁屏作对照 | `pipeline_kiosk_probe.m` |
| 2.4 | 失败处置：A-08（Tahoe 零物理屏下 SCK 送帧不稳定）复发时，记录 OS/机型并回退镜像模式，不阻塞 P2.1 结论 | — |

**完成判据**
- `--exclusive` 启动后：host 打印新建虚拟屏 displayID；会话期间 `CGGetActiveDisplayList` 只返回该虚拟屏（C-09）；client 解码尺寸等于请求规格；结束物理屏恢复、无 WindowServer 断言。
- 物理屏全程无画面泄露（现场截图只有黑屏/锁屏）。
- 若 2.3 在 Tahoe 失败：保留 `--mirror`，把失败写进 `RESULTS-BY-OS`，不宣称独占成立。
- **进度（2026-11-19，Sequoia 本机）**：`--exclusive --keep-main` 冒烟 PASS——虚拟屏 `4128835`、采集 1280×720、client 31/31、控制间隔 1005ms、结束恢复成功。顺带修掉 Sequoia 误用 Tahoe 保守建屏导致的残留槽位镜像死锁（`M1RDPDriver` 改按 `P0OSPolicy()` 分流）。**未做**：全禁物理屏 + C-09（需现场确认可黑屏）、Tahoe host 本轮代码、client 解码尺寸断言。

### P2.3 渲染与记录收尾

| 步骤 | 内容 | 文件 |
|---|---|---|
| 3.1 | 渲染路径去 `CIContext→CGImage` 中转，改 IOSurface 直贴 layer；目标 Sequoia 1080p **≥24fps**、单帧 <40ms | `M1-Skeleton/src/M1FrameView.m` |
| 3.2 | `render_selftest` 增加 1080p/720p 档基线与 color/letterbox 回归 | `M1-Skeleton/tools/render_selftest.m` |
| 3.3 | 回归矩阵入档：{720p15, 1080p20} × {LAN, WAN}，每条记录标注 OS build 与机器（参照 `RESULTS-BY-OS` §1） | `docs/RESULTS-BY-OS.md` |

**完成判据**：1080p20 跨机跑满 20fps 且上屏队列 0 积压；`A-02` 只在拿到 glass-to-glass 实测后关闭（相机同框方案见 `P2-CHECKLIST` §7）。

---

## 3. 不做 / 延后

- 光标独立通道（FR-10）、音频、剪贴板、多屏、断线重连：P2 后。
- FEC / 分片重传：环回 1% 实测仅 0.13（IDR 存活率 ≈2.7%，须反复重试），1% 丢片率下的可用性依赖它；按 P2.1-FEC 单独立项评估（XOR/RS 分片 + 可选 NACK）。
- 控制端本地虚拟屏：不在设计内；控制端只出规格、不改本机显示配置。
- 调整 `summary` 的阈值：改为 LAN(0%)=0.98、LAN(0.1%)=0.90、WAN(目标 ≤0.1% 丢片)=0.85；1% 档不设门禁，避免用阈值掩盖无 FEC 的物理上限。

---

## 4. 风险

| 风险 | 处置 |
|---|---|
| 私有 SPI 建屏在 Tahoe/Sequoia 上触发 stale slot 或 `canonical_mirror_master` 断言 | 沿用 D-05：全部虚拟屏必须在禁物理屏前建齐；会话期间不新建；先跑 kiosk 冒烟 |
| 禁物理屏后 SCK 送帧不稳定（A-08） | `--keep-main` 对照；失败即回退镜像并记录，不硬上 |
| `keyframe-request` 引发关键帧风暴 | 客户端限速（≥300ms）+ 单次在飞；host 端合并请求 |
| 乱序重组内存膨胀 | 帧截止时间 + 在飞帧上限；分片总字节上限 |
| 重编导致 host TCC 失效 | 沿用 `open -a Terminal` 继承屏幕录制；AX 仍缺时用 `--inject record` |

---

## 5. 一句话结论

下一步先实现 **P2.1（位图重组 + 关键帧请求 + 帧口径指标）**；随后用 **P2.2** 把 `stream_probe --host` 接上已有的会话层，让控制端看到按规格新建的虚拟桌面而不是物理屏镜像；渲染优化（P2.3）只在需要 1080p 档时进入关键路径。
