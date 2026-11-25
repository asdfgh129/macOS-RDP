#!/bin/bash
# FR-09 无人值守部署（在 host 本机执行）。
#   1. 安装 veild-host-agent 到 .state/bin/
#   2. 装载 com.veild.host LaunchAgent（开机自启，经 Terminal 继承 TCC 授权）
#   3. 电源/锁屏策略：禁止闲置熄屏/休眠/锁屏（需 sudo）
#
# 自动登录（/etc/kcpassword + autoLoginUser）属于前置条件，本脚本只做检查：
#   python3 - <<'PY'
#   import subprocess; print(subprocess.run(['defaults','read',
#     '/Library/Preferences/com.apple.loginwindow','autoLoginUser'],
#     capture_output=True,text=True).stdout)
#   PY
#
# 用法：bash Scripts/host-deploy/install-unattended.sh <veild-host-agent 路径> [--skip-power]
set -euo pipefail

BIN_FROM="${1:-}"
SKIP_POWER="${2:-}"

if [ -z "${BIN_FROM}" ] || [ ! -x "${BIN_FROM}" ]; then
    echo "用法: bash $0 <veild-host-agent 路径> [--skip-power]"
    exit 1
fi

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST_SRC="${REPO}/Scripts/host-deploy/com.veild.host.plist"
PLIST_DST="${HOME}/Library/LaunchAgents/com.veild.host.plist"

echo "== 安装二进制 =="
mkdir -p "${REPO}/.state/bin"
cp "${BIN_FROM}" "${REPO}/.state/bin/veild-host-agent"
chmod +x "${REPO}/.state/bin/veild-host-agent"
chmod +x "${REPO}/Scripts/host-deploy/run-host.command"
codesign -dv "${REPO}/.state/bin/veild-host-agent" 2>&1 | head -2 || true

echo "== 安装 LaunchAgent =="
mkdir -p "${HOME}/Library/LaunchAgents"
cp "${PLIST_SRC}" "${PLIST_DST}"
launchctl bootout "gui/$(id -u)/com.veild.host" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${PLIST_DST}"
launchctl enable "gui/$(id -u)/com.veild.host"
sleep 2
launchctl print "gui/$(id -u)/com.veild.host" | sed -n '1,10p'

if [ "${SKIP_POWER}" != "--skip-power" ]; then
    echo "== 电源/锁屏策略（需要 sudo）=="
    sudo pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0
    defaults write com.apple.screensaver askForPassword -int 0 || true
    defaults write com.apple.screensaver askForPasswordDelay -int 0 || true
    defaults -currentHost write com.apple.screensaver idleTime -int 0 || true
    echo "✓ 已关闭闲置熄屏/休眠/锁屏"
fi

echo
echo "完成。验证："
echo "  pgrep -fl veild-host-agent"
echo "  tail -f /tmp/veild-host.log"
