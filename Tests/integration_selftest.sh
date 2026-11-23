#!/bin/bash
# 跨模块集成自检（第 3 轮）：构建全部 target，然后运行三个产品入口的纯逻辑自检。
# 不触碰 WindowServer / 网络，不需要真机，可在任何一台开发机上跑。
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED_DATA="${DERIVED_DATA:-/tmp/veilrd-xcode}"
CONFIGURATION="${CONFIGURATION:-Debug}"
PRODUCTS="$DERIVED_DATA/Build/Products/$CONFIGURATION"

echo "=== build all targets ==="
DERIVED_DATA="$DERIVED_DATA" CONFIGURATION="$CONFIGURATION" bash Scripts/build.sh >/tmp/veilrd-integration-build.log 2>&1 || {
  tail -30 /tmp/veilrd-integration-build.log >&2
  exit 1
}

for lib in libRDPKit.a libProtocolCodec.a; do
  test -f "$PRODUCTS/$lib" || { echo "missing library: $lib" >&2; exit 1; }
done

echo "=== veild-host-agent selftest ==="
"$PRODUCTS/veild-host-agent" | tail -5

echo "=== VeilRD client selftest ==="
"$PRODUCTS/VeilRD" --selftest

echo "=== veild-host-daemon smoke ==="
"$PRODUCTS/veild-host-daemon" --help 2>&1 | head -1 || true

# 第 4 轮：环回验证共享节点层（QUIC + 控制会话 + A-02 时钟探针）。
# 不需要屏幕录制/辅助功能授权：只建链，不采集、不注入。
echo "=== stream session loopback selftest ==="
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
IDDIR="$(mktemp -d)/identity"
bash M1-Skeleton/gen_quic_identity.sh "$IDDIR" rdp-identity rdpdev >/dev/null
HEADERS=()
for d in Packages/RDPKit/Sources/* Packages/ProtocolCodec/Sources \
         P1-ClientProbe/src P0-TahoeProbe/src P0V-DisplayIsolation/src P0V-RootDaemon/src; do
  HEADERS+=("-I" "$d")
done
"$CLANG" -fobjc-arc -fmodules -O0 -g -mmacosx-version-min=13.0 -isysroot "$SDKROOT" \
  "${HEADERS[@]}" Tests/stream_session_selftest.m \
  "$PRODUCTS/libRDPKit.a" "$PRODUCTS/libProtocolCodec.a" \
  -framework Foundation -framework AppKit -framework Network -framework Security \
  -framework CoreGraphics -framework CoreVideo -framework CoreMedia -framework VideoToolbox \
  -framework ScreenCaptureKit -framework QuartzCore -framework CoreImage -framework ImageIO \
  -framework ApplicationServices -framework IOKit -framework IOSurface \
  -o /tmp/veilrd-stream-session-selftest >/tmp/veilrd-stream-session-build.log 2>&1 || {
  tail -30 /tmp/veilrd-stream-session-build.log >&2
  exit 1
}
/tmp/veilrd-stream-session-selftest "$IDDIR/rdp-identity.p12" rdpdev

echo "INTEGRATION SELFTEST PASSED"
