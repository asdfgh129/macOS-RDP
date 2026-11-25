# Changelog

> 本项目全部值得记录的更新，按时间**倒序**排列（最新在上）。

格式约定：以日期为版本号构成版本节（`[YYYY-MM-DD]` + 里程碑简述），节内按 **Added / Changed / Fixed / Documentation** 分类，每条附短 commit hash；分类参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，Documentation 用于纯文档提交，本文件自身的维护提交不重复列入。真机结论按 OS 分离记录在 `docs/RESULTS-BY-OS.md`，决策编号见 `docs/DECISIONS.md`。

## [2026-11-25] — M2 重连清理：多会话常驻、显示事务串行、会话间复用虚拟屏

### Fixed

- fix: 多会话收尾移出控制交付队列，改为显示事务串行队列——还屏（16s+）占着交付队列会饿死下一轮的 attach/hello（客户端 `seq=1 重传 20 次仍未确认`，随后 `57`）；节点改为关闭时同步摘除本轮控制对象、新连接就地 attach，入口新增 `veild.display-tx` 串行域承载建屏/还屏/收尾，`onSessionClosed` 先放行主线程判定再入队（`0f7178f`）
- fix: 新增 `M1StreamNode endCurrentSession`——时长到由 host 主动正常挥手（bye 0.2s 后拆连接），`prepareForNextSession` 只复位标量；`attachSessionTo:` 不再排到控制队列（`0f7178f`）

### Changed

- feat: 常驻会话间复用虚拟屏——Tahoe 实测同进程销毁后再 `initWithDescriptor:` 新建的屏永远 `online=0`（mode 停 1×1、10s 超时，换 identity offset 无效），只有 create-then-destroy 的换屏路径可用；会话结束只停管线不清屏，下一轮规格相同直接沿用、不同走 `applySpecs` 换屏；物理屏整个常驻期保持禁用，进程退出统一恢复
- diag: `M1SessionCoordinator` 打印建屏/禁屏分段用时（本轮首轮建屏 8.35s + 禁屏/校验 11.54s）

### Documentation

- docs: `RESULTS-BY-OS.md` §5.44 M2 重连清理入档——`--max-sessions 2` 真机 PASS（1920×1080 17 帧 → 换屏 1280×720 23 帧、时长到收尾、退出 0、物理屏恢复），两个根因（控制交付队列饿死、销毁后重建 VD 必挂）与复用方案；单测 341/341

## [2026-11-25] — M2-C 收口：沉浸模式 / FR-07 复测与控制面健壮性

### Fixed

- fix: `M1FrameView` 出图改双缓冲——单缓冲每帧复用同一 IOSurface 指针，CA 按对象身份判定无变化不再提交，窗口冻结在首帧而解码/渲染计数照常增长（真机截图相隔 5s 逐字节相同，换样式/改 frame 才刷新一次）；交替两块 BGRA 缓冲后窗口与沉浸两种形态均实时
- fix: 控制链路重传预算 8 → 20（250ms×20 ≈ 5s）——WAN 上 RTT 尖峰/乱序下一条消息 8 次重传可能整段丢失，若丢的是 `session-update-result`，后续消息被乱序扣住，控制面永久静默而画面照流
- fix: 新增控制面静默看门狗——STREAMING 中 8s 无任何控制消息即打印、记录 error 并关闭会话（两端同规则）；链路/会话失败由静默改为 stderr 显式打印

### Added

- feat: 控制面诊断快照入 JSON/stdout（datagram 分流、链路 sent/delivered/retransmits/duplicates/held/acks/pending/failed、通道收发与解析错误），用于区分“没到 / 被扣住 / 解析错”

### Documentation

- docs: `RESULTS-BY-OS.md` §5.43 M2-C 收口入档——沉浸模式真机目测 PASS（含画面冻结根因与修复）、FR-07 keep-main 2→1 WAN 复测 5/5 PASS、首轮失败的「重传耗尽 → 控制面静默」根因与两处修复

## [2026-11-24] — M2 收口：会话内换屏（FR-07）与完整输入（FR-06）

### Added（最近更新）

- docs: `RESULTS-BY-OS.md` §5.42 M2 收口真机入档——FR-07 keep-main 2→1 WAN PASS（结果回包、窗口重绑、0 丢帧），FR-06 真机文本注入 PASS（`inputOK=2`、host 落盘逐字节一致）；沉浸模式目测与 FR-07 取档因 host WindowServer 脏态延后，已重启待补
- feat: client `--send-text MS:text` 诊断钩子（按 IME 提交格式上行 text 事件）与沉浸窗口落位打印 (`610a3c7`)

