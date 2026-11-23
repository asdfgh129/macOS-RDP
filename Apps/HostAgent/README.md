# HostAgent（用户态 LaunchAgent）

target `veild-host-agent` 已编译通过；入口 `Sources/main.m` 第 3 轮起直接消费 `RDPKit` / `ProtocolCodec` 静态库，第 4 轮接入共享流会话节点层。

- 默认自检：配对码、会话状态机（注入 `M1SessionDriver` 测试替身，不碰 WindowServer）、输入映射、H.264 目标码率，输出 `veild-host-agent selftest PASS`。
- `--capture <displayID> <seconds>`：显式启动 `M1CapturePipeline → M1VideoEncoder → M1FramePipeline` 真实链路，用计数 sink 替代 QUIC；需要屏幕录制 TCC，仅在真机轮次使用。
- `--serve [--port N] [--spec WxH] [--fps N] [--duration-ms N] [--wait-ms N] [--inject record|real] [--mirror] [--keep-main] [--identity PATH] [--pass PASS] [--out JSON]`：真实 QUIC 监听 + 会话协商（独占模式下按客户端规格建虚拟屏 / 禁物理屏）+ `M1FramePipeline` 推流 + keyframe/frame-nack 补片 + 输入回传。**可与 `VeilRD --connect` 直接对连**，不必经过 `stream_probe`。`--inject` 默认 `record`（单机环回安全），真机改 `real`；`--out` 落 JSON 供夜间汇总。

会话层来自 `Packages/RDPKit/Sources/Session/M1StreamSession`，与 `stream_probe` 共用同一份实现（D-21）。`Tests/integration_selftest.sh` 构建全部 target 并运行纯逻辑自检；环回建链自检见 `Tests/README.md`。约束见 `docs/DESIGN.md` §2.4.1 / §4.1 与 `docs/DECISIONS.md` D-09 / D-10 / D-17 / D-20 / D-21。
