#!/bin/bash
#
# M1-B 端到端自检：窗口上屏 + 输入回传（单机环回）。
#
#   前提：屏幕必须解锁。锁屏时 SCK 拿不到 display、窗口也收不到鼠标事件，
#        这不是代码问题，所以本脚本在这一步直接失败退出，不做任何猜测。
#
#   流程：
#     1. host：采集 → 编码 → 推流，同时 record 模式记录注入计划
#     2. client：--window 起窗口，把解码帧画到屏幕上，并采集窗口输入
#     3. 用 cursor_move 把光标移到窗口中心 / 左 200 / 右 200
#     4. 断言：
#        · 客户端至少贴上 1 帧
#        · 主机收到 ≥3 条输入，且三次点击的全局坐标与窗口内位移成比例
#          （按 host 实际采集分辨率与窗口 letterbox 换算，容差 ±20%）
#
#   用法：
#     ./verify_m1b.sh [输出目录]
#     M1B_DURATION_MS=16000 ./verify_m1b.sh
#
set -uo pipefail

cd "$(dirname "$0")"

OUT="${1:-/tmp/m1b-verify}"
DURATION_MS="${M1B_DURATION_MS:-14000}"
WIN_W=900
WIN_H=506

say() { printf '%s\n' "$*"; }

# ---- 0. 前置：锁屏检查 ----
if ! ./cursor_move locked >/dev/null 2>&1; then
  say "✗ 屏幕已锁定（CGSSessionScreenIsLocked=YES）"
  say "  SCK 采集不到 display，窗口也收不到鼠标事件；请先解锁屏幕再运行。"
  exit 1
fi

# ---- 1. 构建 ----
bash ./build_cursor_move.sh >/dev/null 2>&1 || { say "✗ cursor_move 构建失败"; exit 2; }
bash ./build_stream_probe.sh >/dev/null 2>&1 || { say "✗ stream_probe 构建失败"; exit 2; }

rm -rf "$OUT"; mkdir -p "$OUT"

# ---- 2. host ----
./stream_probe --host --port 0 --port-file "$OUT/port.txt" \
    --duration-ms "$DURATION_MS" --inject record --out "$OUT/host.json" \
    > "$OUT/host.log" 2>&1 &
HOST_PID=$!

for _ in $(seq 1 200); do [ -s "$OUT/port.txt" ] && break; sleep 0.1; done
PORT=$(sed -n '1p' "$OUT/port.txt" 2>/dev/null)
FP=$(sed -n '2p' "$OUT/port.txt" 2>/dev/null)
if [ -z "${PORT:-}" ] || [ -z "${FP:-}" ]; then
  say "✗ host 没起来（见 $OUT/host.log）"
  kill "$HOST_PID" 2>/dev/null
  exit 2
fi
say "host 端口 $PORT"

# ---- 3. client（带窗口）----
./stream_probe --client --port "$PORT" --fingerprint "$FP" \
    --duration-ms "$((DURATION_MS - 1500))" --window "${WIN_W}x${WIN_H}" \
    --save-frames 0 --out "$OUT/client.json" \
    > "$OUT/client.log" 2>&1 &
CLIENT_PID=$!

for _ in $(seq 1 150); do grep -q "已 STREAMING" "$OUT/client.log" 2>/dev/null && break; sleep 0.1; done
if ! grep -q "已 STREAMING" "$OUT/client.log" 2>/dev/null; then
  say "✗ 客户端未进入 STREAMING（见 $OUT/client.log）"
  kill "$CLIENT_PID" "$HOST_PID" 2>/dev/null
  exit 2
fi
say "双端 STREAMING，开始驱动光标"

# ---- 4. 驱动光标：窗口居中，所以屏幕中心 = 窗口内容中心 ----
read -r DW DH <<< "$(./cursor_move info | head -1)"
CX=$(awk -v w="${DW:-3440}" 'BEGIN{printf "%d", w/2}')
CY=$(awk -v h="${DH:-1440}" 'BEGIN{printf "%d", h/2}')
say "主屏 ${DW}x${DH}，光标三点：($CX,$CY) ($((CX-200)),$CY) ($((CX+200)),$CY)"

sleep 1.2
./cursor_move move "$CX" "$CY" >/dev/null
sleep 0.5
./cursor_move move $((CX - 200)) "$CY" >/dev/null
sleep 0.5
./cursor_move move $((CX + 200)) "$CY" >/dev/null
sleep 0.3

