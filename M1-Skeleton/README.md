# M1-Skeleton — 产品骨架（RDPKit ObjC 层）

## 为什么现在做这部分

D-10 已定（SCK 主路径 + 15–30fps），但帧管线参数仍要等 P2 双机微调。会话编排、显示隔离、
输入注入、配对协商**不依赖帧率**，先行落地可让 M1 的关键路径解耦并行。本工程是 D-02
「Swift 主 + ObjC 桥」中 `RDPKit`（ObjC 无 UI）的雏形；Swift App 层在 `RDPApp/`（见下）。
Metal 渲染与帧管线在后续接入。

## 已实现模块

| 模块 | 文件 | 职责 | 依据 |
|---|---|---|---|
| 配对 / TOFU | `M1Pairing.{h,m}` | 6 位配对码、5min 有效、5 次试错锁 10min、64-hex 指纹规范化、TOFU 绑定与变更拒绝、store 注入 | PROTOCOL §2/§6 |
| 现场接管 | `M1Takeover.{h,m}` | Shift≥3s 手势 + 10s 缓冲 + 一次延后累计≤60s；热插拔/睡眠唤醒/锁屏 fail-safe 立即断开 | D-06 §3 |
| 会话编排 | `M1SessionCoordinator.{h,m}` | Path A 生命周期：防睡眠→建齐虚拟屏→禁物理屏→C-09 隔离校验→[登录]→STREAMING→(恢复+销毁+锁屏)；事务性回退 | D-04/D-06/D-08 |
| 锁屏封装 | `M1ScreenLock.{h,m}` | `SACLockScreenImmediate` dlsym 调用，符号缺失返回 NO 不崩溃 | D-06 |
| **生产驱动** | `M1RDPDriver.{h,m}` | `M1SessionDriver` 真实实现：IOKit 双防睡眠断言、`VDManager` 建屏（保守→提升）、`P0VDisplayControl` 快照+守护+禁屏+恢复、C-09 隔离、CGEvent 凭据注入（不落盘）、锁屏 | D-08 / C-09 |
| 驱动纯逻辑 | `M1DriverLogic.{h,m}` | 凭据→unicode 事件序列（支持中文）、C-09 隔离判定 — Foundation-only 可单测 | A-03 / C-09 |
| 输入注入逻辑 | `M1InputLogic.{h,m}` | flags→CGEventFlags 掩码、归一化坐标→目标屏 Quartz 全局坐标、事件→注入计划 — Foundation-only 可单测 | PROTOCOL §3.1 |
| 输入注入器 | `M1InputInjector.{h,m}` | `M1EventSink` seam + `M1CGEventSink`（CGEventPost / 定向 pid）、修饰键全量同步、Shift 手势 CGEventTap（listen-only，需辅助功能授权） | D-06 §3 |

**接口 seam**：`M1SessionDriver` protocol 把 WindowServer / 系统操作抽象出来；生产驱动
`M1RDPDriver` 封装 `VDManager` + `P0VDisplayControl` + `M1ScreenLock`，测试用 mock 记录调用序列。
状态机与纯逻辑确定性单测，真机操作由 `driver_probe`（只读侦察）验证可编译与现场判定。

## 帧管线接入点（D-10 预留，本版留空）

`M1SessionCoordinator` 的 step 5 只把 phase 推进到 `Streaming`，不接采集/编码。
帧管线模块（SCK `SCStream` → VT H.264 → QUIC datagram）按 D-10 独立开发，参数默认
`20fps / 1080p / 关键帧 2s`，通过协议协商后注入，不改本编排器上层。

## 构建与测试

```bash
bash build_tests.sh     # 120 断言全过 + 守护握手负向测试（纯 Foundation 逻辑层）
bash build_driver.sh    # 编译 M1RDPDriver + M1InputInjector 重依赖层
./driver_probe          # 只读侦察：active 屏 / 私有符号 / loginwindow PID / stale 槽位（不改显示配置）
bash build_pipeline.sh  # 帧管线（不建屏/不禁屏）
bash build_kiosk_probe.sh  # 禁屏独占实测探针
bash build_quic_probe.sh   # 真实传输层（QUIC datagram + 指纹钉死），自带测试身份生成
```

覆盖：配对码格式/过期/试错锁定/指纹变更拒绝/持久化；Shift 手势阈值/缓冲到期/延后封顶/
fail-safe 立即；会话 start/end 步骤顺序、带登录时注入在禁屏之后、禁屏失败的事务性回退；
凭据 unicode 序列（含中文）、C-09 隔离判定、flags 掩码、坐标映射、注入计划。

