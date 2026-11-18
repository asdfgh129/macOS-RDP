#!/bin/bash
# M1-Pre 采编探针构建：复用 P0 的 VDManager / PipelineProbe 与 P0V 的显示控制层。
set -euo pipefail
cd "$(dirname "$0")"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
P0SRC="../P0-TahoeProbe/src"
V01SRC="../P0V-DisplayIsolation/src"
SOURCES=(
  "$P0SRC/ProbeUtil.m"
  "$P0SRC/VDManager.m"
  "$P0SRC/PipelineProbe.m"
  "$V01SRC/P0VDisplayControl.m"
  "src/main.m"
)
for f in "${SOURCES[@]}"; do
  if [ ! -f "$f" ]; then echo "缺文件 $f" >&2; exit 1; fi
done
"$CLANG" -fobjc-arc -fmodules -O0 -g -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" -I "$P0SRC" -I "$V01SRC" \
  -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  "${SOURCES[@]}" \
  -framework Foundation -framework ApplicationServices -framework CoreGraphics \
  -framework CoreMedia -framework CoreVideo -framework ScreenCaptureKit \
  -framework VideoToolbox -framework IOSurface -framework QuartzCore -framework IOKit \
  -o ./capturecodec
codesign --force --sign - --identifier com.m1pre.capturecodec --timestamp=none ./capturecodec 2>/dev/null || true
echo "构建完成：./capturecodec"