wait "$CLIENT_PID" 2>/dev/null
wait "$HOST_PID" 2>/dev/null

# ---- 5. 断言 ----
say ""
say "--- host 输入段 ---"
sed -n '/输入注入/,/^$/p' "$OUT/host.log" | head -20
sed -n '/输入：/p' "$OUT/host.log"
say "--- client 上屏段 ---"
sed -n '/上屏：/p;/输入：/p;/判定/p' "$OUT/client.log"

python3 - "$OUT" "$WIN_W" "$WIN_H" "$CX" "$CY" <<'PY'
import json, sys

out, win_w, win_h, cx, cy = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
fails, notes = [], []

def load(name):
    try:
        return json.load(open(f"{out}/{name}"))
    except Exception as e:
        fails.append(f"{name} 读不出来: {e}")
        return {}

host = load("host.json")
client = load("client.json")
print("\n=== 断言 ===")

# 1) 客户端上屏
rendered = client.get("framesRendered", 0)
print(f"上屏帧数 {rendered}，单帧转换峰值 {client.get('maxRenderMs')} ms")
if rendered < 1:
    fails.append("客户端一帧都没贴上（窗口没出画面）")

# 2) 输入条数
mouse = [p for p in host.get("inputPlans", []) if p.get("kind") == "mouse"]
print(f"主机收到输入 {host.get('inputReceived', 0)} 条，其中 mouse {len(mouse)} 条")
if len(mouse) < 3:
    fails.append(f"鼠标事件只有 {len(mouse)} 条，少于驱动的 3 次移动")

# 3) 坐标比例：按 host 实际分辨率与窗口 letterbox 换算
pw, ph = host.get("pixelWidth", 0), host.get("pixelHeight", 0)
if pw <= 0 or ph <= 0:
    fails.append("host.json 缺 pixelWidth/pixelHeight")
    expected_delta = 0
else:
    video_aspect = pw / ph
    win_aspect = win_w / win_h
    if video_aspect > win_aspect:
        fit_w = float(win_w)          # 宽受限，左右顶满
    else:
        fit_w = win_h * video_aspect  # 高受限，上下顶满
    expected_delta = 200.0 * pw / fit_w
    print(f"采集 {pw}x{ph}，窗口 {win_w}x{win_h} → 画面宽 {fit_w:.0f}px，"
          f"200 窗口像素应对应 {expected_delta:.0f} 屏幕像素")

if len(mouse) >= 3:
    xs = [p["x"] for p in mouse[-3:]]
    ys = [p["y"] for p in mouse[-3:]]
    print(f"最后三次 x = {['%.0f' % v for v in xs]}，y = {['%.0f' % v for v in ys]}")

    center_like = [v for v in xs if abs(v - cx) <= 0.03 * pw]
    left_like   = [v for v in xs if v < cx - 0.5 * expected_delta]
    right_like  = [v for v in xs if v > cx + 0.5 * expected_delta]
    if not center_like:
        fails.append(f"没有一次落在屏幕中心附近（期望 x≈{cx:.0f}±{0.03*pw:.0f}）")
    if not left_like:
        fails.append("没有一次落在中心左侧")
    if not right_like:
        fails.append("没有一次落在中心右侧")

    if expected_delta > 0:
        for label, cand in (("中心", center_like), ("左侧", left_like), ("右侧", right_like)):
            if cand:
                d = abs(cand[0] - cx)
                tol = 0.25 * expected_delta + 0.02 * pw
                if label != "中心" and abs(d - expected_delta) > 0.20 * expected_delta:
                    fails.append(f"{label}位移 {d:.0f} 与预期 {expected_delta:.0f} 偏差超 20%")

    # 竖直方向：窗口标题栏会把内容中心往下推十几像素，容差给 8%
    if ys and abs(ys[0] - cy) > 0.08 * ph:
        fails.append(f"y={ys[0]:.0f} 偏离屏幕中心 {cy:.0f} 超过 8%")

print()
if fails:
    print("结论: FAIL")
    for f in fails:
        print("  ·", f)
    sys.exit(1)
print("结论: PASS — 窗口上屏 + 输入回传全链路成立")
PY
RC=$?
say ""
say "原始输出：$OUT/{host.log,client.log,host.json,client.json}"
exit $RC
