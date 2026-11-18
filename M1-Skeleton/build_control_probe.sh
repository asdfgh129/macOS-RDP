#!/bin/bash
#
# 构建 M1-A 第 3 步的控制通道探针（control_probe）。
# 依赖：M1QuicTransport（datagram 传输 + M1ControlLink 可靠性）+ M1ControlChannel/M1ControlSession。
#
set -euo pipefail

cd "$(dirname "$0")"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
P1SRC="../P1-ClientProbe/src"

bash ./gen_quic_identity.sh .state rdp-identity rdpdev >/dev/null

"$CLANG" -fobjc-arc -fmodules -O2 -g -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" -I src -I "$P1SRC" \
  -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  src/M1QuicTransport.m \
  src/M1MessageSink.m \
  src/M1ControlLink.m \
  src/M1ControlChannel.m \
  src/M1ControlSession.m \
  "$P1SRC/ProtocolCodec.m" \
  "$P1SRC/P1SessionState.m" \
  control_probe.m \
  -framework Foundation -framework Network -framework Security -framework QuartzCore \
  -o ./control_probe

echo "built: ./control_probe"
