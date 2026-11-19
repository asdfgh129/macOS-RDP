#!/bin/bash
#
# M1-B 端到端自检：窗口上屏 + 输入回传（单机环回）。
#
#   前提：屏幕必须解锁。锁屏时 SCK 拿不到 display、窗口也收不到鼠标事件。
#        实测这台机器会出现「短暂解锁几秒又自动锁回」的窗口，所以本脚本按轮重试，
#        每一轮都很短（约 10 s），命中解锁窗口即通过。
#
#   每一轮：
#     1. host：采集 → 编码 → 推流，同时 record 模式记录注入计划
#     2. client：--window 起窗口，把解码帧画到屏幕上，并采集窗口输入
#     3. 用 cursor_move 把光标移到窗口中心 / 左 200 / 右 200
#     4. 断言：
#        · 客户端至少贴上 1 帧
#        · 主机收到 ≥3 条输入，且三次移动的全局坐标与窗口内位移成比例
#          （按 host 实际采集分辨率与窗口 letterbox 换算）
#
#   用法：
#     ./verify_m1b.sh [输出目录]                    # 默认 4 轮
#     M1B_ATTEMPTS=8 M1B_DURATION_MS=8000 ./verify_m1b.sh
#
set -uo pipefail

cd "$(dirname "$0")"

OUT_ROOT="${1:-/tmp/m1b-verify}"
DURATION_MS="${M1B_DURATION_MS:-9000}"
ATTEMPTS="${M1B_ATTEMPTS:-4}"
WIN_W=900
WIN_H=506

say() { printf '%s\n' "$*"; }

# 连续 3 次都读成解锁才算解锁：单次读取会被会话切换的瞬时 NULL 骗到，
# 实测出现过「报解锁、随即又锁」的假信号。
#
# 退出码约定（别记反）：`cursor_move locked` → 锁定时 exit 1，解锁时 exit 0。
# 所以「检查失败（非 0）」= 锁定 = 本轮不可测。
is_unlocked() {
  local _i
  for _i in 1 2 3; do
    # state 把「锁屏」和「显示器睡了」合并成一个判据（两者对验证一样致命），
    # 并且能打印细项，跳过时不再只写一句含糊的「屏幕锁定」。
    ./cursor_move state >/dev/null 2>&1 || return 1
    sleep 0.3
  done
  return 0
}

