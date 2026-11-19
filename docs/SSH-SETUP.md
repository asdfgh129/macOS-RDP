# 远程 SSH 接入配置（被控端 = 本机 192.168.10.23）

目的：让另一网段那台 **Sequoia 15.5** 通过 SSH 登进本机，远程跑 `P2-Dual/p2.sh`、
看日志、收 JSON，实现半自动双机验收。

> **状态（2026-11-19 21:2x）：已打通。** 远程登录已开、Sequoia 公钥已写入
> `~/.ssh/authorized_keys`（`SHA256:f3pQpQPFvqcLiPwpi0oZdUs8JGKpHDxKDV+osBk+uQA`），
> 远程 SSH 登录正常，host 端已能由远程驱动。下面保留完整步骤作为复现与排错依据。
>
> **结论先说：不需要安装任何第三方软件。** macOS 自带 OpenSSH 服务端（当前
> `OpenSSH_10.2p1`），缺的只是「打开开关 + 放密钥 + 放行 TCP 端口」三件事。

---

## 1. 本机体检结果（2026-11-19 20:3x 实测）

| 项目 | 现状 | 影响 |
|---|---|---|
| 远程登录（sshd） | **关闭**：无 `sshd` 进程，22/TCP 无监听 | 现在任何人 SSH 都连不上 |
| sshd 配置文件 | `/etc/ssh/sshd_config` 正常，`Include /etc/ssh/sshd_config.d/*` 生效 | 可以用 drop-in 加固，不动主配置 |
| 密钥登录 | `~/.ssh` 存在（700），**没有 `authorized_keys`** | 只能密码登录（若密码登录开着） |
| macOS 应用防火墙 | **已关闭**（State = 0） | 不会拦 22，无需额外放行规则 |
| FileVault | **Off** | 重启后不需要人解锁，SSH 能自己起来 |
| 网络唤醒 / 睡眠 | `womp 1`；当前 `sleep 0`（被 screensharingd/Electron 顶着） | 一般不会睡；长期无人值守建议见 §7 |
| 账号 | `bemin` (uid 501, 已在 `com.apple.access_ssh` 组)、shell `/bin/zsh` | 可直接用该账号登录 |
| 已知密钥 | `~/.ssh/id_ed25519.pub`（bemin@126.com）、`id_ed25519_udlab.pub` | 若对方机已有对应私钥可直接复用 |
| 已有远程通道 | `screensharingd` 在跑（屏幕共享已开） | TCC 授权弹窗可在 GUI 里点，见 §6 |

## 2. 要补的只有四件事

1. **打开「远程登录」**（等价于系统设置里的开关）；
2. **把 Sequoia 的公钥放进 `~/.ssh/authorized_keys`**；
3. **在防火墙上加一条 TCP 映射**——这是最容易漏的一点，见 §4；
4. （建议）**关掉密码登录**，只留密钥。

现成的脚本已经按顺序做好：

```bash
cd P2-Dual

./enable_ssh.sh status        # 只读体检，随时可跑
./enable_ssh.sh enable        # ① 开远程登录（会要 sudo 密码）
./enable_ssh.sh add-key '<Sequoia 的公钥>'   # ② 放公钥
./enable_ssh.sh harden        # ④ 关密码登录（确认密钥能登之后再跑）
```

`harden` 在 `authorized_keys` 为空时会**拒绝执行**，不会把你自己锁在门外。

### 步骤 ① 的两种打开方式

- 命令行：`sudo systemsetup -setremotelogin on`
  （调用它的终端必须有「完全磁盘访问权限」，否则报 `operation not permitted`；
  脚本会自动退回 `launchctl bootstrap` 方式）
- 图形界面（最稳）：**系统设置 → 通用 → 共享 → 远程登录** 打开，并在右侧
  「允许访问」里包含 `bemin`（管理员默认就在里面）。

打开后本机自测：

```bash
lsof -nP -iTCP:22 -sTCP:LISTEN        # 应看到 sshd
ssh bemin@127.0.0.1 'uname -a'        # 走 loopback，验证服务本身
```

## 3. 放公钥（两种方式）

**A. 在 Sequoia 上生成并推送（推荐，私钥不离开对方机）**

```bash
# Sequoia 上
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_p2 -C "p2-test"
ssh-copy-id -p <外部端口> bemin@112.5.32.34      # 需要本机密码登录暂时开着
```

**B. 把公钥贴过来，我在本机写进去**

```bash
cd P2-Dual
./enable_ssh.sh add-key 'ssh-ed25519 AAAA... p2-test'
./enable_ssh.sh status        # 确认条目和权限都正常
```

要求：`~/.ssh` 700、`authorized_keys` 600、家目录不能被组/其他用户写
（脚本会检查家目录权限）。

## 4. 防火墙：SSH 需要**另加一条 TCP 映射**（关键）

现有打洞只做了 **UDP 46600**（QUIC 数据面）。SSH 是 **TCP**，那条规则对它**无效**——
这是「UDP 能通、SSH 连不上」最常见的原因。

| 用途 | 协议 | 外部 | 内部 | 必须？ |
|---|---|---|---|---|
| P2 数据面 | **UDP** 46600 | `112.5.32.34:46600` | `192.168.10.23:46600` | 已有 |
| SSH 管理面 | **TCP** | `112.5.32.34:46601`（建议非 22） | `192.168.10.23:22` | **需要新增** |

