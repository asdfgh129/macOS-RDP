#!/bin/bash
# Tahoe 锁屏态三场景对照重测（2026-11-18）
#   A: 锁屏后允许显示睡眠（2-3s 黑屏），在屏睡态建虚拟屏并三路径采集
#   B: caffeinate -d 阻止显示睡眠，锁屏后建虚拟屏并采集
#   C: 屏睡后注入键鼠唤醒，再建虚拟屏并采集
# 程序化锁屏；用户只在 ALL_DONE 后解锁。
set -uo pipefail
ROOT=/Volumes/Data/Code/macOS-RDP
PROBE="$ROOT/P0V-RootDaemon/build/P0VRootProbe.app/Contents/MacOS/p0vprobe"
ALT="$ROOT/P0V-AltCapture/altprobe"
TAG=tahoe-20261118-r3
DONE=/tmp/${TAG}.done
LOG=/tmp/${TAG}.log
rm -f "$DONE" "$LOG"
exec > >(tee -a "$LOG") 2>&1

wait_lock() {
    for i in $(seq 1 30); do
        s=$("$PROBE" probe 2>/dev/null | python3 -c 'import json,sys; print(1 if json.load(sys.stdin)["session"]["screenIsLocked"] else 0)' 2>/dev/null || echo 0)
        [ "$s" = 1 ] && return 0
        sleep 0.5
    done
    return 1
}

run_case() {
    local name="$1"
    local out="/tmp/${TAG}-${name}.json"
    echo "--- $name $(date '+%H:%M:%S') ---"
    "$ALT" --spec 1280x720 --capture-ms 1500 --no-disable --out "$out" > "/tmp/${TAG}-${name}.log" 2>&1 &
    local pid=$!
    for i in $(seq 1 150); do
        grep -q '虚拟屏就绪' "/tmp/${TAG}-${name}.log" 2>/dev/null && break
        sleep 0.2
    done
    local vid
    vid=$(grep -o '虚拟屏就绪: [0-9]*' "/tmp/${TAG}-${name}.log" 2>/dev/null | tail -1 | awk '{print $2}')
    echo "  virtualID=$vid"
    if [ -n "$vid" ]; then
        "$PROBE" capture --display "$vid" --ms 1500 > "/tmp/${TAG}-${name}-sck.json" 2>/dev/null
        python3 - "$name" <<'PY'
import json,sys,os
n=sys.argv[1]
p=f'/tmp/tahoe-20261118-r3-{n}-sck.json'
if os.path.exists(p):
    d=json.load(open(p))
    print('  SCK:',d.get('verdict'),'frames=',d.get('frames'),'black=',d.get('suspectedBlackFrames'),'locked=',d.get('session',{}).get('screenIsLocked'))
PY
    fi
    wait "$pid"; echo "  altprobe exit=$?"
    python3 - "$name" <<'PY'
import json,sys,os
n=sys.argv[1]
p=f'/tmp/tahoe-20261118-r3-{n}.json'
if not os.path.exists(p): print('  NO_RESULT'); raise SystemExit
d=json.load(open(p))
print('  virtual=',d.get('virtualDisplayID'),'online=',d.get('virtualOnline'),'active=',d.get('virtualActive'),
      'physActive=',d.get('physicalActiveIDs'),'sckVisible=',d.get('sckVisible'))
for phase in ('baseline',):
    for path in ('sck','cgDisplay','windows'):
        r=d.get(phase,{}).get(path,{})
        print(f'  {phase}/{path}: verdict={r.get("verdict")} minMean={r.get("minMean")} maxVar={r.get("maxLumaVariance") or r.get("maxVar")} black={r.get("suspectedBlackFrames")}')
PY
}

echo "=== A: 锁屏，允许屏睡 ==="
"$PROBE" lock >/dev/null
wait_lock || { echo LOCK_FAILED_A; echo "LOCK_FAILED" > "$DONE"; exit 2; }
echo "  locked at $(date '+%H:%M:%S')"
for t in 0 1 2 3 5; do
    [ "$t" != 0 ] && sleep $(( t == 1 ? 1 : (t == 2 ? 1 : (t == 3 ? 1 : 2)) ))
    "$PROBE" probe > "/tmp/${TAG}-A-t${t}.json" 2>/dev/null
    python3 - "$t" <<'PY'
import json,sys
t=sys.argv[1]; d=json.load(open(f'/tmp/tahoe-20261118-r3-A-t{t}.json'))
ds=d.get('displays',{}).get('list',[])
print(f'  t={t}s activeCount={len(ds)} asleep={[x.get("asleep") for x in ds]} sckIDs={d.get("sckDisplayIDs")}')
PY
done
sleep 3
run_case A

echo "=== C: 屏睡态注入键鼠唤醒后建屏 ==="
"$PROBE" inject-test --text "" >/dev/null 2>&1 || true
osascript -e 'tell application "System Events" to key code 10' >/dev/null 2>&1 || true
sleep 2
"$PROBE" probe > "/tmp/${TAG}-C-wake.json" 2>/dev/null
python3 -c 'import json;d=json.load(open("/tmp/tahoe-20261118-r3-C-wake.json"));print("  after wake: locked=",d["session"]["screenIsLocked"],"active=",len(d["displays"]["list"]))'
run_case C

echo "=== 完成 ==="
echo "脚本已结束。注意：此时屏幕仍锁定，用户看不到终端输出；"
echo "由调用方在对话中通知用户解锁，不要依赖本文件的 ALL_DONE 标记。"
echo "ALL_DONE_A_C" > "$DONE"
