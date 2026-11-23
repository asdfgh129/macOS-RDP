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

echo "INTEGRATION SELFTEST PASSED"
