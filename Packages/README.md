# Packages（可复用库层）

与产品可执行层分离的逻辑库。**第 2 轮已完成物理归位**：真实源码在 `RDPKit/Sources/` 与 `ProtocolCodec/Sources/`，由三个产品 target 直接引用。

| 目录 | 内容 | 来源 |
|---|---|---|
| `RDPKit/` | 采集、编码、帧通道、传输、控制、显示、输入、公共类型 | 原 `M1-Skeleton/src/` |
| `ProtocolCodec/` | 控制消息 / 帧头 / 输入事件编解码、会话状态机、坐标 | 原 `P1-ClientProbe/src/` |

## 兼容层

旧路径 `M1-Skeleton/src/<File>.{h,m}`、`P1-ClientProbe/src/<File>.{h,m}` 保留为**相对软链**，指向上表的真实文件。目的是让 `M1-Skeleton/build_*.sh`、`RDPApp/build.sh` 等 12 个既有脚本和双机 runbook 中的 `cd ~/macOS-RDP/<dir>` 路径继续可用；它们不是源码副本，改一处即全链路生效。

移除条件：P2 延迟验收结束后统一迁移探针脚本与 runbook 路径，再删软链；在那之前禁止向软链目录新增文件。
