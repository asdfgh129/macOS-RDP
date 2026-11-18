# P0V-DisplayIsolation —— V-01 / V-03 显示隔离探针

验证 M1 会话层的前置假设 A-08：

1. **V-01**：把一块物理屏从窗口服务器的 active 集合中 disable 后
   - 物理屏不再出现在 `CGGetOnlineDisplayList` / `CGGetActiveDisplayList`
   - 虚拟屏仍然可以被 ScreenCaptureKit 捕获（`HAS_CONTENT`）
   - 指针/鼠标事件仍能落在虚拟屏坐标空间内
   - 唤醒类事件不会把物理屏重新 enable
2. **V-03**：全部物理屏都 disable 的极限情形下
   - 仍可建虚拟屏、捕获、注入
   - 仍可在只剩虚拟屏时再建第二块虚拟屏

对应硬约束：C-07（禁止镜像语义）、C-09（会话期间 active 集合只含本会话虚拟屏）、
D-05（disable 而非置黑）。本探针**只做验证**，不是 M1 的会话实现。

> **实测环境**：本文 2026-11-17 的全部结论来自 **macOS 15.5 Sequoia（24F74）/
> Macmini8,1 / Intel i5-9500 / x86_64**。当天下午 Tahoe 机的 P0-T 结果与本文不可混用，
> 执行前先确认 `probe` 打印的 `osVersion` / `model`。

## 构建

```bash
cd P0V-DisplayIsolation
bash build.sh          # 产物 ./v01probe，ad-hoc 签名 com.p0v.displayisolation
```

源码复用 `P0-TahoeProbe/src` 的 `ProbeUtil` / `VDManager` / `PipelineProbe`，
虚拟屏 vendor 固定为 `0x5030`，与物理屏区分。

## 执行顺序（务必按此顺序）

```bash
# 0. 只读侦察：确认私有符号、SCK、显示拓扑
./v01probe probe

# 1. 落盘快照（恢复用；run 内部也会自动落盘）
./v01probe snapshot --out /tmp/p0v-snapshot-manual.json

# 2. 干跑：只建虚拟屏 + 捕获基线，不碰物理屏
./v01probe run --dry-run --yes --spec 1280x720 --capture-ms 800 --watch-secs 0

# 3. V-01：禁用一块物理屏（默认优先非主屏）
./v01probe run --mode one --yes

# 4. V-03：禁用全部物理屏（整机 UI 会消失，必须有人在场）
./v01probe run --mode all --yes
```

`run` 在非交互环境必须显式给 `--yes`；交互环境会要求输入 `YES`。
默认结果写到 `/tmp/p0v-display-isolation.json`，快照写到
`/tmp/p0v-display-snapshot-<pid>.json`。

### 主要选项

| 选项 | 含义 |
| --- | --- |
| `--mode one\|all` | V-01 禁一块 / V-03 禁全部 |
| `--target ID` | 指定要禁用的物理屏；默认优先非主屏 |
| `--spec WxH` `--hidpi` | 虚拟屏点尺寸与 2x |
| `--count N` | 虚拟屏块数（默认 1） |
| `--watch-secs N` | 禁用后观察重新 enable 的秒数（默认 20，0=跳过） |
| `--commit session\|permanent` | 显示配置提交范围（默认 session） |
| `--reassert` | 观察到物理屏回来后再禁用一次（默认只记录） |
| `--dry-run` | 建虚拟屏 + 捕获基线后停止，不动物理屏 |
| `--no-rebuild-test` | V-03 下跳过「再建一块虚拟屏」测试 |
| `--allow-stale-slots` | 明知有残留虚拟屏槽位仍一次创建多块（可能触发 WindowServer 断言，勿轻用） |
| `--no-guardian` | 不启动兜底守护进程（不推荐） |
| `--commit-timeout N` | 显示事务死线秒数（默认 20） |
| `--out PATH` | 结果 JSON 路径 |

