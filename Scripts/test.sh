#!/bin/bash
# VeilRD 统一单测入口
# 仅跑纯开发单测，不触发双机真机联调。
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== M1-Skeleton tests ==="
bash M1-Skeleton/build_tests.sh

echo "=== P1-ClientProbe tests ==="
bash P1-ClientProbe/build_tests.sh

echo "=== cross-module integration selftest ==="
bash Tests/integration_selftest.sh

echo "ALL UNIT TESTS PASSED"
