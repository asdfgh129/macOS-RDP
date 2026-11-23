# Tests

跨模块测试入口与测试夹具。第 3 轮新增 `integration_selftest.sh`，第 4 轮新增环回建链自检，均由根 `Scripts/test.sh` 自动调用。

- `integration_selftest.sh`：构建五个 target（含两个静态库），运行 `veild-host-agent`、`VeilRD --selftest` 与 daemon 冒烟；随后编译并运行 `stream_session_selftest.m`。
- `stream_session_selftest.m`：用临时 QUIC 身份在本机环起 host/client 两个 `M1StreamNode`，验证 QUIC 握手 → 控制会话到 STREAMING → A-02 时钟探针有样本。**不采集、不注入**，不需要屏幕录制 / 辅助功能授权，可在纯开发轮次跑；它验证的是产品两端与探针共用的会话层。
- `M1-Skeleton/tests/`：骨架单测、`guardian_handshake_test.m`
- `P1-ClientProbe/tests/`：协议 / 输入 / 状态机单测
- `P2-Dual/p2.sh`：双机门禁，属真机联调，不在纯开发轮次内跑

单测文件仍留在各探针目录，避免破坏 runbook 路径；新增跨模块测试从本目录进入。`--serve` / `--connect` 的真实采集 → 上屏 → 注入对连仍需夜间真机验收（D-21）。
