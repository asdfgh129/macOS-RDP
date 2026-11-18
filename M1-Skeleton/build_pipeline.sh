#!/bin/bash
# M1 帧管线构建：SCK 采集 + VT H.264 编码 + 协议分片 + 环回解码验证。
# 产出 pipeline_probe（只采集当前已有显示，不建屏/不禁屏/不改显示配置）。
set -euo pipefail
cd "$(dirname "$0")"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
P1SRC="../P1-ClientProbe/src"
SRC="src"
SOURCES=(
  "$SRC/M1PipelineTypes.m"
  "$SRC/M1DatagramSink.m"
  "$SRC/M1FrameSender.m"
  "$SRC/M1VideoEncoder.m"
  "$SRC/M1CapturePipeline.m"
  "$SRC/M1FrameReceiver.m"
  "$SRC/M1FramePipeline.m"
  "$P1SRC/ProtocolCodec.m"
  "pipeline_probe.m"
)
for f in "${SOURCES[@]}"; do
  if [ ! -f "$f" ]; then echo "缺文件 $f" >&2; exit 1; fi
done
"$CLANG" -fobjc-arc -fmodules -O2 -g -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" -I "$SRC" -I "$P1SRC" \
  -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  "${SOURCES[@]}" \
  -framework Foundation -framework CoreGraphics -framework CoreMedia \
  -framework CoreVideo -framework ScreenCaptureKit -framework VideoToolbox \
  -framework CoreImage -framework ImageIO -framework ApplicationServices \
  -o ./pipeline_probe
# 固定签名标识：屏幕录制 TCC 授权按 identifier 记录，重编后不必重新授权。
codesign --force --sign - --identifier com.m1.pipeline --timestamp=none ./pipeline_probe 2>/dev/null || true
echo "构建完成：./pipeline_probe（环回验证，运行: ./pipeline_probe --duration-ms 5000）"
