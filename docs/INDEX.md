# VeilRD 文档索引

按阅读顺序组织。版本与日期以各文件头部为准；本索引只做导航，不重复正文。

## 1. 先读：产品与边界

1. `README.md`（仓库根）：定位、状态矩阵、快速入口、目录结构、命名边界
2. `DESIGN.md` v1.5：需求、约束（C-01…C-09）、架构、帧管线、里程碑
   - §1.2.1：VNC / RFB 与 RDP 的管线差别（为什么不是镜像）
   - §2.4.1：13–26 双角色构建与采集后端门控
3. `DECISIONS.md`：决策编号 D-01…D-19，含已作废项与理由
   - D-04 独占式会话 / D-08 远程登录 / D-12 禁屏兜底硬约束
   - D-17 客户端上屏与输入回传 / D-18 项目命名 / D-19 源码分层与兼容软链
4. `PROTOCOL.md` v1（冻结）：通道、状态机、控制消息、帧头 v3、错误码

## 2. 再看：事实与验收

5. `RESULTS-BY-OS.md`：**按 OS 分离的实测结论**，禁止跨版本外推
6. `P2-CHECKLIST.md`：双机验收清单
7. `P2-NEXT-PLAN.md` / `P2-TONIGHT-RUNBOOK.md`：夜间执行计划与 runbook
8. `SSH-SETUP.md`：测试机 SSH / 端口映射

## 3. 工程骨架

- `VeilRD.xcworkspace` / `VeilRD.xcodeproj`：三个 target 壳（daemon / agent / client）与共享 scheme，已编译通过
- `Scripts/build.sh` / `Scripts/test.sh`：统一构建与单测入口
- 根 `Apps/`、`Packages/`、`Tests/`：产品级目录；第 2 轮源码已归位到 `Packages/RDPKit/Sources/{Common,Capture,Codec,Frame,Transport,Control,Display,Input}` 与 `Packages/ProtocolCodec/Sources`，旧 `src/` 路径为兼容软链；`Tests/` 仍占位
- `Probes/README.md`：验证资产索引；现有探针目录原位保留
- `M1-Skeleton/README.md`：M1 骨架源码、探针与单测说明
- `P1-ClientProbe/`、`P2-Dual/`：协议单测与双机脚本

## 约定

- **开发与测试分离**：纯开发轮次不跑双机真机；真机测试放夜间。
- **OS 分离**：Tahoe / Sequoia / Ventura 结论不得互推。
- **命名边界**：文档自称 VeilRD；仓库路径、代码标识符、钥匙串 CN 保留 `macOS-RDP`（D-18）。
- **不复制 GPL 源码**：OpenDisplay 仅参考行为结论（C-02、DESIGN §3.4）。