### Added

- feat: FR-07 会话内事务换屏——`session-update/result`（协议 v1.4）、驱动「先建新-验可见-再拆旧」+ 协调器回滚、Host 管线重建、Client 窗口重绑 (`7d7041b`)
- feat: FR-06 完整输入——`kind:"text"` 整串文本注入（≤256 UTF-16）、修饰键逐键 `flagsChanged`、`Cmd+Opt+F` 沉浸模式 (`7d7041b`)

### Fixed

- fix: 控制消息交付移出 QUIC 收包线程——换屏 ~2.2s 会拖死双方 ACK，250ms×8 重传预算耗尽后控制链路静默失败（帧流照常） (`7f664b6`)

## [2026-11-23] — 产品化骨架与四轮收口（VeilRD 定名 / workspace / 分层 / 静态库 / QUIC 端到端链路）

### Added（最近更新）

- docs: `RESULTS-BY-OS.md` §5.41 P2.3 基线取数条件收敛——Qoder 仅最小化（进程未挂起、mds 未暂停）8 轮 ALL PASS，各档 p50 与隔离口径差 ≤0.5ms
- docs: `RESULTS-BY-OS.md` §5.40 双屏真注入 + P2.3 基线复核入档——host 15/15 注入、光标位移确认；8 轮离屏 ALL PASS 与 §5.38 一致
- docs: `RESULTS-BY-OS.md` §5.39 M2 多屏双机 WAN 实测入档——keep-main 与全独占双屏均 PASS（138/138、981/981 解码上屏，0 丢帧，C-09 verified）
- docs: `RESULTS-BY-OS.md` §5.38 P2.3 渲染基线复测入档——离屏 8 轮无回退，CG 后端 20fps 真实流渲染 100%、0 积压
- docs: `RESULTS-BY-OS.md` §5.37 产品入口 WAN 对照入档——全独占 + C-09 PASS、`--mirror` 诊断档三轮 PASS（`9113c32`）
- docs: 新增 `docs/PRODUCT-DUAL-RUNBOOK.md` 产品入口 `--serve` ↔ `--connect` 双机实测操作单，根 README / `docs/INDEX.md` 导航同步（`613336f`）

### Added

- feat: 多屏（M2）——per-display 接收器/帧队列、关键帧与补片请求带 `displayID`（按屏限流）、Host 每屏一条管线、Client 每屏一窗并按屏回传输入；上限 8 屏（D-22，`docs/PROTOCOL.md` §3.2）
- feat: 打通产品端 QUIC 端到端链路并抽出共享会话层（第4轮） (`dc10fbc`)
- feat: 建立 VeilRD 产品骨架并完成源码分层归位 (`f1b62f4`)

### Changed

- refactor: 产品层收口，五 target 静态库化与入口自检 (`c72f4b9`)

### Fixed

- fix: 进入 STREAMING 时清零控制到达时钟，首包心跳不再把建屏空窗算成间隔；Tahoe keep-main WAN r4 门禁通过（§5.36 r3/r4，v0.66）
- fix: host 控制间隔指标在对端 CLOSED 后停止记账，host JSON 增 `maxGapAtOffsetMs`（§5.36 口径问题，v0.65）
- fix: 产品 host 入口实现 `--guardian` 兜底握手（C-12.2），keep-main 双机 WAN 闭环入档 §5.36 (`17f9883`)

## [2026-11-22] — 帧头 v3 与 P2 基线收口

### Added

- feat: 帧头 v3 内嵌采集时刻 + time-sync，取得跨机 capture→render 基线 (`6f6771b`)
- feat: M1 窗口布局快照/恢复 + 采集默认 best（§5.33/§5.34） (`f4e072b`)

### Documentation

- docs: P2.3 干净基线入档（§5.33 v0.61） (`2f3323f`)
- docs: 补充 r4 后连续显示扰动导致再次崩溃的观察 (§5.32) (`e7bb64a`)
- docs: 健康态独占复测 PASS + Path A 独占态根因定位 (§5.32) (`288afe6`)
- docs: C-09 剩余边界补测收敛——1080p/连续建屏 OS 层崩溃，Path A 独占与多屏未覆盖 (§5.31) (`bda4649`)

## [2026-11-21] — Ventura 13 采集回退、独占登录窗与双机实测

### Added

- feat: 锁屏态 CGDisplayCreateImage 后端 + 13 Path A 视觉/注入 PASS（§5.29） (`ce7092a`)
- feat: 13 host CGDisplayStream 回退后端 + 双机全链路 PASS（§5.27） (`85aca0d`)

