# VeilRD 文档索引

按阅读顺序组织。版本与日期以各文件头部为准；本索引只做导航，不重复正文。

## 1. 先读：产品与边界

1. `README.md`（仓库根）：定位、状态矩阵、快速入口、目录结构、命名边界
2. `DESIGN.md` v1.5：需求、约束（C-01…C-09）、架构、帧管线、里程碑
   - §1.2.1：VNC / RFB 与 RDP 的管线差别（为什么不是镜像）
   - §2.4.1：13–26 双角色构建与采集后端门控
3. `DECISIONS.md`：决策编号 D-01…D-21，含已作废项与理由
   - D-04 独占式会话 / D-08 远程登录 / D-12 禁屏兜底硬约束
   - D-17 客户端上屏与输入回传 / D-18 项目命名 / D-19 源码分层 / D-20 产品入口与静态库 / D-21 共享流会话节点层
4. `PROTOCOL.md` v1（冻结）：通道、状态机、控制消息、帧头 v3、错误码
5. `CHANGELOG.md`（仓库根）：全部更新按日期**倒序**归档，节内分 Added / Changed / Fixed / Documentation 并附 commit hash；本文件自身的维护提交不重复列入

## 2. 再看：事实与验收

5. `RESULTS-BY-OS.md`：**按 OS 分离的实测结论**，禁止跨版本外推
6. `P2-CHECKLIST.md`：双机验收清单
7. `P2-NEXT-PLAN.md` / `P2-TONIGHT-RUNBOOK.md`：夜间执行计划与 runbook
8. `SSH-SETUP.md`：测试机 SSH / 端口映射

## 3. 工程骨架

- `VeilRD.xcworkspace` / `VeilRD.xcodeproj`：五个 target（`RDPKit` / `ProtocolCodec` 静态库 + daemon / agent / client）与共享 scheme，已编译通过
- `Scripts/build.sh` / `Scripts/test.sh`：统一构建与测试入口；后者含跨模块集成自检与 QUIC 环回建链自检；`generate_xcodeproj.py` 为 pbxproj 唯一生成源
- 根 `Apps/`、`Packages/`、`Tests/`：产品级目录；源码在 `Packages/`（`Session/` 为第 4 轮抽出的共享节点层），三个入口在 `Apps/*/Sources/`，旧探针路径为兼容软链；`Tests/integration_selftest.sh` + `stream_session_selftest.m` 为跨模块入口
- `Probes/README.md`：验证资产索引；现有探针目录原位保留
- `M1-Skeleton/README.md`：M1 骨架源码、探针与单测说明
- `P1-ClientProbe/`、`P2-Dual/`：协议单测与双机脚本

## 约定

- **开发与测试分离**：纯开发轮次不跑双机真机；真机测试放夜间。
- **OS 分离**：Tahoe / Sequoia / Ventura 结论不得互推。
- **命名边界**：文档自称 VeilRD；仓库路径、代码标识符、钥匙串 CN 保留 `macOS-RDP`（D-18）。
- **不复制 GPL 源码**：OpenDisplay 仅参考行为结论（C-02、DESIGN §3.4）。
