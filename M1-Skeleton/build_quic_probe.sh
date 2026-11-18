#!/bin/bash
#
# 构建 M1-A 的 QUIC 数据报探针（quic_probe）。
# 依赖：M1QuicTransport（Network.framework QUIC datagram flow）+ P1 协议分片。
#
set -euo pipefail

cd "$(dirname "$0")"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
P1SRC="../P1-ClientProbe/src"

# 自签测试身份（不存在则生成）
bash ./gen_quic_identity.sh .state rdp-identity rdpdev >/dev/null

"$CLANG" -fobjc-arc -fmodules -O2 -g -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" -I src -I "$P1SRC" \
  -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  src/M1QuicTransport.m \
  src/M1DatagramSink.m \
  src/M1PipelineTypes.m \
  src/M1FrameSender.m \
  "$P1SRC/ProtocolCodec.m" \
  quic_probe.m \
  -framework Foundation -framework Network -framework Security \
  -o ./quic_probe

echo "built: ./quic_probe"