### Fixed

- fix: 13 C-09 ScreensharingAgent 竞态规避 + 独占真机 PASS (§5.30) (`7054bc5`)
- fix: loginwindow 定向键入延时与清场 + 13 真实口令解锁 PASS（§5.29） (`771f7a3`)
- fix: startCapture 失败时不再 removeStreamOutput（Ventura 13 崩溃） (`52ab8b8`)
- 兼容 13 SDK 编译 14+ SCK API 并明确 13-26 双角色目标 (`e118f89`)

### Documentation

- docs: A-07 剩余项收敛 + p0vprobe type 命令（§5.28） (`4061a23`)
- docs: 13 host 替代采集路径调研 + CGDisplayStream 本机可用（§5.26） (`e735eea`)
- docs: 13 host 屏幕共享恢复后复测仍被 SkyLight 拒绝（§5.25） (`fe37b05`)
- docs: Ventura 13 host 建流被系统拒绝 + 崩溃修复（§5.25） (`1d1ef27`)
- docs: 1080p20 满帧门禁达成，定位 SCK 降采样瓶颈（§5.24 补测） (`9b8c77a`)
- docs+fix: 双真机跨网段 LAN 实测 PASS，修 p2.sh 路径与脚本执行位 (`6588fe2`)
- docs: Ventura client 预检通过，记录远程解锁边界 (`20ff227`)
- docs: 入档 13.3 SDK 编译与单测验证（§5.23） (`68869c6`)

## [2026-11-20] — P2 门禁、NACK 补片与独占显示配置

### Changed

- G2: host 默认按客户端规格建虚拟屏并禁物理屏，--mirror 降为诊断开关 (`2ed7d5a`)
- P2.3: 720p15 WAN 镜像/独占矩阵补测（2b9ec03）+ LAN/渲染基线缺口如实记录 (`3875a71`)
- P2.1: 窗口外分片锁死治理 + 丢弃去向诊断 (`2b9ec03`)
- P2.1: 整帧补片（frame-nack all:true）消除镜像 1080p 缺口级联 (`56af656`)
- P2.1: 定向补片 NACK（frame-nack）+ 主机分片缓存定向重发 (`dd75399`)
- P2.1: 补齐 keyframeRequestRttMs 观测指标（首个成功请求→关键帧重组） (`ff7f922`)
- P2: 独占退出恢复+C-09证据，p2.sh 参数透传与分层门禁 (`7864855`)
- P2.3.2: render_selftest 重构为四档位回归，补齐 720p/1080p 基线 (`af4e6aa`)
- P2: p2.sh 透传 host 编码宽高，支持一条命令起 720p 公网复测 (`647d36e`)
- P2.2: 补齐客户端解码尺寸断言，summary 仅独占模式判 FAIL (`e86e5ed`)

### Documentation

- docs: G2 默认建屏回归入档（§5.22）+ runbook 镜像开关说明 (`367e14b`)
- docs: 整帧补片修复与镜像 1080p20 两轮 PASS（RESULTS §5.19） (`8a2fcc3`)
- docs: NACK 公网门禁 PASS 与 P2.2 独占 C-09 跨机实测记录 (`ca3b36c`)
- docs: 操作单 commit 基线改为兼容写法（7864855/e1d6ff8） (`8f178db`)
- docs: 今晚 P2 实测操作单（P2.1 公网门禁→P2.2 独占 C-09→跨机矩阵） (`e1d6ff8`)
- 清单补 P2.1 跨公网 720p15 门禁复测命令 (`8beae4f`)

## [2026-11-19] — P2 跨公网联调与 M1-B 输入闭环

### Changed

- P2.1+P2.2: 重组容错/关键帧请求落地，虚拟屏会话冒烟通过 (`b4f20c2`)
- P2: 跨公网实测结论入库，并定下一阶段计划 (`c9c54a8`)
- host 支持无限等待（--wait-ms 0），无人值守直到 client 接入 (`df2ab9a`)
- 远程 SSH 打通，host 侧改为远程可驱动；忽略联调产物目录 (`e18fdfd`)
- P2: 远程 SSH 接入配置（无需第三方软件）+ GUI 会话包装脚本 (`d7a2a20`)
- P2: 填入公网端点 112.5.32.34:46600，跨网段超时可配 (`624cd94`)
- P2: 跨网段打洞准备——host 只需 UDP/46600，新增 --advertise 对外端点 (`3bf3885`)
- P2: 双机联调准备——--connect/--preflight、修端口与并发崩溃、操作单与脚本 (`9101589`)
- M1-B: 加手动驱动（真人动鼠标），真鼠标那一跳闭环，第 1 轮 PASS (`a749a74`)
- M1-B: 真光标驱动定位到「窗口必须前台」+ 锚点/断言/构建复现三处修正 (`bf37e16`)
- M1-B: 输入去重复跑确认 + 锁屏判据改多信号 + 记录 AX 按 cdhash 授权的坑 (`80f0361`)
- M1-B: 端到端判据通过，修锁屏判据反向 + 输入事件去重 + 加合成驱动 (`e31293f`)

