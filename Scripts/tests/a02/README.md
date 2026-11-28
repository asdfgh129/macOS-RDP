# A-02 端到端延迟：无相机替代法

A-02 的定义是「主机屏幕上出现某时刻的画面 → 客户端屏幕上也出现它」的时间差。
没有 240fps 相机时，本目录提供两条互补路径：

1. **主判据 inband（推荐，数值判据）**：用 SCK 帧头携带的
   `SCStreamFrameInfoDisplayTime`（WindowServer 真正显示该帧的 mach 时刻），
   客户端在贴层时结算 `presentP50 = 显示时刻 → 上屏`。**不截屏、不侵入合成器**。
2. **交叉验证双钟同框**：主机画洋红毫秒条码（被采集），客户端在自己窗口里画青色
   参考条码（不经流），一次截屏同时读两个钟，截屏时刻消掉。仅作视觉/自检用。

## 1. 为什么不用「单钟 + 截屏」

`CGDisplayCreateImage` 在本机（Tahoe 26.5.2 / 3440×1440）单次耗时 **177–695ms**，
而且无法知道快照究竟发生在调用的哪一刻：同一张图上 `t0 − 钟读数` 是 −600ms、
`t1 − 钟读数` 是 +40ms。延迟在 30–50ms 量级时不确定度比被测量还大，不能用于判定。

## 2. 主判据 inband 的口径

| 项 | 说明 |
|---|---|
| 起点 | WindowServer 把该帧显示出来（`SCStreamFrameInfoDisplayTime`，换算成 epoch） |
| 终点 | 客户端把该帧 IOSurface 赋给 `layer.contents` |
| 含 | 采集、编码、QUIC 传输、重组、解码、渲染转换、主线程贴层 |
| 不含 | 两端显示器扫描输出、相机曝光；**不等于**相机同框的 glass-to-glass |
| 跨机 | 两端墙钟差需减掉控制通道 `time-sync` 估出的 `clockOffsetUs`；同机为 0 |

关键实现（改动见 C-17.47）：

* `M1CapturePipeline.m`：SCK 回调不再用 `M1WallMs()`（回调时刻），改读
  `SCStreamFrameInfoDisplayTime` 并按 `mach_timebase_info` 换算成 epoch 毫秒。
  积压时两者差可达秒级，旧口径会把延迟系统性低估。CGDisplayStream / 锁屏快照
  后端没有该字段，仍用回调时刻。
* `M1FrameView.m/.h`：新增 `onPresentCommit`，在 `layer.contents` 提交的
  **同一主线程事务**里回调。
* `Apps/Client/Sources/main.swift`：`A02RefBarcodeView` 不再用 8ms Timer 重绘
  （主线程积压时会冻结读数，把 713ms 测成 100ms），改为随帧同步更新 `layer.contents`。

## 3. 用法

```bash
bash Scripts/tests/a02/build.sh                 # 出 a02_clock / a02_shot
bash M1-Skeleton/build_stream_probe.sh          # 出 host 侧 stream_probe
bash Scripts/build.sh VeilRD                    # 出客户端（含 --ref-barcode / onPresentCommit）

# 主判据：本机 host + client，40s，720p。3440×1440 源屏默认带 M1_CAPTURE_RESOLUTION=best
./run.sh inband-local --display <CGDisplayID> --spec 1280x720 --seconds 40

# 主判据：跨机（host 已在 14 上起好），13 这边只跑客户端并结算
./run.sh inband-client --host 192.168.34.212 --port 46600 \
    --fingerprint <host_fp> --spec 1920x1080 --seconds 40

# 双钟判读链路自检：注入 -40ms，判读中位数应为 -40ms（±20ms）
./run.sh selftest --display <CGDisplayID> --skew-ms -40

# 双钟交叉验证（数据不可当判据，见 §5）
./run.sh local --capture-display <CGDisplayID> --samples 20 --interval 0.3
./run.sh shot --two --window <CGWindowID> [--png out.png]
./run.sh shot --png-in shot.png          # 离线复判
./run.sh list                            # 屏幕与窗口 id
```

产物在 `--outdir`：`host.json` / `client.json`（计数与 presentP50/P95）、
`host.log` / `client.log`、`clock.log`；双钟模式另有 `samples.jsonl` / `sample.png`。

## 4. 实测结果（2026-11-28，仅 Tahoe 26.5.2 / Macmini8,1）

镜像模式，源屏 3440×1440，内容源 `a02_clock` 30fps：

| 规格 | 采集设置 | display→present p50 | p95 | 判定 |
|---|---|---|---|---|
| 1280×720 @30 | `M1_CAPTURE_RESOLUTION=best` | **39.5ms** | 48.5ms | PASS |
| 1920×1080 @30 | 默认（3440×1440 降采样） | 181.5ms | 1213.5ms | FAIL |
| 1920×1080 @30 | best，两轮 | 47.5 / 54.5ms | 498.5 / 1115.5ms | 贴线，未稳定达标 |

⇒ strict A-02（1080p <50ms）在 Tahoe 本机**未稳定闭合**；720p 达标。
本机双物理屏 + 3440×1440 源屏是不利条件，**不外推到 13/14**。
14×13 的 72h soak 结束后按上面的 `inband-client` 在两台独立机器上补 1080p。

## 5. 双钟模式的已知限制（详见 RESULTS §5.51）

* 同屏环回 → 镜中镜：流里嵌套整块主屏，`A02LargestComponent` 选中主屏直出的大条码 ⇒ 假值 100ms。
* 跨屏 + `CGDisplayCreateImage` 抓副屏 → 单次抓图 597ms 侵入合成器 ⇒ 假值 2554ms。
* 跨屏 + `--window` 抓客户端窗口 → 抓图 150–650ms，仍拖慢合成器；双钟读数分裂为
  80–400ms 与 1.1–3.5s 两簇，且与抓图耗时强相关。**只作交叉验证。**
* 副屏（独立 Space）上由其它进程创建的窗口拿不到合成；`orderFrontRegardless`、
  激活、screenSaver 层级、全局坐标 `setFrame` 全试过，副屏始终只有壁纸。
  所以参考钟放在客户端进程自己的窗口里。
* 条码在格宽 < 6px（画面被缩到 1/6 以下）时读不出，属分辨率边界。

## 6. TCC 与环境的坑

* **host 不能套 `script -q /dev/null`**：pty 会改变 TCC 责任进程，SCK 立刻被拒。
* **未签名的 `veild-host-agent` 在非 GUI 上下文拿不到屏幕录制**；`stream_probe`
  已有授权 ⇒ `run.sh` 默认用它当 host（`A02_HOST=product` 可切回产品入口）。
* 客户端日志要行缓冲才能轮询状态，所以客户端仍套 `script`。
* 屏睡会让 SCK 直接没有帧；`run.sh` 全程 `caffeinate -d -u`。
* 会话被锁时截图只剩壁纸、客户端整帧不上屏（`framesRendered=0`）。
  前置检查：`ioreg -n Root -d1 | grep IOConsoleLocked`（`=No` 才对）或
  `stream_probe --preflight` 的 `locked=0`，不要只看截图。
* 黑屏 ≠ 锁屏：机器空闲会熄屏但不锁，`caffeinate -d -u -t N` 唤醒即可。
