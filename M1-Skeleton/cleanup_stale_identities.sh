#!/bin/bash
# 清理早期实现残留在登录钥匙串里的测试证书。
#
# 背景：在引入「进程私有临时钥匙串」之前（见 docs/DECISIONS.md NEG-04），
# SecPKCS12Import 会把 .state 里的测试身份写进**登录钥匙串**，并带上持久 ACL。
# 这些条目已经没有调用方，留着只会污染钥匙串，并可能在误用旧二进制时再次
# 拉起 SecurityAgent 授权框。
#
# 本脚本只删证书（CN=macOS-RDP M1 dev），不碰私钥条目——删除私钥本身会弹授权框，
# 而且不可逆，留给用户自己在「钥匙串访问」里处理。
#
# 用法：
#   ./cleanup_stale_identities.sh          # 只列出
#   ./cleanup_stale_identities.sh --delete # 执行删除

set -uo pipefail
CN="macOS-RDP M1 dev"
KC="${HOME}/Library/Keychains/login.keychain-db"

shas=$(security find-certificate -a -c "$CN" -Z "$KC" 2>/dev/null \
        | awk -F': ' '/SHA-1 hash/{print $2}')

if [[ -z "$shas" ]]; then
    echo "登录钥匙串里没有 CN=\"$CN\" 的残留证书"
    exit 0
fi

n=$(echo "$shas" | wc -l | tr -d ' ')
echo "登录钥匙串里 CN=\"$CN\" 的证书：$n 张"
echo "$shas" | sed 's/^/  /'

if [[ "${1:-}" != "--delete" ]]; then
    echo
    echo "这是只读预览。执行删除：./cleanup_stale_identities.sh --delete"
    exit 0
fi

ok=0
for sha in $shas; do
    if security delete-certificate -Z "$sha" "$KC" >/dev/null 2>&1; then
        ok=$((ok + 1))
    else
        echo "  删除失败: $sha" >&2
    fi
done
echo "已删除 $ok / $n 张"
