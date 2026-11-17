#!/bin/bash
# A-01 最小面验证：默认单块虚拟屏 1920x1080、不编码、不跑 --direct 对照。
# 必须在【已登录桌面的 Terminal.app 窗口】里运行（不要 ssh / LaunchDaemon）。
# 设计原则：TCC 预检失败就立即退出，绝不创建虚拟屏，保证系统不受影响。
#
# 可选环境变量：
#   P0_SPEC=1920x1080x1     屏规格（WxHxHIDPI，多屏用逗号分隔）
#   P0_ENCODE=1             打开 H.264 编码（默认关闭）
#   P0_EXTRA="--duration 8000"   额外透传参数

set -uo pipefail
cd "$(dirname "$0")" || exit 1

SPEC="${P0_SPEC:-1920x1080x0}"
ENCODE_FLAG="--no-encode"
if [ "${P0_ENCODE:-0}" = "1" ]; then ENCODE_FLAG=""; fi

STAMP="$(date +%Y%m%d-%H%M%S)"
DIAG="diag-min-${STAMP}"
LOG="$DIAG/verify-min.log"
mkdir -p "$DIAG" || exit 1

{
  echo "=== A-01 最小面验证 $STAMP ==="
  echo "GUI 会话   : $(launchctl managername 2>/dev/null || echo unknown)"
  echo "终端       : ${TERM_PROGRAM:-unknown}"
  echo "父进程     : $(ps -o comm= -p "$PPID" 2>/dev/null || echo unknown)"
  echo "二进制签名 : $(codesign -dv ./p0probe 2>&1 | grep -m1 'Identifier=' || echo unknown)"
  echo "--- sw_vers ---"
  sw_vers
  echo

  echo "--- [0] TCC 预检（不建屏）---"
  ./p0probe probe 2>/dev/null > "$DIAG/probe.jsonl"
  grep -h '"stage":"sck-before"' "$DIAG/probe.jsonl"
  echo
  if ! grep -qE '"screenRecordingGranted":(1|true)' "$DIAG/probe.jsonl"; then
    APP="${TERM_PROGRAM:-Terminal}"
    [ "$APP" = "Apple_Terminal" ] && APP="Terminal"
    echo "!! 屏幕录制权限未就绪，已中止。未创建任何虚拟屏，系统未受影响。"
    echo "   处理：系统设置 → 隐私与安全性 → 屏幕录制 → 勾选「${APP}」"
    echo "        然后完全退出该终端(App)，重新打开后再跑本脚本。"
    echo "   排查工具：./tcc_doctor.sh（会区分是终端没授权还是签名身份没继承）"
    echo "   注意：p0probe 是未签名/adhoc 二进制，重建会让授权失效，故本脚本不编译。"
    echo "RESULT: TCC_BLOCKED"
    exit 2
  fi
  echo "TCC OK，继续。"

  echo
  echo "--- [1] verify：spec=$SPEC  编码=${P0_ENCODE:-0}  --fresh ---"
  ./p0probe verify --spec "$SPEC" $ENCODE_FLAG --fresh ${P0_EXTRA:-} 2>&1
  RC=$?
  echo
  echo "verify 退出码 = $RC"
  if [ -f p0_result.json ]; then
    cp p0_result.json "$DIAG/p0_result.json"
  fi
  echo "RESULT: rc=$RC"
} 2>&1 | tee "$DIAG/verify-min.log"

ln -sfn "$DIAG/verify-min.log" last_min.log

echo
echo "=============================================="
echo "日志  : $PWD/$DIAG/verify-min.log"
echo "快捷  : $PWD/last_min.log"
if [ -f "$HOME/.p0_identity.json" ]; then
  cp "$HOME/.p0_identity.json" "$DIAG/identity.json"
  echo "identity: 已找到并复制（identity walk 成功过）"
else
  echo "identity: 无 ~/.p0_identity.json（可能未触发 walk）"
fi
echo "可关闭此窗口，把上面日志交给助手分析。"
