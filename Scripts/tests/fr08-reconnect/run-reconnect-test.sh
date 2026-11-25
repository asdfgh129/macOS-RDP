#!/bin/bash
# FR-08 断网重连验收：客户端侧 pf 双向阻断（或单向），验证判死→退避→重连→恢复推流。
#
# 用法：sudo -v   # 先取得 pf 授权（脚本只用 sudo -n，不含口令）
#       bash run-reconnect-test.sh <HOST_IP> <PORT> <FP_HEX> [断路秒数=12] [--one-way]
# 环境：VEILRD_BIN 指定客户端二进制（默认 /tmp/veilrd-xcode/Build/Products/Debug/VeilRD）
#
# 判定（README）：恢复后出现「重连成功」、JSON reconnects>=1；
# 不得出现「控制链路失败 → 断线重连 0 次」（§5.45 C 的僵尸 STREAMING 回归）。
set -u

HOST_IP="${1:?HOST_IP}"; PORT="${2:?PORT}"; FP="${3:?FP_HEX}"
BLOCK_SEC="${4:-12}"; ONE_WAY="${5:-}"
CLIENT="${VEILRD_BIN:-/tmp/veilrd-xcode/Build/Products/Debug/VeilRD}"
OUT=/tmp/fr08
sudo -n true 2>/dev/null || { echo "✗ 先执行 sudo -v 取得 pf 授权"; exit 1; }
[ -x "$CLIENT" ] || { echo "✗ 缺客户端二进制 $CLIENT"; exit 1; }
mkdir -p "$OUT"

CONF="$OUT/pf-reconnect.conf"
{
    echo "block drop quick inet from any to $HOST_IP"
    [ "$ONE_WAY" = "--one-way" ] || echo "block drop quick inet from $HOST_IP to any"
    echo "pass"
} > "$CONF"

restore() {
    sudo -n pfctl -f /etc/pf.conf >/dev/null 2>&1
    sudo -n pfctl -F states >/dev/null 2>&1
    sudo -n pfctl -d >/dev/null 2>&1
}
trap restore EXIT

: > "$OUT/reconnect.log"
env -u http_proxy -u https_proxy -u ALL_PROXY script -q /dev/null \
    "$CLIENT" --connect "$HOST_IP" --port "$PORT" --fingerprint "$FP" \
    --spec 1280x720 --window 1280x720 --reconnect --handshake-ms 8000 \
    --wait-ms 45000 --duration-ms 70000 --out "$OUT/reconnect.json" \
    >> "$OUT/reconnect.log" 2>&1 &
CPID=$!

for _ in $(seq 1 200); do grep -q "已 STREAMING" "$OUT/reconnect.log" && break; sleep 0.5; done
grep -q "已 STREAMING" "$OUT/reconnect.log" || { echo "✗ 客户端未进入 STREAMING"; tail -20 "$OUT/reconnect.log"; exit 1; }
sleep 5

sudo -n pfctl -e >/dev/null 2>&1
sudo -n pfctl -f "$CONF" >/dev/null 2>&1
sudo -n pfctl -F states >/dev/null 2>&1
echo "##### 断路开始 $(date +%H:%M:%S)（${BLOCK_SEC}s${ONE_WAY:+ 单向}）#####" >> "$OUT/reconnect.log"
sleep 3
echo "##### probe1 $(date +%H:%M:%S) $(ping -c1 -W1 "$HOST_IP" 2>&1 | tail -1) #####" >> "$OUT/reconnect.log"
sleep $((BLOCK_SEC - 3 > 0 ? BLOCK_SEC - 3 : 0))
restore
echo "##### 恢复网络 $(date +%H:%M:%S) #####" >> "$OUT/reconnect.log"
sleep 30
wait $CPID
echo "##### client 退出 code=$? $(date +%H:%M:%S) #####" >> "$OUT/reconnect.log"

grep -v "\[client\] STREAMING$" "$OUT/reconnect.log" | tail -30
if grep -q "断线重连 0 次" "$OUT/reconnect.log"; then
    echo "✗ 未触发重连（僵尸 STREAMING 回归？）"; exit 1
fi
grep -q "重连成功" "$OUT/reconnect.log" && echo "✓ FR-08 PASS" || { echo "✗ 未见重连成功"; exit 1; }
