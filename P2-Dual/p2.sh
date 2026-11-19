#!/bin/bash
#
# P2 双机联调：一条命令跑一侧。
#
#   第一台（被控端，叫 host）：
#       ./p2.sh host
#       → 屏幕上会打出「给客户端的三项」：IP / 端口 / 证书指纹
#
#   第二台（控制端，叫 client）：
#       ./p2.sh client --host 192.168.10.23 --fingerprint <指纹>
#
#   任何一侧先自检：
#       ./p2.sh preflight host
#       ./p2.sh preflight client --host 192.168.10.23
#
#   把两边的结果汇总（两个 json 都拿到本机后）：
#       ./p2.sh summary <host.json> <client.json>
#
# 环境变量（都可选）：
#   P2_PORT=46600       host 本机监听端口 / client 默认连接端口（防火墙放行这个 UDP 端口）
#   P2_ADVERTISE=IP:PORT  host 对外端点（跨网段/NAT 时填防火墙映射后的公网 IP 与端口）
#                         外部端口可与 P2_PORT 不同；client 侧用 --port 指定映射后的端口
#   P2_SECONDS=60       推流时长
#   P2_FPS=20           目标帧率
#   P2_INJECT=real      host 的注入方式：real（真注入，需辅助功能授权）/ record
#   P2_WINDOW=1280x720  client 窗口尺寸
#   P2_WAIT_MS=15000    等客户端/等 STREAMING 的超时；跨网段建议 60000，
#                         设 0 表示一直等（host 无人值守，直到 client 接入）
#   P2_HANDSHAKE_MS=12000 客户端握手超时；跨网段建议 30000
#   P2_OUT=<dir>        输出目录，默认 P2-Dual/out/<时间戳>
#
# 退出码：0 成功；2 前置条件不满足；3 构建失败；其他见输出。
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SKEL="$HERE/../M1-Skeleton"
cd "$SKEL" || { echo "找不到 M1-Skeleton"; exit 2; }

PORT="${P2_PORT:-46600}"
ADVERTISE="${P2_ADVERTISE:-}"
WAIT_MS="${P2_WAIT_MS:-15000}"
HANDSHAKE_MS="${P2_HANDSHAKE_MS:-12000}"
SECS="${P2_SECONDS:-60}"
FPS="${P2_FPS:-20}"
INJECT="${P2_INJECT:-real}"
WIN="${P2_WINDOW:-1280x720}"
OUT="${P2_OUT:-$HERE/out/$(date +%m%d-%H%M%S)}"

say() { printf '%s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 2; }

need_bin() {
  if [ ! -x ./stream_probe ]; then
    say "构建 stream_probe…"
    bash ./build_stream_probe.sh >/dev/null 2>&1 || die "构建失败，先单独跑 ./build_stream_probe.sh 看报错"
  fi
}

do_preflight() {
  local role="$1" peer="${2:-}" inject_arg="" adv_arg="" rc
  [ "$role" = host ] && [ "$INJECT" = real ] && inject_arg="--inject real"
  [ -n "$ADVERTISE" ] && adv_arg="--advertise $ADVERTISE"
  # shellcheck disable=SC2086
  ./stream_probe --preflight "$role" $inject_arg $adv_arg
  rc=$?
  [ "$rc" = 0 ] || die "本机自检未通过（见上面 [preflight] fail= 行）"
  if [ -n "$peer" ]; then
    say ""
    say "-- 到对端 $peer 的连通性 --"
    if ping -c 2 -W 1000 -q "$peer" >/dev/null 2>&1; then
      say "  ping 通"
    else
      say "  ⚠ ping 不通：确认同一网段、关闭访客网络隔离、先用 IP 而不是主机名"
    fi
    say "  路由：$(route -n get "$peer" 2>/dev/null | awk '/interface:|gateway:/{printf "%s ", $0}')"
  fi
  say ""
}

case "${1:-}" in
preflight)
  need_bin
  role="host"; peer=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      host|client) role="$1"; shift ;;
      --host) peer="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  do_preflight "$role" "$peer"
  ;;

host)
  need_bin
  mkdir -p "$OUT"
  # 上次的 host 子进程可能活着而父 shell 已退出（p2.sh 被杀不会带走 stream_probe），
  # 结果就是 EADDRINUSE 48。启动前先看一眼，给出可复制的清理命令。
  if lsof -nP -iUDP:"$PORT" >/dev/null 2>&1; then
    say "端口 $PORT 已被占用，可能是上次遗留的 host 进程："
    lsof -nP -iUDP:"$PORT" | tail -n +2 | sed 's/^/  /'
    say "清理：pkill -f 'stream_probe --host'  然后重跑"
    exit 2
  fi
  do_preflight host ""
  say "host：采集 ${SECS}s，端口 ${PORT}，注入 ${INJECT}"
  say "输出：$OUT"
  # 屏睡会让 SCK 直接没有帧，联调期间必须挡住。
  # P2_WAIT_MS=0 是无限等待，此时 caffeinate 必须给足（否则等一会儿屏睡了就没帧）。
  if [ "${WAIT_MS:-0}" -gt 0 ] 2>/dev/null; then
    CAF_SECS=$(( SECS + WAIT_MS / 1000 + 300 ))
  else
    CAF_SECS=86400
  fi
  caffeinate -d -u -t "$CAF_SECS" &
  CAF=$!
  trap 'kill $CAF 2>/dev/null' EXIT INT TERM
  adv_arg=""
  [ -n "$ADVERTISE" ] && adv_arg="--advertise $ADVERTISE"
  # shellcheck disable=SC2086
  ./stream_probe --host --port "$PORT" $adv_arg --wait-ms "$WAIT_MS" \
      --duration-ms "$((SECS * 1000))" --fps "$FPS" \
      --inject "$INJECT" --out "$OUT/host.json" 2>&1 | tee "$OUT/host.log"
  rc=${PIPESTATUS[0]}
  say ""
  say "host 结束（rc=${rc}），产物：${OUT}/host.json"
  exit "$rc"
  ;;

