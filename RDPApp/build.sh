#!/bin/bash
# RDPApp 构建（D-02：Swift 主 + ObjC 桥，第 3 轮兼容入口）。
#   1) clang -fobjc-arc 把 RDPKit / ProtocolCodec 需要的 ObjC 模块编成 libRDPKit.a
#   2) swiftc 编译 Apps/Client/Sources/main.swift + 桥接头，链接静态库
# Swift 入口与桥接头已物理归位到 Apps/Client/Sources/，此处路径是兼容软链。
# 真实构建入口是 Scripts/build.sh（Xcode 五个 target）；本脚本保留供旧 runbook 使用。
set -euo pipefail
cd "$(dirname "$0")"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
M1="../M1-Skeleton/src"
P1="../P1-ClientProbe/src"
SESSION="../Packages/RDPKit/Sources/Session"
BRIDGE="Sources/RDPApp-Bridging-Header.h"
OBJDIR=".build/obj"
mkdir -p "$OBJDIR"

OBJS=()
compile_module() {
  local src="$1" name="$2"
  "$CLANG" -fobjc-arc -fmodules -O0 -g -mmacosx-version-min=13.0 \
    -isysroot "$SDKROOT" -I "$M1" -I "$P1" -I "$SESSION" -Wall -Wno-unused-parameter \
    -c "$src" -o "$OBJDIR/$name.o"
  OBJS+=("$OBJDIR/$name.o")
}
# 第 3 轮起 Swift 入口还消费 M1FrameReceiver / M1FrameView，静态库需一并收编其依赖。
for name in M1Pairing M1Takeover M1SessionCoordinator M1DriverLogic M1InputLogic \
            M1FrameReceiver M1FrameView M1PipelineTypes; do
  compile_module "$M1/$name.m" "$name"
done
# 第 4 轮：--connect 直接消费共享流会话节点（QUIC/控制/会话/重组解码）。
compile_module "$SESSION/M1StreamSession.m" "M1StreamSession"
for name in M1QuicTransport M1DatagramSink M1MessageSink \
            M1ControlLink M1ControlChannel M1ControlSession; do
  compile_module "$M1/$name.m" "$name"
done
for name in ProtocolCodec P1InputCodec P1SessionState; do
  compile_module "$P1/$name.m" "$name"
done
libtool -static -o .build/libRDPKit.a "${OBJS[@]}"

xcrun --sdk macosx swiftc -O \
  -target x86_64-apple-macosx13.0 \
  -I "$M1" -I "$P1" -I "$SESSION" \
  -import-objc-header "$BRIDGE" \
  Sources/main.swift \
  -I .build -L .build -lRDPKit \
  -framework Foundation -framework AppKit -framework CoreGraphics \
  -framework CoreVideo -framework CoreMedia -framework VideoToolbox \
  -framework QuartzCore -framework CoreImage -framework IOSurface \
  -framework Network -framework Security -framework ImageIO -framework ApplicationServices \
  -o ./rdpapp
codesign --force --sign - --identifier com.rdp.app --timestamp=none ./rdpapp 2>/dev/null || true
echo "构建完成：./rdpapp（RDPKit 静态库 + Swift 桥接）"
