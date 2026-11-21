#!/bin/bash
#
# 构建 M1-A 第 4 步的跨进程推流探针（stream_probe）。
#
# host  : SCK 采集 → VT 编码 → M1FrameSender → QUIC datagram
# client: QUIC datagram → M1FrameReceiver 重组 → VT 解码 → PNG
# 控制与视频共用同一条 datagram 连接（D-14 C-14.2），靠首字节魔数分流。
#
set -euo pipefail

cd "$(dirname "$0")"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
P1SRC="../P1-ClientProbe/src"
P0SRC="../P0-TahoeProbe/src"
V01SRC="../P0V-DisplayIsolation/src"
SRC="src"

bash ./gen_quic_identity.sh .state rdp-identity rdpdev >/dev/null

SOURCES=(
  "$SRC/M1QuicTransport.m"
  "$SRC/M1MessageSink.m"
  "$SRC/M1ControlLink.m"
  "$SRC/M1ControlChannel.m"
  "$SRC/M1ControlSession.m"
  "$SRC/M1PipelineTypes.m"
  "$SRC/M1DatagramSink.m"
  "$SRC/M1FrameSender.m"
  "$SRC/M1VideoEncoder.m"
  "$SRC/M1CapturePipeline.m"
  "$SRC/M1FrameReceiver.m"
  "$SRC/M1FramePipeline.m"
  "$SRC/M1FrameView.m"
  "$SRC/M1InputLogic.m"
  "$SRC/M1InputInjector.m"
  # 独占会话（P2.2）：建虚拟屏 / 禁物理屏 / 守护恢复
  "$SRC/M1DriverLogic.m"
  "$SRC/M1Takeover.m"
  "$SRC/M1ScreenLock.m"
  "$SRC/M1SessionCoordinator.m"
  "$SRC/M1RDPDriver.m"
  "$P0SRC/ProbeUtil.m"
  "$P0SRC/VDManager.m"
  "$V01SRC/P0VDisplayControl.m"
  "$P1SRC/ProtocolCodec.m"
  "$P1SRC/P1SessionState.m"
  "$P1SRC/P1InputCodec.m"
  "stream_probe.m"
)

for f in "${SOURCES[@]}"; do
  if [ ! -f "$f" ]; then echo "缺文件 $f" >&2; exit 1; fi
done

"$CLANG" -fobjc-arc -fmodules -O2 -g -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" -I "$SRC" -I "$P1SRC" -I "$P0SRC" -I "$V01SRC" \
  -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  "${SOURCES[@]}" \
  -framework AppKit \
  -framework Foundation -framework Network -framework Security -framework QuartzCore \
  -framework CoreGraphics -framework CoreMedia -framework CoreVideo \
  -framework ScreenCaptureKit -framework VideoToolbox \
  -framework CoreImage -framework ImageIO -framework ApplicationServices \
  -framework IOKit -framework IOSurface \
  -o ./stream_probe

# 固定签名标识：屏幕录制 TCC 授权按 identifier 记录，重编后不必重新授权。
codesign --force --sign - --identifier com.m1.pipeline --timestamp=none ./stream_probe 2>/dev/null || true

echo "built: ./stream_probe"
