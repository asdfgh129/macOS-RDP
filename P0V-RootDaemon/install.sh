#!/bin/bash
# 安装 root daemon 探针（需管理员密码）
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d build/P0VRootProbe.app ]; then
    echo "先跑 ./build.sh" >&2
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行：sudo ./install.sh" >&2
    exit 1
fi

rm -rf /Applications/P0VRootProbe.app
cp -R build/P0VRootProbe.app /Applications/
chown -R root:wheel /Applications/P0VRootProbe.app

install -m 644 -o root -g wheel com.p0v.rootprobe.plist /Library/LaunchDaemons/com.p0v.rootprobe.plist

launchctl bootout system/com.p0v.rootprobe 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.p0v.rootprobe.plist

echo "已安装。检查状态："
launchctl print system/com.p0v.rootprobe 2>&1 | head -20 || true
echo
echo "手动触发一次（在未锁屏态先验证机制是否通）："
echo "  sudo launchctl kickstart -k system/com.p0v.rootprobe && sleep 6 && cat /tmp/p0v-root.json"
