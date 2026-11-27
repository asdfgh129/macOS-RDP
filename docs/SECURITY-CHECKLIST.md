# NFR-07 安全自查清单（渗透自查）

适用范围：VeilRD 主机（Tahoe 26.5.2）× 客户端（Sequoia 15.5）WAN 直连形态。
本表既是设计对照，也是渗透/自查的执行清单：每项给出机制、代码位置、验证方式与当前状态。

状态口径：✅ 已实现且有单测/真机证据；🟡 已实现、待真机逐项验收；❌ 已知缺口（M3 收口项）。

## A. 身份与传输

| # | 检查项 | 机制 | 位置 | 验证 | 状态 |
|---|---|---|---|---|---|
| A1 | 传输加密 | QUIC(TLS 1.3) datagram，ALPN `rdp1` | `M1QuicTransport.m` | 真机 WAN 会话 `transportIsQUIC=1` | ✅ |
| A2 | 服务端身份钉死 | 客户端按 SHA-256 指纹校验 Host 叶子证书（`verifyPeer` + `expectedPeerFingerprint`） | `M1QuicTransport.m:456` | 指纹不符时握手失败（真机 + 单测 `ctl-hello-fingerprint-mismatch`） | ✅ |
| A3 | 客户端身份钉死 | Host `--allow-fingerprint HEX` 校验 hello `certFingerprint`；客户端以 `.state/rdp-identity.p12` 持久身份接入 | `Apps/HostAgent/Sources/main.m`（`--allow-fingerprint`）、`M1ControlSession.m:262` | 单测 `ctl-host-pins-client-fingerprint`；真机待跑 | 🟡 |
| A4 | 未配置钉死时的行为 | Host 启动横幅告警「任何客户端都可接入」；不静默放行 | `main.m` banner | 启动日志 | ✅ |
| A5 | 私钥/证书不入库 | `.gitignore` 忽略 `M1-Skeleton/.state/`、`.state/` | `.gitignore` | `git status` 无 p12/key | ✅ |

## B. 配对认证

| # | 检查项 | 机制 | 位置 | 验证 | 状态 |
|---|---|---|---|---|---|
| B1 | 首次配对码 | 6 位码，Host 静态比对，Client 发 `pair-request`/Host 回 `pair-confirm` | `M1ControlSession.m` | 单测 `ctl-pair-code-*` | ✅ |
| B2 | 配对码时效与试错锁定 | TTL 5min、连续 5 次失败锁定 10min（默认值） | `M1Pairing.h:75-78` | 单测（配对状态机用例） | ✅ |
| B3 | TOFU 指纹变更检测 | 已配对后指纹不一致 → `M1PairingErrorFingerprintChanged` | `M1Pairing.m` | 单测 `fp-change-rejected` | ✅ |
| B4 | 持久化 | `M1PairingStore` 协议；Keychain 实现待接产品 UI | `M1Pairing.h:38-44` | — | ❌（M3 后接 UI） |

## C. 输入注入边界（最高风险面）

| # | 检查项 | 机制 | 位置 | 验证 | 状态 |
|---|---|---|---|---|---|
| C1 | 仅已配对会话可注入 | 注入回调只在控制会话进入 STREAMING（即已完成配对/认证）后触发 | `M1ControlSession.h` 注释、`P1SessionState.m:65` | 单测 `in-host-received` 前置 `both-streaming` | ✅ |
| C2 | 非 STREAMING 拒绝 | 状态机对 `input` 事件返回 `InputNotAllowed`；节点层静默丢弃并计数 | `P1SessionState.m:65-68`、`M1StreamSession` | 单测 | ✅ |
| C3 | 事件校验 | kind/坐标 [0,1]/键码/flags 白名单，畸形拒绝并计数 | `M1ControlSession.m`（P1InputCodec） | 单测 `in-reject-bad-coord` 等 | ✅ |
| C4 | 速率限制 | ≤1000 event/s，超限丢 move/scroll | `M1ControlSession.m:77` | 单测 | ✅ |
| C5 | 记录模式默认 | `--inject` 默认 `record`，不真注入 | `main.m` | 启动日志 | ✅ |
| C6 | 注入落在当前 GUI 会话 | `CGEventPost(kCGHIDEventTap)` 只作用于本机 Aqua 会话（agent 必须以登录用户身份运行） | `M1InputInjector.m:21` | 真机 | ✅ |

## D. 资源滥用与 DoS 面（单对端范围内）

