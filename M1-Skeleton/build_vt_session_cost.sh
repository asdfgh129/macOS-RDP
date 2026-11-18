#!/bin/bash
#
# 构建 VT 会话创建成本测量程序（tools/vt_session_cost）。
# 用途：复核 D-15 F-15.1/F-15.2 —— VT 会话首次创建是进程内一次性开销，
# 且解码侧用「不含 SPS/PPS 的裸 format desc」也能建出会话。
#
#   ./build_vt_session_cost.sh && ./vt_session_cost
#   ./vt_session_cost --bare-only     # 只测裸 fd（不建编码器）
#
set -euo pipefail

cd "$(dirname "$0")"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"

"$CLANG" -fobjc-arc -fmodules -O1 -g -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" \
  -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  tools/vt_session_cost.m \
  -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
  -o ./vt_session_cost

echo "built: ./vt_session_cost"
