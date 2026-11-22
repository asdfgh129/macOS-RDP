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
#   P2_WIDTH=1280       host 编码输出宽（镜像模式降分辨率用；0=跟随采集源）
#   P2_HEIGHT=720       host 编码输出高（同上）
#   P2_INJECT=real      host 的注入方式：real（真注入，需辅助功能授权）/ record
#   P2_WINDOW=1280x720  client 窗口尺寸
#   P2_SPEC=1280x720    client 请求 host 的推流规格（独占模式下解码尺寸必须与之相同）
#   P2_SAVE_FRAMES=0    client 保存前 N 帧到 $OUT（锁屏/登录 UI 视觉证据用；默认 0）
#   P2_EXCLUSIVE=1      host 建虚拟屏并禁物理屏（现已是默认；保留兼容）
#   P2_MIRROR=1         host 采物理主屏（诊断用；旧默认）
#   P2_KEEP_MAIN=1      独占时保留物理主屏（诊断模式，不满足 C-09）
#   P2_SIM_LOSS=0.1     host 发送端模拟丢片百分比（环回复现 WAN）
#   P2_SIM_REORDER=1    host 发送端模拟乱序交换百分比
#   P2_WAIT_MS=15000    等客户端/等 STREAMING 的超时；跨网段建议 60000，
#                         设 0 表示一直等（host 无人值守，直到 client 接入）
#   P2_HANDSHAKE_MS=12000 客户端握手超时；跨网段建议 30000
#   P2_OUT=<dir>        输出目录，默认 P2-Dual/out/<时间戳>
#
# 退出码：0 成功；2 前置条件不满足；3 构建失败；其他见输出。
#
set -uo pipefail

# 记录调用方 cwd：下面会 cd 到 SKEL，但 summary 的 <host.json>/<client.json>
# 按操作单是相对调用目录写的（./p2.sh summary out/x/host.json out/x/client.json）。
# 不在这里转成绝对路径就会在 SKEL 下找不到文件。
CALLER_PWD="$(pwd)"
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
  WH_ARG=""
  [ -n "${P2_WIDTH:-}" ] && [ -n "${P2_HEIGHT:-}" ] && WH_ARG="--width $P2_WIDTH --height $P2_HEIGHT"
  MODE_ARG=""
  [ "${P2_MIRROR:-0}" = 1 ] && MODE_ARG="$MODE_ARG --mirror"
  [ "${P2_EXCLUSIVE:-0}" = 1 ] && MODE_ARG="$MODE_ARG --exclusive"
  [ "${P2_KEEP_MAIN:-0}" = 1 ] && MODE_ARG="$MODE_ARG --keep-main"
  SIM_ARG=""
  [ -n "${P2_SIM_LOSS:-}" ] && SIM_ARG="$SIM_ARG --sim-loss $P2_SIM_LOSS"
  [ -n "${P2_SIM_REORDER:-}" ] && SIM_ARG="$SIM_ARG --sim-reorder $P2_SIM_REORDER"
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
  # shellcheck disable=SC2086
  ./stream_probe --host --port "$PORT" $adv_arg $WH_ARG $MODE_ARG $SIM_ARG --wait-ms "$WAIT_MS" \
      --duration-ms "$((SECS * 1000))" --fps "$FPS" \
      --inject "$INJECT" --out "$OUT/host.json" 2>&1 | tee "$OUT/host.log"
  rc=${PIPESTATUS[0]}
  say ""
  say "host 结束（rc=${rc}），产物：${OUT}/host.json"
  exit "$rc"
  ;;

