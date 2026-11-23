# VeilRD 产品入口双机实测操作单（2026-11-23）

按此单从上到下跑。目标是把第 4 轮的产品入口 **`veild-host-agent --serve` ↔ `VeilRD --connect`**
直接对连跑通，不再经过 `p2.sh` / `stream_probe`。旧探针路径的操作单见
`P2-TONIGHT-RUNBOOK.md`，本文只回答「今晚按什么顺序、用什么命令、做到哪条算过」。

- 代码基线：`dc10fbc`（第 4 轮产品入口），文档 HEAD `3e90243`。两端拉到同一提交；记录实际 commit 并回报。
- 判定细则见 `P2-CHECKLIST.md` §4/§5；**实测结论按 OS 分离写 `RESULTS-BY-OS.md`，禁止跨版本外推**。
- 本单只做双机实测，不改代码；开发轮次与真机轮次不混跑。

## 0. 环境与前置（两端都做，约 10 分钟）

变量约定（下面命令直接复制，先按实际改这三行）：

```bash
REPO="$HOME/macOS-RDP"
PRODUCTS="/tmp/veilrd-xcode/Build/Products/Debug"
HOST_IP="192.168.10.23"          # Tahoe host 内网地址；公网入口 112.5.32.34:46600
```

| 角色 | 机器 | OS | 构建方式 |
|---|---|---|---|
| host | Macmini8,1 | Tahoe 26.5.2 (25F84) | `bash Scripts/build.sh`（需 Xcode） |
| client A | Macmini8,1 / Sequoia 那台 | Sequoia 15.5 (24F74) | `bash Scripts/build.sh VeilRD` |
| client B | iMac17,1 `192.168.34.213` | Ventura 13.6.7 (22G720) | **仅 CLT 14.3.1**，无 Xcode → `cd RDPApp && bash build.sh` 得 `./rdpapp` |

> Ventura 机器不能开 `VeilRD.xcworkspace`（无完整 Xcode），只能走 `RDPApp/build.sh`；
> 该脚本已收编第 4 轮的 `M1StreamSession`，产出的 `./rdpapp` 与 `VeilRD` 是同一份 `main.swift`。

### 0.1 同步与构建

```bash
# 两端
git -C "$REPO" pull && git -C "$REPO" log -1 --oneline   # 记录 commit
cd "$REPO" && bash Scripts/test.sh                        # 纯开发门禁，必须全 PASS

# host（Tahoe，Xcode 完整）
cd "$REPO" && bash Scripts/build.sh
ls -l "$PRODUCTS"/{veild-host-agent,VeilRD,libRDPKit.a,libProtocolCodec.a}

# client A（Sequoia）：同样 bash Scripts/build.sh，$PRODUCTS/VeilRD --selftest
# client B（Ventura，CLT only）
cd "$REPO/RDPApp" && bash build.sh && ./rdpapp --selftest
```

入口自检：`veild-host-agent`（无参）与 `VeilRD --selftest` / `./rdpapp --selftest` 都应打印 PASS。

### 0.2 身份与指纹（只需在 host 上确认）

host `--serve` 默认读 **当前工作目录** 下的 `.state/rdp-identity.p12`；仓库里的身份在
`M1-Skeleton/.state/`，所以**必须显式传绝对路径**，否则会报「读不到 QUIC 身份指纹」。

```bash
ID="$REPO/M1-Skeleton/.state/rdp-identity.p12"
openssl pkcs12 -in "$ID" -clcerts -nokeys -passin pass:rdpdev 2>/dev/null \
  | openssl x509 -outform DER 2>/dev/null | shasum -a 256
# 期望：3305dec4c356fadda287fdbe069bd10d8d4088aac57ba08108e7fb39433b1604
```

client 只需 `--fingerprint` 这个 hex，**不需要** p12。若握手报 `-9858`，在仓库根用
`bash M1-Skeleton/gen_quic_identity.sh M1-Skeleton/.state rdp-identity rdpdev --force`
换钥匙，重新算指纹并同步给 client（旧 p12 立即失效，两端必须重跑）。

