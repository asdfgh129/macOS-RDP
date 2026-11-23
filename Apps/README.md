# Apps（产品可执行层）

三个产品 target 已在 `VeilRD.xcodeproj` 建好并编译通过（共享 scheme 在 `VeilRD.xcworkspace`）。第 2 轮后共享逻辑已归位到 `Packages/`，target 直接引用真实路径；本层只放产物入口，根守护与 Swift 壳仍是过渡来源。

| 目录 | 角色 | target | 当前实现资产 |
|---|---|---|---|
| `HostDaemon/` | root LaunchDaemon：显示配置 / 禁物理屏、登录窗捕获、定向注入、开机引导 | `veild-host-daemon` | `P0V-RootDaemon/src/p0vprobe.m`（过渡，未搬入本层） |
| `HostAgent/` | 用户态 LaunchAgent：建虚拟屏、SCK / CG 采集、编码、常规注入 | `veild-host-agent` | `Sources/main.m` + `Packages/RDPKit/Sources/`、`Packages/ProtocolCodec/Sources/` |
| `Client/` | 控制端 Swift UI：收流 / 解码 / 上屏、键鼠采集 | `VeilRD` | `RDPApp/Sources/main.swift`（过渡壳） + `Packages/RDPKit/Sources/{Control,Display,Input}/` |

命名与路径边界见 `docs/DESIGN.md` §1.3 与 `docs/DECISIONS.md` D-18：文档自称用 VeilRD，仓库目录与代码标识符暂留 `macOS-RDP`。
