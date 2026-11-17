# P0V-RootDaemon — V-04 特权探针

验证 **D-08 Path A** 的核心假设：**root 特权进程能否在锁屏 / 登录窗态下拿到画面，并把键鼠事件定向送进 loginwindow。**

这是"远程登录"能不能做的唯一判据。此前 D-07 的"永不锁屏"是**在未验证的前提下**做出的妥协，本探针就是来把它证伪或证实的。

## 判据（对应 DESIGN A-09 / V-04）

| 编号 | 内容 | 通过判据 |
|---|---|---|
| V-04a | root daemon 在锁屏态用 SCK 捕获 | `capture.verdict = HAS_CONTENT`，且肉眼对比截图确实是登录界面而非纯黑 |
| V-04b | 向 loginwindow 定向注入按键 | `inject.verdict = INJECTION_ACCEPTED_UI_CHANGED`（画面有变化）或 `..._AND_UNLOCKED` |
| V-04c | 注入密码完成解锁 | `inject.mayHaveUnlocked = 1` |
| V-04d | 登录窗态下建虚拟屏 + 禁物理屏 | **本版未实现**，需在 a/b/c 通过后接 P0 的 `VDManager` 再做 |

## 用法

### 1. 构建（无需权限）

```bash
cd P0V-RootDaemon
./build.sh
```

产物：`build/P0VRootProbe.app`（ad-hoc 签名，bundle id `com.p0v.rootprobe`）。

> **改代码必须重新授权。** 每次构建 cdhash 都变，TCC 记录随之失效。所以流程是「一次构建 → 一次授权 → 之后只跑不改」。

### 2. 授权（人工，必须做，否则 daemon 拿不到画面）

系统设置 → 隐私与安全性 → 依次把 `build/P0VRootProbe.app` 加进：

- **屏幕录制**（SCK 捕获必需）
- **辅助功能**（向 loginwindow 投递事件必需）

root daemon **没有 UI 会话，弹不出授权框**，只能手动加。这是 D-08 里记的那笔账，现在就撞上了。

### 3. 安装（需管理员密码）

```bash
sudo ./install.sh
```

会做三件事：把 app 复制到 `/Applications`、装 LaunchDaemon、`launchctl bootstrap`。`RunAtLoad=false`，**不随开机自动运行**，只在你手动触发时跑一次。

### 4. 先跑未锁屏基线

```bash
sudo launchctl kickstart -k system/com.p0v.rootprobe && sleep 8 && python3 -m json.tool /tmp/p0v-root.json
```

基线要能看到：
- `env.session.available = 0`（daemon 不在 GUI 会话内，这是**正常**的）
- `env.axTrusted = 1`（辅助功能已授权）
- `capture.verdict = HAS_CONTENT`
- `env.sckError = null`

**基线不通就别进锁屏**，先解决授权问题。

### 5. 锁屏态测试（V-04a/b/c）

```bash
sudo ./run_locked_test.sh
```

脚本会先跑一遍基线，然后倒计时 5 秒提示你按 **Ctrl+Cmd+Q** 锁屏。锁屏后脚本在后台：
1. 等 6 秒；
2. `caffeinate -u` 唤醒显示器但**不解锁**（产品里也要这么做，否则锁屏态屏是灭的，抓不到东西）；
3. 触发 daemon；
4. 结果写到 `/tmp/p0v-B-locked.json`。

解锁后：

```bash
cat /tmp/p0v-B-status.txt
python3 -m json.tool /tmp/p0v-B-locked.json
```

> 注入内容是 `aa` + Return —— 一个错误密码，**只会失败**，用来观察登录界面是否有反应（密码框抖动/提示文字）。它不会真的登录进去，除非你的密码就是 `aa`。

### 6. 卸载

```bash
sudo ./uninstall.sh
```

清理 LaunchDaemon、`/Applications` 下的 app、`/tmp` 下的输出。TCC 里的条目需在系统设置中手动删除。

## 判读

| 现象 | 含义 | 下一步 |
|---|---|---|
| `session.available = 0`，`capture.verdict = HAS_CONTENT` | daemon 不在会话内也能抓屏 | 继续看 inject |
| `capture.verdict = MOSTLY_BLACK` / `NO_FRAMES` | 锁屏态抓不到画面 | Path A 死，回 Path B |
| `sckError` 非空（`SCStreamErrorUserDeclined` 等） | 授权没真正落到 daemon 身上 | 检查 TCC 是否按二进制记账；必要时改 MDM PPPC |
| `inject.verdict = INJECTION_NO_VISIBLE_EFFECT` | 事件没被 loginwindow 接受 | 检查 `axTrusted`；可能需 `CGEventPostToPid` 之外的路子 |
| `inject.mayHaveUnlocked = 1` | 注入链路全通，V-04c 直接通过 | 做 V-04d |

## 实现说明

- **进程查找**用 `libproc`（`proc_listpids` + `proc_pidpath`），不依赖 `pgrep`，daemon 里不该 shell out。
- **指纹判据**：把捕获帧的 Y 平面降采样成 16×16 亮度网格，注入前后各取一次，比较单元格差值（>8 计数）。比"整帧平均亮度"敏感得多 —— 密码框抖一下这种局部变化，全局均值根本动不了，网格能抓到。
- **黑屏阈值**沿用 P0 的结论：`420YpCbCr8BiPlanarVideoRange` 的纯黑是 **Y=16**，不是 0。按 0 判会把真黑屏误判成有内容（P0 阶段踩过）。
- **`showsCursor`**：默认 NO（产品里光标由客户端画）。注入测试也开 NO —— 鼠标光标只有几个像素，在 16×16 网格里几乎不产生差异，开了也没用。
- 只写 `/tmp`，不监听任何网络端口，不常驻。

## 已知限制

1. V-04d（登录窗态建虚拟屏）未实现，需接 `P0-TahoeProbe` 的 `VDManager`。
2. 注入用的是 `CGEventPostToPid(loginwindow)`；若被拒，备选是 `CGEventPostToPSN`、或先 `CGSGetSessionConnection` 拿到登录会话连接再投递。
3. 单屏（主屏）测试。多屏登录窗行为未覆盖。
4. 未处理 Secure Input 对注入的影响（注入 v.s. 监听是两回事，Secure Input 主要挡监听，理论上不影响投递，但没实测）。
