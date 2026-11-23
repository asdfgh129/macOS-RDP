# Apps（产品可执行层）

三个产品 target 已在 `VeilRD.xcodeproj` 建好并编译通过（共享 scheme 在 `VeilRD.xcworkspace`）。第 3 轮后三个入口的物理源码都归位到本层，并通过 target 依赖链接 `RDPKit` / `ProtocolCodec` 静态库；旧探针路径只是软链兼容层。

| 目录 | 角色 | target | 当前实现资产 |
|---|---|---|---|
| `HostDaemon/` | root LaunchDaemon：显示配置 / 禁物理屏、登录窗捕获、定向注入、开机引导 | `veild-host-daemon` | `Sources/main.m`（由 p0vprobe 归位） |
| `HostAgent/` | 用户态 LaunchAgent：建虚拟屏、SCK / CG 采集、编码、常规注入 | `veild-host-agent` | `Sources/main.m`（selftest + `--capture`）+ 两个静态库 |
| `Client/` | 控制端 Swift UI：收流 / 解码 / 上屏、键鼠采集 | `VeilRD` | `Sources/main.swift` + `Sources/RDPApp-Bridging-Header.h` + 两个静态库 |

命名与路径边界见 `docs/DESIGN.md` §1.3 与 `docs/DECISIONS.md` D-18：文档自称用 VeilRD，仓库目录与代码标识符暂留 `macOS-RDP`。