client)
  need_bin
  PEER=""; FP=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) PEER="$2"; shift 2 ;;
      --fingerprint) FP="$2"; shift 2 ;;
      --port) PORT="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$PEER" ] || die "缺 --host：客户端要连的对端 IP"
  [ -n "$FP" ] || die "缺 --fingerprint：host 屏幕上「给客户端的三项」里那串"
  mkdir -p "$OUT"
  do_preflight client "$PEER"
  say "client：连 ${PEER}:${PORT}，窗口 ${WIN}，接收 ${SECS}s"
  say "输出：$OUT"
  ./stream_probe --client --connect "$PEER" --port "$PORT" --fingerprint "$FP" \
      --handshake-ms "$HANDSHAKE_MS" --wait-ms "$WAIT_MS" \
      --duration-ms "$((SECS * 1000))" --window "$WIN" \
      --save-frames 0 --out "$OUT/client.json" 2>&1 | tee "$OUT/client.log"
  rc=${PIPESTATUS[0]}
  say ""
  say "client 结束（rc=${rc}），产物：${OUT}/client.json"
  exit "$rc"
  ;;

summary)
  H="${2:-}"; C="${3:-}"
  [ -n "$H" ] && [ -n "$C" ] || die "用法: ./p2.sh summary <host.json> <client.json>"
  python3 - "$H" "$C" <<'PY'
import json, os, sys

def load(p):
    try:
        return json.load(open(p))
    except Exception as e:
        print(f"读不出 {p}: {e}")
        return {}

h, c = load(sys.argv[1]), load(sys.argv[2])
plans = h.get("inputPlans")
rows = [
    ("握手",            "%.1f ms" % c.get("handshakeMs", 0)),
    ("主机采集/编码/发出", "%s / %s / %s" % (h.get("framesCaptured"), h.get("framesEncoded"), h.get("framesSent"))),
    ("主机编码前丢弃/发送失败", "%s / %s" % (h.get("framesDroppedBeforeEncoder"), h.get("sendFailures"))),
    ("客户端收齐/解出",    "%s / %s" % (c.get("framesCompleted"), c.get("framesDecoded"))),
    ("客户端丢帧/解码失败", "%s / %s" % (c.get("framesDropped"), c.get("decodeFailures"))),
    ("客户端分片丢弃/等待关键帧", "%s 片 / %s ms" % (c.get("fragmentsDiscarded"), c.get("awaitingKeyframeMs"))),
    ("关键帧请求 发出/主机收到", "%s / %s" % (c.get("keyframeRequestsSent"), h.get("keyframeRequestsReceived"))),
    ("客户端上屏",        "%s 帧（跳过 %s 不可见）" % (c.get("framesRendered"), c.get("renderSkippedOccluded"))),
    ("首帧延迟",          "主机 %s ms / 客户端 %s ms" % (h.get("firstFrameLatencyMs"), c.get("firstFrameLatencyMs"))),
    ("解码/渲染 单帧",     "%s ms / %s ms" % (c.get("lastDecodeLatencyMs", "?"), c.get("lastRenderMs"))),
    ("控制通道最大间隔",   "%s ms" % c.get("maxControlGapMs")),
    ("输入 收到/注入成功",  "%s / %s" % (h.get("inputReceived"), h.get("inputInjected", 0))),
    ("输入 计划条数(record)", "%s" % (len(plans) if plans is not None else "-（real 模式无计划记录）")),
    ("输入 上行/丢弃/拒绝", "%s / %s / %s" % (c.get("inputSent"), c.get("inputDropped"), c.get("inputRejected"))),
    ("主机注入失败",       "%s" % h.get("inputInjectFails")),
    ("主机光标位移",       "%s px" % h.get("cursorMovedPx", "-")),
]
w = max(len(k) for k, _ in rows)
print()
for k, v in rows:
    print(f"  {k.ljust(w)} : {v}")

cap, enc, sent = h.get("framesCaptured", 0), h.get("framesEncoded", 0), h.get("framesSent", 0)
dropped, decoded = c.get("framesDropped", 0), c.get("framesDecoded", 1)
fails = []
if not c.get("streaming"): fails.append("客户端未处于 STREAMING")
if decoded <= 0: fails.append("客户端一帧都没解出来")
else:
    # 阈值按实测丢片率分层（docs/P2-CHECKLIST.md §4）：无 FEC 时 IDR 存活率随分片数
    # 指数衰减，1% 分片丢包下 720p IDR（≈360 片）存活率仅 ≈2.7%，高阈值不成立。
    min_ratio = float(os.environ.get("P2_MIN_DECODE_RATIO", "0.95"))
    if sent and decoded / max(sent, 1) < min_ratio:
        fails.append(f"解码/发出 = {decoded}/{sent} < {min_ratio:g}")
if h.get("sendFailures", 0): fails.append(f"主机发送失败 {h['sendFailures']} 次")
if h.get("malformed") or c.get("malformed"): fails.append("有畸形分片")
if (c.get("maxControlGapMs") or 0) > 3000: fails.append("控制通道间隔 > 3s（心跳被挤）")
print()
if fails:
    print("  判定 FAIL: " + "；".join(fails))
    sys.exit(1)
print("  判定 PASS（结构性指标；延迟是否达标见 docs/P2-CHECKLIST.md 的阈值）")
PY
  ;;

*)
  sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
  ;;
esac
