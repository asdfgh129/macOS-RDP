#!/bin/bash
# 真 loginwindow 态（loginDone=0）补测 — D-08 / A-09 遗留项
# =============================================================================
# 背景：2026-11-18 已关闭的 A-08/A-09 是在「已登录用户锁屏态」（loginDone=1,
#       screenIsLocked=1）测的。开机后未登录、停在用户名/密码输入框的真
#       loginwindow 态（loginDone=0, auditID 不同）尚未覆盖。
#
# ★ 决策（2026-11-18 15:30）：本项**延后到 M2 借测机执行**，不占用主力机。
#   理由：需手动登出（中断全部 app），且 SSH 场景下 root 进程不在 GUI 会话，
#   存在已知架构障碍（见下）。文档见 DECISIONS.md D-11。
#
# ★ 已知障碍（Sequoia 15.5 实测，DESIGN A-09）：root daemon 路径被「TCC 路径
#   条目 + 无 GUI 会话」双重阻挡。SSH 起的 root 进程通常不在 Aqua session，
#   CGDisplayCreateImage 会返回全黑。本脚本已内置自动 bsexec 重入来绕过这一层：
#   先用 gui_session_probe 判定会话归属，若不在 GUI 会话则用 launchctl bsexec
#   挂进 loginwindow 的图形会话再跑。
#
# 用法（在 M2 借测机上）：
#   1) 借测机联调 OK 后，从 菜单登出，停在登录框（此时 loginDone=0）；
#   2) 从另一台机器 SSH 进来：ssh <user>@<借测机IP>
#   3) sudo bash run_loginwindow_probe.sh
#   4) 读 /tmp/loginwindow-*.json 与 *-shot.png，确认禁屏后虚拟屏出现登录框；
#   5) 在登录框输密码正常登录恢复。
#
# 退出码：0 通过（禁屏后虚拟屏有内容）　3 非 loginDone=0 态（守卫拒绝）
#         4 GUI 会话不可达（bsexec 也失败）　5 探针缺失/环境错误
#         6 采集到内容但判黑（TCC 授权问题）　2 恢复失败
# =============================================================================
set -uo pipefail
ROOT=/Volumes/Data/Code/macOS-RDP
PROBE="$ROOT/P0V-RootDaemon/build/P0VRootProbe.app/Contents/MacOS/p0vprobe"
ALT="$ROOT/P0V-AltCapture/altprobe"
GUIPROBE="$ROOT/P0V-SessionRecon/gui_session_probe"
TAG=loginwindow-tahoe-$(date +%Y%m%d-%H%M%S)
OUT=/tmp/${TAG}.json
SHOT=/tmp/${TAG}-shot.png
LOG=/tmp/${TAG}.log

# --- 前置检查（在日志重定向之前，确保失败原因能直接显示到终端） ---
echo "=== 前置检查 ==="
if [ "$(id -u)" != 0 ]; then
    echo "必须以 root 运行：sudo bash $0" >&2
    exit 5
fi
for f in "$PROBE" "$ALT"; do
    if [ ! -x "$f" ]; then
        echo "缺少可执行探针: $f" >&2
        echo "  p0vprobe  → 先构建 P0V-RootDaemon" >&2
        echo "  altprobe  → 先 bash P0V-AltCapture/build.sh" >&2
        exit 5
    fi
done
if [ ! -x "$GUIPROBE" ]; then
    echo "缺 gui_session_probe，正在编译…"
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    cc -fobjc-arc -O2 -mmacosx-version-min=13.0 -isysroot "$SDKROOT" \
       -Wno-deprecated-declarations -framework Foundation -framework CoreGraphics \
       -framework ApplicationServices \
       "$ROOT/P0V-SessionRecon/gui_session_probe.m" -o "$GUIPROBE" || {
        echo "gui_session_probe 编译失败" >&2; exit 5; }
fi

# 前置通过，开始写日志（bsexec 子进程继承父层 tee 输出，不重复重定向）
if [ "${M1_IN_BSEXEC:-0}" != "1" ]; then
    rm -f "$OUT" "$SHOT" "$LOG"
    exec > >(tee -a "$LOG") 2>&1
fi

# --- 守卫 A：必须 loginDone=0（真登录窗），避免误在已登录会话里禁屏 ---
STATE=$("$PROBE" probe 2>/dev/null)
echo "$STATE" | python3 -c '
import json,sys
d=json.load(sys.stdin)["session"]
print("  loginDone=%s screenIsLocked=%s available=%s onConsole=%s auditID=%s" % (
    d.get("loginDone"), d.get("screenIsLocked"), d.get("available"),
    d.get("onConsole"), d.get("auditID")))
sys.exit(0 if str(d.get("loginDone")) in ("0","False") else 3)
'
if [ $? -ne 0 ]; then
    echo "当前不是 loginDone=0（真登录窗）态，拒绝运行。请先登出到登录框。"
    exit 3
fi

