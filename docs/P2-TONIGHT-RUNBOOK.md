# P2 今晚实测操作单（2026-11-20）

按此单从上到下跑，每条都有可复制命令和判定。背景/阈值细节见
`P2-CHECKLIST.md`（怎么判、出错查什么）与 `P2-NEXT-PLAN.md`（为什么做）。
本单只回答：**今晚按顺序做什么、做到哪条算过**。

- 代码基线：`7864855`（P2 工程改动全部在此）；文档 HEAD：`e1d6ff8`（仅新增本操作单与文档链接，**无代码差异**）。两端拉到同一提交即可，暂时停在 `7864855` 也能开测。
- Tahoe host：Macmini8,1 / 26.5.2，内网 `192.168.10.23`，公网 `112.5.32.34:46600`
- 控制端：Sequoia 15.5 那台
- 证书指纹（身份 p12 未换，不变）：
  `3305dec4c356fadda287fdbe069bd10d8d4088aac57ba08108e7fb39433b1604`

---

## 0. 两端共同准备（先做，5 分钟）

```bash
# 两台机器都执行
git -C <macOS-RDP> pull                 # 两端拉到同一提交
cd <macOS-RDP>/M1-Skeleton && bash build_stream_probe.sh
git -C <macOS-RDP> log -1 --oneline     # 记录实际 commit，回报结果时带上
git -C <macOS-RDP> diff --stat 7864855 -- M1-Skeleton P2-Dual   # 应为空：代码与基线一致
```

**重编后 TCC 会失效**（ad-hoc cdhash 变了）。host 端先自检：

```bash
cd <macOS-RDP>/P2-Dual
./p2.sh preflight host
# 必须 capture=1；若 capture=0 / ax=0 → 见下方「TCC 重新授权」
```

> SSH 驱动 host 必须包一层 `./gui-run.sh ./p2.sh host`（否则没有 WindowServer，采集为空）。
> TCC 弹窗在 SSH 里看不见，首次要在屏幕前/屏幕共享里点掉一次。

防火墙：确认边界设备有 **UDP 外 46600 → 192.168.10.23:46600**（跨公网那两条测试要）；
SSH 另需 **TCP 46601 → :22**。不开 TCP/46600。关掉 VPN/代理（会劫 UDP 路由）。

---

## 1. P2.1 跨公网门禁复测（主线，先跑这条）

镜像模式、720p15、30s，客户从公网打进来。验证 P2.1 重组/关键帧请求在真实丢包下的效果。

**host（Tahoe，本机）**——无限等待，被控端不用掐时间：

```bash
cd <macOS-RDP>/P2-Dual
P2_ADVERTISE=112.5.32.34:46600 P2_PORT=46600 P2_WAIT_MS=0 \
P2_WIDTH=1280 P2_HEIGHT=720 P2_FPS=15 P2_SECONDS=35 \
P2_INJECT=record P2_OUT=$PWD/out/wan-p21-1120 \
./gui-run.sh ./p2.sh host 2>&1 | tee host-run.log
# 打出「给客户端的三项」后保持等待（每 10s 一行心跳）；终端别关
```

**client（Sequoia）**——换指纹那台执行：

```bash
cd <macOS-RDP>/P2-Dual
M1_QUIC_DEBUG=1 P2_HANDSHAKE_MS=30000 P2_WAIT_MS=60000 P2_SECONDS=35 \
P2_OUT=$PWD/out/wan-p21-1120 \
./p2.sh client --host 112.5.32.34 --port 46600 \
  --fingerprint 3305dec4c356fadda287fdbe069bd10d8d4088aac57ba08108e7fb39433b1604
```

把 host 的 `host.json` 拷到 client 那台，汇总判定：

```bash
./p2.sh summary <host.json> <client.json>
```

**判过**（`summary` 自动判，WAN 档分层已落地）：
- `判定 PASS`；解码/发出 ≥**0.85**、`sendFailures=0`、等待关键帧占比 <**10%**、
  控制间隔 <3s；新表里的「会话形态/C-09」应显示 `mirror / -`（镜像不判 C-09，正常）。
- 新表还有「关键帧请求 RTT 最近/样本」，只作观测不设门禁；若是旧二进制或没有丢片，
  显示 `0 ms / 0 次` 是正常的。

**若 FAIL**：先看新表逐行定位——
`解码/发出` 低 → 查端到端丢片率（看 `分片丢弃`）；`等待关键帧` 高 → 关键帧请求没到编码器
（对照 `关键帧请求 发出/主机收到`）；`控制间隔` 超 → 心跳被视频挤掉。
细节查 `P2-CHECKLIST.md §5` 失败对照表，先确认两端 commit 一致再查 TLS/MTU。

---

## 2. P2.2 独占会话：本地冒烟 → 全禁物理屏 + C-09（有黑屏风险，按顺序）

**这一步会让被控端物理屏黑掉，务必先跑 2.1 冒烟、人在机器旁、能物理恢复。**

### 2.1 kiosk 冒烟（本机、无网络，先证建屏/禁屏/恢复闭环）

