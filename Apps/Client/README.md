# Client（控制端）

target `VeilRD` 已建并编译通过；当前编译 `RDPApp/Sources/main.swift` + 桥接头 + 5 个 M1 ObjC 模块（`M1Pairing`、`M1Takeover`、`M1SessionCoordinator`、`M1DriverLogic`、`M1InputLogic`）。规划承载 Swift UI：收流、解码、零拷贝上屏、键鼠采集与独立光标通道。

第 2 轮后这 5 个模块的真实源码在 `Packages/RDPKit/Sources/{Control,Display,Input}/`，Xcode 已直接引用；渲染/解码底座 `M1FrameReceiver`、`M1FrameView`、`M1InputLogic` 分别在 `Frame/`、`Display/`、`Input/`。过渡壳仍留 `RDPApp/Sources/`，未搬到本目录，以免改动 Swift 构建路径。约束见 `docs/DESIGN.md` §4.2 与 `docs/DECISIONS.md` D-17。
