#!/bin/bash
# veild-host-agent 常驻启动器（由 com.veild.host LaunchAgent 经 Terminal 拉起）。
#   崩溃后 10s 拉起下一轮；24h 会话上限到点后 agent 正常退出（上一个会话已结束），
#   同样进入下一轮。TCC（屏幕录制/辅助功能）跟随 Terminal 的授权。
#   仓库路径按脚本自身位置推导（2026-11-27 改）：原先写死 /Volumes/Data/Code/macOS-RDP，
#   在仓库克隆到 ~/macOS-RDP 的测试机上会直接起不来。可用 VEILD_REPO 覆盖。
REPO="${VEILD_REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$REPO" || exit 1
LOG=/tmp/veild-host.log
BIN=.state/bin/veild-host-agent

# NFR-07 F4：无人值守主机必须钉死允许接入的客户端指纹，否则输入注入对任何能完成
# TLS 握手的对端开放。指纹放 .state/allow-fingerprint（不进仓库），有该文件才加参数。
PIN=()
if [ -f .state/allow-fingerprint ]; then
    FP="$(tr -d '[:space:]' < .state/allow-fingerprint)"
    [ -n "$FP" ] && PIN=(--allow-fingerprint "$FP")
fi

if [ ${#PIN[@]} -gt 0 ]; then PINNED=yes; else PINNED=no; fi
echo "==== $(date '+%F %T') 启动器启动 pid=$$ repo=$REPO 钉死=$PINNED ====" >> "$LOG"
while true; do
    [ -x "$BIN" ] || { echo "✗ 缺 $BIN" >> "$LOG"; exit 1; }
    # 端口被占（上一轮 agent 还没退干净、或手工起了另一个实例）时不要硬起：
    # 直接起会 listener 失败 48(EADDRINUSE) 并进入 10s 重试风暴。
    if lsof -nP -iUDP:46600 >/dev/null 2>&1; then
        echo "---- $(date '+%F %T') 46600 已被占用，等 5s 再看" >> "$LOG"
        sleep 5
        continue
    fi
    echo "---- $(date '+%F %T') agent 启动" >> "$LOG"
    # script -q /dev/null：给 agent 一个伪 tty 并把输出实时落日志；
    # 其 stdout 不能是管道，否则 script 报 tcgetattr 失败。
    script -q /dev/null "$BIN" --serve \
        --port 46600 --max-sessions 0 --wait-ms 0 --duration-ms 86400000 \
        --fps 30 --inject real --identity .state/rdp-identity.p12 \
        "${PIN[@]}" --out .state/host-last.json >> "$LOG" 2>&1
    code=$?
    echo "---- $(date '+%F %T') agent 退出 code=${code}，10s 后重启" >> "$LOG"
    [ "$code" -eq 0 ] && [ -f /tmp/veild-no-restart ] && break
    sleep 10
done
