# P0V-RootDaemon — V-04 特权探针

验证 **D-08 Path A** 的核心假设：**root 特权进程能否在锁屏 / 登录窗态下拿到画面，并把键鼠事件定向送进 loginwindow。**

这是"远程登录"能不能做的唯一判据。此前 D-07 的"永不锁屏"是**在未验证的前提下**做出的妥协，本探针就是来把它证伪或证实的。

> **第 3 轮工程收口**：`src/p0vprobe.m` 已物理归位到 `Apps/HostDaemon/Sources/main.m`，本目录旧路径为兼容软链，`./build.sh` 等 runbook 用法不变。产品身份见 `Apps/HostDaemon/README.md` 与 D-20。

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

> **2026-11-17 实测（Sequoia 15.5）**：ad-hoc 签名下，无论把 `.app` 还是
> `Contents/MacOS/p0vprobe` 加进这两个列表，系统 TCC 都只会记成
> `client_type=1` 的路径条目，daemon 侧既不认辅助功能也不认屏幕录制
> （`axTrusted=0`、SCK 返回 declined/超时）。需要 Developer ID 或至少
> 自签名证书，让 TCC 能按 bundle id 记账；详见文末实测记录。

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

## 实测记录（2026-11-17 22:40–22:53，Sequoia 15.5 / Macmini8,1 / i5-9500）

环境：**Sequoia 15.5（24F74）**，与 Tahoe 机结果不可混用。

### 1. root LaunchDaemon：TCC 与 GUI 会话双重失败

按 README 流程安装后（`/Applications/P0VRootProbe.app`，ad-hoc 签名，
cdhash `ee2231ad…`），分别把 `.app` 和可执行文件
`/Applications/P0VRootProbe.app/Contents/MacOS/p0vprobe` 加入「辅助功能」与
「屏幕与系统录音」。系统 TCC 库中确实出现两条 `auth_value=2` 的记录，但均为
`client_type=1`（路径条目）、`csreq` 只有 40 字节的 cdhash。

daemon 实测（`sudo launchctl kickstart -k system/com.p0v.rootprobe`）：

| 项 | 结果 |
|---|---|
| `euid` / `bundleID` | 0 / `com.p0v.rootprobe` |
| `session.available` | 0（不在 GUI 会话） |
| `axTrusted` | **0**（尽管辅助功能条目 allowed） |
| SCK | **`SCShareableContent 6s 超时`** |
| 注入 | `INJECTION_NO_VISIBLE_EFFECT`（抓不到帧，无判据） |

用户域 LaunchAgent 启动同一二进制时，SCK 直接返回
`The user declined TCCs for application, window, display capture`，
证明之前“用户态能跑”是继承了 Qoder 的 responsible-process 授权，而不是
探针自己的 TCC 条目生效。对照：Qoder/Terminal 的 TCC 条目都是
`client_type=0`（bundle id）且 `csreq` 更长；ad-hoc 签名只能生成 cdhash
要求，系统设置把探针记成路径条目，**执行侧不采纳**。

### 2. 用户会话进程：锁屏捕获 + 定向注入均通过（V-04a / V-04b）

用继承 Qoder TCC 授权的用户态进程（同一 `p0vprobe` 二进制，非 root）
在锁屏后执行：

```bash
caffeinate -u -t 150 &
# 轮询 probe 直到 session.screenIsLocked=true，再等 3s
screencapture -x /tmp/p0v-lock3-before.png
p0vprobe capture --ms 1000
p0vprobe inject-test          # 注入 "aa" + Return（错误密码）
screencapture -x /tmp/p0v-lock3-after.png
p0vprobe capture --ms 1500
```

结果：

| 项 | 数据 |
|---|---|
| 锁屏截图 | 真实登录界面（用户头像 + 密码框 + 时间），非黑帧 |
| `capture.verdict` | `HAS_CONTENT`，注入前 1 帧 / 注入后 1 帧 |
| `inject.verdict` | `INJECTION_ACCEPTED_UI_CHANGED`，152/256 格变化 |
| 注入后截图 | 密码框已出现输入圆点，"Enter Password" 占位符消失 |
| `sessionAfter.screenIsLocked` | `true`（错误密码按预期未解锁） |

**结论：loginwindow 并不阻止用户会话进程捕获或定向注入。** 之前 D-08 的
“必须 root 才能进登录窗”前提在本机被推翻；真正的门槛是 **TCC 身份**（应用必须
被正确签名并按 bundle id 记账），不是进程特权等级。

### 3. 尚未验证

- **V-04c（正确密码解锁）**：探针按设计只注入错误密码。完整解锁需要真实凭据，
  2026-11-17 决定**主动跳过、记为未测**；留到正式签名后的产品验证。现有证据是
  密码框接收了注入字符（出现圆点），解锁链路本身未被否定。
- **V-04d（登录窗态建虚拟屏 + 禁物理屏）**：未实现。
- **正式签名身份**：本机没有 Developer ID / Apple Development 证书；自签名
  证书能否让 TCC 记成 `client_type=0` 尚未测试。

### 4. 安装脚本缺陷（已修）

仓库位于 exFAT（noowners）、umask 077，`cp -R` 会把 700 权限带进
`/Applications`，导致系统设置和 TCC 无法读取 bundle。`build.sh` 与
`install.sh` 已加 `chmod -R a+rX`。

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

## 2026-11-18 Tahoe 26.5.2 实测（用户会话路径）

探针新增 `lock`（调用 `SACLockScreenImmediate`）、`capture --display ID`、
`inject-test --text STR`，用于自动化锁屏态验证。

| 项 | 结果 | 证据 |
|---|---|---|
| V-04a 锁屏捕获 | ✅ `session.screenIsLocked=true`、`HAS_CONTENT`、17 帧、0 黑帧 | `/tmp/tahoe-20261118-r2-v04a.json` |
| V-04b 定向注入 | ⚠️ 未确认：r1 用 `aa` 后用户手动解锁，判据污染；r2 改用 `zzzzzzzz` 但抓屏时会话已解锁、256/256 格无变化 | `/tmp/tahoe-20261118-{,r2-}v04b.json` |
| V-04c 正确密码解锁 | 未测（不向助手提供凭据） | — |
| V-04d 登录窗建屏+禁屏 | ❌ 不成立：锁屏态虚拟屏 `active=false`；一次抓屏发生在解锁后，数据无效 | `docs/RESULTS-BY-OS.md` §3.3 |

**Tahoe 上 Path A 不成立，不能沿用 Sequoia 的用户态锁屏结论。** 完整按 OS 分离的结论见
`docs/RESULTS-BY-OS.md`。