```bash
cd <macOS-RDP>/M1-Skeleton
./gui-run.sh ./pipeline_kiosk_probe --preflight          # 只验兜底链路，不改显示配置
./gui-run.sh ./pipeline_kiosk_probe --spec 1280x720 --duration-ms 5000 \
    --fps 15 --shot /tmp/kiosk-keepmain.png --keep-main   # 半禁屏：主屏仍可见
```
判定：打印虚拟屏 displayID、`采集 1280x720`、结束「已恢复物理屏」；
`/tmp/kiosk-keepmain.png` 有画面。Sequoia 上这轮已 PASS；**Tahoe 本轮未跑，这步就是要补的证据**。

若 2.1 就失败（零显示/WindowServer 断言）：**停**，记 OS/build 到 `RESULTS-BY-OS.md`，
回退镜像模式，不上 2.2。

### 2.2 全禁独占端到端（Tahoe host × Sequoia client）

2.1 过了再跑。host 去掉 `--keep-main`，物理屏会黑；client 连上后看到的是新建虚拟桌面。

```bash
# host（Tahoe）：独占 + 全禁物理屏 + 请求规格 1280x720
cd <macOS-RDP>/P2-Dual
P2_EXCLUSIVE=1 P2_SPEC=1280x720 P2_WIDTH=1280 P2_HEIGHT=720 \
P2_FPS=15 P2_SECONDS=30 P2_INJECT=record P2_WAIT_MS=60000 \
P2_OUT=$PWD/out/exclusive-1120 \
./gui-run.sh ./p2.sh host 2>&1 | tee host-exclusive.log
# 关注三行：
#   [独占] 虚拟屏就绪 ids=...  phase=Streaming
#   [独占] C-09=verified  禁屏后 active=(仅虚拟屏)
#   采集目标：虚拟屏 displayID=...（物理屏已禁用）
```

```bash
# client（Sequoia）：传 --spec，尺寸断言生效
cd <macOS-RDP>/P2-Dual
P2_SPEC=1280x720 P2_HANDSHAKE_MS=30000 P2_WAIT_MS=60000 P2_SECONDS=30 \
P2_OUT=$PWD/out/exclusive-1120 \
./p2.sh client --host 112.5.32.34 --port 46600 \
  --fingerprint 3305dec4c356fadda287fdbe069bd10d8d4088aac57ba08108e7fb39433b1604
```

**判过**（`summary` 新增的独占判据）：
- `会话形态/C-09` 显示 `exclusive / verified`；`请求规格/解码尺寸` 一致；
- host.json：`c09Status=verified`、`activeDisplayIDsAfterDisable` 只有虚拟屏、
  `sessionRecovered=true`、`virtualDisplayIDs` 非空；
- 会话结束物理屏恢复、无黑屏残留；client 窗口尺寸 = 1280x720。

**现场确认**：host 物理屏全程无画面泄露；结束后屏幕回来。
若出现 A-08（零物理屏下送帧不稳）：记 OS/机型，回退 `--keep-main` 模式，不阻塞 P2.1 结论。

> 若只想先安全验证禁屏/恢复机制、不碰 C-09：`P2_EXCLUSIVE=1 P2_KEEP_MAIN=1 ...`，
> 此时 `c09Status=skipped-keep-main`，`summary` 不会把它当 C-09 通过。

---

## 3. 跨机回归矩阵（时间够再做）

组合 `{720p15, 1080p20} × {LAN, WAN}`，入档每条标注 OS build 与机器。
命令沿用 §1（把 `P2_WIDTH/HEIGHT/FPS` 换档），LAN 把 `--host` 改内网 `192.168.10.23`。
**Sequoia 3440×1440 单帧 84.7ms 是独立瓶颈**——1080p 档先看 client `lastRenderMs`，
渲染超预算时先降分辨率，不要误判成网络丢包。

---

## 4. 收口

1. 每轮把两端 `host.json`/`client.json`/`summary` 输出贴回对话，我更新 `RESULTS-BY-OS.md`
   的 §5 与 A-02 状态。
2. 独占那轮额外贴 `c09Status / activeDisplayIDsAfterDisable / sessionRecovered` 三行。
3. 延迟（glass-to-glass）本轮**不测**——没有相机同框/硬件打点手段，A-02 保持开放。

## 5. 中途停止 / 异常

- 停 host：`Ctrl-C` 或 `pkill -f 'stream_probe --host'`；（本轮新代码在正常退出与超时都会
  `endExclusive()` 恢复物理屏，守护进程仍作异常退出兜底）。
- 独占测试后屏幕没回来：先看 `P2-Dual/out/<dir>/host-exclusive.log` 末尾有没有
  `[独占] 已恢复物理屏并销毁虚拟屏`；没有就跑 `./gui-run.sh ./pipeline_kiosk_probe --preflight`
  看守护快照状态，必要时物理重启（不要反复盲跑建屏）。

## 6. TCC 重新授权（重编后 capture=0 / ax=0）

```bash
cd <macOS-RDP>/P2-Dual
cat > host.command <<'EOF'
#!/bin/bash
cd <macOS-RDP>/P2-Dual
exec ./p2.sh host "$@"
EOF
chmod +x host.command
open -a Terminal host.command     # 在屏幕前点「允许」屏幕录制（和辅助功能，若要真注入）
```
授权后**重启该进程**再自检；要走真注入还要在系统设置里给 stream_probe/Terminal 勾辅助功能。
