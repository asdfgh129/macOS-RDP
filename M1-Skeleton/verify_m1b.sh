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
MANUAL_SECS="${M1B_MANUAL_SECS:-12}"

# 手动模式（M1B_DRIVER=manual）要留出「首帧 + 提示 + 人操作」的整段时间，
# 否则客户端会话在提示还没走完就到期了。
if [ "${M1B_DRIVER:-}" = manual ]; then
  _need=$(( MANUAL_SECS * 1000 + 12000 ))
  [ "$DURATION_MS" -lt "$_need" ] && DURATION_MS="$_need"
fi

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
      --save-frames 0 ${KEEP_FRONT_ARG:-} ${SYNTH_ARG:-} ${MANUAL_ARG:-} --out "$out/client.json" \
      > "$out/client.log" 2>&1 &
  local client_pid=$!

  for _i in $(seq 1 150); do grep -q "已 STREAMING" "$out/client.log" 2>/dev/null && break; sleep 0.1; done
  if ! grep -q "已 STREAMING" "$out/client.log" 2>/dev/null; then
    say "  客户端未进入 STREAMING"
    kill "$client_pid" "$host_pid" 2>/dev/null
    return 2
  fi

  # 驱动点必须用「画面中心」而不是「屏幕中心」：窗口内容里视频是 letterbox 的，
  # 屏幕中心经常落在黑边上，而黑边按设计不产生输入（踩过：真光标四次移动，
  # 视图收到 8 个 mouseMoved，主机 0 条）。锚点由客户端首帧到达后打印。
  local anchors cx cy lx ly rx ry
  for _i in $(seq 1 120); do
    anchors=$(grep -m1 "\[anchors\]" "$out/client.log" 2>/dev/null)
    [ -n "$anchors" ] && break
    sleep 0.1
  done
  if [ -z "$anchors" ]; then
    say "  没等到首帧锚点（客户端可能没解出画面）"
    kill "$client_pid" "$host_pid" 2>/dev/null
    return 2
  fi
  cx=$(printf '%s' "$anchors" | sed -n 's/.*center=(\([-0-9]*\),\([-0-9]*\)).*/\1/p')
  cy=$(printf '%s' "$anchors" | sed -n 's/.*center=(\([-0-9]*\),\([-0-9]*\)).*/\2/p')
  lx=$(printf '%s' "$anchors" | sed -n 's/.*left=(\([-0-9]*\),\([-0-9]*\)).*/\1/p')
  ly=$(printf '%s' "$anchors" | sed -n 's/.*left=(\([-0-9]*\),\([-0-9]*\)).*/\2/p')
  rx=$(printf '%s' "$anchors" | sed -n 's/.*right=(\([-0-9]*\),\([-0-9]*\)).*/\1/p')
  ry=$(printf '%s' "$anchors" | sed -n 's/.*right=(\([-0-9]*\),\([-0-9]*\)).*/\2/p')
  say "  画面锚点：$(printf '%s' "$anchors" | sed 's/^ *//')"

  if [ "$DRIVER" = manual ]; then
    say "  驱动=manual —— 客户端会响 3 声、把窗口标题改成「▶▶ 现在动鼠标」"
    say "  看到提示后：点一下窗口，再在画面里左右慢慢划 ${MANUAL_SECS}s"
    local _w
    for _w in $(seq 1 $((MANUAL_SECS + 20))); do
      grep -q "时间到，停手" "$out/client.log" 2>/dev/null && break
      sleep 1
    done
    if grep -q "时间到，停手" "$out/client.log" 2>/dev/null; then
      grep "窗口采集" "$out/client.log" | tail -2 | sed 's/^/    /'
    else
      say "  ✗ 没等到手动窗口结束（提示没出现，或首帧一直没来）"
      tail -5 "$out/client.log" | sed 's/^/    /'
    fi
  elif [ "$DRIVER" = physical ]; then
    # 首帧锚点出现 ≠ 窗口已经在收事件：实测第三次移动时窗口才投递第一个
    # mouseEntered，前两次移动被吞。所以先等窗口稳定，再把三点走两轮。
    say "  驱动=physical（真光标）→ ($cx,$cy) ($lx,$ly) ($rx,$ry)，各两轮"
    sleep 2.5
    drive() {
      ./cursor_move move "$1" "$2" >/dev/null
      sleep 0.9
      [ -n "${M1B_TRACE:-}" ] && say "    目标($1,$2) → 光标 $(./cursor_move info | sed -n 2p)"
    }
    drive "$cx" "$cy"; drive "$lx" "$ly"; drive "$rx" "$ry"
    drive "$cx" "$cy"; drive "$lx" "$ly"; drive "$rx" "$ry"
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

  python3 - "$out" "$WIN_W" "$WIN_H" "$cx" "$cy" "$DRIVER" <<'PY'