建议外部端口用 `46601` 而不是 `22`：公网 22 每天被爆破，换个号能挡掉绝大多数噪音
（安全性靠密钥，端口只是降噪）。

如果边界设备不允许再加规则，两条替代路线：

- **反向隧道**（本机主动连出去，不需要任何入站映射；本机出网正常，HTTPS 实测 200）：
  ```bash
  # 本机执行：把本机 22 映射到对方机的 22022
  ssh -N -R 22022:127.0.0.1:22 bemin@<对方机地址>
  # 对方机执行
  ssh -p 22022 bemin@127.0.0.1
  ```
- **Tailscale / ZeroTier**：两端各装一个，走 100.x 私有地址，不开任何公网端口。
  本机没装 brew，需要从官网下 `.pkg`；这是最省事的长期方案，但要求两端都能装。

## 5. 加固（可选但建议，公网暴露时基本必需）

`./enable_ssh.sh harden` 会写 `/etc/ssh/sshd_config.d/200-p2-automation.conf`：

```
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers bemin
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 60
ClientAliveCountMax 3
```

脚本会先 `sshd -t` 校验，失败自动回滚。生效后 `sudo launchctl kickstart -k system/com.openssh.sshd`。

**回退**（万一密钥丢了）：

```bash
sudo rm /etc/ssh/sshd_config.d/200-p2-automation.conf
sudo launchctl kickstart -k system/com.openssh.sshd
```

回退后密码登录恢复，可用本机屏幕或屏幕共享进去重配。

## 6. SSH 驱动测试的两个坑（重要，会影响 P2 验收）

### 坑 1：SSH 会话不在 GUI 会话里，采集/注入会失败

`stream_probe` 的屏幕采集（`SCShareableContent` / `SCStream`）和事件注入
（`CGEventPost`）都依赖 WindowServer。纯 SSH 会话没有 Aqua 会话，即使 TCC 已授权，
也会拿不到画面或注入无效。用 `gui-run.sh` 把进程塞回登录用户的会话：

```bash
cd P2-Dual
./gui-run.sh --check                 # 确认能劫持到 gui/501
./gui-run.sh ./p2.sh host            # 等同于在 GUI 里双击运行
./gui-run.sh ./stream_probe --preflight host
```

`gui-run.sh` 内部是 `sudo launchctl asuser 501 sudo -u bemin <cmd>`，所以要 sudo。
想让自动化免密，加一条最小授权（`sudo visudo -f /etc/sudoers.d/p2-gui`）：

```
bemin ALL=(root) NOPASSWD: /bin/launchctl asuser 501 /usr/bin/sudo -u bemin *
```

### 坑 2：TCC 授权弹窗只能在 GUI 里点

首次授予「屏幕录制 / 辅助功能」时系统会弹窗，SSH 里看不到也点不了。流程应是：
**先在屏幕前（或屏幕共享）跑一次 `./p2.sh host`，把两个授权点掉**，之后 SSH +
`gui-run.sh` 就能复用（`stream_probe` 用固定签名标识 `com.m1.pipeline`，重编不掉授权）。

## 7. 可选：无人值守时的稳定性

```bash
sudo pmset -a sleep 0 displaysleep 10     # 系统不睡、只关屏（当前已是 sleep 0）
caffeinate -dimsu -t 7200                 # 跑测试期间临时顶住
```

FileVault 已关，重启后 sshd 会随系统起来，不需要人到场解锁。

## 8. 从 Sequoia 连过来的最终命令

```bash
# 先用密钥登录验证（外部 TCP 46601 → 本机 22）
ssh -p 46601 -i ~/.ssh/id_ed25519_p2 bemin@112.5.32.34 'cd ~/macOS-RDP && git log --oneline -1'

# 跑半自动验收（host 在 GUI 会话里起，60s）
cd ~/macOS-RDP/P2-Dual
P2_ADVERTISE=112.5.32.34:46600 P2_PORT=46600 P2_WAIT_MS=60000 \
  ./gui-run.sh ./p2.sh host
```

> 若把本机 host 整体交给 Sequoia 远程驱动，Sequoia 那侧就只做 client；
> 两端仍然要同一 commit，host 侧构建用 `bash M1-Skeleton/build_stream_probe.sh`。

## 9. 排错对照

| 现象 | 原因 | 处理 |
|---|---|---|
| `Connection refused` | 远程登录没开，或 22 没监听 | `./enable_ssh.sh status`；GUI 里开远程登录 |
| `Connection timed out` | 防火墙没做 TCP 映射 / 映射到错的内网 IP | 确认是 **TCP** `46601 → 192.168.10.23:22` |
| `Permission denied (publickey)` | authorized_keys 缺失、权限松、或家目录组可写 | `chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys; chmod go-w ~` |
| `Permission denied (publickey,password)` 且密码也不对 | `harden` 已关密码登录 | 用密钥；或按 §5 回退 |
| SSH 能登，但 `stream_probe` 采集失败 | 不在 GUI 会话 | 用 `./gui-run.sh` 包一层 |
| SSH 能登，但提示无屏幕录制权限 | TCC 未授权（SSH 无法弹窗） | 到屏幕前/屏幕共享里跑一次并点「允许」 |
| 一段时间后自动断开 | 网络空闲或睡眠 | 已配 `ClientAliveInterval 60`；确认 `pmset` 不睡 |
