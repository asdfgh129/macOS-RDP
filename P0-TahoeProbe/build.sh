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
if [ "$MAJOR" = "26" ]; then
  echo "目标系统 Tahoe 26：verify 将启用保守 canvas + identity walk 全套 workaround。"
elif [ "$MAJOR" = "15" ]; then
  echo "当前 Sequoia 15：verify 走本机实证的基线路径（直建目标分辨率、固定 identity、失败即止）。"
  echo "      这是冒烟基线，Tahoe 结论仍以被控端真机为准。"
else
  echo "警告：当前 macOS 大版本是 $MAJOR，既非目标 Tahoe 26 也非已验证的 Sequoia 15。" >&2
  echo "      verify 走最小风险路径，结论仅供参考。" >&2
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
  -framework IOKit
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
# 自动 ad-hoc 签名（2026-11-17 实测结论，务必保留）：
#   TCC 对命令行工具按「路径 + cdhash」记账。未签名的二进制每次重建都会丢掉
#   屏幕录制授权；更糟的是**未签名状态下连「委托给责任进程」都不成立**，
#   会直接回落到 "The user declined TCCs" 而看不出原因。
#   固定 identifier 让 TCC 记录在多次重建之间保持可识别。
if command -v codesign >/dev/null 2>&1; then
  if codesign --force --sign - --identifier "com.p0.tahoeprobe" --timestamp=none ./p0probe 2>/dev/null; then
    echo "已 ad-hoc 签名（identifier=com.p0.tahoeprobe）"
  else
    echo "警告：ad-hoc 签名失败，重建后屏幕录制授权可能失效" >&2
  fi
fi

echo "构建完成：./p0probe"
echo "先跑：./p0probe probe --capabilities"
echo "记得给「终端」授权：系统设置 → 隐私与安全性 → 屏幕录制（以及辅助功能）"
