#!/bin/bash
# VeilRD 统一构建入口
#   bash Scripts/build.sh                 # 构建三个 target
#   bash Scripts/build.sh VeilRD          # 只构建指定 scheme
#   CONFIGURATION=Release bash Scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED_DATA="${DERIVED_DATA:-/tmp/veilrd-xcode}"
CONFIGURATION="${CONFIGURATION:-Debug}"

SCHEMES=("$@")
if [ ${#SCHEMES[@]} -eq 0 ]; then
  SCHEMES=(veild-host-daemon veild-host-agent VeilRD)
fi

for scheme in "${SCHEMES[@]}"; do
  echo "=== BUILD $scheme ==="
  xcodebuild -workspace VeilRD.xcworkspace \
    -scheme "$scheme" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    build
done

echo "产物目录：$DERIVED_DATA/Build/Products/$CONFIGURATION"
