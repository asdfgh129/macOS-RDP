#!/bin/bash
# 第 2 项批处理：一次跑完「编码面」与「HiDPI 面」，减少来回。
# 在 Terminal.app 里运行： ./run_batch.sh
# 每步都先过 TCC 预检；任一步 TCC 失败立即退出，不建屏。

set -uo pipefail
cd "$(dirname "$0")" || exit 1

STAMP="$(date +%Y%m%d-%H%M%S)"
DIAG="diag-batch-${STAMP}"
mkdir -p "$DIAG" || exit 1

echo "=== 批处理 $STAMP ==="
echo "终端: ${TERM_PROGRAM:-unknown}  父进程: $(ps -o comm= -p "$PPID" 2>/dev/null)"
sw_vers | tr '\n' ' '; echo

./p0probe probe 2>/dev/null > "$DIAG/probe.jsonl"
grep -h '"stage":"sck-before"' "$DIAG/probe.jsonl"
if ! grep -qE '"screenRecordingGranted":(1|true)' "$DIAG/probe.jsonl"; then
  echo "!! TCC 未就绪，已中止（未建任何虚拟屏）。"
  echo "RESULT: TCC_BLOCKED"
  exit 2
fi

run_case() {
  local name="$1" spec="$2"
  echo
  echo "=============================================="
  echo " [$name] spec=$spec"
  echo "=============================================="
  ./p0probe verify --spec "$spec" --fresh 2>&1 | tee "$DIAG/$name.log"
  local rc=${PIPESTATUS[0]}
  echo "退出码=$rc" | tee -a "$DIAG/$name.log"
  return $rc
}

# 1) 编码面：单屏 1080p，打开 H.264（默认即开编码）
run_case encode-1080p "1920x1080x0"
RC1=$?

# 2) HiDPI 面：1280x720 points → 2560x1440 像素，验证 pointPixelScale 修复与 pixelsOK 判据
run_case hidpi-720p "1280x720x1"
RC2=$?

echo
echo "=============================================="
echo " 汇总"
echo "=============================================="
for f in "$DIAG"/*.log; do
  echo "--- $(basename "$f") ---"
  grep -hE '"stage":"(verdict|modes|capture)"' "$f" 2>/dev/null | head -4
done
grep -hE '"stage":"verdict"' "$DIAG"/*.log > "$DIAG/verdicts.jsonl" 2>/dev/null
echo
echo "RESULT: encode_rc=$RC1 hidpi_rc=$RC2"
echo "日志目录: $PWD/$DIAG"
echo "（把 RESULT 行和上面汇总贴回来即可）"
