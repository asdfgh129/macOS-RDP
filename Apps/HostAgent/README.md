# HostAgent（用户态 LaunchAgent）

target `veild-host-agent` 已编译通过；入口 `Sources/main.m` 第 3 轮起直接消费 `RDPKit` / `ProtocolCodec` 静态库，不再是纯占位壳。

- 默认自检：配对码、会话状态机（注入 `M1SessionDriver` 测试替身，不碰 WindowServer）、输入映射、H.264 目标码率，输出 `veild-host-agent selftest PASS`。
- `--capture <displayID> <seconds>`：显式启动 `M1CapturePipeline → M1VideoEncoder → M1FramePipeline` 真实链路，用计数 sink 替代 QUIC；需要屏幕录制 TCC，仅在真机轮次使用。

`Tests/integration_selftest.sh` 会构建全部 target 并运行上述自检。约束见 `docs/DESIGN.md` §2.4.1 / §4.1 与 `docs/DECISIONS.md` D-09 / D-10 / D-17 / D-20。
