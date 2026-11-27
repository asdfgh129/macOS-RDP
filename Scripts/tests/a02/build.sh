#!/bin/bash
# A-02（glass-to-glass，时钟+截屏替代法）工具构建
#
# 产出 ./a02_clock（主机侧内容源）与 ./a02_shot（客户端侧截屏判读）。
# 只用 clang + 系统框架，Ventura 13（仅 CLT）也能构建，与项目其它测试工具口径一致。
set -euo pipefail
cd "$(dirname "$0")"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"

build() {
  local src="$1" out="$2"; shift 2
  echo "== build $out =="
  "$CLANG" -fobjc-arc -fmodules -O2 -g -mmacosx-version-min=13.0 \
    -isysroot "$SDKROOT" \
    -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
    "$src" "$@" -o "$out"
  codesign --force --sign - --identifier "com.veild.a02.$(basename "$out")" \
    --timestamp=none "$out" 2>/dev/null || true
}

build a02_clock.m a02_clock -framework Cocoa -framework CoreGraphics
build a02_shot.m  a02_shot  -framework Foundation -framework CoreGraphics -framework ImageIO

echo "构建完成：$(pwd)/a02_clock  $(pwd)/a02_shot"
