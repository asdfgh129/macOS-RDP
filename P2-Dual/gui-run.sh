#!/bin/bash
# 在「登录用户的 Aqua 会话」里执行命令 —— 供 SSH 远程驱动 host 端测试用。
#
# 为什么需要它：
#   SSH 会话不是 GUI 会话，没有 WindowServer 连接。stream_probe 的屏幕采集
#   （SCShareableContent / SCStream）和事件注入（CGEventPost）都依赖窗口服务，
#   直接在 SSH 里跑会失败或拿到空画面。用 launchctl asuser 把进程塞回 GUI 会话
#   再跑，采集/注入的行为就和本地双击运行一致。
#
# 用法（在 SSH 里）：
#   ./gui-run.sh ./p2.sh host
#   ./gui-run.sh ./stream_probe --preflight host
#   ./gui-run.sh --check          # 只验证 GUI 上下文是否可用
#
# 注：launchctl asuser 需要 root，因此这里会调 sudo。若希望免密，见
#     docs/SSH-SETUP.md §5 的 sudoers 片段。
set -uo pipefail

U="$(id -u)"
N="$(id -un)"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "--check" ]; then
    echo "== GUI 上下文自检 =="
    echo "  uid/gid: $U / $N"
    echo "  当前会话: $(launchctl managername 2>/dev/null || echo unknown)"
    if [ "$(launchctl managername 2>/dev/null)" = "Aqua" ]; then
        echo "  ✓ 已经在 Aqua 会话里，不需要 gui-run.sh"
        exit 0
    fi
    echo "  → 在 SSH 会话里，尝试劫持到 gui/$U"
    exec sudo launchctl asuser "$U" sudo -u "$N" launchctl managername
fi

if [ "$#" -eq 0 ]; then
    echo "用法：$0 <命令> [参数...]" >&2
    echo "      $0 --check" >&2
    exit 2
fi

# 普通 SSH 会话没有 Aqua：交给 launchd 用 GUI 会话身份重跑。
SESS="$(launchctl managername 2>/dev/null || echo unknown)"
if [ "$SESS" = "Aqua" ]; then
    exec "$@"
fi

# 相对路径 ./p2.sh 之类在 asuser 下会丢 cwd，先转成绝对路径。
CMD="$1"; shift
case "$CMD" in
    /*) : ;;
    */*) CMD="$PWD/$CMD" ;;
    *)   CMD="$(command -v "$CMD" || echo "$CMD")" ;;
esac

exec sudo launchctl asuser "$U" sudo -u "$N" "$CMD" "$@"