client)
  need_bin
  PEER=""; FP=""; SPEC_ARG=""; EXTRA_ARGS=()
  [ -n "${P2_SPEC:-}" ] && SPEC_ARG="--spec $P2_SPEC"
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) PEER="$2"; shift 2 ;;
      --fingerprint) FP="$2"; shift 2 ;;
      --port) PORT="$2"; shift 2 ;;
      --input-synth|--manual|--keep-front) EXTRA_ARGS+=("$1" "$2"); shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$PEER" ] || die "缺 --host：客户端要连的对端 IP"
  [ -n "$FP" ] || die "缺 --fingerprint：host 屏幕上「给客户端的三项」里那串"
  mkdir -p "$OUT"
  do_preflight client "$PEER"
  say "client：连 ${PEER}:${PORT}，窗口 ${WIN}，接收 ${SECS}s"
  say "输出：$OUT"
  # P2_SAVE_FRAMES：保存客户端解码前 N 帧到 $OUT，默认 0（不改变既有行为）。
  # 用于锁屏 / 登录 UI 等需要视觉证据的场景；帧名 frame-001.png 递增。
  SAVE_FRAMES="${P2_SAVE_FRAMES:-0}"
  # shellcheck disable=SC2086
  ./stream_probe --client --connect "$PEER" --port "$PORT" --fingerprint "$FP" $SPEC_ARG \
      ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
      --handshake-ms "$HANDSHAKE_MS" --wait-ms "$WAIT_MS" \
      --duration-ms "$((SECS * 1000))" --window "$WIN" \
      --outdir "$OUT" --save-frames "$SAVE_FRAMES" --out "$OUT/client.json" 2>&1 | tee "$OUT/client.log"
  rc=${PIPESTATUS[0]}
  say ""
  say "client 结束（rc=${rc}），产物：${OUT}/client.json"
  exit "$rc"
  ;;

