#!/bin/bash
# 本机（被控端）SSH 配置助手。macOS 自带 sshd，不需要装任何第三方软件。
#
# 用法：
#   ./enable_ssh.sh status                # 只读：看当前状态，不改任何东西
#   ./enable_ssh.sh enable                # 打开「远程登录」（需要 sudo）
#   ./enable_ssh.sh add-key '<公钥>'      # 追加密钥（也可 add-key - 从 stdin 读）
#   ./enable_ssh.sh add-key <文件>        # 从 .pub 文件追加密钥
#   ./enable_ssh.sh harden                # 关掉密码登录（必须先确认密钥能登）
#
# 设计原则：harden 在 authorized_keys 为空时拒绝执行，避免把自己锁在外面。
set -uo pipefail

USER_NAME="$(id -un)"
SSH_DIR="$HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
DROPIN="/etc/ssh/sshd_config.d/200-p2-automation.conf"
SSHD_JOB="system/com.openssh.sshd"

c_ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
c_bad()  { printf "  \033[31m✗\033[0m %s\n" "$*"; }
c_warn() { printf "  \033[33m!\033[0m %s\n" "$*"; }

listening() { lsof -nP -iTCP:22 -sTCP:LISTEN >/dev/null 2>&1; }

cmd_status() {
    echo "=== 远程登录（sshd）==="
    if pgrep -x sshd >/dev/null 2>&1; then c_ok "sshd 进程在跑"; else c_bad "sshd 没有运行"; fi
    if listening; then
        c_ok "22/TCP 正在监听"
        lsof -nP -iTCP:22 -sTCP:LISTEN | tail -n +2 | awk '{print "      " $1, $9}'
    else
        c_bad "22/TCP 没有监听 —— 远程登录是关闭的"
    fi
    if [ -f /etc/ssh/ssh_host_ed25519_key.pub ]; then
        echo "  主机指纹：$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}')"
    fi

    echo
    echo "=== 密钥登录 ==="
    if [ -d "$SSH_DIR" ]; then c_ok "$SSH_DIR 存在（$(stat -f '%Sp' "$SSH_DIR")）"; else c_bad "$SSH_DIR 不存在"; fi
    if [ -s "$AUTH_KEYS" ]; then
        c_ok "$AUTH_KEYS 有 $(grep -cE '^(ssh-|ecdsa-|sk-)' "$AUTH_KEYS") 条公钥（$(stat -f '%Sp' "$AUTH_KEYS")）"
        awk '{print "      " $1, $NF}' "$AUTH_KEYS" | sed 's/^/ /'
    else
        c_bad "没有 authorized_keys —— 现在只能用密码登录（如果密码登录开着）"
    fi

    echo
    echo "=== 密码登录策略 ==="
    if [ -f "$DROPIN" ]; then
        c_ok "已装加固配置 $DROPIN"
        grep -vE '^\s*(#|$)' "$DROPIN" | sed 's/^/      /'
    else
        c_warn "未装加固配置：当前使用系统默认（密码登录开着），公网暴露时风险较高"
    fi

    echo
    echo "=== 本机网络 / 防火墙 ==="
    local ip
    ip=$(ifconfig en0 2>/dev/null | awk '/inet /{print $2; exit}')
    [ -n "$ip" ] && c_ok "en0 内网地址 $ip" || c_bad "en0 没有 IPv4"
    if /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | grep -q disabled; then
        c_ok "macOS 应用防火墙已关闭（不会拦 22）"
    else
        c_warn "应用防火墙开着：需要给 sshd 放行入站，否则入站会被丢"
    fi

    echo
    echo "=== 电源（远程登录时若睡眠会断线）==="
    pmset -g 2>/dev/null | awk '/womp|^ sleep|displaysleep/{print "      " $0}'
}

cmd_enable() {
    echo "== 打开远程登录 =="
    if listening; then c_ok "已经在监听 22，跳过"; return 0; fi
    # 首选 systemsetup：效果等同于「系统设置 → 通用 → 共享 → 远程登录」开关。
    # 注意：调用它的终端需要「完全磁盘访问权限」，否则会报 operation not permitted。
    if sudo systemsetup -setremotelogin on 2>&1 | grep -qiE "on|enabled"; then
        c_ok "systemsetup 已打开远程登录"
    else
        c_warn "systemsetup 失败（多半是缺完全磁盘访问权限），改用 launchctl"
        sudo launchctl enable "$SSHD_JOB" || true
        sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null \
            || sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist 2>/dev/null \
            || true
    fi
    sleep 1
    if listening; then
        c_ok "22/TCP 已监听，SSH 可用"
        echo "  本机自测：ssh $USER_NAME@127.0.0.1 'echo ok'"
    else
        c_bad "仍在监听不到 22，请用 GUI 打开：系统设置 → 通用 → 共享 → 远程登录"
        return 1
    fi
}

