#!/bin/bash
# NFR-06 72h soak — 客户端侧驱动脚本（在 client 机上跑）。
#   每轮起一个 VeilRD 会话（默认 30min，--reconnect 留 10min 窗口），会话结束后重开；
#   全程采样客户端 RSS；每轮 JSON 落到 $OUT/。
#
# 用法（推荐）：
#   bash soak-client.sh --host 192.168.34.212 --port 46600 --fp <HEX> --hours 72 \
#        [--spec 1280x720] [--bin /tmp/VeilRD] [--display <id>] [--out DIR]
# 用法（兼容旧的位置参数）：
#   bash soak-client.sh <HOST_IP> <PORT> <FP_HEX> [小时数=72] [--spec WxH]
#
# 环境变量：VEILRD_BIN / SOAK_OUT / SOAK_DISPLAY_ID / SOAK_NO_CAFFEINATE=1
# 产物：$SOAK_OUT/{client-<ts>.json,client-<ts>.log,client-rss.csv,driver.log}
set -u

HOST_IP=""; PORT=""; FP=""; HOURS=72; SPEC="1280x720"; WINDOW=""
BIN="${VEILRD_BIN:-/tmp/veilrd-xcode/Build/Products/Debug/VeilRD}"
OUT="${SOAK_OUT:-/tmp/veilrd-soak}"
DISPLAY_ID="${SOAK_DISPLAY_ID:-}"
ROUND_MS=1800000            # 单轮 30min：覆盖换屏/断线重连多个子场景
RECONNECT_WINDOW_MS=600000  # 断线后留 10min 重连窗口

# 位置参数（旧写法）：soak-client.sh <IP> <PORT> <FP> [HOURS] [--spec WxH]
if [ "${1:-}" ] && [ "${1#--}" = "$1" ]; then
    HOST_IP="$1"; PORT="${2:-}"; FP="${3:-}"; HOURS="${4:-72}"
    shift 4 2>/dev/null || shift $#
fi
while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST_IP="${2:-}"; shift 2 ;;
        --port) PORT="${2:-}"; shift 2 ;;
        --fp) FP="${2:-}"; shift 2 ;;
        --hours) HOURS="${2:-72}"; shift 2 ;;
        --spec) SPEC="${2:-1280x720}"; shift 2 ;;
        --window) WINDOW="${2:-}"; shift 2 ;;
        --bin) BIN="${2:-}"; shift 2 ;;
        --out) OUT="${2:-}"; shift 2 ;;
        --display) DISPLAY_ID="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
if [ -z "$HOST_IP" ] || [ -z "$PORT" ] || [ -z "$FP" ]; then
    echo "用法: bash soak-client.sh --host IP --port PORT --fp HEX [--hours 72] [--spec WxH] [--bin PATH]" >&2
    exit 2
fi
[ -n "$WINDOW" ] || WINDOW="$SPEC"
if [ ! -x "$BIN" ]; then
    echo "✗ 找不到可执行客户端: ${BIN}（用 --bin 或 VEILRD_BIN 指定）" >&2
    exit 2
fi

mkdir -p "$OUT"
{
    echo "=== soak-client $(date '+%F %T')"
    echo "拓扑: $(sw_vers -productVersion) / $(sysctl -n hw.model) → $HOST_IP:$PORT"
    echo "目标: ${HOURS}h 规格 $SPEC 二进制 $BIN 输出 $OUT"
} | tee -a "$OUT/driver.log"

# 13/14 默认 1 分钟内屏睡；client 屏一睡首帧就是黑的，容易被误判成产品缺陷。
CAFF_PID=""
if [ "${SOAK_NO_CAFFEINATE:-0}" != "1" ]; then
    caffeinate -d -i -u -t $((HOURS * 3600 + 600)) >/dev/null 2>&1 &
    CAFF_PID=$!
    echo "已起 caffeinate(-d -i -u) pid=${CAFF_PID}，防止屏睡/空闲睡眠" | tee -a "$OUT/driver.log"
fi

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
cleanup() {
    kill "$SAMPLER_PID" 2>/dev/null
    [ -n "$CAFF_PID" ] && kill "$CAFF_PID" 2>/dev/null
}
trap cleanup EXIT

display_state() { pmset -g powerstate IODisplayWrangler 2>/dev/null | tail -1; }

DEADLINE=$(( $(date +%s) + HOURS*3600 ))
ROUND=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    ROUND=$((ROUND+1)); TS=$(date +%Y%m%d-%H%M%S)
    # 每轮开跑前把屏叫醒：唤醒后 IODisplayWrangler 才回到 on，首轮不至于黑屏。
    caffeinate -u -t 2 >/dev/null 2>&1
    echo "---- $(date '+%F %T') 第 $ROUND 轮 | 屏态: $(display_state)" | tee -a "$OUT/driver.log"

    ARGS=(--connect "$HOST_IP" --port "$PORT" --fingerprint "$FP" --spec "$SPEC" --window "$WINDOW"
          --reconnect --reconnect-window-ms "$RECONNECT_WINDOW_MS"
          --handshake-ms 15000 --wait-ms 20000 --duration-ms "$ROUND_MS"
          --out "$OUT/client-$TS.json")
    [ -n "$DISPLAY_ID" ] && ARGS+=(--display "$DISPLAY_ID")

    script -q /dev/null "$BIN" "${ARGS[@]}" >> "$OUT/client-$TS.log" 2>&1
    echo "---- $(date '+%F %T') 第 $ROUND 轮结束 code=$?" | tee -a "$OUT/driver.log"
    sleep 10
done
echo "=== soak-client 完成 $ROUND 轮 $(date '+%F %T')" | tee -a "$OUT/driver.log"