# --- 守卫 B：GUI 会话可达性 + 能否抓到真实画面（只读，不动显示配置） ---
if [ "${M1_SKIP_PREFLIGHT:-0}" != "1" ]; then
    echo "=== Preflight：GUI 会话与抓屏能力（只读） ==="
    "$GUIPROBE" --frames 3
    GUIRC=$?

    case $GUIRC in
      0)
        echo "  ✓ 在 GUI 会话且能抓到内容，继续。"
        ;;
      10)
        echo "  ✗ 不在 GUI 会话（SSH root 常见），尝试 bsexec 进入 loginwindow 会话…"
        LW_PIDS=$(pgrep -x loginwindow | tr '\n' ' ')
        if [ -z "$LW_PIDS" ]; then
            echo "  找不到 loginwindow 进程，无法 bsexec。"
            exit 4
        fi
        OK=0
        TCC_HIT=0
        for lw in $LW_PIDS; do
            echo "  → bsexec $lw 试跑 gui_session_probe"
            M1_IN_BSEXEC=1 launchctl bsexec "$lw" "$GUIPROBE" --frames 2 >/tmp/gsp-$lw.json 2>/dev/null
            BRC=$?
            if [ $BRC -eq 0 ]; then
                echo "  ✓ bsexec $lw 可达 GUI 会话且能抓到内容"
                OK=1
                export M1_IN_BSEXEC=1
                export M1_BSEXEC_PID="$lw"
                # 用 bsexec 重入本脚本，后续全部步骤在图形会话内执行
                launchctl bsexec "$lw" "$0" "$@"
                RC=$?
                echo "=== bsexec 子进程返回 $RC ==="
                exit $RC
            elif [ $BRC -eq 11 ]; then
                # 进了会话但抓不到内容：TCC 屏幕录制问题，不是会话不可达
                echo "    bsexec $lw 进入了会话，但抓屏被判黑（疑似 TCC）"
                TCC_HIT=1
            else
                echo "    bsexec $lw 不可用（exit=$BRC，该 loginwindow 非 console 会话或权限不足）"
            fi
        done
        if [ $OK -eq 0 ]; then
            if [ $TCC_HIT -eq 1 ]; then
                echo "  ✗ 能进入 GUI 会话但抓不到内容（TCC 屏幕录制未授权）。"
                echo "    处理：给 $ALT 与 $GUIPROBE 授予屏幕录制权限，或改用已签名的探针。"
                exit 6
            fi
            echo "  ✗ 所有 loginwindow 均无法 bsexec 进入。"
            echo "    备选：在借测机上装一个 LoginWindow 域的 launchd job 来跑本脚本。"
            exit 4
        fi
        ;;
      11)
        echo "  ✗ 在 GUI 会话但抓不到内容（疑似 TCC 屏幕录制未授权）。"
        echo "    处理：给 $ALT 与 $GUIPROBE 授予屏幕录制权限，或检查二进制签名。"
        exit 6
        ;;
      *)
        echo "  ✗ preflight 异常（exit=$GUIRC）"
        exit 5
        ;;
    esac
fi

echo "=== caffeinate 防屏睡（loginwindow 态同样需要） ==="
caffeinate -d -w $$ >/dev/null 2>&1 & CAFF=$!

echo "=== 建虚拟屏 → 禁全部物理屏 → 采集登录 UI ==="
# altprobe 默认 disable-all（内含快照/守护/恢复）；loginwindow 态下截图应含登录框
"$ALT" --spec 1280x720 --capture-ms 1500 \
    --shot "$SHOT" --out "$OUT" >/tmp/${TAG}-alt.log 2>&1
ALT_EXIT=$?
echo "  altprobe exit=$ALT_EXIT"

kill "$CAFF" 2>/dev/null

echo "=== 结果 ==="
python3 - "$OUT" "$SHOT" <<'PY'
import json, os, sys
out, shot = sys.argv[1], sys.argv[2]
if not os.path.exists(out):
    print("  NO_RESULT（探针未产出 JSON）"); raise SystemExit(6)
d = json.load(open(out))
dis = d.get("disable", {})
res = d.get("restore", {})
print("  禁屏 ok=%s activeAfter=%s" % (dis.get("ok"), dis.get("activeAfter")))
print("  恢复 ok=%s activeAfter=%s" % (res.get("ok"), res.get("activeAfter")))
for ph in ("baseline", "disabled"):
    for path in ("sck", "cgDisplay", "windows"):
        r = d.get(ph, {}).get(path, {})
        print("  %s/%s: %s mean=%s var=%s black=%s" % (
            ph, path, r.get("verdict"), r.get("minMean"),
            r.get("maxVariance"), r.get("suspectedBlackFrames")))
print("  截图: %s (%s bytes)" % (shot, os.path.getsize(shot) if os.path.exists(shot) else "缺失"))
# 人工判据：查看 disabled 阶段截图是否含登录 UI（用户名/密码框/时钟）。
print("  判据：查看截图 *.disabled.png，若禁屏后虚拟屏出现登录框 → A-09 在 loginDone=0 成立。")

if not res.get("ok"):
    raise SystemExit(2)
for path in ("cgDisplay", "sck"):
    r = d.get("disabled", {}).get(path, {})
    if r.get("verdict") in ("HAS_CONTENT",):
        raise SystemExit(0)
raise SystemExit(6)
PY
PYRC=$?

echo "=== 完成（rc=$PYRC）。请用密码正常登录恢复会话。 ==="
echo "  产物: $OUT / $SHOT / $LOG"
exit $PYRC
