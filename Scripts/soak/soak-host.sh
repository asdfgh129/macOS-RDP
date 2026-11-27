#!/bin/bash
# NFR-06 72h soak — 主机侧采样脚本（在 host 机上与 veild-host-agent 并行跑）。
#   agent 本身由 LaunchAgent/run-host.command 常驻；本脚本只做长时观察：
#     · 每 60s 采 veild-host-agent / WindowServer / guardian 的 CPU+RSS
#     · 每 10min 记录一次 WindowServer 是否仍在本 PID（意外重启 = 拖挂事故）
#     · agent 进程消失 / 重生的时刻记一条事件（无人值守可靠性信号）
#   产物：$SOAK_OUT/{host-rss.csv,ws-pid.csv,host-events.csv}
#
# 用法：bash soak-host.sh [小时数=72]
# 环境变量：SOAK_OUT / SOAK_EXTRA_PROCS="名字1,名字2"
set -u
HOURS="${1:-72}"
OUT="${SOAK_OUT:-/tmp/veild-soak}"
EXTRA="${SOAK_EXTRA_PROCS:-}"
mkdir -p "$OUT"
echo "ts,process,pid,cpu_pct,rss_kb" > "$OUT/host-rss.csv"
echo "ts,ws_pid" > "$OUT/ws-pid.csv"
echo "ts,event,detail" > "$OUT/host-events.csv"

echo "=== soak-host $(date '+%F %T') | $(sw_vers -productVersion) / $(sysctl -n hw.model) | 目标 ${HOURS}h | 输出 $OUT"

HOST_PROCS="veild-host-agent WindowServer"
for extra in ${EXTRA//,/ }; do HOST_PROCS="$HOST_PROCS $extra"; done

sample() {
    for name in $HOST_PROCS; do
        p=$(pgrep -n -x "$name" || true)
        [ -z "$p" ] && continue
        line=$(ps -o %cpu=,rss= -p "$p" 2>/dev/null) || continue
        cpu=${line%% *}; rss=${line##* }
        echo "$(date +%s),$name,$p,$cpu,$rss" >> "$OUT/host-rss.csv"
    done
}

DEADLINE=$(( $(date +%s) + HOURS*3600 ))
LAST_WS_LOG=0
LAST_AGENT_PID=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    sample
    now=$(date +%s)
    agent_pid=$(pgrep -n -x veild-host-agent || echo "")
    if [ -z "$agent_pid" ]; then
        echo "$now,agent_missing," >> "$OUT/host-events.csv"
    elif [ "$agent_pid" != "$LAST_AGENT_PID" ]; then
        [ -n "$LAST_AGENT_PID" ] && echo "$now,agent_restarted,pid=$agent_pid prev=$LAST_AGENT_PID" >> "$OUT/host-events.csv"
        LAST_AGENT_PID="$agent_pid"
    fi
    if [ $((now - LAST_WS_LOG)) -ge 600 ]; then
        echo "$now,$(pgrep -n -x WindowServer || echo 0)" >> "$OUT/ws-pid.csv"
        LAST_WS_LOG=$now
    fi
    sleep 60
done
echo "=== soak-host 采样结束 $(date '+%F %T')"
