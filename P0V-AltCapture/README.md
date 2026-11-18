# P0V-AltCapture — 零 active 物理屏下的替代采集路径对照

## 为什么有这个工程

2026-11-18 在 Tahoe 26.5.2 上实测发现：V-03 把全部物理屏退出 active 后，
虚拟屏仍在正常合成（系统截图可见完整桌面），但 **SCK 送出的帧多数或全部是黑帧**。
Sequoia 15.5 上同一流程曾 `HAS_CONTENT`，结论不可跨版本外推。

本探针在**同一个会话**里对三条路径做 A/B：

| 路径 | API | 目的 |
|---|---|---|
| SCK | `SCStream` / `PipelineProbe`（复用 P0） | 现有产品路径，作基线/失败对照 |
| 整屏 | `CGDisplayCreateImage(displayID)` | 看公开抓屏 API 是否绕过 SCK 异常 |
| 窗口 | `CGWindowListCreateImage(region, onScreenOnly)` | 看能否只抓窗口内容（不含桌面） |

## 构建

```bash
cd P0V-AltCapture
bash build.sh      # 产物 ./altprobe，ad-hoc 签名 com.p0v.altcapture
```

源码复用 `P0-TahoeProbe/src/{VDManager,PipelineProbe,ProbeUtil}` 与
`P0V-DisplayIsolation/src/P0VDisplayControl`，不改它们。

## 执行

```bash
./altprobe --spec 1280x720 --capture-ms 1200 --out /tmp/p0v-alt-tahoe.json
# 可选：--no-disable 只建屏不禁屏；--focus 把光标移到虚拟屏并点击；
#       --shot /tmp/x.png 存禁屏前帧，另自动存 /tmp/x.png.disabled.png（禁屏后帧）
```

流程：

1. 快照 active display，启动守护进程兜底（与 `v01probe` 同机制）；
2. 建 1 块虚拟屏并 promote 到目标分辨率，等 SCK 可见；
3. **基线**：禁屏前，三条路径各采一轮；
4. 在同一显示配置事务内禁用**全部物理屏**；
5. **对照**：禁屏后，三条路径各采一轮；
6. 按快照恢复物理屏，写 JSON。

> 会临时让整机 UI 消失，必须有人在场。退出码 2 表示恢复失败或前置失败，
> 先看 `<snapshot>.guardian-result.json` 与 `/tmp/p0v-display-guardian.log`，
> 再手动 `P0V-DisplayIsolation/v01probe restore --snapshot <path>`。

## 判读

每轮结果含 `mean`（最暗采样点）、`maxVariance`（最亮采样点的方差）、
`blackSamples` 与 `verdict`：

- `HAS_CONTENT`：所有采样都有非黑内容；
- `PARTIAL`：部分采样有内容；
- `MOSTLY_BLACK`：全部采样接近纯黑。

真正决定 M1 的是**禁屏后**的一轮：

- 若 `CGDisplayCreateImage` 或 `CGWindowListCreateImage` 稳定 `HAS_CONTENT`，
  则 M1 可用它替代 SCK，C-09（物理屏全禁）保住；
- 若三条路径都黑，则 Tahoe 上只能按 D-05 第 3 条降级
  （`CGDisplayCapture` + 遮罩 + 强制光标接管），并写明非绝对安全；
- SCK 一行的价值是复现已知失败，不作为产品路径结论。

## 按 OS 记录

结果一律标注实测 OS/build，禁止把 Sequoia 结论外推到 Tahoe：

- Sequoia 15.5（24F74）：未测。
- Tahoe 26.5.2（25F84）：2026-11-18 实测。禁掉全部物理屏后：
  - `CGDisplayCreateImage`：1280×720 `minMean=39/maxVar=1506`，1920×1080 `minMean=37/maxVar=1562`，均 0 黑采样、`HAS_CONTENT`；
  - `CGWindowListCreateImage`：修正禁屏后 bounds 重排（x=4520→0）导致的区域错位后，与整屏路径一致；
  - SCK：V-03 中曾全黑/多数帧黑；本探针中虽 `HAS_CONTENT`，但仅 2–4fps，不可作为实时路径。
  - 恢复 OK。证据：`/tmp/p0v-alt-tahoe3.json`、`/tmp/p0v-alt-tahoe-1080.json`。
- 锁屏态 `--no-disable`：旧版 8s liveness 判 `active=false` 是假阴性（硬闸门提前退出），
  修正后锁屏+屏亮态虚拟屏 `active=1`，三路径均 `HAS_CONTENT`。
- **2026-11-18 10:52 最终结论（Path A 成立）**：在锁屏+屏亮态建 active 虚拟屏后
  **禁掉全部物理屏**，登录 UI 完整迁移到虚拟屏：

```bash
# 先 caffeinate -d 保持屏亮，再程序化锁屏（见 P0V-SessionRecon/run_patha_*.sh）
./altprobe --spec 1280x720 --capture-ms 1500 --focus \
    --shot /tmp/lock.png --out /tmp/result.json
# 禁屏后帧存到 /tmp/lock.png.disabled.png：可见日期/时钟/用户名/Enter Password 框
```

  `--focus`（移光标+点击）**非必需**：`run_patha_nofocus.sh` 不做聚焦，禁屏后同样拿到
  完整登录框 ⇒ 触发条件是「零 active 物理屏」。两轮禁用/恢复均 OK，
  SCK/双公开 API 在三路径下全 `HAS_CONTENT`。详见 `docs/RESULTS-BY-OS.md` §3.3/§4。
