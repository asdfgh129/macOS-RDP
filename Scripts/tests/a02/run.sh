#!/bin/bash
# A-02 玻璃到玻璃（无相机替代法）——「双钟同框 + 截屏」驱动
#
#  原理（为什么不需要相机）：
#    相机法的本质是「把主机屏幕和客户端屏幕拍进同一帧，读两个时钟」。
#    这里把「同一帧」从相机的 CMOS 换成屏幕的帧缓冲：
#      · 主机侧跑 a02_clock（洋红条码）→ 被采集、编码、传输、解码、上屏；
#      · 客户端侧跑 a02_clock --cyan 作为本机参考钟（青条码），不经过任何流；
#      · 一次截屏同时包含两个条码 ⇒ 两者是同一帧的内容，
#        截屏本身耗时 200–600ms **完全不进入计算**（这是单钟+截屏法的致命伤，
#        本机实测 CGDisplayCreateImage 单次 177–695ms，时刻不可知）。
#    延迟 = 参考钟读数 − 流里钟的读数。
#
#  口径（必须连同结论一起写）：
#    · 起点是「主机应用把该毫秒值绘进图层」的时刻，终点是「客户端窗口该帧被合成」的时刻；
#      含主机合成/采集、编码、传输、解码、上屏，**不含**两端显示器的扫描输出与相机采样。
#    · 主机绘制到采集之间有 0～2 个刷新周期（合成+双缓冲），是系统性高估来源；
#      与客户端 present 直方图（capture→present）配合可给出上下界。
#
#  用法：
#    ./a02-run.sh local  --capture-display <id> --client-display <id> [选项]
#    ./a02-run.sh list
#    ./a02-run.sh selftest --display <id> [--skew-ms -40]
#
#  选项（local）：--spec 1280x720 --fps 30 --samples 40 --interval 0.25 --outdir DIR
#                --port 46600 --host-mode mirror|keep-main
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BIN="${A02_BIN:-/tmp/veilrd-xcode/Build/Products/Debug}"
HOST_BIN="$BIN/veild-host-agent"
PROBE_BIN="${A02_PROBE:-$REPO/M1-Skeleton/stream_probe}"
HOST_KIND="${A02_HOST:-probe}"
CLIENT_BIN="$BIN/VeilRD"
IDENTITY="${A02_IDENTITY:-$REPO/M1-Skeleton/.state/rdp-identity.p12}"

say() { printf '%s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

cmd="${1:-}"; shift || true

case "$cmd" in
  list)
    "$HERE/a02_clock" --list-screens
    say "--- 可截屏显示器"
    "$HERE/a02_shot" --list
    ;;
  shot)
    exec "$HERE/a02_shot" "$@"
    ;;
  clock|refclock)
    exec "$HERE/a02_clock" "$@"
    ;;
  selftest)
    # 已知偏差自检：参考钟故意偏 --skew-ms，读到 -skew 才说明整条判读链路无系统性错位。
    display=""; skew="-40"
    while [ $# -gt 0 ]; do
      case "$1" in
        --display) display="$2"; shift 2 ;;
        --skew-ms) skew="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$display" ] || die "selftest 需要 --display <id>"
    "$HERE/a02_clock" --display "$display" --hold 14 >/dev/null 2>&1 &
    M=$!
    sleep 1.5
    "$HERE/a02_clock" --display "$display" --cyan --no-text --skew-ms "$skew" \
        --size 900x120 --anchor bl --hold 10 >/dev/null 2>&1 &
    R=$!
    sleep 2
    got="$("$HERE/a02_shot" --two --display "$display" | python3 -c \
        'import json,sys;d=json.load(sys.stdin);print(d["latencyMs"] if d["ok"] else "fail")')"
    kill $M $R 2>/dev/null || true
    say "注入偏差 ${skew}ms → 判读 ${got}ms"
    [ "$got" = "$(( -skew ))" ] && say "SELFTEST PASS" && exit 0
    say "SELFTEST FAIL"; exit 1
    ;;
  local) ;;
  # 先按 local 收参数（函数体在下面），这里不 break
  *)
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac

# ---------- local：同机环回（host 采 A 屏、client 沉浸到 B 屏，避免镜中镜） ----------
CAP=""; CDISP=""; SPEC="1280x720"; FPS=30; SAMPLES=40; INTERVAL=0.25
OUTDIR="/tmp/veild-a02"; PORT=46600; MODE="mirror"
while [ $# -gt 0 ]; do
  case "$1" in
    --capture-display) CAP="$2"; shift 2 ;;
    --client-display) CDISP="$2"; shift 2 ;;
    --spec) SPEC="$2"; shift 2 ;;
    --fps) FPS="$2"; shift 2 ;;
    --samples) SAMPLES="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --host-mode) MODE="$2"; shift 2 ;;
    *) die "未知参数 $1" ;;
  esac
