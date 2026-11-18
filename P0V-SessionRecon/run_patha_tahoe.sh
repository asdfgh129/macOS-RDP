#!/bin/bash
# Tahoe Path A 关键实验（2026-11-18 r5）
#  1) caffeinate 先启动，保持锁屏后屏幕不睡
#  2) 程序化锁屏
#  3) altprobe 建虚拟屏 → 光标聚焦 → 三路径采集 → 禁全部物理屏 → 再采集 → 恢复
#  4) 用 P0V_PW 环境变量里的密码做干净的 V-04c 注入（不落盘、不回显）
#  注意：用户锁屏时看不到终端，脚本结束后由助手在对话里通知/确认。
set -uo pipefail
ROOT=/Volumes/Data/Code/macOS-RDP
PROBE="$ROOT/P0V-RootDaemon/build/P0VRootProbe.app/Contents/MacOS/p0vprobe"
ALT="$ROOT/P0V-AltCapture/altprobe"
TAG=tahoe-20261118-r5
LOG=/tmp/${TAG}.log
PW="${P0V_PW:-}"
rm -f "$LOG" /tmp/${TAG}.* /tmp/${TAG}-shot*.png
exec > >(tee -a "$LOG") 2>&1

state() {
    "$PROBE" probe 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print("locked=%s active=%d sck=%s ax=%s"%(d["session"]["screenIsLocked"],len(d["displays"]["list"]),d["sckDisplayIDs"],d["axTrusted"]))' 2>/dev/null
}

echo "=== 1. caffeinate -d 先于锁屏 ==="
caffeinate -d -w $$ >/dev/null 2>&1 & CAFF=$!
sleep 1
pmset -g assertions 2>/dev/null | grep 'PreventUserIdleDisplaySleep' | head -1

echo "=== 2. 锁屏 ==="
"$PROBE" lock >/dev/null
for i in $(seq 1 30); do
    s=$("$PROBE" probe 2>/dev/null | python3 -c 'import json,sys;print(1 if json.load(sys.stdin)["session"]["screenIsLocked"] else 0)' 2>/dev/null || echo 0)
    [ "$s" = 1 ] && break
    sleep 0.5
done
echo -n "  锁屏后: "; state

echo "=== 3. 虚拟屏 + 光标聚焦 + 禁屏前后对照 ==="
"$ALT" --spec 1280x720 --capture-ms 1500 --focus \
    --shot /tmp/${TAG}-shot.png --out /tmp/${TAG}-migrate.json \
    > /tmp/${TAG}-alt.log 2>&1
echo "  altprobe exit=$?"
python3 - <<'PY'
import json,os
p='/tmp/tahoe-20261118-r5-migrate.json'
if not os.path.exists(p): print('  NO_RESULT'); raise SystemExit
d=json.load(open(p))
print('  virtual=',d.get('virtualDisplayID'),'online=',d.get('virtualOnline'),'active=',d.get('virtualActive'),
      'axTrusted=',d.get('axTrusted'))
print('  focus=',json.dumps(d.get('focus'),ensure_ascii=False))
print('  disable ok=',d.get('disable',{}).get('ok'),'activeAfter=',d.get('disable',{}).get('activeAfter'))
print('  restore ok=',d.get('restore',{}).get('ok'))
for phase in ('baseline','disabled'):
    for path in ('sck','cgDisplay','windows'):
        r=d.get(phase,{}).get(path,{})
        print(f'  {phase}/{path}: {r.get("verdict")} mean={r.get("minMean")} var={r.get("maxVariance")} black={r.get("blackSamples")}/{r.get("samples")}')
PY
ls -l /tmp/${TAG}-shot*.png 2>/dev/null
echo -n "  采集后: "; state

echo "=== 4. V-04c 正确密码注入 ==="
if [ -z "$PW" ]; then
    echo "  NO_PASSWORD：跳过注入"
else
    "$PROBE" inject-test --text "$PW" > /tmp/${TAG}-inject.json 2>/dev/null
    python3 - <<'PY'
import json,os
p='/tmp/tahoe-20261118-r5-inject.json'
if not os.path.exists(p): print('  NO_INJECT_RESULT'); raise SystemExit
d=json.load(open(p))
print('  verdict=',d.get('verdict'),'ok=',d.get('ok'),'diff=',json.dumps(d.get('diff'),ensure_ascii=False))
print('  sessionAfter=',json.dumps(d.get('sessionAfter'),ensure_ascii=False))
PY
fi
echo -n "  注入后: "; state

echo "=== DONE ==="
kill "$CAFF" 2>/dev/null || true
