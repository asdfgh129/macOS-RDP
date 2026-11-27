#!/bin/bash
# 显示事务硬熔断（NFR-06）故障注入测试：构建 + 三种模式各跑一遍。
#
# 安全性：故障模式下事务线程永不调用 CGBeginDisplayConfiguration /
# CGCompleteDisplayConfiguration，物理屏不会被禁用；脚本仍会在跑前跑后
# 各拍一次 active display 列表做对照。
#
# 用法：
#   bash Scripts/tests/tx-breaker/run.sh              # 构建 + 三种模式
#   bash Scripts/tests/tx-breaker/run.sh --build-only
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 1
ROOT="$(pwd)"
OUT="${TX_BREAKER_OUT:-/tmp/veild-tx-breaker}"
SRC_P0V="$ROOT/P0V-DisplayIsolation/src"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
mkdir -p "$OUT"

build() {
  echo "== build =="
  echo "OS   : $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "SDK  : $SDKROOT"
  "$CLANG" -fobjc-arc -fmodules -O0 -g -mmacosx-version-min=13.0 \
    -isysroot "$SDKROOT" \
    -I "$SRC_P0V" -I "$ROOT/P0-TahoeProbe/src" \
    -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
    "$ROOT/P0-TahoeProbe/src/ProbeUtil.m" \
    "$SRC_P0V/P0VDisplayControl.m" \
    "$ROOT/Scripts/tests/tx-breaker/tx_breaker_test.m" \
    -framework Foundation -framework ApplicationServices -framework CoreGraphics \
    -framework IOKit \
    -o "$OUT/tx_breaker" || return 1
  codesign --force --sign - --identifier "com.veild.txbreaker" --timestamp=none \
    "$OUT/tx_breaker" 2>/dev/null && echo "已 ad-hoc 签名"
  return 0
}

if [ "${1:-}" = "--build-only" ]; then build; exit $?; fi
build || exit 1

echo ""
fail=0
for mode in normal hang wsfreeze; do
  echo ""
  echo "================ mode=$mode ================"
  if [ "$mode" = "normal" ]; then
    env -u P0V_FAULT_TX "$OUT/tx_breaker" normal 2>&1 | tee "$OUT/$mode.log"
    rc=${PIPESTATUS[0]}
  else
    env P0V_FAULT_TX="$mode" "$OUT/tx_breaker" "$mode" 2>&1 | tee "$OUT/$mode.log"
    rc=${PIPESTATUS[0]}
  fi
  echo "exit=$rc"
  [ "$rc" -eq 0 ] || fail=1
done

echo ""
echo "== 汇总 =="
for mode in normal hang wsfreeze; do
  line=$(grep -E "^(elapsed|  PASS|  FAIL)" "$OUT/$mode.log" | tr '\n' ' ')
  echo "$mode: $line"
done
echo "日志目录: $OUT"
exit $fail
