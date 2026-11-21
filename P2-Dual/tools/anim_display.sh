#!/bin/bash
# 编译并运行 anim_display：给指定显示（通常是独占会话的虚拟屏）喂动态内容。
#
# 用法：
#   ./tools/anim_display.sh <displayID> [秒]
#
# displayID 从 host 日志里拿：
#   pipeline_kiosk_probe → 「虚拟屏 displayID=...」
#   p2.sh host 独占模式   → 「[独占] 虚拟屏就绪 ids=...」
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${TMPDIR:-/tmp}/m1-anim-display"
SRC="$HERE/anim_display.swift"
if [ "$#" -lt 1 ]; then
    echo "用法：$0 <displayID> [秒]" >&2
    exit 2
fi
if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
    swiftc -O -o "$BIN" "$SRC"
fi
exec "$BIN" "$@"
