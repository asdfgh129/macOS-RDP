# HostDaemon（root LaunchDaemon）

target `veild-host-daemon` 已编译通过；第 3 轮把 `P0V-RootDaemon/src/p0vprobe.m` 物理归位为 `Sources/main.m`，旧路径保留软链供探针 runbook 使用。

当前仍保留 p0vprobe 的命令行形态（`lock|probe|capture|inject-test|type|daemon-run`），承载特权能力：显示配置 / 禁物理屏、登录窗捕获、定向注入、开机引导。下一步是补齐 LaunchDaemon plist、TCC 授权说明与签名配置——这些打包项依赖 P2 后的真机验收，不在骨架轮次内。

约束见 `docs/DESIGN.md` C-03 / C-12 与 `docs/DECISIONS.md` D-08 / D-11 / D-12 / D-20。