### 0.3 会话、代理、端口

- host 必须从 **Aqua/GUI 会话**启动才有采集能力：SSH 里用 `P2-Dual/gui-run.sh` 包一层；
  若重编后 TCC 失效（`capture=0`），改用屏幕前 `open -a Terminal` 的 `.command` 包装（见 §5）。
- client 的 `VeilRD --connect` 会开 `NSWindow` 上屏，**也必须在本机 GUI 会话里启动**（前台 Terminal 直接跑，
  或 SSH 到 client 后用 `gui-run.sh` 包一层）；纯 SSH 无 Aqua 会话时窗口不可见、输入事件进不来。
- host 本机代理 `127.0.0.1:20171` 会劫 UDP 路由：**所有联调命令都加 `env -u http_proxy -u https_proxy`**。
- 边界设备：UDP 外 `46600 → 192.168.10.23:46600`（WAN 档要）；SSH 另需 TCP `46601 → :22`。不开 TCP/46600。
- 跨网段：iMac `192.168.34.213` ↔ host `192.168.10.23` 已路由互通（网关 .10.1 ↔ .34.1）。
- 严禁在 host 物理机前无人时跑全独占档（§3）。

---

## 1. 第一档：镜像 + record（不改显示配置，先证协议链路）

目的：证明两个**产品入口**能握手、推流、上屏、回传输入；不涉及虚拟屏/禁屏，安全可回退。
720p15、LAN、`--mirror`、`--inject record`（不注入真事件，只记录，无需辅助功能）。

host（Tahoe，SSH 驱动）：

```bash
cd "$REPO"
O="$REPO/P2-Dual/out/product-mirror-lan"; mkdir -p "$O"
env -u http_proxy -u https_proxy \
  P2-Dual/gui-run.sh "$PRODUCTS/veild-host-agent" --serve \
  --port 46600 --mirror --spec 1280x720 --width 1280 --height 720 \
  --fps 15 --wait-ms 0 --duration-ms 20000 --inject record \
  --identity "$REPO/M1-Skeleton/.state/rdp-identity.p12" --pass rdpdev \
  --out "$O/host.json" 2>&1 | tee "$O/host.log"
# 记下「给客户端的三项」里的指纹；host 会一直等到 client 接入
```

client A（Sequoia）：

```bash
cd "$REPO"
O="$REPO/P2-Dual/out/product-mirror-lan-client"; mkdir -p "$O"
"$PRODUCTS/VeilRD" --connect 192.168.10.23 --port 46600 \
  --fingerprint 3305dec4c356fadda287fdbe069bd10d8d4088aac57ba08108e7fb39433b1604 \
  --spec 1280x720 --window 1280x720 \
  --duration-ms 18000 --wait-ms 60000 --handshake-ms 30000 \
  --save-frames 5 --outdir "$O" --out "$O/client.json" 2>&1 | tee "$O/client.log"
```

client B（Ventura，CLT only）把上面二进制换成 `./rdpapp`、工作目录 `RDPApp` 即可，其余参数不变。

**跑测动作**：client 窗口出现后，在窗口里移动鼠标/点击 ≥5 次（否则输入计数为 0，不算协议失败但要注明）；
给 host 物理主屏喂动态内容（如 `P2-Dual/gui-run.sh P2-Dual/tools/anim_display.sh 0 60`），
否则「按内容变化送帧」会让 complete 帧只有 ~1/s，别误判采集退化。

**判过（本档）**：

