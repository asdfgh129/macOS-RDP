#!/bin/bash
# 多屏独占测试：构建外部虚拟屏持有器并分发到测试机。
#
# 说明：两台 Intel 测试机各只有一块物理屏，无法构造「双物理屏」场景。
# 这里用独立进程持有的一块虚拟屏，站在被测 host 会话视角上等价于
# 「一块不属于本会话的 active 屏」——用来验证独占禁屏的集合覆盖与恢复。
# 它不能替代双物理屏的 OS 层行为（mode-commit 时序 / 显示栈竞态）。
set -euo pipefail
cd "$(dirname "$0")/../../.." || exit 1
ROOT="$(pwd)"
OUT="${EXTRA_DISPLAY_OUT:-/tmp/veild-extra-display}"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
mkdir -p "$OUT"

echo "== build extra_display =="
"$CLANG" -fobjc-arc -fmodules -O0 -g -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" \
  -I "$ROOT/P0-TahoeProbe/src" \
  -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  "$ROOT/P0-TahoeProbe/src/ProbeUtil.m" \
  "$ROOT/P0-TahoeProbe/src/VDManager.m" \
  "$ROOT/Scripts/tests/multi-display/extra_display.m" \
  -framework Foundation -framework CoreGraphics -framework IOKit \
  -o "$OUT/extra_display"
codesign --force --sign - --identifier "com.veild.extradisplay" --timestamp=none \
  "$OUT/extra_display" 2>/dev/null && echo "已 ad-hoc 签名"
echo "构建完成：$OUT/extra_display"
