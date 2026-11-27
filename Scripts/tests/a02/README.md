# A-02 玻璃到玻璃延迟：无相机替代法（时钟 + 截屏）

A-02 的定义是「主机屏幕上出现某时刻的画面 → 客户端屏幕上也出现它」的时间差。
原计划用 240fps 相机把两块屏拍进同一帧读数；**没有相机**时，本目录用
「同一帧里放两个时钟」的办法等价实现——把相机的 CMOS 换成显示器帧缓冲。

## 1. 为什么单钟截屏不行

`CGDisplayCreateImage` 在本机（Tahoe 26.5.2 / 3440×1440）单次耗时 **177–695ms**，
而且无法知道快照究竟发生在调用的哪一刻：同一张图上
`t0 − 钟读数` 是 **−600ms**、`t1 − 钟读数` 是 **+40ms**，中间全靠猜。
延迟在 30–50ms 量级时，这个不确定度比被测量本身还大，**单钟 + 截屏不能用于判定**。

## 2. 双钟同框（本方案）

```
        ┌───────────── 采集屏（同屏模式，单显示器即可）─────────────┐
        │  a02_clock 全屏：洋红条码 + 大号毫秒时钟（被采集的内容）  │
        │      ┌─────── 客户端窗口（1200×675，居中）───────┐        │
        │      │  远端画面（含洋红条码，已延迟）            │        │
        │      │  左下角：青色条码 = 本机当前毫秒（--ref-barcode）│  │
        │      └────────────────────────────────────────────┘        │
        └────────────────────────────────────────────────────────────┘
                                ↑ 一次截屏，只裁客户端内容矩形
```

* 洋红条码 = 主机侧「被采集的内容」，经过 采集→编码→QUIC→解码→上屏；
* 青色条码 = 客户端进程自己画的**本机时钟**，不经过任何流；
* 两者在**同一帧**里被合成 ⇒ 截屏的时刻完全消掉，延迟 = 青读数 − 洋红读数。

条码是 48 位 epoch 毫秒 + 8 位校验（56 格），外框洋红/青各 C/2 厚，
解码端用「彩色连通域 + 57:4 形状 + 密度」定位，再按 Cx/Cy 分别反推格宽，
因此**缩放无关**（3440 采成 1280、再显示成 1200 都能量）。

### 口径（写结论时必须带上）

| 项 | 说明 |
|---|---|
| 起点 | 主机应用把该毫秒值绘进图层（不是显示器扫描出光子） |
| 终点 | 客户端窗口该帧被 WindowServer 合成（不是相机采样到光子） |
| 含 | 主机合成/采集、编码、传输、解码、上屏 |
| 不含 | 两端显示器扫描输出、相机曝光；**不等于**相机同框的 glass-to-glass |
| 系统性偏差 | 主机绘制→采集之间有 0–2 个刷新周期（16.7–33.4ms @60Hz），偏高 |
| 对照量 | 客户端 `presentP50Ms`（帧头 `capturedAtUs` → 上屏）给出**下界** |

即：真实 glass-to-glass 落在 `[presentP50, 双钟p50]` 区间内——
下界是「采集完成」起算，上界是「应用绘制」起算，差值就是主机合成+采集那一段。

## 3. 用法

```bash
bash Scripts/tests/a02/build.sh                 # 出 a02_clock / a02_shot

# 同屏环回（推荐，单显示器即可；也不需要 GUI Terminal 授权之外的任何东西）
./run.sh local --capture-display <CGDisplayID> --samples 40 --interval 0.3

# 自检：参考钟故意偏 40ms，判读应为 +40ms（证明整条判读链路无错位）
./run.sh selftest --display <CGDisplayID> --skew-ms -40

# 单次采样（跨机时在客户端机器上跑）
./run.sh shot --two --display <CGDisplayID> --rect x,y,w,h [--png out.png]
./run.sh shot --png-in shot.png          # 离线复判，用于取证
./run.sh list                            # 屏幕与显示器 id
```

产物在 `/tmp/veild-a02/`：`samples.jsonl`（每次采样一行 JSON）、`sample.png`
（第一帧截图，人眼可核对条码与时钟）、`host.json` / `client.json`（两端计数）、
`host.log` / `client.log`。

## 4. 跨机怎么跑（soak 结束后）

主机侧（本机，需屏幕录制授权，见 §5）：

```bash
a02_clock --display <采集屏> --hold 120          # 洋红条码内容源
stream_probe --host --port 46600 --mirror --display <采集屏> \
    --spec 1280x720 --width 1280 --height 720 --fps 30 \
    --duration-ms 120000 --identity <p12> --out /tmp/host.json
```

客户端侧（另一台机器）：

```bash
VeilRD --connect <host> --port 46600 --fingerprint <host_fp> \
    --identity <p12> --spec 1280x720 --window 1200x675 \
    --ref-barcode --duration-ms 90000 --out /tmp/client.json
# 客户端会打印 A02_WINDOW_RECT x,y,w,h（CG 全局坐标，左上原点）
a02_shot --two --display <客户端屏> --rect <A02_WINDOW_RECT>   # 反复采样
```

跨机时两端时钟不同源：延迟 = (青读数 + host−client 时钟差) − 洋红读数，
钟差用控制通道 `time-sync` 的最小 RTT 样本（LAN 上 ±1ms 量级）。
同机环回时该差为 0，这也是本目录默认先跑环回的原因。

## 5. TCC 与主机选择（踩过的坑）

* **host 不能套 `script -q /dev/null`**：pty 会改变 TCC 的「责任进程」，
  SCK 立刻报 `The user declined TCCs ...`、CGDisplayStream 返回空 stream。
* **未签名的 `veild-host-agent` 在非 GUI 上下文拿不到屏幕录制**（本机 debug 产物
  无签名），而 `stream_probe`（adhoc、`com.m1.pipeline`）已有授权 ⇒
  `run.sh` 默认用 `stream_probe` 当 host（采集/编码/传输是同一份 RDPKit），
  `A02_HOST=product` 可切回产品入口（须在 GUI Terminal 内运行）。
* **客户端日志要行缓冲**才能轮询 `A02_WINDOW_RECT`，所以客户端仍套 `script`。
* 屏睡会让 SCK 直接没有帧；`run.sh` 全程 `caffeinate -d -u`。
* **会话被锁**（`CGSSessionScreenIsLocked=Yes`）时截图只剩壁纸、客户端整帧不上屏
  （`framesRendered=0`）——这一条最容易误判成「窗口没显示/工具坏了」。

## 6. 已知限制

* 参考钟放在客户端进程内，是因为**副屏（独立 Space）上由其它进程创建的窗口拿不到
  合成**：`orderFrontRegardless`、激活、screenSaver 层级、全局坐标 `setFrame` 全试过，
  副屏始终只有壁纸。同屏布局因此不需要第二块显示器。
* 主机绘制到采集之间的 0–2 帧无法用软件消除，只能用 `presentP50` 给下界。
* 条码在格宽 < 6px（画面被缩到 1/6 以下）时会读不出，属分辨率边界。