| # | 检查项 | 机制 | 位置 | 验证 | 状态 |
|---|---|---|---|---|---|
| D1 | 关键帧请求限流 | 300ms/屏 | `M1ControlSession.m:552` | 单测 RATE_LIMITED | ✅ |
| D2 | 补片请求限流 | 5ms/屏（定向/整帧独立桶），indices ≤64 且 < fragCount | `M1ControlSession.m:616,654` | 单测 | ✅ |
| D3 | 控制面重传上限 | 250ms × 20 次后判死，本地转 Closed，不无限重传 | `M1ControlLink` + `abortWithReason:` | FR-08 断网实测 | ✅ |
| D4 | 控制面静默熔断 | 8s 无心跳判死（看门狗） | `M1StreamSession.m` watchdog | FR-07 实测 | ✅ |
| D5 | 显示 SPI 挂起熔断 | 8s 软死线 → 12s 状态收敛观察期，仍未收敛则置 `WindowServerHung`，此后拒绝一切显示事务；收敛判据本身改为「WS 探活 + verify 同一个 1s 有界窗口」，真挂起时不会卡死反而漏熔断 | `P0VDisplayIsolation/src/P0VDisplayControl.m`、`M1RDPDriver.m` | 单测（事务超时用例）+ **真机故障注入 PASS（`Scripts/tests/tx-breaker/`）**：`wsfreeze` 8.3–9.3s 熔断、`hang` 20.2s 熔断、熔断后新事务 code 10 即时拒绝（<200ms），Tahoe 26 / Sonoma 14 / Ventura 13 三机一致（RESULTS §5.49 A） | ✅ |
| D6 | 半开连接 | QUIC idle 30s、单次接入失败不掀常驻进程（连续 5 次放弃） | `M1QuicTransport.m:434`、`main.m` | 真机 | ✅ |

## E. 凭据与日志

| # | 检查项 | 机制 | 位置 | 验证 | 状态 |
|---|---|---|---|---|---|
| E1 | 日志不含凭据 | 控制面诊断仅计数/时序；口令、配对码、解锁凭据都不进日志 | 全仓 `printf`/`NSLog`/`fprintf` 审计（2026-11-27） | 命中项只有两处**非日志**输出：`veild-host-agent pairing` 自检子命令打印自签发的配对码（该码本来就要交给用户，且不在 serve 路径）、客户端 `demoPairing()` 演示函数 | ✅ |
| E2 | p12 口令来源 | `M1ResolveIdentityPassphrase`：显式 `--pass` > 环境变量 `VEILRD_IDENTITY_PASS` > 钥匙串（`veild-identity` / `$USER`）> 开发默认 `rdpdev`（走最后一档会打印告警） | `M1QuicTransport.m`、`Apps/HostAgent/Sources/main.m`、`Apps/Client/Sources/main.swift`、`M1StreamSession.m` | 生产部署用 env 或钥匙串，`ps -ef` 里看不到口令；命令行 `--pass` 保留给联调 | ✅ |
| E3 | 身份文件权限 | `.state/` 0700、p12 0600 | `gen_quic_identity.sh` | `ls -l` | ✅ |
| E4 | 诊断包不含凭据 | `--out` JSON 仅统计指标 | `main.m` 汇总段 | 抽查 JSON | ✅ |

## F. 主机侧物理安全

| # | 检查项 | 机制 | 位置 | 验证 | 状态 |
|---|---|---|---|---|---|
| F1 | 禁屏前必须有兜底 | 无快照/无守护进程时拒绝禁屏 | `M1RDPDriver.m:366` | 单测 `无兜底时拒绝启动守护` | ✅ |
| F2 | 有序收尾 | SIGTERM/SIGINT → 停管线 → 还物理屏 → 销毁 VD → 摘 guardian | `Apps/HostAgent/Sources/main.m`（`handleTermination`） | 真机待验证 | 🟡 |
| F3 | 崩溃兜底 | guardian 外部进程按快照恢复（Tahoe 上存在恢复失败边界，见 RESULTS-BY-OS §5.44） | `P0VStartGuardian` | 真机 | 🟡 |
| F4 | 无人值守加固 | 自动登录 + LaunchAgent + 禁止闲置锁屏 + 输入钉死 | `Scripts/host-deploy/` | M3 真机验收 | 🟡 |

## 渗透自查执行步骤（每次发布前）

1. **未配对接入**：不核对指纹直接用 VeilRD 连接主机 → 必须被 hello 指纹校验拒绝（A3 开启时）。
2. **配对码暴破**：连续 6 次错误码 → 第 6 次报锁定，10min 内正确码也应被拒（B2）。
3. **伪造输入**：非 STREAMING 阶段构造 input 包 → 主机不得注入（C1/C2）。
4. **坐标越界/畸形事件**：`x=2.0`、缺 kind、fragCount 越界 → 拒绝且会话不断（C3）。
5. **洪泛**：1001 event/s、连环 keyframe-request → 限流生效、会话不断（C4/D1）。
6. **断网重连**：pf 双向阻断 12s → 会话对端判死并重连，不留僵尸会话（D3/D4）。
7. **日志抽查**：`grep -rEi "password|passphrase|pass=|pair-?code|credential" /tmp/veild-*.log /tmp/veilrd-soak/*.log .state/*.log` → 除自检子命令外零命中（E1）。
8. **主机收尾**：`kill -TERM $(pgrep veild-host-agent)` → 物理屏 5s 内恢复、无 WindowServer 脏态（F2）。
9. **口令来源**：`ps -ef | grep -i veild` → 命令行里不应出现 `--pass`（E2）。生产部署用：
   `security add-generic-password -U -s veild-identity -a "$USER" -w '<口令>'`，或导出 `VEILRD_IDENTITY_PASS`。
