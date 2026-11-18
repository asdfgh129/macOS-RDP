#!/bin/bash
# Tahoe V-02 / V-04 编排（r2）：等待锁屏后按「先建屏、后注入」顺序执行。
# r1 的问题：虚拟屏 ID 取错字段；aa+Return 被用户手动解锁污染；注入顺序过早。
set -uo pipefail
cd "$(dirname "$0")"

ROOT=/Volumes/Data/Code/macOS-RDP
PROBE="$ROOT/P0V-RootDaemon/build/P0VRootProbe.app/Contents/MacOS/p0vprobe"
V01="$ROOT/P0V-DisplayIsolation/v01probe"
TAG=tahoe-20261118-r2
DONE=/tmp/${TAG}-v02v04.done
LOG=/tmp/${TAG}-v02v04.log
rm -f "$DONE" /tmp/${TAG}-lock.flag "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== 程序化锁屏（SACLockScreenImmediate）==="
"$PROBE" lock
locked=0
for i in $(seq 1 20); do
    state=$("$PROBE" probe 2>/dev/null | python3 -c 'import json,sys; print(1 if json.load(sys.stdin)["session"].get("screenIsLocked") else 0)' 2>/dev/null || echo 0)
    if [ "$state" = "1" ]; then locked=1; echo "[$(date '+%H:%M:%S')] 检测到锁屏"; break; fi
    sleep 1
done
if [ "$locked" != "1" ]; then echo "LOCK_FAILED" > "$DONE"; exit 2; fi
echo "LOCK_DETECTED" > /tmp/${TAG}-lock.flag

virtual_id_from_log() {
    grep -o '虚拟屏就绪: [0-9]*' "$1" 2>/dev/null | tail -1 | awk '{print $2}'
}

echo "=== V-04a：锁屏态用户会话进程捕获（不注入）==="
"$PROBE" probe > /tmp/${TAG}-v04-probe.json 2>/dev/null
"$PROBE" capture --ms 1200 > /tmp/${TAG}-v04a.json 2>/dev/null
python3 - <<'PY'
import json
p='/tmp/tahoe-20261118-r2-v04a.json'
d=json.load(open(p))
print('V-04a session=',d.get('session'),'verdict=',d.get('verdict'),
      'frames=',d.get('frames'),'minMean=',d.get('minMean'),'black=',d.get('suspectedBlackFrames'))
PY

echo "=== V-02：锁屏态建虚拟屏 + SCK 捕获 ==="
V02LOG=/tmp/${TAG}-v02-dryrun.log
"$V01" run --dry-run --yes --spec 1280x720 --capture-ms 1200 --watch-secs 0 \
    --out /tmp/${TAG}-v02-dryrun.json > "$V02LOG" 2>&1 &
v02pid=$!
virtual_id=""
for i in $(seq 1 150); do
    virtual_id=$(virtual_id_from_log "$V02LOG")
    [ -n "$virtual_id" ] && break
    sleep 0.2
done
if [ -n "$virtual_id" ]; then
    echo "V-02 虚拟屏 ID=$virtual_id"
    "$PROBE" capture --display "$virtual_id" --ms 1200 > /tmp/${TAG}-v02-virtual.json 2>/dev/null
    python3 - <<'PY'
import json
d=json.load(open('/tmp/tahoe-20261118-r2-v02-virtual.json'))
print('V-02 virtual capture session=',d.get('session'),'verdict=',d.get('verdict'),
      'frames=',d.get('frames'),'minMean=',d.get('minMean'),
      'maxVar=',d.get('maxVariance'),'black=',d.get('suspectedBlackFrames'),
      'error=',d.get('error'))
PY
else
    echo "V-02 virtual display not detected"
fi
wait $v02pid
echo "V-02 dry-run exit=$?"

echo "=== V-04d：登录窗态建虚拟屏 + 禁物理屏 ==="
V04DLOG=/tmp/${TAG}-v04d.log
"$V01" run --mode all --yes --watch-secs 0 --no-rebuild-test \
    --out /tmp/${TAG}-v04d.json > "$V04DLOG" 2>&1 &
v04dpid=$!
virtual_id=""
for i in $(seq 1 150); do
    virtual_id=$(virtual_id_from_log "$V04DLOG")
    [ -n "$virtual_id" ] && break
    sleep 0.2
done
if [ -n "$virtual_id" ]; then
    echo "V-04d 虚拟屏 ID=$virtual_id"
    "$PROBE" capture --display "$virtual_id" --ms 1200 > /tmp/${TAG}-v04d-virtual.json 2>/dev/null
    python3 - <<'PY'
import json
d=json.load(open('/tmp/tahoe-20261118-r2-v04d-virtual.json'))
print('V-04d virtual capture session=',d.get('session'),'verdict=',d.get('verdict'),
      'frames=',d.get('frames'),'minMean=',d.get('minMean'),
      'maxVar=',d.get('maxVariance'),'black=',d.get('suspectedBlackFrames'),
      'error=',d.get('error'))
PY
else
    echo "V-04d virtual display not detected"
fi
wait $v04dpid
echo "V-04d run exit=$?"

echo "=== V-04b：最后做定向注入（长错误密码，避免误解锁）==="
"$PROBE" inject-test --text zzzzzzzz > /tmp/${TAG}-v04b.json 2>/dev/null
python3 - <<'PY'
import json
d=json.load(open('/tmp/tahoe-20261118-r2-v04b.json'))
print('V-04b verdict=',d.get('verdict'),'before=',d.get('before'),'after=',d.get('after'),
      'diff=',d.get('diff'),'sessionAfter=',d.get('sessionAfter'))
PY

echo "ALL_DONE" > "$DONE"
echo "=== 全部完成，可以解锁；结果见 $LOG ==="
