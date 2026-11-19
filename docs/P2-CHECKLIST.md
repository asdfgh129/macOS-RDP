# P2 双机联调清单（M1-B 跨机验收 + A-02 延迟打点）

本文是**今晚照着做**的操作单：两台机器、三十步以内、每步都有可核对的输出。
所有脚本都在 `P2-Dual/`，二进制在 `M1-Skeleton/`。

---

## 0. 角色与拓扑

```
   ┌──────────────────────────┐          ┌──────────────────────────┐
   │  host（被控端）            │          │  client（控制端）          │
   │  SCK 采集 → VT 编码        │  QUIC    │  重组 → VT 解码 → 窗口上屏  │
   │  → 分片 → QUIC datagram   │◄────────►│  鼠标键盘 → 归一化 → 回传   │
   │  ← 输入事件 → CGEventPost  │  局域网   │                          │
   └──────────────────────────┘          └──────────────────────────┘
       需要：屏幕录制 + 辅助功能              需要：无特殊授权
```

- **host 就是被远程的那台**：它必须给「屏幕录制」（SCK 采集）和「辅助功能」（CGEventPost 注入）两个授权。
- **client 是你看画面的那台**：不需要任何 TCC 授权，但要能解码 3440×1440（或 host 的实际分辨率）。
- 两端必须**同一份 commit**：帧头已升到 v2（18B，`fragIdx/fragCount` 为 u16），v1 二进制解不了 v2 分片。

建议先确认：`git log --oneline -1` 两端一致。

---

## 1. 两台机器都要做的准备

| 项 | 命令 / 做法 | 判定 |
|---|---|---|
| 代码 | `git clone`（或用 `rsync -a --exclude .state` 从这台拷过去） | 目录里有 `M1-Skeleton/` |
| 编译 | `cd M1-Skeleton && bash build_stream_probe.sh` | 最后一行 `built: ./stream_probe` |
| 网络 | 同一网段、优先有线；关闭 VPN/代理（会劫走 UDP 路由） | 互相 `ping` 通 |
| 休眠 | host 端 `caffeinate -d -u -t 3600`（`p2.sh host` 会自动起一个） | 屏幕不睡 |
| 防火墙 | 系统设置 → 网络 → 防火墙：**关**，或给 `stream_probe` 放行入站 | `--getglobalstate` 显示 disabled，或已放行 |

端口统一用 **46600/UDP**（`P2_PORT` 可改，两端要一致）。

---

## 2. host 端（被控机）

```bash
cd P2-Dual
./p2.sh preflight host          # 先自检
./p2.sh host                    # 正式跑，默认 60s、20fps、--inject real
```

`preflight` 逐行看，必须 `ok=1`：

```
[preflight] ax=1 capture=1 locked=0 asleep=0 onConsole=1 active=2
[preflight] proto frameHeaderVersion=2 headerSize=18 maxPayload=1150
[preflight] ip=192.168.10.23(en0)
[preflight] ok=1
```

- `capture=0` → 缺**屏幕录制**：系统设置 → 隐私与安全性 → 屏幕录制 → 勾 `stream_probe`（或终端/WorkBuddy），**授权后要重启该进程**。
- `ax=0` 且用 `--inject real` → 缺**辅助功能**：同一面板勾上，授权后重启进程。
- `locked=1` / `asleep=1` → 解锁 / `caffeinate -d -u`。

跑起来后屏幕上会出现：

```
===== 给客户端的三项 =====
  IP   : 192.168.10.23(en0)
  端口 : 46600
  指纹 : 3305dec4c356...b1604
=========================
```

**把这三项抄给 client 那台**（指纹是 64 位 hex，别抄错；抄错会卡在 `preparing` 直到超时）。

host 会等客户端接入最多 15s，然后推流 `P2_SECONDS` 秒。

---

## 3. client 端（你看画面那台）

```bash
cd P2-Dual
./p2.sh preflight client --host 192.168.10.23     # 顺带测连通性
./p2.sh client --host 192.168.10.23 --fingerprint 3305dec4...
```

正常输出顺序：

```
连接 192.168.10.23:46600
握手完成 18.1 ms
已 STREAMING，接收 60000 ms
  目标屏 displayID=1000（w=1920 h=1080），开始捕获窗口输入
```

出现窗口后**点一下窗口**（WindowServer 只把 `mouseMoved` 投给前台应用），
然后在画面里移动鼠标——host 那台的**光标会跟着动**，这是本轮最关键的一条实证。

> `目标屏 displayID=1000` 是 M1 阶段的占位值（真实 displayID 由 VDManager 在 M1-C 接入），
> 不影响输入：host 用自己采集那块屏的 `CGDisplayBounds` 做坐标映射。

---

## 4. 判定阈值

