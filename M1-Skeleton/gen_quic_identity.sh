#!/bin/bash
#
# 生成 QUIC 用的自签身份（p12），M1-A 第 1/2 步的测试证书。
# 生产形态应由用户在配对流里确认指纹，而不是预置固定证书；这里只服务本机环回实验。
#
# 用法：./gen_quic_identity.sh [目录] [名称] [p12 密码]
#
set -euo pipefail

DIR="${1:-.state}"
NAME="${2:-rdp-identity}"
PASS="${3:-rdpdev}"

mkdir -p "$DIR"
if [[ -f "$DIR/$NAME.p12" ]]; then
    echo "已存在: $DIR/$NAME.p12"
    exit 0
fi

OPENSSL="$(command -v openssl || true)"
if [[ -z "$OPENSSL" ]]; then
    echo "找不到 openssl，无法生成测试身份" >&2
    exit 1
fi

# SecPKCS12Import 对现代 PBES2/AES 的兼容性不稳，统一用 3DES+SHA1（PBE-SHA1-3DES）
# 导出，这是 macOS Keychain 长期以来最稳的组合。
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout "$DIR/$NAME.key" -out "$DIR/$NAME.crt" \
    -days 3650 -subj "/CN=macOS-RDP M1 dev" \
    -addext "extendedKeyUsage=serverAuth" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null

"$OPENSSL" pkcs12 -export -out "$DIR/$NAME.p12" \
    -inkey "$DIR/$NAME.key" -in "$DIR/$NAME.crt" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -name "$NAME" -passout "pass:$PASS" 2>/dev/null

chmod 600 "$DIR/$NAME.key" "$DIR/$NAME.p12"
echo "已生成: $DIR/$NAME.p12（密码 ${PASS}）"