## 安全设计

- **先快照、后动屏**：只记录 active 屏的完整状态（bounds / mode / mirror / main），
  SLS 里的残留槽位不会进快照。
- **守护进程兜底**：`posix_spawn` 自身以独立进程组运行 `--guardian`，父进程
  Ctrl+C / SIGKILL / 崩溃时由它读快照恢复物理屏，结果写
  `<snapshot>.guardian-result.json`；父进程恢复成功会写 `<snapshot>.done` 让它退出。
  日志：`/tmp/p0v-display-guardian.log`。
- **事务死线 + 熔断**：所有 WindowServer 同步 IPC 放后台线程，超时置
  `windowServerHung` 并立即中止，之后不再重试、不再释放虚拟屏（交给进程退出）。
- **两阶段恢复**：先只 enable 当前不在 active 集合的快照屏，再在事务内恢复
  mirror / mode / origin，最后校验 active 集合、bounds（±1pt）与主屏身份。
- **拓扑校验失败退出码 2**，同时保留快照与 guardian 日志供人工恢复。

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 通过 / 干跑完成 / 取消但恢复成功 |
| 1 | 假设不成立（某项判据 FAIL），但恢复成功 |
| 2 | 恢复失败（需要人工介入） |
| 3 | 参数或前置条件错误 |

## 结果判读

`run` 结果 JSON 里 `checks` 的各项：

- `disableEffective`：目标屏已从 active（并预期从 online）消失
- `virtualCapture`：虚拟屏捕获为 `HAS_CONTENT`
- `sckClean`：SCK 的 displays 只含虚拟屏（C-09）
- `pointerOK`：5 点 warp 偏差 ≤ 1px
- `inputOK`：鼠标 move 事件能注入并落在虚拟屏内
- `noReenable`：观察期内物理屏没有被唤醒事件重新 enable
- `rebuildOK`：V-03 下再建一块虚拟屏并捕获成功
- `rebuildTested`：重建子项是否真的执行（有停放槽位时为 `false`，`rebuildOK` 此时不计入判定）
- `activeSetMatchesExpected`：active 集合与预期完全一致

`label`：`PASS` / `PASS_NO_WAKE_TEST` / `FAIL` / `ABORTED` / `CANCELLED` /
`WINDOWSERVER_HUNG` / `RESTORE_FAILED` / `DRY_RUN`。

## 已知限制

- **Intel 上 `SLSConfigureDisplayEnabled` 可能只是「禁用」而非真正断开**：屏会掉出
  online/active，但仍可被 `SLSGetDisplayList` 枚举。判据以 active 集合为准。
- **窗口重排不会自动还原**：禁用/恢复屏后系统会移动窗口，本探针不恢复窗口位置。
  这是 M1 的工作项。
- **权限**：SCK 捕获需要父进程（Terminal/iTerm）有「屏幕录制」权限；
  输入注入需要「辅助功能」权限。`probe` 会打印 `parentApp` 便于授权。
- **整机黑屏风险**：`--mode all` 会让本机 UI 全部消失。必须有人在场，并准备好
  SSH / 另一台机器观察结果；target 屏被禁用后不要指望还能在本机看到终端。
- **macOS 15.5（Sequoia / Macmini8,1）WindowServer 停放槽位**：已注销虚拟屏会以
  `vendor=0xFFFFFFFF / offline / 1x1` 的槽位留在 `SLSGetDisplayList` 里（本机
  4128831–4128835）。新建屏固定复用 4128835，并可能继承镜像态；`VDManager` 单屏自愈
  会提前解除镜像。这些槽位**无法从用户态按 displayID 清除**（见下文实测），只有注销/
  重启会清空。程序不再为它们要求重启：单块建屏、V-01、V-03 核心都可直接运行。
  **注意：下午的 Tahoe 机结果与晚上的 Sequoia 机不能混用**，执行前先确认 `probe` 打印的
  `osVersion` / `model`。

