#!/bin/bash
# P0V-RootDaemon 构建：编译 → 组装最小 .app bundle → ad-hoc 签名
#
# 注意：每次重新构建都会改变 cdhash，导致已授予的 TCC 权限失效。
# 因此流程是「构建一次 → 授权一次 → 之后只跑、不改代码」。要改代码就重跑授权。
set -euo pipefail
cd "$(dirname "$0")"

APP="build/P0VRootProbe.app"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.p0v.rootprobe</string>
    <key>CFBundleName</key><string>P0VRootProbe</string>
    <key>CFBundleExecutable</key><string>p0vprobe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

clang -fobjc-arc -O2 -Wall -Wextra \
      -mmacosx-version-min=13.0 \
      -o "$APP/Contents/MacOS/p0vprobe" \
      src/p0vprobe.m \
      -framework Foundation \
      -framework CoreGraphics \
      -framework CoreVideo \
      -framework CoreMedia \
      -framework ApplicationServices \
      -framework ScreenCaptureKit

codesign --force --sign - --identifier com.p0v.rootprobe --timestamp=none "$APP"

# 仓库可能位于 exFAT（noowners），umask 077 会让 bundle 目录变成 700；
# TCC 与系统设置的文件选择器需要能读取 bundle，统一放宽到标准权限。
chmod -R a+rX "$APP"

echo "--- 构建结果 ---"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature|CDHash|Format' || true
echo "产物: $(pwd)/$APP"
echo
echo "下一步（需人工）："
echo "  1) 把 $APP 加入 系统设置 → 隐私与安全性 → 屏幕录制 / 辅助功能"
echo "  2) sudo ./install.sh"
