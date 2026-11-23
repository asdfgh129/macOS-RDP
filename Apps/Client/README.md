# Client（控制端）

target `VeilRD` 已编译通过；第 3 轮把 Swift 入口与桥接头物理归位到 `Sources/main.swift` 与 `Sources/RDPApp-Bridging-Header.h`（旧 `RDPApp/Sources/` 为软链）。

- 默认输出 D-02 桥接演示：Swift 实现 `M1SessionDriver`、调用配对 / 接管 / 输入逻辑，并新增解码预热与 `M1FrameView` 构造演示。
- `--selftest`：跑纯逻辑自检（配对、会话、输入映射、解码器预热、上屏视图构造），输出 `VeilRD client selftest PASS`，由 `Tests/integration_selftest.sh` 调用。

真实 QUIC 收流 / 窗口上屏仍在 `M1-Skeleton/stream_probe.m`，本入口尚未并入；这属于后续产品化范围。约束见 `docs/DESIGN.md` §4.2 与 `docs/DECISIONS.md` D-17 / D-20。