done
[ -n "$CAP" ] || die "缺 --capture-display"
[ -n "$CDISP" ] || CDISP="$CAP"   # 默认同屏：客户端窗口居中叠在时钟上，截屏裁到窗口内容区域
[ -x "$HOST_BIN" ] || die "找不到 ${HOST_BIN}（先 bash Scripts/build.sh）"
[ -x "$CLIENT_BIN" ] || die "找不到 $CLIENT_BIN"

W="${SPEC%x*}"; H="${SPEC#*x}"
# 每次 a02_shot 在本机实测 1.2–2.2s（截屏 0.2–0.7s + 判读 + 进程启动），按 3s 预算。
WARMUP=6
CLIENT_MS=$(( (WARMUP + SAMPLES * 3 + 6) * 1000 ))
HOST_MS=$(( (WARMUP + SAMPLES * 3 + 14) * 1000 ))
WAIT_MS=60000   # 本机 fork/exec 开销 1–4s/次，等指纹可能花十几秒，等待窗口必须远大于它

# 客户端窗口尺寸：16:9，明显小于采集屏，保证窗口不盖住屏幕顶部那条「直出条码」
WIN_W="${A02_WIN_W:-1200}"; WIN_H=$(( WIN_W * 9 / 16 ))

mkdir -p "$OUTDIR"; rm -f "$OUTDIR"/samples.jsonl "$OUTDIR"/sample.png
# 屏睡会让 SCK 直接没有帧（本机 21:xx 实测几次「没有可推流的显示」都是屏睡触发的）。
caffeinate -d -u -t "$(( HOST_MS / 1000 + 30 ))" &
CAF_PID=$!
say "== A-02 local =="
say "采集屏 ${CAP}（同屏模式），规格 $SPEC @ ${FPS}fps，客户端窗口 ${WIN_W}x${WIN_H}，${SAMPLES} 次采样"
say "输出 $OUTDIR"

# 1) 主机内容源
"$HERE/a02_clock" --display "$CAP" --hold "$(( HOST_MS / 1000 + 6 ))" >"$OUTDIR/clock.log" 2>&1 &
CLOCK_PID=$!
sleep 1

# 2) host（镜像档：只采 --display 指定那块，不建/不禁任何显示）
MODE_ARG="--mirror"; [ "$MODE" = "keep-main" ] && MODE_ARG="--keep-main"
# 注意：host 不能套 `script`——pty 会改变 TCC 的“责任进程”，SCK 立刻被拒。
# 默认用 stream_probe 当 host：本机屏幕录制授权挂在 stream_probe 上，而未签名的
# veild-host-agent 在非 GUI 上下文会被 SCK 直接拒（见 README「TCC 与主机选择」）。
# 采集/编码/传输是同一份 RDPKit 代码，A02_HOST=product 可切回产品入口
# （须在 GUI Terminal 内运行以继承授权）。
if [ "$HOST_KIND" = "product" ]; then
  "$HOST_BIN" --serve --port "$PORT" $MODE_ARG --display "$CAP" --fps "$FPS" \
      --wait-ms "$WAIT_MS" --duration-ms "$HOST_MS" --identity "$IDENTITY" \
      --out "$OUTDIR/host.json" >"$OUTDIR/host.log" 2>&1 &
else
  [ -x "$PROBE_BIN" ] || die "找不到 ${PROBE_BIN}（先 bash M1-Skeleton/build_stream_probe.sh）"
  "$PROBE_BIN" --host --port "$PORT" $MODE_ARG --display "$CAP" \
      --spec "$SPEC" --width "$W" --height "$H" --fps "$FPS" \
      --wait-ms "$WAIT_MS" --duration-ms "$HOST_MS" --identity "$IDENTITY" \
      --out "$OUTDIR/host.json" >"$OUTDIR/host.log" 2>&1 &
fi
HOST_PID=$!

