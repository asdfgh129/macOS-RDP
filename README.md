# VeilRD

**Veil Remote Desktop（帷幕远程桌面）** — 为 Intel Mac 打造的独占式远程桌面。

> 远端熄屏，眼前如本地。连接后被控端物理屏退出坐标空间，客户端按自己的规格得到虚拟桌面；**不是屏幕镜像，也不是 Windows RDP 多会话**。

正式名 **Veil Remote Desktop**，简称 **VeilRD**，中文「帷幕远程桌面」。命名决定见 `docs/DECISIONS.md` D-18。

## 当前状态

| 项 | 值 |
|---|---|
| 平台 | Intel x86_64，macOS 13 Ventura – 26 Tahoe；双端均可当 host / client |
| 设计基线 | `docs/DESIGN.md` v1.5（M1 基线，补注 §1.2.1 与 D-18 不改变基线） |
| 决策 | `docs/DECISIONS.md`，编号至 D-19 |
| 协议 | `docs/PROTOCOL.md` v1，2026-11-18 冻结 |
| 实测 | `docs/RESULTS-BY-OS.md`，**按 OS 分离，禁止跨版本外推** |
| 工程形态 | `VeilRD.xcworkspace` + 三个 target（daemon / agent / client）编译通过；第 2 轮源码已分层归位到 `Packages/`，旧探针路径留兼容软链 |

## 快速入口

```bash
# 构建三个产品 target（或只传一个 scheme：bash Scripts/build.sh VeilRD）
bash Scripts/build.sh

# 纯开发单测：M1-Skeleton + P1-ClientProbe
bash Scripts/test.sh

# 仍可用的探针入口
cd M1-Skeleton && bash build_stream_probe.sh
```

双机门禁脚本在 `P2-Dual/p2.sh`，属真机联调；按项目约定**不与纯开发轮次混跑**。

## 目录结构

```
.
├── VeilRD.xcworkspace/  # Xcode workspace（三个共享 scheme）
├── VeilRD.xcodeproj/    # 三个 target，文件引用指向 Packages 真实路径
├── Apps/          # 产品可执行层：HostDaemon / HostAgent / Client
├── Packages/      # 可复用库层：RDPKit/Sources/{Common,Capture,Codec,Frame,Transport,Control,Display,Input}、ProtocolCodec/Sources
├── Probes/        # 验证资产索引（探针目录原位保留）
├── Scripts/       # 统一 build.sh / test.sh 入口
├── Tests/         # 跨模块测试入口（占位）
├── docs/          # 设计、决策、协议、实测、测试清单
├── M1-Skeleton/   # 探针与单测；src/ 为 Packages/RDPKit 的兼容软链
├── P1-ClientProbe/ # 协议单测；src/ 为 Packages/ProtocolCodec 的兼容软链
├── P2-Dual/
└── P0-* / M1-Pre-CaptureCodec / RDPApp/   # 既有探针与过渡壳
```

三个 target 的源文件已全部指向 `Packages/` 的真实路径。`M1-Skeleton/src/` 与 `P1-ClientProbe/src/` 现在是**相对软链兼容层**，不是源码副本：保留它是为了让 12 个既有构建脚本和双机 runbook 的 `cd ~/macOS-RDP/<dir>` 路径继续有效。`Tests/` 仍为跨模块测试占位；`RDPApp/Sources/` 作为 Swift 过渡壳未搬动。

## 文档索引

- `docs/INDEX.md`：文档导航与阅读顺序
- `docs/DESIGN.md`：软件设计方案、需求、约束、架构
- `docs/DECISIONS.md`：决策记录（D-01 … D-19）
- `docs/PROTOCOL.md`：控制协议与帧头
- `docs/RESULTS-BY-OS.md`：按 OS 分离的实测结论
- `docs/P2-CHECKLIST.md` / `P2-NEXT-PLAN.md` / `P2-TONIGHT-RUNBOOK.md`：双机验收与夜间执行

## 命名与路径边界

文档与产品自称使用 **VeilRD**；仓库目录、路径占位、代码标识符 / 类名 / 二进制名、既有钥匙串条目 `CN=macOS-RDP M1 dev` 仍沿用历史名 `macOS-RDP`，避免破坏构建、实测资产与证书匹配。统一 CLI / 产品二进制名需另立决策并配套迁移。

## 许可

见 `LICENSE`（MIT 口径，依据设计约束 C-02「基座只用 MIT 组件」）。依赖与参考资产的许可证差异见 `docs/DESIGN.md` §3.4；OpenDisplay 为 GPL-3.0，仅参考行为结论，禁止复制源码。
