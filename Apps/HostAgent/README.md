# HostAgent（用户态 LaunchAgent）

target `veild-host-agent` 已建并编译通过；入口为 `Sources/main.m`。规划承载会话内能力：建虚拟屏、SCK / CG / CGDisplayCreateImage 采集后端门控、H.264 编码、常规键鼠注入。

第 2 轮后，实际模块来自 `Packages/RDPKit/Sources/{Capture,Codec,Frame,Transport,Control,Display,Input,Common}` 与 `Packages/ProtocolCodec/Sources`（如 `M1CapturePipeline`、`M1VideoEncoder`、`M1RDPDriver`、`M1InputInjector`）；Xcode 已直接引用真实路径，旧 `M1-Skeleton/src/` 仅为兼容软链。约束见 `docs/DESIGN.md` §2.4.1 / §4.1 与 `docs/DECISIONS.md` D-09 / D-10 / D-17。
