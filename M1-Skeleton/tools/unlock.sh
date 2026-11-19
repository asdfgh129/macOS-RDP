#!/bin/bash
#
# 解锁当前会话（锁屏 → 桌面）。
#
#   前提：调用方必须有「辅助功能」授权，否则 osascript 会直接报
#         System Events got an error: A privilege violation occurred. (-10004)
#         检查：./cursor_move ax
#   口令：本机钥匙串 P0V_UNLOCK（不落仓库）：
#         security add-generic-password -U -s P0V_UNLOCK -a "$USER" -w '<口令>'
#
#   用法：./tools/unlock.sh
#
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

if ! ./cursor_move locked >/dev/null 2>&1; then
  echo "已解锁"
  exit 0
fi

PW=$(security find-generic-password -s P0V_UNLOCK -w 2>/dev/null)
if [ -z "${PW:-}" ]; then
  echo "✗ 钥匙串里没有 P0V_UNLOCK 条目" >&2
  exit 2
fi

# 先点一次「用户活动」，把睡下去的显示器叫醒：唤醒用的第一次按键常常被吞掉，
# 所以后面先发一个不产生字符的 fn（key code 63），再清空口令框、再输入。
caffeinate -u -t 2 >/dev/null 2>&1 &
sleep 0.6

osascript -e 'tell application "System Events" to key code 63' >/dev/null 2>&1 || {
  echo "✗ 无法投递按键（缺辅助功能授权：./cursor_move ax 应为 0）" >&2
  exit 3
}
sleep 0.8

# 口令框里可能残留上次的字符：全选删除再输入，避免拼出错误口令触发失败延时。
osascript \
  -e 'tell application "System Events" to keystroke "a" using command down' \
  -e 'tell application "System Events" to key code 51' >/dev/null 2>&1

osascript \
  -e "tell application \"System Events\" to keystroke \"$PW\"" \
  -e 'tell application "System Events" to key code 36' >/dev/null 2>&1

for _i in $(seq 1 20); do
  if ! ./cursor_move locked >/dev/null 2>&1; then
    echo "已解锁"
    exit 0
  fi
  sleep 0.3
done

echo "✗ 解锁失败（口令错误，或锁屏界面没拿到键盘焦点）" >&2
exit 4
