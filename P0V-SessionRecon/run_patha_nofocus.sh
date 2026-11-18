#!/bin/bash
# Path A 对照实验 r6：锁屏+屏亮下禁全部物理屏，但不移动光标（无 --focus）
# 目的：判定登录 UI 迁移到虚拟屏的触发条件是「零物理屏」还是「光标聚焦」。
# 结束后用 P0V_PW 自动解锁，不依赖用户操作。
set -uo pipefail
ROOT=/Volumes/Data/Code/macOS-RDP
PROBE="$ROOT/P0V-RootDaemon/build/P0VRootProbe.app/Contents/MacOS/p0vprobe"
ALT="$ROOT/P0V-AltCapture/altprobe"
TAG=tahoe-20261118-r6
PW="${P0V_PW:-}"
rm -f /tmp/${TAG}.* /tmp/${TAG}-shot*.png
exec > >(tee -a /tmp/${TAG}.log) 2>&1

echo "=== caffeinate + 锁屏 ==="
caffeinate -d -w $$ >/dev/null 2>&1 & CAFF=$!
sleep 1
"$PROBE" lock >/dev/null
for i in $(seq 1 30); do
    s=$("$PROBE" probe 2>/dev/null | python3 -c 'import json,sys;print(1 if json.load(sys.stdin)["session"]["screenIsLocked"] else 0)' 2>/dev/null || echo 0)
    [ "$s" = 1 ] && break
    sleep 0.5
done

echo "=== 禁屏（不聚焦）==="
"$ALT" --spec 1280x720 --capture-ms 1200 \
    --shot /tmp/${TAG}-shot.png --out /tmp/${TAG}-migrate.json \
    > /tmp/${TAG}-alt.log 2>&1
echo "  altprobe exit=$?"
python3 - <<'PY'
import json,os
p='/tmp/tahoe-20261118-r6-migrate.json'
if not os.path.exists(p): print('  NO_RESULT'); raise SystemExit
d=json.load(open(p))
print('  focus键存在=', 'focus' in d, ' disable ok=', d.get('disable',{}).get('ok'),
      ' activeAfter=', d.get('disable',{}).get('activeAfter'), ' restore=', d.get('restore',{}).get('ok'))
for ph in ('baseline','disabled'):
    for pa in ('sck','cgDisplay','windows'):
        r=d.get(ph,{}).get(pa,{})
        print(f'  {ph}/{pa}: {r.get("verdict")} mean={r.get("minMean")} var={r.get("maxVariance")}')
PY
ls -l /tmp/${TAG}-shot*.png 2>/dev/null

echo "=== 自动解锁 ==="
if [ -n "$PW" ]; then
    "$PROBE" inject-test --text "$PW" > /tmp/${TAG}-inject.json 2>/dev/null
    python3 -c 'import json;d=json.load(open("/tmp/tahoe-20261118-r6-inject.json"));print("  verdict=",d.get("verdict")," lockedAfter=",d.get("sessionAfter",{}).get("screenIsLocked"))'
else
    echo "  NO_PASSWORD"
fi
"$PROBE" probe 2>/dev/null | python3 -c 'import json,sys;print("  当前 locked=",json.load(sys.stdin)["session"]["screenIsLocked"])'
echo "=== DONE ==="
kill "$CAFF" 2>/dev/null || true
