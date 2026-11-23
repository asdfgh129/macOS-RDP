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
BRIDGE="Sources/RDPApp-Bridging-Header.h"
OBJDIR=".build/obj"
mkdir -p "$OBJDIR"

OBJS=()
compile_module() {
  local src="$1" name="$2"
  "$CLANG" -fobjc-arc -fmodules -O0 -g -mmacosx-version-min=13.0 \
    -isysroot "$SDKROOT" -I "$M1" -I "$P1" -Wall -Wno-unused-parameter \
    -c "$src" -o "$OBJDIR/$name.o"
  OBJS+=("$OBJDIR/$name.o")
}
# 第 3 轮起 Swift 入口还消费 M1FrameReceiver / M1FrameView，静态库需一并收编其依赖。
for name in M1Pairing M1Takeover M1SessionCoordinator M1DriverLogic M1InputLogic \
            M1FrameReceiver M1FrameView M1PipelineTypes; do
  compile_module "$M1/$name.m" "$name"
done
for name in ProtocolCodec P1InputCodec; do
  compile_module "$P1/$name.m" "$name"
done
libtool -static -o .build/libRDPKit.a "${OBJS[@]}"

xcrun --sdk macosx swiftc -O \
  -target x86_64-apple-macosx13.0 \
  -I "$M1" -I "$P1" \
  -import-objc-header "$BRIDGE" \
  Sources/main.swift \
  -I .build -L .build -lRDPKit \
  -framework Foundation -framework AppKit -framework CoreGraphics \
  -framework CoreVideo -framework CoreMedia -framework VideoToolbox \
  -framework QuartzCore -framework CoreImage -framework IOSurface \
  -o ./rdpapp
codesign --force --sign - --identifier com.rdp.app --timestamp=none ./rdpapp 2>/dev/null || true
echo "构建完成：./rdpapp（RDPKit 静态库 + Swift 桥接）"
