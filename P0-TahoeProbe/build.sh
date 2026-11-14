#!/bin/bash
# P0-TahoeProbe 构建脚本
# 在【被控端】Intel Mac / macOS 26 Tahoe 上运行。
# 只需 Xcode Command Line Tools（xcode-select --install），不需要 Xcode 工程、签名或 App bundle。
set -euo pipefail

cd "$(dirname "$0")"

if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  echo "错误：找不到 macOS SDK。请先执行 xcode-select --install" >&2
  exit 1
fi

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"

# 这几行会被 run_p0.sh 一并收进诊断包，编译报错时用于判断是 SDK 差异还是代码问题。
echo "OS    : $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "ARCH  : $(uname -m)"
echo "XCODE : $(xcode-select -p)"
echo "SDK   : $SDKROOT"
echo "CLANG : $CLANG"

MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MAJOR" != "26" ]; then
  echo "警告：当前 macOS 大版本是 $MAJOR，本工程的目标是被控端 Tahoe 26。" >&2
  echo "      probe / capabilities 仍可采集环境，但 verify 的结论不作数。" >&2
fi

SOURCES=(
  src/ProbeUtil.m
  src/VDManager.m
  src/PipelineProbe.m
  src/main.m
)

FRAMEWORKS=(
  -framework Foundation
  -framework CoreGraphics
  -framework CoreMedia
  -framework CoreVideo
  -framework ScreenCaptureKit
  -framework VideoToolbox
  -framework IOSurface
  -framework QuartzCore
)

for f in "${SOURCES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "错误：缺文件 $f（拷贝时可能漏了 src/ 目录）" >&2
    exit 1
  fi
done

if ! "$CLANG" \
  -fobjc-arc \
  -fmodules \
  -O0 -g \
  -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" \
  -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  "${SOURCES[@]}" \
  "${FRAMEWORKS[@]}" \
  -o ./p0probe; then
  echo "" >&2
  echo "编译失败。请把完整报错连同上面 OS / SDK / CLANG 三行一起带回（run_p0.sh 会自动收集）。" >&2
  echo "常见两类：SDK 里 API 可用性差异、框架头文件缺失；不要因为 warning 中止。" >&2
  exit 1
fi

echo ""
echo "构建完成：./p0probe"
echo "先跑：./p0probe probe --capabilities"
echo "记得给「终端」授权：系统设置 → 隐私与安全性 → 屏幕录制（以及辅助功能）"
