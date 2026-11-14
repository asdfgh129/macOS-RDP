#!/bin/bash
# P0-TahoeProbe 一键运行 + 诊断回收（在【被控端】Intel Mac / macOS 26 Tahoe 上运行）
#
# 用法（务必在已登录桌面的 Terminal.app 窗口里跑，不要 ssh）：
#   bash run_p0.sh
#
# 可选环境变量：
#   P0_NO_BUILD=1             跳过编译，用已有 ./p0probe
#   P0_QUICK=1                只跑 probe + verify，跳过 --direct 对照
#   P0_RUN_HOLD=60            额外跑 hold 并保持 60 秒（便于在「系统设置→显示器」肉眼核对）
#   P0_EXTRA="--fresh --max-retries 12"   透传给每个 verify/hold
#
# 产物：diag-<时间戳>/ 目录 + p0-diag-<时间戳>.tar.gz。把 tar.gz 一个文件带回来即可。
# 本脚本故意不用 set -e：任何一步失败都要继续把后面的日志收齐。

set -uo pipefail
cd "$(dirname "$0")"

STAMP="$(date +%Y%m%d-%H%M%S)"
DIAG="diag-${STAMP}"
ARCHIVE="p0-diag-${STAMP}.tar.gz"
mkdir -p "$DIAG"

log() { printf '[run_p0] %s\n' "$*"; }

# ---------------------------------------------------------------- 环境采集
MGR="$(launchctl managername 2>/dev/null || echo unknown)"
{
  echo "generatedAt : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "GUI_SESSION : $MGR"
  echo "TERM_PROGRAM: ${TERM_PROGRAM:-unknown}"
  echo "PARENT_PROC : $(ps -o comm= -p "$PPID" 2>/dev/null || echo unknown)"
  echo ""
  echo "--- sw_vers ---"; sw_vers
  echo "--- uname ---"; uname -a
  echo "--- xcode-select ---"; xcode-select -p
  echo "--- sdk path ---"; xcrun --sdk macosx --show-sdk-path
  echo "--- id ---"; id
  echo "--- SPDisplaysDataType (前 60 行) ---"
  system_profiler SPDisplaysDataType 2>/dev/null | head -60
} > "$DIAG/environment.txt" 2>&1

log "GUI 会话 = $MGR（预期 Aqua）"
if [ "$MGR" != "Aqua" ]; then
  log "!! 警告：不在 Aqua GUI 会话。若你是 ssh/LaunchDaemon 进来的，虚拟屏不会 attach 到"
  log "   WindowServer，结果必然全黑 —— 请在已登录桌面的 Terminal.app 窗口里重跑。"
fi
log "TCC 提示：屏幕录制权限归属启动本脚本的终端；授权后要完全退出终端再重开。"

# ---------------------------------------------------------------- 编译
BUILD_OK=1
if [ "${P0_NO_BUILD:-0}" = "1" ] && [ -x ./p0probe ]; then
  log "跳过编译（P0_NO_BUILD=1，使用已有 ./p0probe）"
else
  log "编译中（bash build.sh）..."
  bash build.sh > "$DIAG/build.stdout.log" 2> "$DIAG/build.stderr.log" || BUILD_OK=0
  cat "$DIAG/build.stdout.log"
  if [ -s "$DIAG/build.stderr.log" ]; then
    log "--- 编译 stderr ---"
    cat "$DIAG/build.stderr.log" >&2
  fi
  [ "$BUILD_OK" = "1" ] && log "编译成功" || log "编译失败，跳过运行；诊断包仍会生成"
fi

run_step() {
  name="$1"; shift
  log "--- $name : ./p0probe $* ---"
  ./p0probe "$@" > "$DIAG/$name.jsonl" 2> "$DIAG/$name.stderr.log"
  rc=$?
  echo "$rc" > "$DIAG/$name.rc"
  log "$name 退出码=$rc"
  if [ -f p0_result.json ]; then
    cp p0_result.json "$DIAG/p0_result.$name.json"
  fi
}

if [ "$BUILD_OK" = "1" ]; then
  # 第 1 步永远先跑：不建屏，只验环境 / 私有类签名 / TCC / 编码器档位。
  run_step probe probe --capabilities

  # 第 2 步：默认保守 canvas 的完整链路。
  run_step verify verify ${P0_EXTRA:-}

  # 第 3 步：对照实验，跳过保守 canvas 直接以目标分辨率建屏（PR #288 的 A/B）。
  if [ "${P0_QUICK:-0}" != "1" ]; then
    run_step verify_direct verify --direct ${P0_EXTRA:-}
  fi

  if [ "${P0_RUN_HOLD:-0}" != "0" ]; then
    run_step hold hold --hold-seconds "$P0_RUN_HOLD" ${P0_EXTRA:-}
  fi
fi

# identity 成功 offset 是正式产品必须复用的持久化状态，一并带回。
if [ -f "$HOME/.p0_identity.json" ]; then
  cp "$HOME/.p0_identity.json" "$DIAG/identity.json"
fi

# ---------------------------------------------------------------- 摘要
{
  echo "P0-TahoeProbe 诊断摘要  $STAMP"
  echo "GUI_SESSION = $MGR"
  echo "BUILD_OK    = $BUILD_OK"
  echo ""
  echo "--- 各步退出码 ---"
  for f in "$DIAG"/*.rc; do
    [ -e "$f" ] || continue
    echo "$(basename "$f") = $(cat "$f")"
  done
  echo ""
  echo "--- verdict ---"
  grep -h '"stage":"verdict"' "$DIAG"/*.jsonl 2>/dev/null || echo "(无)"
  echo ""
  echo "--- 私有 API 签名比对 ---"
  grep -h '"stage":"spi-signature-check"' "$DIAG"/*.jsonl 2>/dev/null || echo "(无)"
  echo ""
  echo "--- 屏幕录制权限（sck-before） ---"
  grep -h '"stage":"sck-before"' "$DIAG"/*.jsonl 2>/dev/null | head -4 || echo "(无)"
  echo ""
  echo "--- capture ---"
  grep -h '"stage":"capture"' "$DIAG"/*.jsonl 2>/dev/null || echo "(无)"
  echo ""
  echo "--- 编码器能力 ---"
  grep -h '"stage":"encoder-capabilities"' "$DIAG"/*.jsonl 2>/dev/null | head -2 || echo "(无)"
} > "$DIAG/SUMMARY.txt" 2>&1

if grep -q '"screenRecordingGranted":false' "$DIAG"/*.jsonl 2>/dev/null; then
  log "!! sck-before 显示屏幕录制权限未就绪：给「$(ps -o comm= -p "$PPID" 2>/dev/null)」授权后，"
  log "   完全退出终端再重开，然后重跑本脚本。否则后面全部是假失败。"
fi

tar -czf "$ARCHIVE" -C "$DIAG" . 2>/dev/null || tar -czf "$ARCHIVE" "$DIAG"

echo ""
cat "$DIAG/SUMMARY.txt"
echo ""
log "诊断目录：$PWD/$DIAG"
log "诊断包  ：$PWD/$ARCHIVE"
log "把这一个 .tar.gz 带回 Windows 侧即可（含 build 日志、全部 jsonl、环境与 SUMMARY）。"
