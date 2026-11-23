# Tests

**占位目录。** 规划承载跨模块集成测试入口与测试夹具。

当前测试资产：

- `M1-Skeleton/tests/`（骨架单测、`guardian_handshake_test.m`）
- `P1-ClientProbe/tests/`（协议 / 输入 / 状态机单测）
- `P2-Dual/p2.sh`（双机门禁，属真机联调，不在纯开发轮次内跑）

根 `Scripts/test.sh` 已聚合两个脚本；第 2 轮源码分层迁移后断言数不回退。测试文件仍留在各探针目录，待 P2 验收后再统一迁入本目录。