> 测试中抓出并修复了一个真实缺陷：建屏成功但禁屏失败时虚拟屏会泄漏（原回退只看
> `physicalDisabled`）。现由 `virtualCreated` 标志统一触发恢复。

`driver_probe` 实测（2026-11-18）：2 块物理屏 active、私有显示控制可用、loginwindow PID 有效、
锁屏符号可用、WindowServer 未挂起，并检出 6 个 stale 虚拟槽位（多屏创建前需注意）。

## 禁屏独占实测（`pipeline_kiosk_probe`）与兜底硬约束

禁屏是本项目唯一能把整机变成黑砖的操作。2026-11-18 已实际发生过一次：屏幕全黑、
无法唤醒、只能强制重启。那次事故拆出四个真实缺陷，现在四条都已修掉并被测试钉住：

| # | 缺陷 | 现在的约束 |
|---|---|---|
| 1 | 宿主二进制没实现 `--guardian`，守护子进程打印用法后立刻退出，父进程却以为有兜底 | `P0VStartGuardian` 增加 `<snapshot>.guardian-ready` **就绪握手**，3s 内没就绪即失败；`M1RDPDriver` 在无快照/无守护时**拒绝禁屏**。负向测试：`tests/guardian_handshake_test.m` |
| 2 | 快照在**建虚拟屏之后**才拍，虚拟屏被写进快照并当成 main，销毁后拓扑破碎 | `prepareSessionShieldError:` 在建屏**之前**快照，`createVirtualDisplays:` 内部强制先预备护盾 |
| 3 | 禁屏 `keepIDs` 传了空数组，连刚建好的虚拟屏一起被禁 → **零显示**；而旧判据 `active ⊆ 虚拟屏` 对空集恒真，安全检查放行 | keep 自动并入本会话虚拟屏；禁屏后自检 active 非空；新增 `M1IsolationViolation()` 把「零显示」判为违规（比泄漏更严重） |
| 4 | 恢复只在 `@finally` 里做，`SIGINT/SIGTERM/SIGHUP` 会直接终止进程，`@finally` 根本不执行 | 信号 → 自管道 → 专用线程恢复后退出；另有「时长 + 120s」看门狗强制收尾 |

用法：

```bash
./pipeline_kiosk_probe --preflight          # ① 只验证快照+守护握手，不碰显示配置（1s）
./pipeline_kiosk_probe --keep-main --duration-ms 8000   # ② 半禁屏：主屏全程可见，验证禁/恢复机制
./pipeline_kiosk_probe --spec 1920x1080 --duration-ms 10000   # ③ 全禁屏（真黑屏，有兜底）
```

三级递进的用意：`--preflight` 证明「有人兜底」，`--keep-main` 证明「禁得下去也恢复得回来」
（屏幕始终可用），最后才做全禁屏。2026-11-18 的事故就是跳过了前两级直接跑第三级。

已实测（2026-11-18 16:26，`--keep-main --duration-ms 8000`）：快照只含 2 块物理屏
（`main=3440×1440`，无虚拟屏记录），禁用 1 块物理屏 → 采编环回 15 帧/8s（1.8fps，
与 §5.2「物理屏在线时约 2fps」一致）→ 恢复成功、两块物理屏回到原 displayID。
`--preflight` 与半禁屏两次运行的守护握手均在约 25ms 内完成。

`--preflight` 会在 1 秒内给出「万一崩了有没有人兜底」的确定答案，失败即禁止禁屏。
真禁屏期间如果探针被 `kill -9`（信号拦不住），守护进程读到快照后恢复物理屏，并额外
禁用不属于快照的 P0 虚拟屏（孤儿槽位），恢复结果写在 `<snapshot>.guardian-result.json`。

## 真实传输层（M1-A 第 1/2 步，D-13）

`M1QuicTransport.{h,m}` 是 `M1DatagramSink` 的生产实现：Network.framework 的 **QUIC
datagram flow**（`nw_quic_set_stream_is_datagram`，macOS 13+），一次 `nw_connection_send`
= 一个 datagram 边界，不重传、不排序——正是 D-01 要的语义。

> 开工前先核对了 SDK 头文件：`nw_quic_stream_type_datagram` / `nw_quic_set_max_datagram_frame_size`
> / `nw_quic_get_stream_usable_datagram_frame_size` 都存在且 macOS 13 起可用。原先担心的
> 「Network.framework 不暴露 RFC 9221 datagram、只能退回裸 UDP」**不成立**，不需要自建加密。

