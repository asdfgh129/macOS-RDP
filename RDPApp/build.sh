#!/bin/bash
# RDPApp 构建（D-02：Swift 主 + ObjC 桥）。
#   1) clang -fobjc-arc 把 ObjC 模块编成静态库 libRDPKit.a（对应 RDPKit target）
#   2) swiftc 编译 Swift 入口 + 桥接头，链接 libRDPKit.a（对应 RDPApp target）
# 这样 ObjC 由 clang 按 ARC 正确编译，Swift 只做桥接消费，贴近真实 Xcode 工程。
# 本版收编纯逻辑模块；M1RDPDriver（重依赖 VDManager/P0VDisplayControl/IOKit）由
# M1-Skeleton/build_driver.sh 单独验证，帧管线就绪后在 RDPKit 源列表追加。
set -euo pipefail
cd "$(dirname "$0")"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
M1="../M1-Skeleton/src"
BRIDGE="Sources/RDPApp-Bridging-Header.h"
OBJDIR=".build/obj"
mkdir -p "$OBJDIR"

OBJS=()
for name in M1Pairing M1Takeover M1SessionCoordinator M1DriverLogic M1InputLogic; do
  "$CLANG" -fobjc-arc -fmodules -O0 -g -mmacosx-version-min=13.0 \
    -isysroot "$SDKROOT" -I "$M1" -Wall -Wno-unused-parameter \
    -c "$M1/$name.m" -o "$OBJDIR/$name.o"
  OBJS+=("$OBJDIR/$name.o")
done
libtool -static -o .build/libRDPKit.a "${OBJS[@]}"

xcrun --sdk macosx swiftc -O \
  -target x86_64-apple-macosx13.0 \
  -I "$M1" \
  -import-objc-header "$BRIDGE" \
  Sources/main.swift \
  -I .build -L .build -lRDPKit \
  -framework Foundation \
  -o ./rdpapp
codesign --force --sign - --identifier com.rdp.app --timestamp=none ./rdpapp 2>/dev/null || true
echo "构建完成：./rdpapp（RDPKit 静态库 + Swift 桥接）"
