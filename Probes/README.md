# Probes（验证资产索引）

本目录是**逻辑索引占位**，现有探针目录**原位保留、不移动**，以免破坏 `cd ~/macOS-RDP/<dir>` 与已有构建脚本。

| 目录 | 验证内容 |
|---|---|
| `P0-TahoeProbe/` | Tahoe 建屏 / 捕获 / 编码 / HiDPI / 崩溃取证 |
| `P0V-RootDaemon/` | root daemon 能力侦察 |
| `P0V-SessionRecon/` | 会话枚举、GUI 会话判定、loginwindow 补测资产 |
| `P0V-DisplayIsolation/` | 显示隔离 / 禁屏 / 应急恢复 |
| `P0V-AltCapture/` | 替代采集路径 |
| `M1-Pre-CaptureCodec/` | 采集 + 编码性能前置验证 |
| `M1-Skeleton/` | 探针与单测；`src/` 已改为指向 `Packages/RDPKit/Sources/` 的兼容软链 |
| `P1-ClientProbe/` | 协议 / 输入 / 状态机单测；`src/` 为 `Packages/ProtocolCodec/Sources/` 的兼容软链 |
| `P2-Dual/` | 双机联调脚本与结果 |

`RDPApp/` 仍是过渡期的 Swift UI 壳，为避免改动 Swift 构建路径未物理搬到 `Apps/Client/`。真机结论按 OS 分离记录于 `docs/RESULTS-BY-OS.md`。