# 一轮完整验证。返回 0 = PASS。
one_attempt() {
  local out="$1"
  rm -rf "$out"; mkdir -p "$out"

  ./stream_probe --host --port 0 --port-file "$out/port.txt" \
      --duration-ms "$DURATION_MS" --inject record --out "$out/host.json" \
      > "$out/host.log" 2>&1 &
  local host_pid=$!

  local _i port fp
  for _i in $(seq 1 200); do [ -s "$out/port.txt" ] && break; sleep 0.1; done
  port=$(sed -n '1p' "$out/port.txt" 2>/dev/null)
  fp=$(sed -n '2p' "$out/port.txt" 2>/dev/null)
  if [ -z "${port:-}" ] || [ -z "${fp:-}" ]; then
    say "  host 没起来"; kill "$host_pid" 2>/dev/null; return 2
  fi

  ./stream_probe --client --port "$port" --fingerprint "$fp" \
      --duration-ms "$((DURATION_MS - 1500))" --window "${WIN_W}x${WIN_H}" \
      --save-frames 0 ${SYNTH_ARG:-} --out "$out/client.json" \
      > "$out/client.log" 2>&1 &
  local client_pid=$!

  for _i in $(seq 1 150); do grep -q "已 STREAMING" "$out/client.log" 2>/dev/null && break; sleep 0.1; done
  if ! grep -q "已 STREAMING" "$out/client.log" 2>/dev/null; then
    say "  客户端未进入 STREAMING"
    kill "$client_pid" "$host_pid" 2>/dev/null
    return 2
  fi

  # 窗口居中 ⇒ 屏幕中心 = 窗口内容中心
  local dw dh cx cy
  read -r dw dh <<< "$(./cursor_move info | head -1)"
  cx=$(awk -v w="${dw:-3440}" 'BEGIN{printf "%d", w/2}')
  cy=$(awk -v h="${dh:-1440}" 'BEGIN{printf "%d", h/2}')

  if [ "$DRIVER" = physical ]; then
    say "  驱动=physical（真光标）三点：($cx,$cy) ($((cx-200)),$cy) ($((cx+200)),$cy)"
    # 解锁窗口只有十几秒，驱动节奏要快
    sleep 0.6
    ./cursor_move move "$cx" "$cy" >/dev/null
    sleep 0.35
    ./cursor_move move $((cx - 200)) "$cy" >/dev/null
    sleep 0.35
    ./cursor_move move $((cx + 200)) "$cy" >/dev/null
    sleep 0.3
  else
    say "  驱动=synth（进程内 NSEvent，客户端在 +1.2/+1.55/+1.9s 各投一次）"
  fi

  wait "$client_pid" 2>/dev/null
  wait "$host_pid" 2>/dev/null

  # SCK 在锁屏/屏睡时拿不到 display，这一轮必然没有帧
  if grep -q "管线启动失败" "$out/host.log" 2>/dev/null; then
    say "  主机管线启动失败：$(grep -m1 '管线启动失败' "$out/host.log")"
    return 2
  fi

  python3 - "$out" "$WIN_W" "$WIN_H" "$cx" "$cy" <<'PY'
import json, sys

out, win_w, win_h, cx, cy = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
fails = []

def load(name):
    try:
        return json.load(open(f"{out}/{name}"))
    except Exception as e:
        fails.append(f"{name} 读不出来: {e}")
        return {}

host = load("host.json")
client = load("client.json")

rendered = client.get("framesRendered", 0)
skipped = client.get("renderSkippedOccluded", 0)
print("  上屏 %d 帧（丢 %s 积压 / 跳过 %s 不可见），单帧渲染 %.1f/%.1f ms" % (
    rendered, client.get("renderDropped"), skipped,
    client.get("lastRenderMs") or 0, client.get("maxRenderMs") or 0))
if rendered < 1:
    if skipped:
        fails.append("窗口不可见（被登录窗/锁屏遮住），%d 帧全部跳过未上屏" % skipped)
    else:
        fails.append("客户端一帧都没贴上")

mouse = [p for p in host.get("inputPlans", []) if p.get("kind") == "mouse"]
print("  主机收到输入 %s 条，其中 mouse %d 条" % (host.get("inputReceived", 0), len(mouse)))
if len(mouse) < 3:
    fails.append("鼠标事件只有 %d 条，少于驱动的 3 次移动" % len(mouse))

pw, ph = host.get("pixelWidth", 0), host.get("pixelHeight", 0)
expected_delta = 0
if pw <= 0 or ph <= 0:
    fails.append("host.json 缺 pixelWidth/pixelHeight")
else:
    video_aspect = pw / ph
    win_aspect = win_w / win_h
    fit_w = float(win_w) if video_aspect > win_aspect else win_h * video_aspect
    expected_delta = 200.0 * pw / fit_w
    print("  采集 %dx%d，窗口 %dx%d → 画面宽 %.0fpx，200 窗口像素 ≈ %.0f 屏幕像素" % (
        pw, ph, win_w, win_h, fit_w, expected_delta))

if len(mouse) >= 3:
    xs = [p["x"] for p in mouse]
    ys = [p["y"] for p in mouse]
    print("  收到 %d 条 mouse，x = %s ；y = %s" % (
        len(mouse), " ".join("%.0f" % v for v in xs[-6:]),
        " ".join("%.0f" % v for v in ys[-6:])))
    center_like = [v for v in xs if abs(v - cx) <= 0.03 * pw]
    left_like   = [v for v in xs if v < cx - 0.5 * expected_delta]
    right_like  = [v for v in xs if v > cx + 0.5 * expected_delta]
    if not center_like:
        fails.append("没有一次落在屏幕中心附近（期望 x≈%.0f±%.0f）" % (cx, 0.03 * pw))
    if not left_like:
        fails.append("没有一次落在中心左侧")
    if not right_like:
        fails.append("没有一次落在中心右侧")
    if expected_delta > 0:
        for label, cand in (("左侧", left_like), ("右侧", right_like)):
            if cand and abs(abs(cand[0] - cx) - expected_delta) > 0.20 * expected_delta:
                fails.append("%s位移 %.0f 与预期 %.0f 偏差超 20%%" % (
                    label, abs(cand[0] - cx), expected_delta))
    if ys and max(abs(v - cy) for v in ys) > 0.08 * ph:
        fails.append("y 最大偏离屏幕中心 %.0f 超过 8%%" % max(abs(v - cy) for v in ys))

if fails:
    print("  本轮 FAIL: " + "；".join(fails))
    sys.exit(1)
print("  本轮 PASS")
PY

  local rc=$?
  say "  --- host 输入段 ---"
  sed -n '/输入注入/,/输入：/p' "$out/host.log" | head -12
  return $rc
}

# ---- 构建 ----
bash ./build_cursor_move.sh >/dev/null 2>&1 || { say "✗ cursor_move 构建失败"; exit 2; }
bash ./build_stream_probe.sh >/dev/null 2>&1 || { say "✗ stream_probe 构建失败"; exit 2; }

# ---- 驱动方式 ----
# 有「辅助功能」授权 → 真光标 + CGEventPost，连「系统把事件交给 App」这一跳也测到。
# 没有 → 进程内投 NSEvent，走同一条 NSWindow sendEvent → M1FrameView 分发路径，
#         只少 OS 投递那一跳；坐标换算、协议编码、传输、主机解析、注入计划全是真的。
if ./cursor_move ax >/dev/null 2>&1; then
  DRIVER=physical
  SYNTH_ARG=""
  say "驱动: physical —— 真光标（AXIsProcessTrusted=1）"
else
  DRIVER=synth
  SYNTH_ARG="--input-synth 450,253;250,253;650,253"
  say "驱动: synth —— AXIsProcessTrusted=0，改用进程内 NSEvent（缺 OS 投递一跳）"
fi

for a in $(seq 1 "$ATTEMPTS"); do
  say "=== 第 $a/$ATTEMPTS 轮 ==="
  if ! is_unlocked; then
    say "  会话不可用，跳过本轮：$(./cursor_move state 2>/dev/null)"
    sleep 3
    continue
  fi
  OUT="$OUT_ROOT/run$a"
  if one_attempt "$OUT"; then
    say ""
    say "结论: PASS — 窗口上屏 + 输入回传全链路成立（第 $a 轮）"
    say "原始输出：$OUT/{host.log,client.log,host.json,client.json}"
    exit 0
  fi
  sleep 2
done

say ""
say "结论: 未通过 —— $ATTEMPTS 轮都没命中可用的解锁窗口，或断言未满足。"
say "最后输出：$OUT_ROOT/run$ATTEMPTS/"
exit 1
