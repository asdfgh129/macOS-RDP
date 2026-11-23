# Tests

跨模块测试入口与测试夹具。第 3 轮新增 `integration_selftest.sh`，由根 `Scripts/test.sh` 自动调用。

- `integration_selftest.sh`：构建五个 target（含两个静态库），随后运行 `veild-host-agent`、`VeilRD --selftest` 与 daemon 冒烟；只跑纯逻辑，不碰 WindowServer / 网络。
- `M1-Skeleton/tests/`：骨架单测、`guardian_handshake_test.m`
- `P1-ClientProbe/tests/`：协议 / 输入 / 状态机单测
- `P2-Dual/p2.sh`：双机门禁，属真机联调，不在纯开发轮次内跑

单测文件仍留在各探针目录，避免破坏 runbook 路径；新增跨模块测试从本目录进入。
