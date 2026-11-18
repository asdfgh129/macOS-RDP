#!/bin/bash
# Tahoe V-02 / V-04d 锁屏态虚拟屏验证（自动锁屏，无需用户手动按键）。
# 用户只需在 ALL_DONE 后解锁。
set -uo pipefail
ROOT=/Volumes/Data/Code/macOS-RDP
PROBE="$ROOT/P0V-RootDaemon/build/P0VRootProbe.app/Contents/MacOS/p0vprobe"
ALT="$ROOT/P0V-AltCapture/altprobe"
TAG=tahoe-20261118-v02lock
DONE=/tmp/${TAG}.done
LOG=/tmp/${TAG}.log
rm -f "$DONE" "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== 程序化锁屏 ==="
"$PROBE" lock
for i in $(seq 1 20); do
    state=$("$PROBE" probe 2>/dev/null | python3 -c 'import json,sys; print(1 if json.load(sys.stdin)["session"].get("screenIsLocked") else 0)' 2>/dev/null || echo 0)
    [ "$state" = "1" ] && break
    sleep 1
done
"$PROBE" probe > /tmp/${TAG}-probe.json 2>/dev/null
python3 -c 'import json; d=json.load(open("/tmp/tahoe-20261118-v02lock-probe.json")); print("lock state=",d["session"])'

echo "=== 锁屏态建虚拟屏 + 三路径采集 ==="
ALTLOG=/tmp/${TAG}-alt.log
"$ALT" --spec 1280x720 --capture-ms 1200 --no-disable \
    --out /tmp/${TAG}-alt.json > "$ALTLOG" 2>&1 &
altpid=$!
vid=""
for i in $(seq 1 150); do
    vid=$(grep -o '虚拟屏就绪: [0-9]*' "$ALTLOG" 2>/dev/null | tail -1 | awk '{print $2}')
    [ -n "$vid" ] && break
    sleep 0.2
done
if [ -n "$vid" ]; then
    echo "虚拟屏 ID=$vid"
    "$PROBE" capture --display "$vid" --ms 1200 > /tmp/${TAG}-virtual.json 2>/dev/null
    python3 - <<'PY'
import json
d=json.load(open('/tmp/tahoe-20261118-v02lock-virtual.json'))
print('V-02/V-04d SCK virtual:', 'session=',d.get('session'),'verdict=',d.get('verdict'),
      'frames=',d.get('frames'),'minMean=',d.get('minMean'),'maxVar=',d.get('maxVariance'),
      'black=',d.get('suspectedBlackFrames'),'error=',d.get('error'))
PY
else
    echo "NO_VIRTUAL_DISPLAY_DETECTED"
fi
wait $altpid
echo "altprobe exit=$?"
tail -12 "$ALTLOG"

echo "ALL_DONE" > "$DONE"
echo "=== 完成，请解锁；结果见 $LOG ==="