TLS 1.3 随连接建立，自签证书的叶子证书 SHA-256 就是 TOFU 锚点：
`peerCertificateSHA256` 读出指纹，`expectedPeerFingerprint` 钉死。指纹不符时**主动取消连接
并报 `M1QuicErrorFingerprintMismatch`**——只 `complete(false)` 的话 QUIC 会吊在 preparing
直到 idle 超时（实测 20s 都没结论），上层拿不到任何可报的错。

```bash
bash build_quic_probe.sh                 # 内含 gen_quic_identity.sh，生成本地测试 p12（.state/，已 gitignore）
./quic_probe --frames 400 --frame-bytes 3000 --pace-ms 2 --burst 1200
M1_QUIC_DEBUG=1 ./quic_probe ...         # 打印握手/状态/证书细节
```

探针四阶段：A 不校验连上并读出指纹 → B 用该指纹钉死并跑分片压测（**走的是生产同一条
16B 帧头 + 1150B 分片路径**，`M1FrameSender` 直接接在 QUIC sink 上）→ C 用错误指纹必须被拒
→ D 瞬时突发（信息性，观测拥塞窗口满时的丢弃）。

实测（2026-11-18，本机环回）：

| 项 | 结果 |
|---|---|
| 协商 datagram 上限 | 1497 B（1150B 分片占 77%，安全） |
| 分片投递（2ms 节奏，400 帧） | 1200/1200 分片、1,219,200 B **零丢失/零重复/零乱序/零载荷错**，9.6 Mbps |
| 超限拒发 | 3000B > 1497B 本地即拒，不交给 QUIC 静默截断 |
| 错误指纹 | 12–25ms 内 `failed` 并给出指纹差异 |
| 握手耗时 | p50 约 17ms（10 次 13–84ms），偶发 6–11s 离群（待查） |
| **瞬时突发 1200 分片** | 7.0ms 内全发 → **523 整帧丢失（43.6%）**，零重复零乱序 |

最后一行是本次最重要的工程结论：**QUIC datagram 在瞬时突发下会成片丢弃**，帧发送必须
按节奏/拥塞窗口投递，不能「有多少发多少」。这也反证了 PROTOCOL §4 的关键帧重建策略是必需的。

## Swift App 层（D-02，见 `../RDPApp/`）

`RDPApp` 用「Swift 主 + ObjC 静态库」结构：clang 把本目录 ObjC 模块编成 `libRDPKit.a`，
swiftc 通过桥接头链接。已验证 Swift ↔ ObjC 双向可用（Swift 实现 `M1SessionDriver`
protocol 注入协调器、Swift 调 ObjC 纯函数/类），会话序列端到端正确。`cd ../RDPApp && bash build.sh && ./rdpapp`。

## M1 剩余工作（依赖帧管线 / 需人为决策）

1. **帧管线接入真实传输**：SCK `SCStream` → VT H.264 → `M1QuicTransport`，把 `pipeline_probe`
   的环回换成两个进程；发送必须按帧节奏投递（突发实测丢 43.6%）；
2. **Metal 渲染 + 多窗口**（帧管线就绪后）；MIT 基座集成；
3. ~~真 loginwindow（`loginDone=0`）补测~~ → **延后 M2 借测机（D-11）**，不占主力机。资产已备齐：
   `P0V-SessionRecon/gui_session_probe`（只读判定 GUI 会话 + 抓屏 luma）与 `run_loginwindow_probe.sh`
   （守卫 `loginDone=0` → preflight → 自动 `bsexec` 重入 → 建屏/禁屏/采集/恢复）。M2 拿到机器按
   `docs/DECISIONS.md` D-11 的五步流程跑即可；
4. P2 双机 QUIC 互通 + glass-to-glass 打点，关闭 A-02 后冻结协议 v1。
   **双机操作单见 `../docs/P2-CHECKLIST.md`，脚本是 `../P2-Dual/p2.sh`**
   （`preflight | host | client | summary`）。客户端侧用 `--connect <IP>` 指定对端，
   服务端端口已固定（`nw_listener_create` 会忽略端口，已改用 `nw_listener_create_with_port`）。

## 按 OS 记录

逻辑层与 OS 无关；真机驱动行为仍按 `docs/RESULTS-BY-OS.md` 分离，禁止跨版本外推。
