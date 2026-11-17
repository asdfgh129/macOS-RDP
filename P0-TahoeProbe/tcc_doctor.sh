#!/bin/bash
# TCC 归因诊断：判断屏幕录制权限卡在「终端没授权」还是「授权被 p0probe 签名身份吃掉」。
# 用系统自带 screencapture 做对照实验。全程不建虚拟屏、不改系统设置。
# 在 Terminal.app 里运行： ./tcc_doctor.sh

set -uo pipefail
cd "$(dirname "$0")" || exit 1

probe_tcc() {  # 输出 1/0
  ./p0probe probe 2>/dev/null \
    | grep -o '"screenRecordingGranted":[0-9]*' | head -1 | cut -d: -f2
}

granted() { [ "$1" = "1" ] || [ "$1" = "true" ]; }

echo "=============================================="
echo " A. 对照实验：Terminal 自身的抓屏能力"
echo "=============================================="
rm -f /tmp/p0_tcc_test.png /tmp/p0_sc.err
if screencapture -x /tmp/p0_tcc_test.png 2>/tmp/p0_sc.err && [ -s /tmp/p0_tcc_test.png ]; then
  TERM_OK=1
  echo "结果：CAPTURE_OK  → Terminal.app 已经拥有屏幕录制权限"
  echo "      文件 $(ls -lh /tmp/p0_tcc_test.png | awk '{print $5}')"
else
  TERM_OK=0
  echo "结果：CAPTURE_FAIL → Terminal.app 没有屏幕录制权限"
  [ -s /tmp/p0_sc.err ] && { echo "      错误：$(head -2 /tmp/p0_sc.err)"; }
fi
echo

echo "=============================================="
echo " B. p0probe 当前状态（签名：$(codesign -dv ./p0probe 2>&1 | grep -m1 -o 'Identifier=[^ ]*' || echo '未签名')）"
echo "=============================================="
S1=$(probe_tcc)
echo "screenRecordingGranted = ${S1:-?}"
echo

if [ "$TERM_OK" = "1" ] && granted "$S1"; then
  echo "RESULT: READY_SIGNED —— 授权正常，可以直接跑 ./run_verify_min.sh"
  exit 0
fi

echo "=============================================="
echo " C. 去掉 p0probe 的 ad-hoc 签名，让它继承终端的授权"
echo "=============================================="
cp -f p0probe p0probe.signed.bak
codesign --remove-signature ./p0probe 2>&1 | head -2
echo "签名状态：$(codesign -dv ./p0probe 2>&1 | head -1)"
S2=$(probe_tcc)
echo "screenRecordingGranted = ${S2:-?}"
echo

if granted "$S2"; then
  echo "RESULT: READY_UNSIGNED —— 去签名后继承成功，可以跑 ./run_verify_min.sh"
  echo "（注意：以后每次重建二进制都要重新走一次授权）"
  exit 0
fi

# 没成功就恢复签名，保持标识稳定
mv -f p0probe.signed.bak p0probe
echo "已恢复 ad-hoc 签名（$(codesign -dv ./p0probe 2>&1 | grep -m1 -o 'Identifier=[^ ]*')）"
echo
echo "=============================================="
echo " 结论"
echo "=============================================="
if [ "$TERM_OK" = "0" ]; then
  echo "RESULT: TERMINAL_NOT_GRANTED"
  echo
  echo "→ 问题在终端没权限。请做："
  echo "  1) 打开 系统设置 → 隐私与安全性 → 屏幕录制"
  echo "  2) 找到 Terminal 并把开关打开（不在列表里就点左下角 + 手动添加 /System/Applications/Utilities/Terminal.app）"
  echo "  3) 如果 Terminal 已经显示为打开状态：先关掉开关，再打开（刷新记录）"
  echo "  4) Cmd+Q 完全退出 Terminal，重新打开，再跑 ./tcc_doctor.sh"
else
  echo "RESULT: ATTRIBUTION_BLOCKED"
  echo
  echo "→ 终端有权限但 p0probe 用不上，说明 TCC 里存了一条针对 p0probe 的『拒绝』记录。请跑："
  echo "    tccutil reset ScreenCapture com.p0.tahoeprobe"
  echo "  然后重跑 ./tcc_doctor.sh（可能会弹系统授权框，点『允许』）"
  echo "  若仍不行： tccutil reset ScreenCapture    # 重置全部，其他 App 需重新授权"
fi
