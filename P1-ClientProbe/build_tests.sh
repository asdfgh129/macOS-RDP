#!/bin/bash
# P1-ClientProbe 纯函数单测构建运行（不建屏、不触碰 WindowServer，任何机器可跑）
set -euo pipefail
cd "$(dirname "$0")"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"

build_and_run() {
  local name="$1"; shift
  "$CLANG" -fobjc-arc -fmodules -O0 -g -mmacosx-version-min=13.0 \
      -isysroot "$SDKROOT" -I src -Wall -Wextra \
      "$@" -framework Foundation -framework CoreGraphics \
      -o "/tmp/p1_test_${name}"
  echo "=== ${name} ==="
  "/tmp/p1_test_${name}"
}

build_and_run coordinate tests/test_coordinate.m src/P1Coordinate.m
build_and_run protocol   tests/test_protocol.m   src/ProtocolCodec.m
