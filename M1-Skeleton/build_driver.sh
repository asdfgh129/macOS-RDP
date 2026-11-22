#!/bin/bash
# M1-Skeleton 驱动层构建：验证 M1RDPDriver 能链接 VDManager + P0VDisplayControl + IOKit。
# 产出 driver_probe 只做只读侦察，不建屏/禁屏/注入/锁屏（安全）。
set -euo pipefail
cd "$(dirname "$0")"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
P0SRC="../P0-TahoeProbe/src"
V01SRC="../P0V-DisplayIsolation/src"
SRC="src"
SOURCES=(
  "$SRC/M1DriverLogic.m"
  "$SRC/M1InputLogic.m"
  "$SRC/M1InputInjector.m"
  "$SRC/M1Takeover.m"
  "$SRC/M1ScreenLock.m"
  "$SRC/M1SessionCoordinator.m"
  "$SRC/M1WindowLayout.m"
  "$SRC/M1RDPDriver.m"
  "$P0SRC/ProbeUtil.m"
  "$P0SRC/VDManager.m"
  "$V01SRC/P0VDisplayControl.m"
  "driver_probe.m"
)
for f in "${SOURCES[@]}"; do
  if [ ! -f "$f" ]; then echo "缺文件 $f" >&2; exit 1; fi
done
"$CLANG" -fobjc-arc -fmodules -O0 -g -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" -I "$SRC" -I "$P0SRC" -I "$V01SRC" \
  -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  "${SOURCES[@]}" \
  -framework Foundation -framework ApplicationServices -framework CoreGraphics \
  -framework CoreMedia -framework CoreVideo -framework ScreenCaptureKit \
  -framework VideoToolbox -framework IOSurface -framework QuartzCore -framework IOKit \
  -o ./driver_probe
codesign --force --sign - --identifier com.m1.rdpdriver --timestamp=none ./driver_probe 2>/dev/null || true
echo "构建完成：./driver_probe（只读侦察，运行: ./driver_probe）"
