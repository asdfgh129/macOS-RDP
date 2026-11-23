# HostDaemon（root LaunchDaemon）

target `veild-host-daemon` 已建并编译通过；当前直接编译 `P0V-RootDaemon/src/p0vprobe.m`（过渡来源）。规划承载特权能力：显示配置 / 禁物理屏、登录窗捕获、定向注入、开机引导。

实际代码目前在 `P0V-RootDaemon/`。与目标形态对应的约束见 `docs/DESIGN.md` C-03 / C-12 与 `docs/DECISIONS.md` D-08 / D-11 / D-12。

第二轮工程收口时再迁入，并配套 LaunchDaemon plist、TCC 授权说明与签名配置；这些打包项等 P2 延迟验收后再定，不在骨架轮次内。