### 2026-11-18 Tahoe 环境预检（`probe` + `--dry-run`，未禁物理屏）

环境：**Tahoe 26.5.2（25F84）/ Macmini8,1 / x86_64**。本文其余 V-01/V-03 结论仍只来自 Sequoia 15.5。

- 构建：`bash build.sh` 零警告，ad-hoc 签名 `com.p0v.displayisolation`。
- `./v01probe probe`：`26.5.2 x86_64 / Macmini8,1`、`parent=zsh GUI=yes AX=no`、
  `SLSConfigureDisplayEnabled` 可解析；2 块物理屏 active，SCK 两块都可见。
- 停放槽位：**6 个**（4128829、4128831–4128835），与 Sequoia 的 5 个略有不同；
  单块建屏仍复用 4128835，未触发重建测试。
- `run --dry-run --yes --spec 1280x720 --capture-ms 800 --watch-secs 0`
  → `label=DRY_RUN`、退出码 1（dry-run 语义）、恢复 OK；虚拟屏 4128835
  `HAS_CONTENT`，物理屏未被禁用。日志 `/tmp/p0v-tahoe-dryrun.log`，结果
  `/tmp/p0v-tahoe-dryrun.json`。
- **阻塞项**：`AX=no`，输入注入判据目前会假失败；用户需在系统设置 → 隐私与安全性 →
  辅助功能中为责任进程（WorkBuddy 或运行探针的终端）授权后重跑 V-01/V-03。

### 2026-11-18 Tahoe V-01 / V-03 实测（AX=yes）

用户给责任进程（WorkBuddy）开通辅助功能后复检 `AX=yes`，执行禁屏实测。

**V-01（`--mode one --watch-secs 20`）→ `PASS`，退出码 0，恢复 OK**
结果 `/tmp/p0v-tahoe-one.json`，日志 `/tmp/p0v-tahoe-one.log`。

| 判据 | 结果 | 数据 |
|---|---|---|
| `disableEffective` | ✅ | 目标屏 817925634 退出 active |
| `virtualCapture` | ✅ | 1920x1080 `HAS_CONTENT`，minLumaMean=151 |
| `sckClean` | ✅ | SCK 不含被禁屏 |
| `pointerContained` | ✅ | 逐屏 5 点最大偏差 0，落入禁用屏 0 次 |
| `inputInjected` | ✅ | `axTrusted=1`，move 距离 2797，零偏差 |
| `noReenable` | ✅ | 20s 唤醒观察 0 次重新 enable |
| `activeSetMatchesExpected` | ✅ | active = 虚拟屏 + 剩余物理屏 |
| 恢复 | ✅ | bounds / mode / 主屏身份全部回原值，mismatches 为空 |

**V-03（`--mode all`，重建子项跳过）→ 显示隔离机制全部通过，但 SCK 捕获不稳定**
结果 `/tmp/p0v-tahoe-all{,2,3,4}.json`，日志同名 `.log`。
四次运行中 `disableEffective` / `sckClean` / `pointerContained` / `inputInjected` /
`noReenable`（20s 与 30s 两轮）/ `activeSetMatchesExpected` / **恢复**全部通过；
唯一失败面是禁屏后 SCK 送出的帧：

| 运行 | 观察 | 虚拟屏捕获帧 |
|---|---|---|
| #1（20s） | `FAIL` | `MOSTLY_BLACK`，34/34 帧黑，maxLumaVariance=0 |
| #2（0s） | `PASS_NO_WAKE_TEST` | `HAS_CONTENT` 但 45/61 帧黑，maxVar=4074 |
| #3（30s） | `PASS` | `HAS_CONTENT` 但 22/39 帧黑，maxVar=393 |
| #4（0s，放白色 TextEdit 窗口对照） | `FAIL` | `MOSTLY_BLACK`，62/62 帧黑，maxVar=0 |

