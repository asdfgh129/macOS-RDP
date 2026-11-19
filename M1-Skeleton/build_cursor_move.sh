#!/bin/bash
#
# 构建 tools/cursor_move（M1-B 端到端验证用的光标工具）。
#
#   ./build_cursor_move.sh && ./cursor_move info
#
# -Wl,-no_uuid：链接器默认给每次链接塞一个随机 LC_UUID，导致同一份源码重建出的
# cdhash 每次都不同，「辅助功能」授权（按 cdhash 记）随即失效——重编一次就要
# 重新授权一次。这里用 fixuuid.py 把 LC_UUID 钉成固定值（ld64 不支持 -uuid，
# 而 -no_uuid 会让 dyld 直接拒绝加载），再用 -g0 去掉 DWARF 里的构建临时路径；
# 两者合起来才可复现：同一份源码重建 → 字节完全相同 → cdhash 不变 → 授权不丢。
# 代价是没有调试符号（这个工具不需要）。
#
set -euo pipefail

cd "$(dirname "$0")"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"

"$CLANG" -fobjc-arc -fmodules -O1 -g0 -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" \
  -Wall -Wno-unused-parameter \
  tools/cursor_move.m \
  -framework Foundation -framework CoreGraphics -framework ApplicationServices \
  -o ./cursor_move

python3 tools/fixuuid.py ./cursor_move

echo "built: ./cursor_move"