| 来源 | 判据 |
|---|---|
| host stdout | `监听 46600` + 指纹一致；`推流开始`；`serve: frames captured/encoded/sent > 0`；`input ok ≥ 5, fail = 0` |
| client stdout | `握手完成 < 3000ms`（LAN 参考）；`已 STREAMING`；`重组完成/解码 > 0`；`渲染 ≥ 1`；`输入上行 ≥ 5 / 失败 0`；`PNG ≥ 1` |
| 两端 JSON | `framesDecoded / framesSent ≥ 0.98`（LAN 0% 丢片档）；`framesDropped / framesCompleted < 5%`；`maxControlGapMs < 3000` |
| `host.json.c09` | 本档应仍是 `not-started`（镜像不判 C-09，正常） |

p50/p95 与时钟 offset **只记录、不设门禁**；它没有 glass-to-glass 口径，A-02 仍开放。

---

## 2. 第二档：独占 + keep-main（半禁屏，先证建屏与 C-09 链路）

第一档过了再跑。host 默认独占（去掉 `--mirror`），加 `--keep-main` 保留物理主屏可见，风险可控。

host（与 §1 相比：去掉 `--mirror`、加 `--keep-main`；编码尺寸跟随虚拟屏规格，不再传 `--width/--height`）：

```bash
cd "$REPO"
O="$REPO/P2-Dual/out/product-keepmain-lan"; mkdir -p "$O"
env -u http_proxy -u https_proxy \
  P2-Dual/gui-run.sh "$PRODUCTS/veild-host-agent" --serve \
  --port 46600 --keep-main --fps 15 --wait-ms 0 --duration-ms 20000 --inject record \
  --identity "$REPO/M1-Skeleton/.state/rdp-identity.p12" --pass rdpdev \
  --out "$O/host.json" 2>&1 | tee "$O/host.log"
```

看到 `  [独占] 虚拟屏 (...) C-09=skipped-keep-main` 后，用打印出的 displayID 喂动态内容：

```bash
cd "$REPO" && env -u http_proxy -u https_proxy \
  P2-Dual/gui-run.sh "$REPO/P2-Dual/tools/anim_display.sh" <displayID> 60
```

client 命令与 §1 相同（`--spec 1280x720` 必须有，host 靠它建虚拟屏）。

**判过**：host `c09=skipped-keep-main`（不会被 summary 当成 C-09 通过）；client 解码尺寸 1280×720；
host 每秒 `[capture] complete≈15 / idle≈0`；结束打印 `已恢复物理屏并销毁虚拟屏`；物理屏仍可见。

---

## 3. 第三档：全独占 + C-09（物理屏会黑，按顺序）

> **这一步会让被控端物理屏黑掉。必须人在机器旁、能物理恢复；先跑完 §1、§2。**

host 去掉 `--mirror` 和 `--keep-main`，其余同 §1（`--spec` 由 client 传）：

```bash
cd "$REPO"
O="$REPO/P2-Dual/out/product-exclusive-lan"; mkdir -p "$O"
env -u http_proxy -u https_proxy \
  P2-Dual/gui-run.sh "$PRODUCTS/veild-host-agent" --serve \
  --port 46600 --fps 15 --wait-ms 0 --duration-ms 30000 --inject record \
  --identity "$REPO/M1-Skeleton/.state/rdp-identity.p12" --pass rdpdev \
  --out "$O/host.json" 2>&1 | tee "$O/host.log"
# 打出「虚拟屏 (...) C-09=verified」后，拿该 displayID 跑 anim_display.sh <id> 120
```

**判过**：`host.json.c09 = verified`；client 窗口 1280×720、PNG 是虚拟屏动画画面而非黑帧；
client 解码/渲染计数与 §1 同档；结束物理屏恢复、无黑屏残留。现场确认物理屏全程无画面泄露。

**中断纪律**：产品入口**没有信号处理器**，`Ctrl-C` 会绕过 `endExclusive()` 导致物理屏不恢复。
**让 `--duration-ms` 自然走完**；不要手动打断。若必须中断，按 §5 恢复。

---

## 4. 可选档（时间够再做，单独记账）