### Fixed

- 修复单客户端模型不接重连，握手失败日志补全 domain 与对端地址 (`3f3d5f1`)

### Documentation

- 记录跨网段端到端首次跑通（391 帧 / 19.5fps / 0 丢帧） (`4fe5e7c`)
- 记录 GitHub 推送需绕开本地代理 (`a12cce1`)
- 记录 Sequoia 公钥并修正家目录权限判断（StrictModes 只看组/其他可写） (`f9c0bdc`)
- 记录公网映射后的本机回环复测仍失败 (`45d08c1`)

## [2026-11-18] — M1 骨架、QUIC 链路与客户端上屏

### Changed

- M1-B：上屏改 IOSurface 零拷贝（10.4ms/帧），修三处实测暴露的缺陷 (`0e1af00`)
- M1-B 第1步：客户端窗口上屏 + 输入回传（单测/离屏自检全过，端到端待解锁） (`5ff388a`)
- 帧头升 v2：fragIdx/fragCount 扩到 16 位，单帧上限 286KB → 75MB (`bdc9b5f`)
- M1-A 第5步：VT 会话预热，首帧建会话 271→60ms（解码）/406→56ms（编码） (`840cc9f`)
- M1-A 第4步：跨进程推流落盘打通，控制与视频共用一条 datagram 连接 (`b40c03e`)
- M1-A 第1/2步：QUIC 数据报通道 + 指纹钉死（D-13） (`a703761`)
- M1 骨架：会话编排 + 真实驱动 + 输入注入 + SCK 帧管线 (`61a0af3`)
- M1-Pre：采集/编码可行性探针 + 真 loginwindow 探测脚本 (`f3d529e`)
- Path A 在 Tahoe 端到端成立：登录 UI 迁移 + 密码注入解锁全通过 (`c68a66f`)
- P0-V Tahoe 复验 + P1 协议层补全：按 OS 分离结论与替代采集探针 (`2a5ef44`)

### Fixed

- 修复反复弹出的钥匙串授权框（NEG-04） (`20078f1`)
- M1-A 第3步：控制通道跑通 + 定位并修复握手无错误码卡死的真因 (`38e3d87`)
- D-12：修复禁屏兜底链路四处断裂（首次全禁屏实测致整机黑屏） (`7792e88`)
- 修正 V-02 假阴性：区分锁屏/屏睡/屏亮，撤回 Path A 过度否定 (`8233c3e`)

## [2026-11-17] — 设计决策定型与 P0/P1 探针

### Changed

- V-01/V-03 通过 + V-04 实测：root daemon 受 TCC 阻挡，用户会话锁屏捕获/注入通过 (`501d61b`)
- 决策 D-01~D-08：会话模式形态定型 + V-04 root daemon 探针 (`38c710d`)
- P1-ClientProbe: 协议编解码模块与单测（69 断言全过） (`81b97a0`)

### Fixed

- P0-TahoeProbe: A-01/A-04 补测与缺陷修复 (`baa7ad2`)

## [2026-11-16] — 设计方案草案与控制协议 v1

### Fixed

- P0-TahoeProbe: 修复 Sequoia 自动镜像致虚拟屏不可见，双屏+H.264 基线通过 (`5d71044`)

### Documentation

- 设计推进：控制协议 v1 草案 + P1 坐标变换模块与单测 (`15e06a0`)
- docs: macOS-RDP 软件设计方案 v0.2-draft (`1dd04c6`)

## [2026-11-14] — 仓库迁移与真机前置准备

### Changed

- P0-TahoeProbe: 按 OS 版本分流建屏策略并加固 WindowServer 安全 (`8fc95d7`)
- chore: 强制 LF 行尾并补充仓库迁移说明 (`0ab741d`)

### Fixed

- P0-TahoeProbe: 真机验证前的静态审查修复、一键诊断脚本与交接清单 (`d6e3e0a`)
