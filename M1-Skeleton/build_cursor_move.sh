#!/bin/bash
#
# 构建 tools/cursor_move（M1-B 端到端验证用的光标工具）。
#
#   ./build_cursor_move.sh && ./cursor_move info
#
set -euo pipefail

cd "$(dirname "$0")"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"

"$CLANG" -fobjc-arc -fmodules -O1 -g -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" \
  -Wall -Wno-unused-parameter \
  tools/cursor_move.m \
  -framework Foundation -framework CoreGraphics -framework ApplicationServices \
  -o ./cursor_move

echo "built: ./cursor_move"