### 4.1 WAN 公网门禁
client 的 `--connect` 改成 `112.5.32.34 --port 46600`，host 命令不变（边界设备已映射 UDP）。
先按 §1 镜像档跑，别一上来 WAN 全独占。判据：`framesDecoded / framesSent ≥ 0.85`、
`maxControlGapMs < 3000`、等待关键帧占比 <10%（产品 JSON 无该字段时从 log 记）；
LAN 与 WAN 结果**分开**写 `RESULTS-BY-OS.md`。

### 4.2 真输入注入
host 把 `--inject record` 换成 `--inject real`，并给 `veild-host-agent` 授权辅助功能（见 §5）。
在 client 窗口里真移动/点击，判 `inputOK > 0` 且 host 光标确有位移（可用 `M1-Skeleton/cursor_move` 辅助确认）。

### 4.3 Ventura 作为 host
当前只有 Xcode workspace 构建入口，iMac 无完整 Xcode；本轮**不列主线**。
若要做，先另补基于 `RDPApp/build.sh` 的 host 构建脚本，且只测 **720p**（该机 1080p 独占已知触发
WindowServer `layer_blit` 崩溃），并单独记在 Ventura 小节，禁止外推到 Tahoe。

---

## 5. 中途停止 / 异常 / TCC

- **屏没回来**：先看 `host.log` 末尾有没有 `已恢复物理屏并销毁虚拟屏`；没有就跑
  `P2-Dual/gui-run.sh P0V-DisplayIsolation/recover_v5`，再不行 `pipeline_kiosk_probe --preflight` 看快照，
  最后才重新登录（不要反复盲跑建屏）。
- **重编后 `capture=0` / 握手拿不到画面**：ad-hoc cdhash 变了，TCC 要重授权。生成包装脚本并在屏幕前点一次「允许」：

```bash
cat > "$REPO/P2-Dual/out/host-serve.command" <<'EOF'
#!/bin/bash
cd "$HOME/macOS-RDP"
exec /tmp/veilrd-xcode/Build/Products/Debug/veild-host-agent --serve \
  --port 46600 --mirror --identity "$HOME/macOS-RDP/M1-Skeleton/.state/rdp-identity.p12" \
  --pass rdpdev --wait-ms 0 --duration-ms 20000
EOF
chmod +x "$REPO/P2-Dual/out/host-serve.command"
open -a Terminal "$REPO/P2-Dual/out/host-serve.command"   # 在屏幕前点「允许」屏幕录制/辅助功能
```

- **建屏 ACK 踩线**（慢机：mode-commit 1.4–1.6s 阻塞控制 ACK）：加
  `M1_CTRL_RETRY_MS=500 M1_CTRL_MAX_ATTEMPTS=12`（默认 250ms×8 不变）。
- **黑帧**：Tahoe 默认 SCK，失败自动回退 CG；需要时用 `M1_CAPTURE_BACKEND=cg|sck|cgimage` 强制。
- **握手细节**：client 加 `M1_QUIC_DEBUG=1`。
- **崩溃后**：WindowServer 带病进程会让后续建屏再崩，须充分恢复/重新登录后再测。

---

## 6. 收口与回报

每档跑完，把下面几项贴回对话，我按 OS 分别更新 `RESULTS-BY-OS.md` 的 §5 与 A-02 状态：

1. 两端实际 commit、`sw_vers -productVersion (build)`、机器标签（Tahoe / Sequoia / Ventura）；
2. 档位（mirror / keep-main / exclusive / WAN / real）、端口、规格、fps、时长；
3. host 的 `host.json` + 三条 `serve:` 行 + `c09`，client 的 `client.json` + `client:` 三行；
4. 是否出现黑屏、是否需恢复、物理屏是否回来；
5. p50/p95 / clock offset **数值照记**，但不要拿它宣布 A-02 关闭——A-02 仍需要 240fps 同框拍摄的
   glass-to-glass 口径。

**不在本单范围**：A-02 端到端延迟闭环、多屏独占、Ventura host 全链路、签名/打包/plist/TCC 说明。