**根因定位**：第 3 次运行在禁用期间用 `screencapture -x` 抓到完整桌面
（WorkBuddy 窗口、菜单栏、Dock 可见，图 `/tmp/tahoe-v03-main.png`），说明
WindowServer **仍在正常合成虚拟屏**；黑色来自 **SCK 在「零 active 物理屏」状态下
送帧异常**，不是桌面无内容。第 4 次用白色窗口做对照仍全黑，排除了「深色桌面
本来就很暗」的解释。

**结论**：Tahoe 上 V-01 关闭；**V-03 的显示隔离机制成立，但 `SCK + 零 active
物理屏` 这条采集路径不可靠，A-08 不能在 Tahoe 上按原判据关闭**。M1 若坚持 C-09
（物理屏全部退出 active 空间），必须先在 P0V 新增对照探针，验证
`CGDisplayCreateImage` / `CGWindowListCreateImage` 等替代采集路径；否则只能按
D-05 第 3 条降级（`CGDisplayCapture` + 遮罩 + 强制光标接管），并在产品说明中
标注「非绝对安全」。Sequoia 15.5 上 V-03 核心 `HAS_CONTENT` 的旧结论仍然成立，
但**不可外推到 Tahoe**。

## 手动恢复

```bash
./v01probe restore --snapshot /tmp/p0v-display-snapshot-<pid>.json
./v01probe restore --snapshot <snapshot> --commit permanent   # 需要时
```

若 `run` 异常退出且 guardian 没来得及恢复，先看
`/tmp/p0v-display-guardian.log` 与 `<snapshot>.guardian-result.json`，再执行上面的
`restore`。**不要在已知 WindowServer 挂起时反复重试恢复事务。**

## 实测记录

### 2026-11-17 21:58 V-03 首跑（Sequoia 15.5 / Macmini8,1 / i5-9500）

命令：

```bash
./v01probe run --mode all --yes --watch-secs 0 --no-rebuild-test \
  > /tmp/p0v-all.log 2>&1
```

结果：`label=FAIL`（唯一失败项是输入注入），**恢复 OK，退出码 1**。

| 判据 | 结果 | 数据 |
| --- | --- | --- |
| `disableEffective` | ✅ | 3 块物理屏全部退出 active |
| `virtualCapture` | ✅ | 88 帧 / 1.5s，58fps，`HAS_CONTENT`，`minLumaMean=44` |
| `sckClean` | ✅ | SCK 只剩虚拟屏 4128835 |
| `pointerContained` | ✅ | 5/5 点，最大偏差 0 |
| `activeSetMatchesExpected` | ✅ | active 集合只有 `[4128835]` |
| `inputInjected` | ❌ | `axTrusted=0`，`movedDistance=0`，落点停在 2,2 |
| `noReenable` | 未测 | `--watch-secs 0` |
| `rebuildOK` | 跳过 | `--no-rebuild-test` |

要点：

- **active 集合收缩成功**，但 `onlineIDs` 仍含 3 块物理屏 —— 印证 Intel 上
  `SLSConfigureDisplayEnabled` 是「从 active 空间摘除」而非真正断开。
- 指针 warp 不依赖辅助功能，所以 5 点全过；`CGEventPost` 依赖辅助功能，故注入失败。
- 恢复后 3 块物理屏的 active 集合、bounds、主屏身份全部回原值（mismatches 为空）。

下一步：

1. 给运行探针的父进程（Terminal / Qoder）授予「辅助功能」，`probe` 的 `AX=` 变成 `yes` 后重跑。
2. 加 `--watch-secs 20`，观察期内按键盘 / 滑触控板 / 按 Touch ID，测 `noReenable`。
3. 去掉 `--no-rebuild-test` 跑完整 V-03。
4. V-01（`--mode one`）。

### 2026-11-17 22:03 V-03 完整版：重建测试触发 WindowServer 崩溃

