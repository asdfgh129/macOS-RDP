#!/bin/bash
# 卸载 root daemon 探针，恢复机器原状
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行：sudo ./uninstall.sh" >&2
    exit 1
fi

launchctl bootout system/com.p0v.rootprobe 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.p0v.rootprobe.plist
rm -rf /Applications/P0VRootProbe.app
rm -f /tmp/p0v-root.json /tmp/p0v-root.log /tmp/p0v-root-stderr.log /tmp/p0v-root-stdout.log

echo "已卸载。TCC 里如果还留着 P0VRootProbe 条目，可在 系统设置 → 隐私与安全性 里手动删除。"