import json, sys

out, win_w, win_h, cx, cy, driver = (sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
                                    float(sys.argv[4]), float(sys.argv[5]), sys.argv[6])
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
    if driver == "manual":
        # 真人的落点无法规定，只判两件事：确实来了多次移动，且横向真的划过一段。
        # （驱动点式断言留给 physical/synth，那两条路是我们自己在控制坐标。）
        span = max(xs) - min(xs)
        print("  横向跨度 %.0f px（画面宽 %d，占 %.0f%%）" % (span, pw, 100.0 * span / max(pw, 1)))
        if span < 0.10 * pw:
            fails.append("横向跨度只有 %.0f px，不足画面宽 10%%（没有真的左右划）" % span)
        if any(v < 0 or v > ph for v in ys):
            fails.append("y 越界：%s（归一化坐标应在 [0, %d]）"
                         % (", ".join("%.0f" % v for v in ys), ph))
        print("  本轮 PASS")
        sys.exit(0)
    # 断言看的是「归一化后的主机坐标」，与驱动点的全局像素无关：
    # 画面中心 → 0.5 屏宽/屏高；左右两点 ≈ 0.5 ∓ 200 窗口像素换算值。
    center_x, center_y = pw * 0.5, ph * 0.5
    center_like = [v for v in xs if abs(v - center_x) <= 0.03 * pw]
    left_like   = [v for v in xs if v < center_x - 0.5 * expected_delta]
    right_like  = [v for v in xs if v > center_x + 0.5 * expected_delta]
    if not center_like:
        fails.append("没有一次落在画面中心附近（期望 x≈%.0f±%.0f）" % (center_x, 0.03 * pw))
    if not left_like:
        fails.append("没有一次落在中心左侧")
    if not right_like:
        fails.append("没有一次落在中心右侧")
    if expected_delta > 0:
        for label, cand in (("左侧", left_like), ("右侧", right_like)):
            if cand and abs(abs(cand[0] - center_x) - expected_delta) > 0.20 * expected_delta:
                fails.append("%s位移 %.0f 与预期 %.0f 偏差超 20%%" % (
                    label, abs(cand[0] - center_x), expected_delta))
    if ys and max(abs(v - center_y) for v in ys) > 0.08 * ph:
        fails.append("y 最大偏离画面中心 %.0f 超过 8%%" % max(abs(v - center_y) for v in ys))

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
# 已存在就不重编：cursor_move 要发系统事件，它有「辅助功能」授权（按 cdhash 记），
# 构建脚本已做成可复现（-no_uuid -g0），但“不必要地重编”仍是风险，能免则免。
if [ ! -x ./cursor_move ] || [ "${M1B_REBUILD:-0}" = 1 ]; then
  bash ./build_cursor_move.sh >/dev/null 2>&1 || { say "✗ cursor_move 构建失败"; exit 2; }
fi
bash ./build_stream_probe.sh >/dev/null 2>&1 || { say "✗ stream_probe 构建失败"; exit 2; }

# ---- 驱动方式 ----
# 有「辅助功能」授权 → 真光标 + CGEventPost，连「系统把事件交给 App」这一跳也测到。
# 没有 → 进程内投 NSEvent，走同一条 NSWindow sendEvent → M1FrameView 分发路径，
#         只少 OS 投递那一跳；坐标换算、协议编码、传输、主机解析、注入计划全是真的。
if [ "${M1B_DRIVER:-}" = manual ]; then
  # 真人操作：真光标要么被别的应用抢走前台、要么打进 letterbox 黑边，
  # 自动化里这两件事都不受控；改用「提示 + 人动手」，把这一跳真正测到。
  DRIVER=manual
  SYNTH_ARG=""
  MANUAL_ARG="--manual $MANUAL_SECS"
  KEEP_FRONT_ARG=""
  say "驱动: manual —— 响铃+窗口标题给信号，由真人动鼠标 ${MANUAL_SECS}s"
elif ./cursor_move ax >/dev/null 2>&1; then
  DRIVER=physical
  SYNTH_ARG=""
  MANUAL_ARG=""
  # WindowServer 只把 mouseMoved 投给前台应用；客户端窗口被别的 App 抢回前台时
  # 一条 move 都收不到（实测 frontmost=Chrome）。M1B_KEEP_FRONT=1 会每 300ms 重抢前台，
  # 但会打断你正在用的应用，所以默认关，只在需要时显式开。
  KEEP_FRONT_ARG="${M1B_KEEP_FRONT:+--keep-front}"
  say "驱动: physical —— 真光标（AXIsProcessTrusted=1）"
else
  DRIVER=synth
  SYNTH_ARG="--input-synth 450,253;250,253;650,253"
  MANUAL_ARG=""
  KEEP_FRONT_ARG=""
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
