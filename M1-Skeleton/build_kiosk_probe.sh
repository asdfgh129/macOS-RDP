#!/bin/bash
# 帧管线「禁屏独占」实测构建：复用已实机验证的 M1RDPDriver（含守护恢复）
# 与 M1FramePipeline（SCK + VT + 分片 + 环回解码）合成一个探针。
#
# ★ 运行本探针会临时禁用全部物理屏（黑屏），由 P0V 守护兜底恢复。
set -euo pipefail
cd "$(dirname "$0")"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
P0SRC="../P0-TahoeProbe/src"
V01SRC="../P0V-DisplayIsolation/src"
P1SRC="../P1-ClientProbe/src"
SRC="src"
SOURCES=(
  # 帧管线
  "$SRC/M1PipelineTypes.m"
  "$SRC/M1DatagramSink.m"
  "$SRC/M1FrameSender.m"
  "$SRC/M1VideoEncoder.m"
  "$SRC/M1CapturePipeline.m"
  "$SRC/M1FrameReceiver.m"
  "$SRC/M1FramePipeline.m"
  # 驱动层（禁屏/建屏/守护）
  "$SRC/M1DriverLogic.m"
  "$SRC/M1InputLogic.m"
  "$SRC/M1InputInjector.m"
  "$SRC/M1Takeover.m"
  "$SRC/M1ScreenLock.m"
  "$SRC/M1SessionCoordinator.m"
  "$SRC/M1WindowLayout.m"
  "$SRC/M1RDPDriver.m"
  # P0/P0V 底座
  "$P0SRC/ProbeUtil.m"
  "$P0SRC/VDManager.m"
  "$V01SRC/P0VDisplayControl.m"
  "$P1SRC/ProtocolCodec.m"
  "pipeline_kiosk_probe.m"
)
for f in "${SOURCES[@]}"; do
  if [ ! -f "$f" ]; then echo "缺文件 $f" >&2; exit 1; fi
done
"$CLANG" -fobjc-arc -fmodules -O2 -g -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" -I "$SRC" -I "$P0SRC" -I "$V01SRC" -I "$P1SRC" \
  -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  "${SOURCES[@]}" \
  -framework Foundation -framework ApplicationServices -framework CoreGraphics \
  -framework CoreMedia -framework CoreVideo -framework ScreenCaptureKit \
  -framework VideoToolbox -framework IOSurface -framework QuartzCore -framework IOKit \
  -framework CoreImage -framework ImageIO \
  -o ./pipeline_kiosk_probe
codesign --force --sign - --identifier com.m1.pipelinekiosk --timestamp=none ./pipeline_kiosk_probe 2>/dev/null || true
echo "构建完成：./pipeline_kiosk_probe"
echo "⚠ 运行会临时禁用全部物理屏（黑屏），守护进程兜底恢复："
echo "   ./pipeline_kiosk_probe --spec 1920x1080 --duration-ms 10000"
