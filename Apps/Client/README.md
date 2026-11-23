# Client（控制端）

target `VeilRD` 已编译通过；第 3 轮把 Swift 入口与桥接头物理归位到 `Sources/main.swift` 与 `Sources/RDPApp-Bridging-Header.h`（旧 `RDPApp/Sources/` 为软链），第 4 轮接入真实收流链路。

- 默认输出 D-02 桥接演示：Swift 实现 `M1SessionDriver`、调用配对 / 接管 / 输入逻辑，并演示解码预热与 `M1FrameView` 构造。
- `--selftest`：纯逻辑自检（配对、会话、输入映射、解码器预热、上屏视图构造），输出 `VeilRD client selftest PASS`，由 `Tests/integration_selftest.sh` 调用。
- `--connect <IP> --port N --fingerprint HEX [--duration-ms N] [--window WxH] [--spec WxH] [--outdir DIR] [--save-frames N] [--wait-ms N] [--handshake-ms N] [--out JSON]`：真实 QUIC 收流 → `M1FrameReceiver` 重组 / VT 解码 → `M1FrameView` 上屏 → 窗口键鼠归一化经控制通道回传。**可与 `veild-host-agent --serve` 直接对连**，不必经过 `stream_probe`。收尾打印重组/解码/渲染帧数、上屏延迟分位数、A-02 时钟 offset 与样本数、输入上行计数。

会话层来自 `Packages/RDPKit/Sources/Session/M1StreamSession`，与 `stream_probe` 共用同一份实现（D-21）。`--connect` 属真机入口，验证放夜间；纯开发只跑 `--selftest`。约束见 `docs/DESIGN.md` §4.2 与 `docs/DECISIONS.md` D-17 / D-20 / D-21。
