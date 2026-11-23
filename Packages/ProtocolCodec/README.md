# ProtocolCodec

与传输 / 平台无关的协议库。**第 2 轮已把源码物理迁到 `Sources/`**；`P1-ClientProbe/src/` 下保留相对软链供既有脚本使用。

- `ProtocolCodec.{h,m}`：控制消息编解码（4B 长度前缀 + JSON）、帧头 v3（26B，含 `capturedAtUs`）、分片 / 重组
- `P1InputCodec.{h,m}`：输入事件编解码（§3.1）与 1000 event/s 限速
- `P1SessionState.{h,m}`：会话状态机
- `P1Coordinate.{h,m}`：归一化坐标与 Quartz 矩形换算

单测仍在 `P1-ClientProbe/tests/`（验证资产原位保留）。协议冻结版本见 `docs/PROTOCOL.md`。
