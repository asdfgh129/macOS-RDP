# M1-Pre-CaptureCodec — 采集主路径端到端采编验证（D-09）

## 为什么有这个工程

D-09 已把采集主路径定为 `CGDisplayCreateImage`（SCK 降为对照/兼容分支）。定决策时只验证了
「抓到的 CGImage 有内容」，**没有验证「抓帧 → CVPixelBuffer → H.264 硬编」整条链路在实时
帧率下是否成立**。NFR-01/03/05（<30ms、60fps、CPU<15%）是 A-02 的核心，必须在 M1 开工前
给出实测，否则产品骨架的帧管线参数无从确定。

本探针在 Tahoe 零 active 物理屏（C-09 形态）下跑完整链路，并统计：

- 抓帧 / 转换 / 编码入队三段耗时分位（p50/p95/max）
- 实际帧率、黑帧数、编码帧数、解码环回帧数、编码错误
- 进程 CPU 核数与整机 busy 百分比
- SCK 同场景对照（可关闭）

## 构建与运行

```bash
bash build.sh                      # 产物 ./capturecodec（ad-hoc 签名）

# 安全模式（不碰物理屏）：先验证链路
./capturecodec --no-disable --duration-ms 3000 --target-fps 60 \
    --out /tmp/m1-pre-nodisable.json --shot /tmp/m1-pre.png

# 核心模式（禁全部物理屏，临时黑屏约 20s，守护进程兜底恢复）
./capturecodec --duration-ms 4000 --target-fps 60 \
    --out /tmp/m1-pre-disable.json --shot /tmp/m1-pre.png

# SCK 编码环回独占对照（跳过 CGDisplayCreateImage，避免同进程争抢 WindowServer）
./capturecodec --sck-only --duration-ms 4000 --out /tmp/m1-pre-sck-only.json
```

参数：`--spec WxH`（默认 1920x1080）、`--duration-ms N`、`--target-fps N`（0=尽力跑）、
`--bitrate-bpp D`（默认 0.12）、`--out PATH`、`--shot PATH`、`--no-disable`、
`--no-sck-control`、`--sck-encode`（SCK 对照带编码）、`--sck-only`（只跑 SCK 编码环回）。

> 会临时黑屏，必须有人在场或确保守护进程可用。恢复失败时看
> `/tmp/p0v-display-guardian.log`，手动 `P0V-DisplayIsolation/v01probe restore --snapshot <path>`。

## 安全机制

复用 `VDManager`（保守 canvas → promote）与 `P0VDisplayControl`（快照/守护/事务死线/恢复）：

1. 内置 `IOPMAssertionPreventUserIdleDisplaySleep` + `PreventUserIdleSystemSleep` 常驻断言
   （D-08 前置：锁屏后 2–3s 屏睡会让采集为空，见 D-08 实测）；
2. 先建虚拟屏、再禁物理屏、最后抓帧（C-09 + D-05 硬约束，杜绝零物理屏下新建屏的
   `canonical_mirror_master` 崩溃）；
3. 禁屏前落盘快照并启动守护进程，任何异常退出都由守护进程恢复；
4. 恢复后按快照 enable 全部物理屏并还原 mode/origin/mirror。

## 实测结果（2026-11-18，Tahoe 26.5.2 / 25F84，Macmini8,1）

三组运行全部 `verdict=PASS`（抓帧/编码/解码计数一致、0 黑帧、0 编码错误、恢复 OK），但**帧率
全部不达标**：

| 场景 | 分辨率 | 实际 fps | 抓帧 avg/p95 (ms) | 转换 avg/p95 (ms) | 编码入队 p50 (ms) | 整机 busy |
|---|---|---|---|---|---|---|
| `--no-disable` | 1920×1080 | 1 | 282 / 356 | 60 / 96 | 1.2 | 99% |
| 禁全部物理屏 | 1920×1080 | 4 | 125 / 168 | 47 / 94 | 0.1 | 99% |
| 禁全部物理屏 | 1280×720 | 7 | 95 / 124 | 17 / 23 | 0.1 | 77% |

证据：`/tmp/m1-pre-nodisable.json`、`/tmp/m1-pre-disable.json`、`/tmp/m1-pre-disable-720.json`；
截图 `/tmp/m1-pre-nodisable.png`（真实桌面壁纸+菜单栏，2.1MB，非黑）。

### SCK 编码环回对照（`--sck-only`，排除同进程争抢污染）

| 场景 | 编码 | fps | 帧数 | 编码/解码 | 首帧延迟 | 黑帧 |
|---|---|---|---|---|---|---|
| 禁屏 1080p `withEncoder:NO` | 否 | ~~55~~ 假象 | 55 | 0 / 0 | 847ms | 0 |
| 不禁屏 1080p `withEncoder:YES` | 是 | 2 | 11 | 11 / 11 | 1031ms | 0 |
| 禁屏 1080p `withEncoder:YES` | 是 | **18** | 73 | 73 / 73 | 739ms | 0 |

证据：`/tmp/m1-pre-sck-only-nodisable.json`、`/tmp/m1-pre-sck-only-disable.json`。

### 结论（写入 `docs/RESULTS-BY-OS.md`，2026-11-18 11:35 定稿）

1. **两条链路都成立**：`CGDisplayCreateImage` 与 SCK 在零物理屏下端到端都可用，零黑帧、
   编码解码计数一致、无编码错误。采集能力不是瓶颈。
2. **«55fps» 是假象，已撤销**：不带编码时 SCK 按内容变化送帧，静态桌面 1s 推 55 帧，但
   `encodedFrames=0`、首帧 847ms；不能当可用帧率。这是本项目第三次「静态 SCK fps 不可当结论」
   的陷阱（前两次见 README §15 性能警告、A-05），已拦下。
3. **带编码的真实帧率都不达标**：`CGDisplayCreateImage` 1–7fps、SCK 2–18fps，均远低于
   1080p60。相对而言 SCK 更优（禁屏 18fps vs 4fps，且原生 IOSurface 零拷贝）。
4. **CPU 记账**：整机 busy 77–99%，但本进程只占 0.14–0.21 核 —— 开销在 WindowServer/
   系统合成侧。首帧延迟 739–1031ms 也贴近/超过 FR-05「首帧 <1s」。
5. **对 M1 的影响（D-10）**：建议 **SCK 回主路径 + 目标帧率下调 15–30fps**，
   `CGDisplayCreateImage` 降兜底；流水线并行作为后续优化，不进 M1 关键路径。
   **决策前不冻结帧管线参数**；M1 骨架的会话层/显示隔离/输入/配对不受影响，可先开工。

## 按 OS 记录

- Tahoe 26.5.2（25F84）：如上，链路 PASS、帧率不达标。
- Sequoia 15.5：未测（SCK 在该版本 V-03 已达 60fps，无切主路径动机）。