cmd_addkey() {
    local src="${1:-}" key=""
    if [ -z "$src" ]; then
        echo "用法：$0 add-key '<ssh-ed25519 AAAA...>' | add-key <文件.pub> | add-key -" >&2
        return 2
    fi
    if [ "$src" = "-" ]; then
        key="$(cat)"
    elif [ -f "$src" ]; then
        key="$(cat "$src")"
    else
        key="$src"
    fi
    key="$(printf '%s' "$key" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$key" in
        ssh-*|ecdsa-*|sk-*) ;;
        *) echo "这看起来不是公钥（应以 ssh-ed25519 / ssh-rsa / ecdsa- 开头）：$key" >&2; return 2 ;;
    esac

    mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"
    touch "$AUTH_KEYS" && chmod 600 "$AUTH_KEYS"
    if grep -qxF "$key" "$AUTH_KEYS"; then
        c_ok "该公钥已存在，未重复添加"
    else
        printf '%s\n' "$key" >> "$AUTH_KEYS"
        c_ok "已追加公钥：$(printf '%s' "$key" | awk '{print $1, $NF}')"
    fi
    echo "  现在共有 $(grep -cE '^(ssh-|ecdsa-|sk-)' "$AUTH_KEYS") 条公钥"

    # 顺手检查家目录权限：sshd(StrictModes) 只拒绝「组或其他用户可写」的家目录，
    # 750/755 都是安全的，不必强求 700。
    local hp gw ow
    hp=$(stat -f '%Sp' "$HOME")
    gw=$(printf '%s' "$hp" | cut -c6)   # 组写位
    ow=$(printf '%s' "$hp" | cut -c9)   # 其他用户写位
    if [ "$gw" = "w" ] || [ "$ow" = "w" ]; then
        c_warn "家目录权限 $hp 组/其他用户可写，sshd 会拒绝密钥登录：chmod go-w $HOME"
    else
        c_ok "家目录权限 $hp（组/其他不可写，符合 StrictModes）"
    fi
}

cmd_harden() {
    echo "== 关闭密码登录（仅密钥）=="
    if [ ! -s "$AUTH_KEYS" ] || [ "$(grep -cE '^(ssh-|ecdsa-|sk-)' "$AUTH_KEYS" 2>/dev/null)" -eq 0 ]; then
        c_bad "authorized_keys 里没有公钥，拒绝加固（否则会把自己锁在外面）"
        echo "  先执行：$0 add-key '<对方机的公钥>'"
        return 1
    fi
    if ! listening; then c_bad "SSH 还没开，先跑 $0 enable"; return 1; fi

    sudo tee "$DROPIN" >/dev/null <<EOF
# P2 自动化测试用：只允许密钥登录。由 P2-Dual/enable_ssh.sh harden 生成。
# 如需回退：sudo rm $DROPIN && sudo launchctl kickstart -k $SSHD_JOB
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
UsePAM yes
AllowUsers $USER_NAME
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 60
ClientAliveCountMax 3
EOF
    sudo chmod 644 "$DROPIN"
    if sudo /usr/sbin/sshd -t 2>&1 | grep -q .; then
        c_bad "配置校验失败，已回滚"
        sudo rm -f "$DROPIN"
        sudo /usr/sbin/sshd -t
        return 1
    fi
    c_ok "配置校验通过"
    sudo launchctl kickstart -k "$SSHD_JOB" 2>/dev/null || true
    sleep 1
    c_ok "已生效：密码登录关闭，仅 $USER_NAME 可用密钥登录"
    echo "  验证：从对方机 ssh -p <端口> $USER_NAME@<公网IP> true"
    echo "  回退：sudo rm $DROPIN && sudo launchctl kickstart -k $SSHD_JOB"
}

case "${1:-status}" in
    status|check) cmd_status ;;
    enable)       cmd_enable ;;
    add-key)      shift; cmd_addkey "$@" ;;
    harden)       cmd_harden ;;
    *) echo "用法：$0 {status|enable|add-key <公钥|文件|->|harden}" >&2; exit 2 ;;
esac
