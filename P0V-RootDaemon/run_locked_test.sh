#!/bin/bash
# V-04 锁屏态测试编排（sudo 运行）
#
# 流程：
#   A. 未锁屏基线：触发一次 daemon，确认机制本身通（抓得到画面、注入返回）
#   B. 锁屏态：提示你按 Ctrl+Cmd+Q 锁屏 → 唤醒显示器但保持锁定（caffeinate -u）
#      → 触发 daemon → 输出落到 /tmp/p0v-B-locked.json
#   锁屏期间你看不到输出，解锁后再读文件。
#
# 注意：本脚本会在 B 阶段向 loginwindow 注入 "aa"+Return（错误密码，只会失败，
# 用于观察界面是否有反应）。若你的机器密码恰好是 "aa" 请提前改掉（笑）。
set -uo pipefail
cd "$(dirname "$0")"

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行：sudo ./run_locked_test.sh" >&2
    exit 1
fi

LABEL="system/com.p0v.rootprobe"
if ! launchctl print "$LABEL" >/dev/null 2>&1; then
    echo "daemon 未安装，先跑 sudo ./install.sh" >&2
    exit 1
fi

wait_for_json() {
    local out="$1" deadline=$((SECONDS + 25))
    while [ $SECONDS -lt $deadline ]; do
        if [ -s /tmp/p0v-root.json ]; then cp /tmp/p0v-root.json "$out"; return 0; fi
        sleep 1
    done
    echo "超时：/tmp/p0v-root.json 未生成，看 /tmp/p0v-root-stderr.log" >&2
    return 1
}

run_once() {
    local out="$1"
    rm -f /tmp/p0v-root.json
    launchctl kickstart -k "$LABEL" || return 1
    wait_for_json "$out"
}

echo "=== A. 未锁屏基线 ==="
if run_once /tmp/p0v-A-unlocked.json; then
    python3 - <<'PY'
import json
d = json.load(open('/tmp/p0v-A-unlocked.json'))
cap = d.get('capture', {})
print('  session.available =', d['env']['session'].get('available'))
print('  axTrusted         =', d['env']['axTrusted'])
print('  capture.verdict   =', cap.get('verdict'), 'frames=', cap.get('frames'), 'mean=', cap.get('minMean'))
print('  sckError          =', d['env'].get('sckError'))
PY
else
    echo "基线就失败了 —— 先修 A 阶段，不必进入锁屏。" >&2
    exit 2
fi

echo
echo "=== B. 锁屏态（V-04a/b/c）==="
echo "5 秒后开始。请在倒计时结束后按 Ctrl+Cmd+Q 锁屏，然后什么都别做，等 25 秒。"
for i in 5 4 3 2 1; do printf '  %d...\n' "$i"; sleep 1; done

(
    rm -f /tmp/p0v-root.json /tmp/p0v-B-locked.json
    sleep 6
    # 唤醒显示器但不解锁：产品里我们也要做同样的事，否则锁屏态下屏是灭的，抓不到任何东西
    caffeinate -u -t 4 >/dev/null 2>&1 &
    sleep 2
    if run_once /tmp/p0v-B-locked.json; then
        echo "B_DONE" > /tmp/p0v-B-status.txt
    else
        echo "B_FAILED" > /tmp/p0v-B-status.txt
    fi
) >/tmp/p0v-B-orchestrator.log 2>&1 &

disown
echo
echo "现在请按 Ctrl+Cmd+Q 锁屏。解锁后执行："
echo "  cat /tmp/p0v-B-status.txt && python3 -m json.tool /tmp/p0v-B-locked.json"
