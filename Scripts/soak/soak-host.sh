#!/bin/bash
# NFR-06 72h soak — 主机侧采样脚本（在 host 机上与 veild-host-agent 并行跑）。
#   agent 本身由 LaunchAgent/run-host.command 常驻；本脚本只做长时观察：
#     · 每 60s 采 veild-host-agent / WindowServer / WindowServer 子进程的 CPU+RSS
#     · 每 10min 记录一次 WindowServer 是否仍在本 PID（意外重启 = 拖挂事故）
#   产物：/tmp/veild-soak/{host-rss.csv,ws-pid.csv}
#
# 用法：bash soak-host.sh [小时数=72]
set -u
HOURS="${1:-72}"
OUT=/tmp/veild-soak
mkdir -p "$OUT"
echo "ts,process,pid,cpu_pct,rss_kb" > "$OUT/host-rss.csv"
echo "ts,ws_pid" > "$OUT/ws-pid.csv"

sample() {
    for name in veild-host-agent WindowServer; do
        p=$(pgrep -n -x "$name" || true)
        [ -z "$p" ] && continue
        line=$(ps -o %cpu=,rss= -p "$p" 2>/dev/null) || continue
        cpu=${line%% *}; rss=${line##* }
        echo "$(date +%s),$name,$p,$cpu,$rss" >> "$OUT/host-rss.csv"
    done
}

DEADLINE=$(( $(date +%s) + HOURS*3600 ))
LAST_WS_LOG=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    sample
    now=$(date +%s)
    if [ $((now - LAST_WS_LOG)) -ge 600 ]; then
        echo "$now,$(pgrep -n -x WindowServer || echo 0)" >> "$OUT/ws-pid.csv"
        LAST_WS_LOG=$now
    fi
    sleep 60
done
echo "=== soak-host 采样结束 $(date '+%F %T')"