结构性指标（`./p2.sh summary host.json client.json` 会自动判 PASS/FAIL）：

| 指标 | 阈值 | 说明 |
|---|---|---|
| 双端状态序列 | 一致，末态 `STREAMING` | 逐条比对 `stateLog` |
| 解码/发出 | ≥ 0.95 | 低于此值说明丢包或关键帧请求过多 |
| 客户端丢帧 | < 5% | `framesDropped / framesCompleted` |
| 主机 `sendFailures` | = 0 | 非 0 说明分片数/MTU 有问题 |
| 控制通道最大间隔 | < 3000 ms | 心跳 1s，超过 3 倍即被视频挤掉 |
| 客户端上屏 | ≥ 1 帧且 fps ≥ 0.8×目标 | 窗口不可见会被跳过（`renderSkippedOccluded`） |
| 输入 | `inputInjected ≥ 5` 且 `cursorMovedPx > 0` | 真注入必须体现在主机光标上 |

延迟指标（记数字，不设硬门禁，A-02 仍开放）：

| 指标 | 参考值（单机基线） | 备注 |
|---|---|---|
| 握手 | 18 ms（LAN 环回） | 跨机预期 20–100 ms |
| 首帧 | 主机 239 ms / 客户端 475 ms @3440×1440 | 跨机加 100–300 ms |
| 解码单帧 | 0.8 ms | 硬解 |
| 渲染单帧 | 12.9 ms @3440×1440 | IOSurface 直贴 |
| **glass-to-glass** | **本轮测不了** | 需要相机拍客户端屏幕与主机毫秒时钟同框；方案见 §7 |

---

## 5. 失败对照表（都踩过，按这个顺序查）

| 现象 | 真因 | 处理 |
|---|---|---|
| 客户端 `握手未在 12000ms 内完成` | 指纹抄错 / 端口不对 / 被防火墙丢 | 核对三项；`nc -vzu` 不通就查防火墙与网段隔离 |
| 握手卡在 `preparing` 且无错误码 | 证书材料不可用（旧二进制 / 钥匙串 ACL 弹窗） | 看有没有 SecurityAgent 弹窗；重跑 `./gen_quic_identity.sh` 后重建 |
| 端口和 `--port` 不一致 | **已修**：`nw_listener_create` 会忽略端口，改用 `nw_listener_create_with_port` | 本次已修，host 会打出真实端口 |
| `capture=0` / 主机无帧 | 缺屏幕录制授权 | 勾选后**重启进程** |
| `ax=0` / 主机光标不动但 `inputReceived>0` | 缺辅助功能授权，`CGEventPost` 被静默丢弃 | 勾选；**先定稿再授权，重编会让授权失效**（按 cdhash 记） |
| 主机有帧、客户端不显示 | 窗口被遮/不可见 → `renderSkippedOccluded` | 把窗口拿到最前 |
| 画面在动但鼠标不动 | 客户端窗口不是前台应用 | 点一下窗口再动 |
| 帧率异常低、`keyframeRequests` 暴涨 | 链路丢包严重 | 换有线、关 VPN、降 `P2_FPS` |
| 分片解析失败/黑屏 | 两端版本不一致（帧头 v1 vs v2） | 两端同一 commit 重新构建 |

---

## 6. 结果收集

两台机各有一份产物，收口时把 host 的两个文件拷到 client 那台：

```bash
# client 侧
scp bemin@192.168.10.23:/path/to/P2-Dual/out/<时间戳>/host.json .
./p2.sh summary host.json client.json
```

`p2.sh summary` 输出一张表 + PASS/FAIL。把这段贴回对话即可，我按它更新
`docs/RESULTS-BY-OS.md` 的 §5.10 与 A-02 状态。

---

## 7. glass-to-glass（A-02）尚未闭合，今晚不硬测

现有打点只能给出**管线分段**：主机「采集→编码→发出」、客户端「收到→解码→上屏」，
缺的是「显示器扫描出图像 → 摄像头采样」这两跳，以及网络单程时延。

三条可选路线（按成本排序，留给 M2）：

1. **手机高速摄影**（成本最低）：host 屏幕显示毫秒时钟，手机 240fps 同框拍 host 屏与 client 屏，逐帧读表差值。
2. **硬件打点**：host 用 USB-GPIO/Arduino 触发一个光点 + 记时间戳，client 侧光敏电阻接收。
3. **协议内嵌时间戳**（要改帧头 v3）：capture 时写 `CACurrentMediaTime()`，客户端用 NTP 同步后的时钟算单程。精度受时钟同步限制（通常 1–10 ms），够判「是否 < 50 ms」的量级。

今晚先把「跨机能不能跑通、指标稳不稳」钉死；延迟硬指标不要在没有测量手段时下结论。