summary)
  H="${2:-}"; C="${3:-}"
  [ -n "$H" ] && [ -n "$C" ] || die "用法: ./p2.sh summary <host.json> <client.json>"
  # 相对路径按调用方 cwd 解析（此时 shell 已在 SKEL 下）。
  case "$H" in /*) : ;; *) H="$CALLER_PWD/$H" ;; esac
  case "$C" in /*) : ;; *) C="$CALLER_PWD/$C" ;; esac
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
req_w, req_h = c.get("requestedWidth"), c.get("requestedHeight")
spec_requested = bool(req_w and req_h)
# 没传 --spec 时用 session-ready 里 host 实际建的屏规格作判据（独占会话）。
eff_w, eff_h = c.get("effectiveWidth"), c.get("effectiveHeight")
eff_available = bool(eff_w and eff_h)
req_text = (f"{req_w}x{req_h}" if spec_requested else
            (f"{eff_w}x{eff_h}(实际屏)" if eff_available else "未请求"))
got_text = f"{c.get('decodedWidth')}x{c.get('decodedHeight')}"
session_ms = c.get("streamDurationMs") or 0
await_ms = c.get("awaitingKeyframeMs") or 0
await_pct = (await_ms / session_ms) if session_ms > 0 else None
drop_pct = (c.get("framesDropped", 0) / c.get("framesCompleted", 1)) if c.get("framesCompleted") else None
loss = float(h.get("simLossPct") or 0)
is_wan = bool(h.get("advertisedEndpoint"))
session_mode = str(h.get("sessionMode", ""))
# 分层阈值（docs/P2-CHECKLIST.md §4 / P2-NEXT-PLAN §3）：
#   LAN 环回 0% ≥0.98、0.1% ≥0.90；WAN（无注入但跨公网）≥0.85；1% 只记趋势。
if "P2_MIN_DECODE_RATIO" in os.environ:
    min_ratio = float(os.environ["P2_MIN_DECODE_RATIO"])
elif loss >= 1:
    min_ratio = None
elif is_wan:
    min_ratio = 0.85
elif loss > 0:
    min_ratio = 0.90
else:
    min_ratio = 0.98
rows = [
    ("模拟丢片/网络", "%.1f%% / %s" % (loss, "WAN" if is_wan else "LAN")),
    ("握手",            "%.1f ms" % c.get("handshakeMs", 0)),
    ("主机采集/编码/发出", "%s / %s / %s" % (h.get("framesCaptured"), h.get("framesEncoded"), h.get("framesSent"))),
    ("主机编码前丢弃/发送失败", "%s / %s" % (h.get("framesDroppedBeforeEncoder"), h.get("sendFailures"))),
    ("客户端收齐/解出",    "%s / %s" % (c.get("framesCompleted"), c.get("framesDecoded"))),
    ("客户端丢帧/解码失败", "%s / %s" % (c.get("framesDropped"), c.get("decodeFailures"))),
    ("客户端分片丢弃/等待关键帧", "%s 片 / %s ms（%.1f%%）" % (
        c.get("fragmentsDiscarded"), await_ms, (await_pct or 0) * 100)),
    ("客户帧丢弃率", "%.1f%%" % ((drop_pct or 0) * 100)),
    ("关键帧请求 发出/主机收到", "%s / %s" % (c.get("keyframeRequestsSent"), h.get("keyframeRequestsReceived"))),
    ("关键帧请求 RTT 最近/样本", "%s ms / %s 次" % (c.get("keyframeRequestRttMs", 0), c.get("keyframeRequestRttSamples", 0))),
    ("客户端上屏",        "%s 帧（跳过 %s 不可见）" % (c.get("framesRendered"), c.get("renderSkippedOccluded"))),
    ("请求规格/解码尺寸",  "%s → %s（%s）" % (req_text, got_text,
        "一致" if c.get("specMatch") else "未一致/未判定")),
    ("首帧延迟",          "主机 %s ms / 客户端 %s ms" % (h.get("firstFrameLatencyMs"), c.get("firstFrameLatencyMs"))),
    ("解码/渲染 单帧",     "%s ms / %s ms" % (c.get("lastDecodeLatencyMs", "?"), c.get("lastRenderMs"))),
    ("控制通道最大间隔",   "%s ms" % c.get("maxControlGapMs")),
    ("输入 收到/注入成功",  "%s / %s" % (h.get("inputReceived"), h.get("inputInjected", 0))),
    ("输入 计划条数(record)", "%s" % (len(plans) if plans is not None else "-（real 模式无计划记录）")),
    ("输入 上行/丢弃/拒绝", "%s / %s / %s" % (c.get("inputSent"), c.get("inputDropped"), c.get("inputRejected"))),
    ("主机注入失败",       "%s" % h.get("inputInjectFails")),
    ("主机光标位移",       "%s px" % h.get("cursorMovedPx", "-")),
    ("会话形态/C-09",      "%s / %s" % (session_mode or "-", h.get("c09Status", "-"))),
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
    if min_ratio is not None and sent and decoded / max(sent, 1) < min_ratio:
        fails.append(f"解码/发出 = {decoded}/{sent} < {min_ratio:g}"
                     + ("（WAN 门禁）" if is_wan else ""))
if h.get("sendFailures", 0): fails.append(f"主机发送失败 {h['sendFailures']} 次")
if h.get("malformed") or c.get("malformed"): fails.append("有畸形分片")
if (c.get("maxControlGapMs") or 0) > 3000: fails.append("控制通道间隔 > 3s（心跳被挤）")
if drop_pct is not None and drop_pct > 0.05:
    fails.append(f"客户端帧丢弃 {drop_pct:.1%} > 5%")
if await_pct is not None and await_pct > 0.10:
    fails.append(f"等待关键帧占比 {await_pct:.1%} > 10%")
if sent and (c.get("keyframeRequestsSent") or 0) > 0 and not (h.get("keyframeRequestsReceived") or 0):
    fails.append("客户端发了 keyframe-request，但主机没有收到（控制回传失败）")
# P2.2：仅独占会话要求解码尺寸等于 client 请求规格；镜像模式不建屏，不参与此判定。
# specMatch 缺失按 FAIL 处理，迫使两端对齐 commit（旧二进制没有该字段）。
if session_mode.startswith("exclusive") and (spec_requested or eff_available):
    spec_ok = c.get("specMatch") if spec_requested else c.get("effectiveSpecMatch")
    if not spec_ok:
        fails.append(f"解码尺寸 {got_text} ≠ {req_text}（P2.2 会话形态不成立；"
                     "若客户端是旧二进制请重新编译）")
# 独占会话额外核对 C-09 与恢复证据（keep-main 是诊断模式，明确跳过 C-09）。
if session_mode == "exclusive":
    if h.get("c09Status") != "verified":
        fails.append(f"独占会话 C-09 未校验通过（c09Status={h.get('c09Status', '字段缺失')}）")
    if h.get("sessionRecovered") is False:
        fails.append("独占会话结束后物理屏恢复失败")
elif session_mode == "exclusive-keep-main":
    if h.get("c09Status") != "skipped-keep-main":
        fails.append("keep-main 模式应明确跳过 C-09（不能谎报已校验）")
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
