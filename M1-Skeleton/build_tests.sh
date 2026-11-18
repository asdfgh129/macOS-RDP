#!/bin/bash
# M1-Skeleton 单测构建：纯 Foundation，不依赖 WindowServer / AppKit。
set -euo pipefail
cd "$(dirname "$0")"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
P1SRC="../P1-ClientProbe/src"
SOURCES=(
  "src/M1Pairing.m"
  "src/M1Takeover.m"
  "src/M1SessionCoordinator.m"
  "src/M1DriverLogic.m"
  "src/M1InputLogic.m"
  "src/M1PipelineTypes.m"
  "src/M1DatagramSink.m"
  "src/M1FrameSender.m"
  "src/M1MessageSink.m"
  "src/M1ControlChannel.m"
  "src/M1ControlSession.m"
  "$P1SRC/ProtocolCodec.m"
  "$P1SRC/P1SessionState.m"
  "tests/test_skeleton.m"
)
for f in "${SOURCES[@]}"; do
  if [ ! -f "$f" ]; then echo "缺文件 $f" >&2; exit 1; fi
done
"$CLANG" -fobjc-arc -fmodules -O0 -g -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" -I src -I "$P1SRC" \
  -Wall -Wno-unused-parameter \
  "${SOURCES[@]}" -framework Foundation -o ./test_skeleton
./test_skeleton

# 负向安全测试：宿主没实现 --guardian 时，守护握手必须失败（禁止无兜底禁屏）。
# 不做任何显示配置变更，可安全运行。
"$CLANG" -fobjc-arc -fmodules -O1 -g -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" -I ../P0-TahoeProbe/src -I ../P0V-DisplayIsolation/src \
  -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  ../P0-TahoeProbe/src/ProbeUtil.m ../P0V-DisplayIsolation/src/P0VDisplayControl.m \
  tests/guardian_handshake_test.m -framework Foundation -framework CoreGraphics \
  -o ./guardian_handshake_test
./guardian_handshake_test