命令（现场执行）：

```bash
./v01probe run --mode all --yes --watch-secs 20 > /tmp/p0v-all-full.log 2>&1
```

时间线：

| 时刻 | 事件 |
| --- | --- |
| 22:03:08 | 3 块物理屏全部 disable |
| 22:03:21–41 | 唤醒观察 20s：重新出现 0 次，虚拟屏缺失 0 块 |
| 22:03:42.5 | 重建测试创建第 2 块虚拟屏（`displayID=4128834`，identityOffset=1000） |
| 22:03:44.4 | **WindowServer SIGABRT**，整机注销 |
| 22:03:46.6 | guardian 检测到父进程消失，兜底恢复失败（WindowServer 正在重启） |

崩溃栈（`/Library/Logs/DiagnosticReports/WindowServer-2026-11-17-220353.ips`）：

```
__assert_rtn
WSCanonicalMirrorMasterForDisplayDevice
WS::Displays::CDDisplay::canonical_mirror_master() const
PKGDisplay::PKGDisplay(WSDisplayWrapper const&)
DisplaySet::create()
PKGDisplay_display_config_changed(...)
WSPostLocalNotification
CGXDisplaysDidReconfigure
reconfigureDisplays(CGXReconfigurationOptions*)
CGXRestoreDisplayConfiguration
```

结论：**不是输入注入/唤醒事件触发**，而是「已有 5 个残留虚拟屏槽位的 WindowServer」里
一次创建第 2 块虚拟屏时，WindowServer 在 `DisplaySet::create` 构造新屏并解析镜像主屏
的断言失败。第 1 块虚拟屏（复用 4128835）是安全的，且已通过自愈解除镜像。

### 已加的防护与预检策略（2026-11-17 22:30 修订）

- `probe` 输出「停放槽位」列表（`vendor=0xFFFFFFFF / offline / 1x1`）。
- `run` 预检不再因为槽位而中止整个 V-03：
  - **V-03 重建子项**（零物理屏下再建一块）在存在槽位时**自动跳过**，结果 JSON 记录
    `rebuildTest.skipped=staleVirtualSlots`，核心 V-03 判据继续执行；
  - `--count 1`（默认）直接允许；
  - `--count > 1` 仍要求显式 `--allow-stale-slots`（多屏 + 槽位组合未验证），但不再
    要求先重启；
  - 被中止时仍不会启动 guardian、不会落盘快照、不会碰物理屏。
- 实测：修复后 `--dry-run` 在槽位存在时正常创建 4128835 并取得 `HAS_CONTENT`，
  退出码 1 仅为 `DRY_RUN` 语义。

### 2026-11-17 22:35 V-03 核心完整版（20s 唤醒观察，重建自动跳过）

命令：

```bash
./v01probe run --mode all --yes --watch-secs 20 \
  --out /tmp/p0v-all-core2.json > /tmp/p0v-all-core2.log 2>&1
```

结果：**`label=PASS`，退出码 0，恢复 OK**。预检识别 5 个停放槽位后自动跳过重建子项
（`rebuildTest.skipped=staleVirtualSlots`，`rebuildTested=false`），未再触发 WindowServer 断言。

| 判据 | 结果 | 数据 |
| --- | --- | --- |
| `disableEffective` | ✅ | 3 块物理屏全部退出 active |
| `virtualCapture` | ✅ | 60fps，`HAS_CONTENT` |
| `sckClean` | ✅ | SCK 只剩虚拟屏 4128835 |
| `pointerContained` | ✅ | 逐屏 5 点，最大偏差 0，落入禁用屏 0 次 |
| `inputInjected` | ✅ | `axTrusted=1`，move 距离 1126，落点 980,560 零偏差 |
| `noReenable` | ✅ | 20s 观察期重新出现 0 次，虚拟屏缺失 0 块 |
| `activeSetMatchesExpected` | ✅ | active = `[4128835]` |
| 恢复 | ✅ | 3 块物理屏 bounds / mode / 主屏身份回原值，mismatches 为空 |

