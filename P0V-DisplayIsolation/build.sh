#!/bin/bash
# P0V-DisplayIsolation 构建脚本
# 复用 P0-TahoeProbe 的 VDManager / PipelineProbe / ProbeUtil（不复制源码）。
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  echo "错误：找不到 macOS SDK。请先执行 xcode-select --install" >&2
  exit 1
fi

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"

echo "OS    : $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "ARCH  : $(uname -m)"
echo "SDK   : $SDKROOT"

P0SRC="../P0-TahoeProbe/src"
SOURCES=(
  "$P0SRC/ProbeUtil.m"
  "$P0SRC/VDManager.m"
  "$P0SRC/PipelineProbe.m"
  "src/P0VDisplayControl.m"
  "src/main.m"
)

FRAMEWORKS=(
  -framework Foundation
  -framework ApplicationServices
  -framework CoreGraphics
  -framework CoreMedia
  -framework CoreVideo
  -framework ScreenCaptureKit
  -framework VideoToolbox
  -framework IOSurface
  -framework QuartzCore
  -framework IOKit
)

for f in "${SOURCES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "错误：缺文件 $f（请确认 P0-TahoeProbe/src 与本工程同级）" >&2
    exit 1
  fi
done

if ! "$CLANG" \
  -fobjc-arc \
  -fmodules \
  -O0 -g \
  -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" \
  -I "$P0SRC" \
  -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  "${SOURCES[@]}" \
  "${FRAMEWORKS[@]}" \
  -o ./v01probe; then
  echo "" >&2
  echo "编译失败。" >&2
  exit 1
fi

# TCC 按「路径 + cdhash」给命令行工具记账。固定 identifier 让多次重建之间仍可识别，
# 但每次重建 cdhash 都会变，屏幕录制 / 辅助功能授权可能需要重新确认。
if command -v codesign >/dev/null 2>&1; then
  if codesign --force --sign - --identifier "com.p0v.displayisolation" --timestamp=none ./v01probe 2>/dev/null; then
    echo "已 ad-hoc 签名（identifier=com.p0v.displayisolation）"
  else
    echo "警告：ad-hoc 签名失败，重建后 TCC 授权可能失效" >&2
  fi
fi

echo ""
echo "构建完成：./v01probe"
echo "先跑只读侦察：./v01probe probe"
echo "再跑测试（会临时关闭物理屏）：./v01probe run --mode one"