# 3) 指纹直接从身份证书算（与 M1QuicIdentityFingerprint 同口径 = DER 的 SHA-256），
#    不再依赖 host 日志——日志重定向到文件时是全缓冲，会憋到进程退出才落盘。
CRT="${IDENTITY%.p12}.crt"
[ -f "$CRT" ] || die "缺身份证书 $CRT"
FP="$(openssl x509 -in "$CRT" -outform DER 2>/dev/null | shasum -a 256 | awk '{print $1}')"
[ ${#FP} -eq 64 ] || die "算不出身份指纹：$CRT"
say "host 指纹 ${FP:0:16}…（来自 ${CRT}）"

# 3b) 等 host 真的在监听（UDP 端口）。日志不可靠，端口是硬事实。
READY=0
for _ in $(seq 1 150); do
  if lsof -nP -iUDP:"$PORT" 2>/dev/null | grep -qE "veild|stream"; then READY=1; break; fi
  sleep 0.2
done
[ "$READY" = 1 ] || { cat "$OUTDIR/host.log"; die "host 未监听 $PORT"; }

# 4) client：沉浸到客户端屏
script -q /dev/null "$CLIENT_BIN" --connect 127.0.0.1 --port "$PORT" --fingerprint "$FP" \
    --identity "$IDENTITY" --spec "$SPEC" \
    --ref-barcode --window "${WIN_W}x${WIN_H}" --duration-ms "$CLIENT_MS" \
    --out "$OUTDIR/client.json" >"$OUTDIR/client.log" 2>&1 &
CLIENT_PID=$!

# 5) 等 STREAMING（同样避免外挂 grep）
STREAMED=0
for _ in $(seq 1 120); do
  CLOG="$(cat "$OUTDIR/client.log" 2>/dev/null || true)"
  if [[ "$CLOG" == *"已 STREAMING"* ]]; then STREAMED=1; break; fi
  sleep 0.2
done
[ "$STREAMED" = 1 ] || { tail -20 "$OUTDIR/client.log"; die "客户端未进入 STREAMING"; }
say "已进入 STREAMING，预热 ${WARMUP}s"

# 6) 预热。参考钟由客户端进程自己画（--ref-barcode）：
#    副屏上独立进程的窗口拿不到合成（实测只有壁纸），客户端窗口本来就在那块屏上，
#    子视图与画面同帧合成，截屏时刻因此完全不进入计算。
sleep "$WARMUP"

# 6b) 取客户端窗口的内容矩形（客户端自己打印，含标题栏偏移与坐标翻转）
RECT=""
for _ in $(seq 1 60); do
  CLOG="$(cat "$OUTDIR/client.log" 2>/dev/null || true)"
  if [[ "$CLOG" =~ A02_WINDOW_RECT\ ([0-9]+),([0-9]+),([0-9]+),([0-9]+) ]]; then
    RECT="${BASH_REMATCH[1]},${BASH_REMATCH[2]},${BASH_REMATCH[3]},${BASH_REMATCH[4]}"; break
  fi
  sleep 0.2
done
[ -n "$RECT" ] || { tail -10 "$OUTDIR/client.log"; die "客户端未报告窗口矩形"; }
say "客户端内容矩形 ${RECT}（截屏只在这个矩形内判读）"

# 7) 采样
ok=0; bad=0
for i in $(seq 1 "$SAMPLES"); do
  png=""
  [ "$i" = 1 ] && png="--png $OUTDIR/sample.png"
  line="$("$HERE/a02_shot" --two --display "$CDISP" --rect "$RECT" $png 2>/dev/null | tail -1 || true)"
  printf '%s\n' "$line" >>"$OUTDIR/samples.jsonl"
  if printf '%s' "$line" | grep -q '"ok":true'; then ok=$((ok+1)); else bad=$((bad+1)); fi
  sleep "$INTERVAL"
done
say "采样完成：ok=$ok bad=$bad"

kill $CLOCK_PID $CAF_PID 2>/dev/null || true
wait $CLIENT_PID 2>/dev/null || true
wait $HOST_PID 2>/dev/null || true

# 8) 汇总
python3 - "$OUTDIR" <<'PY'
import json, os, sys, statistics as st
outdir = sys.argv[1]
lat, bad = [], []
for line in open(os.path.join(outdir, "samples.jsonl")):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("ok"):
        lat.append(d["latencyMs"])
    else:
        bad.append(d.get("why"))
if not lat:
    print("FAIL：没有有效样本", set(bad))
    sys.exit(1)
lat.sort()
def pct(p):
    k = min(len(lat) - 1, max(0, int(round((p / 100.0) * (len(lat) - 1)))))
    return lat[k]
print(f"样本 {len(lat)}（丢弃 {len(bad)}：{sorted(set(bad)) if bad else '—'}）")
print(f"端到端（绘制→客户端可见） min {lat[0]}  p50 {pct(50)}  p95 {pct(95)}  max {lat[-1]}  mean {st.mean(lat):.1f} ms")

cj = os.path.join(outdir, "client.json")
if os.path.exists(cj):
    c = json.load(open(cj))
    print(f"客户端采集→上屏 presentP50 {c.get('presentP50Ms', 0):.1f} "
          f"presentP95 {c.get('presentP95Ms', 0):.1f} ms"
          f"（样本 {c.get('presentSamples', '?')}，时钟差 {c.get('clockOffsetUs', 0)}us）")
    print(f"客户端解出/上屏 {c.get('framesDecoded', '?')}/{c.get('framesRendered', '?')}，"
          f"丢帧 {c.get('framesDropped', '?')}")
hj = os.path.join(outdir, "host.json")
if os.path.exists(hj):
    h = json.load(open(hj))
    print(f"主机采/编/发 {h.get('framesCaptured','?')}/{h.get('framesEncoded','?')}/{h.get('framesSent','?')}")
p50 = pct(50)
print("VERDICT " + ("PASS" if p50 <= 50 else "FAIL") + f"（A-02 总链路 ≤50ms，p50={p50}ms）")
PY
say "产物：$OUTDIR"