至此 V-03 核心在 Sequoia 15.5 / Macmini8,1 关闭；唯一未验证项是「零物理屏下再建第二块」，
属平台崩溃点，改由 M1 的「先建齐、后禁屏」顺序规避。

### 停放槽位能否手动清除？（实测：不能）

2026-11-17 22:30 在本机（Sequoia 15.5 / Macmini8,1）逐项验证：

| 路径 | 结果 | 原因 |
| --- | --- | --- |
| `CDVirtualDisplayDestroy(client)` | ❌ | 需要创建进程内的 `VirtualDisplayClient` 指针；disassembly 入口先断言类型再 `unplug`，槽位没有对应 client 对象 |
| `SL2CDVirtualDisplayDestroy(displayID)` | ❌ | 只查本进程的 `CGXVirtualDisplay` 表，找不到直接返回；槽位在 WindowServer 侧 |
| 用 `0xFFFFFFFF` 身份重建 1x1 屏 | ❌ | 仍然只复用 4128835，不会认领 4128831–4128834 |
| `pmset displaysleepnow` + `caffeinate -u`（两轮） | ❌ | 可回收「在线孤儿」，但本机是「离线停放槽位」，完整显示重配置也不回收 |
| 注销 / 重启 | ⏳ 未重测 | 唯一已知路径；本机尚未执行 |

结论：**用户态没有按 displayID 注销停放槽位的接口**。这些槽位在 WindowServer 崩溃
重启后仍存在，属于 WindowServer 持有的状态，不是进程内缓存或 plist 数据。程序不应
假装能清理它们，正确做法是检测并绕开唯一不安全的状态组合。

当前保留的平台限制：**本机无法安全验证「零物理屏下再建第二块虚拟屏」**。M1 的多屏
会话必须在禁用物理屏**之前**建齐全部虚拟屏；A-08 应据此记录，而不是要求用户每次
重启机器。

### 2026-11-17 22:15 V-01 通过（Sequoia 15.5 / Macmini8,1）

命令：

```bash
./v01probe run --mode one --yes --watch-secs 20 --out /tmp/p0v-one2.json \
  > /tmp/p0v-one2.log 2>&1
```

结果：**`label=PASS`，退出码 0，恢复 OK**。

| 判据 | 结果 | 数据 |
| --- | --- | --- |
| `disableEffective` | ✅ | 目标屏 583619142 退出 active |
| `virtualCapture` | ✅ | `HAS_CONTENT` |
| `sckClean` | ✅ | 被禁用的物理屏不在 SCK 列表 |
| `pointerContained` | ✅ | 逐屏 5 点采样，最大偏差 0，落进禁用屏 0 次 |
| `inputInjected` | ✅ | `axTrusted=1`，move 距离 2070 |
| `noReenable` | ✅ | 20s 观察期重新出现 0 次 |
| `activeSetMatchesExpected` | ✅ | active = 虚拟屏 + 剩余 2 块物理屏 |
| 恢复 | ✅ | bounds / 主屏身份全部回原值，mismatches 为空 |

两个测试逻辑修正：

1. **指针判据**改为逐块 active 屏采样（四角 + 中心），并显式断言落点不进入任何被
   禁用屏矩形。旧实现取多屏并集外接矩形的四角，V-01 的 L 形布局左上角是空白区，
   系统把指针钳制到最近有效屏，造成假阳性（并非真的越界）。
2. 输入判据同样改为「落点在任一 active 屏内，且不在被禁用屏内」。

同时记录一个副作用：**V-01 禁用一块屏后，剩余物理屏会被 WindowServer 临时重排**
（本次观察到主屏与竖屏都变成 1920x1080 并重叠），恢复后 bounds 与主屏身份精确回原值。
M1 的窗口/布局快照恢复不可省略。
