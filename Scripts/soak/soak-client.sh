#!/bin/bash
# NFR-06 72h soak — 客户端侧驱动脚本（在 client 机上跑）。
#   每轮起一个 VeilRD 会话（--reconnect 留 10min 窗口），会话正常结束后重开；
#   全程采样客户端 RSS；每轮 JSON 落到 $OUT/。
#
# 用法：
#   bash soak-client.sh <HOST_IP> <PORT> <FP_HEX> [小时数=72] [--spec WxH]
#   产物：/tmp/veilrd-soak/{client-<ts>.json,client-<ts>.log,client-rss.csv,driver.log}
set -u

HOST_IP="${1:?HOST_IP}"; PORT="${2:?PORT}"; FP="${3:?FP_HEX}"
HOURS="${4:-72}"; SPEC="1280x720"; WINDOW="1280x720"
[ "${5:-}" = "--spec" ] && SPEC="${6:-1280x720}"

BIN="${VEILRD_BIN:-/tmp/veilrd-xcode/Build/Products/Debug/VeilRD}"
OUT=/tmp/veilrd-soak
mkdir -p "$OUT"
echo "=== soak-client $(date '+%F %T') 主机会话: $HOST_IP:$PORT 目标 ${HOURS}h 规格 $SPEC" | tee -a "$OUT/driver.log"

sampler() {
    echo "ts,pid,rss_kb" > "$OUT/client-rss.csv"
    while true; do
        p=$(pgrep -n -f "VeilRD --connect" || true)
        if [ -n "$p" ]; then
            rss=$(ps -o rss= -p "$p" 2>/dev/null | tr -d ' ')
            echo "$(date +%s),$p,${rss:-0}" >> "$OUT/client-rss.csv"
        fi
        sleep 60
    done
}
sampler & SAMPLER_PID=$!
trap 'kill $SAMPLER_PID 2>/dev/null' EXIT

DEADLINE=$(( $(date +%s) + HOURS*3600 ))
ROUND=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    ROUND=$((ROUND+1)); TS=$(date +%Y%m%d-%H%M%S)
    echo "---- $(date '+%F %T') 第 $ROUND 轮" | tee -a "$OUT/driver.log"
    # 单轮最多 30min（覆盖换屏/断线重连多个子场景），结束即重开。
    script -q /dev/null "$BIN" --connect "$HOST_IP" --port "$PORT" \
        --fingerprint "$FP" --spec "$SPEC" --window "$WINDOW" \
        --reconnect --reconnect-window-ms 600000 \
        --handshake-ms 15000 --wait-ms 20000 --duration-ms 1800000 \
        --out "$OUT/client-$TS.json" >> "$OUT/client-$TS.log" 2>&1
    echo "---- $(date '+%F %T') 第 $ROUND 轮结束 code=$?" | tee -a "$OUT/driver.log"
    sleep 10
done
echo "=== soak-client 完成 $ROUND 轮" | tee -a "$OUT/driver.log"
