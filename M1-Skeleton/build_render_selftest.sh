#!/bin/bash
#
# 构建 M1FrameView 离屏自检（tools/render_selftest）。
# 不需要可见窗口、不需要解锁屏幕，验证「像素缓冲 → CGImage → layer.contents」这一跳。
#
#   ./build_render_selftest.sh && ./render_selftest
#
set -euo pipefail

cd "$(dirname "$0")"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
P1SRC="../P1-ClientProbe/src"
SRC="src"

"$CLANG" -fobjc-arc -fmodules -O1 -g -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" -I "$SRC" -I "$P1SRC" \
  -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  "$SRC/M1FrameView.m" "$SRC/M1InputLogic.m" "$P1SRC/P1InputCodec.m" \
  "$P1SRC/ProtocolCodec.m" \
  tools/render_selftest.m \
  -framework AppKit -framework CoreImage -framework QuartzCore \
  -framework CoreVideo -framework CoreGraphics \
  -o ./render_selftest

echo "built: ./render_selftest"
