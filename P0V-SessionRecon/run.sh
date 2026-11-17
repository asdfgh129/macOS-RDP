#!/bin/bash
# P0V-SessionRecon 构建并运行
# 只读侦察，不创建会话、不建屏、不提交任何显示变更。
# 用法：bash run.sh [--test-config]
set -uo pipefail
cd "$(dirname "$0")" || exit 1

SDK="$(xcrun --sdk macosx --show-sdk-path)"
OUT=./recon

echo "=== 构建 ==="
xcrun --sdk macosx clang -fobjc-arc -O1 -Wall \
  -mmacosx-version-min=13.0 -isysroot "$SDK" \
  recon.m -framework Foundation -framework CoreGraphics \
  -o "$OUT" 2>&1 | grep -E "error|warning" | head -10
if [ ! -x "$OUT" ]; then echo "构建失败"; exit 1; fi

# 让二进制能继承终端的 TCC 授权（与 P0 探针同一策略）
codesign --force --sign - --identifier "com.p0v.sessionrecon" --timestamp=none "$OUT" 2>/dev/null

echo "=== 运行（$(sw_vers -productVersion) / $(uname -m)）==="
"$OUT" "$@"
RC=$?
echo "=== rc=$RC ==="
exit $RC
