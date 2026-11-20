# macOS-RDP 实测结论（按 OS 分离）

| 项 | 值 |
|---|---|
| 版本 | v0.36-draft |
| 日期 | 2026-11-20 |
| 原则 | **结论绑定具体 OS build 与机器，禁止跨版本外推**。同一判据在 Sequoia 与 Tahoe 分别记录，未测就写未测。 |
| 上位文档 | `docs/DESIGN.md` §8、`docs/DECISIONS.md` |

---

## 1. 环境标识

| 标签 | OS | Build | 机器 | 备注 |
|---|---|---|---|---|
| **Sequoia** | macOS 15.5 | 24F74 | Macmini8,1 / i5-9500 / x86_64 | 2026-11-17 晚间实测机；屏幕 3 块（含竖屏） |
| **Tahoe** | macOS 26.5.2 | 25F84 | Macmini8,1 / i5-9500 / x86_64 | 2026-11-17/18 白天实测机；物理屏 2 块 |

> 2026-11-17 早前文档写过的 26.7.3 未在该机复现，已作废。

---

## 2. P0 建屏 / 捕获 / 编码

| 判据 | Sequoia 15.5 | Tahoe 26.5.2 |
|---|---|---|
| 私有 SPI 解析 | ✅ | ✅ `allClassesResolved=true`、`missing=[]` |
| 单屏 verify | ✅（P0 基线，2026-11-16） | ✅ 2026-11-17 11:55，`pass=1`、offset=0、未触发 identity walk |
| SCK 捕获 | ✅ | ✅ `HAS_CONTENT`，判黑阈值修复后 0 黑帧 |
| H.264 硬编环回 | ✅ | ✅ `encode_rc=0`，19 帧、0 编码错误 |
| HiDPI | 未专项实测 | ✅ 1280×720@2x → 2560×1440px；硬约束：`initWithDescriptor:` 一次给足 |
| 多屏容量 | 未专项实测 | ✅ 2 物理 + 4 虚拟 = 6 屏同时 online/active 且全部可捕获 |
| 建屏耗时 | 未测 | ⚠️ create→promote ≈11.3s（M1 优化项） |
| 运动场景帧率/延迟 | 未测 | 未测（静态 SCK 按变化送帧，fps/P95 不可当结论） |

---

## 3. P0-V 独占会话能力

### 3.1 V-01（禁一块物理屏）

| 项 | Sequoia 15.5 | Tahoe 26.5.2 |
|---|---|---|
| 结果 | ✅ PASS（2026-11-17 22:15） | ✅ PASS（2026-11-18 08:56） |
| active 集合收缩 | ✅ | ✅ |
| 虚拟屏 `HAS_CONTENT` | ✅ | ✅ minLumaMean=151 |
| SCK 干净 / 指针 0 偏差 | ✅ | ✅ |
| 输入注入 | ✅ `axTrusted=1` | ✅ `axTrusted=1`，move 2797 |
| 20s 唤醒观察 | ✅ 0 次重新 enable | ✅ 0 次重新 enable |
| 恢复 | ✅ bounds/主屏精确回原值 | ✅ mismatches 为空 |
| 证据 | `P0V-DisplayIsolation/README.md` §实测 | `/tmp/p0v-tahoe-one.json` |

### 3.2 V-03（禁全部物理屏）

| 项 | Sequoia 15.5 | Tahoe 26.5.2 |
|---|---|---|
| 核心机制 | ✅ PASS（2026-11-17 22:35） | ✅ 通过：active 只剩虚拟屏、指针 0 偏差、注入通过、20–30s 无重新 enable、恢复 OK |
| SCK 捕获 | ✅ 60fps `HAS_CONTENT` | ❌ **不可靠**：4 次运行 1 次全黑（34/34）、2 次多数帧黑（45/61、22/39）、1 次放白色窗口仍全黑（62/62） |
| 合成是否停止 | 否 | **否**：禁用期间系统截图有完整桌面（`/tmp/tahoe-v03-main.png`） |
| 重建子项（零屏再建第 2 块） | ❌ 触发 `canonical_mirror_master` 断言、WindowServer 注销；后改为检测停放槽位自动跳过 | 未做（沿用自动跳过；平台级崩溃点不重试） |
| 结论 | V-03 核心关闭；重建子项改由 M1「先建齐后禁屏」规避 | **A-08 在 Tahoe 未关闭**：显示隔离成立，`SCK + 零 active 物理屏` 采集路径不成立 |
| 证据 | `P0V-DisplayIsolation/README.md` §实测 | `/tmp/p0v-tahoe-all{,2,3,4}.json` |

### 3.3 V-02（锁屏态建虚拟屏 + 采集）与 V-04d（登录窗态禁物理屏）

**状态区分（2026-11-18 10:40 更正）**：此前把三种状态混为一谈，导致 V-02 被误判为失败：

| 状态 | 判据 | CG active | SCK displays | 虚拟屏 active |
|---|---|---|---|---|
| 锁屏 + 屏亮（caffeinate 先于 lock） | `screenIsLocked=1`、无 display sleep 断言 | 2 块物理屏 | 2 块物理屏 | ✅ 1 |
| 锁屏 + 屏睡（2-3s 后自动） | `screenIsLocked=1`、display sleep | 0 | 0（**SCK 也看不到**） | ✅ 1（建屏后） |
| 真登录窗（loginwindow / 未登录） | `loginDone=0` 或不同 auditID | 未测 | 未测 | ⏸ **延后到 M2 借测机（D-11，2026-11-18 15:30 用户定）**，不占用主力机。资产已备齐：`P0V-SessionRecon/gui_session_probe.m`（只读判定 GUI 会话 + 抓屏 luma）与 `run_loginwindow_probe.sh`（守卫 `loginDone=0` → preflight → 自动 `bsexec` 重入 → 建屏/禁屏/采集）。已知障碍：SSH root 不在 Aqua session，需 bsexec 绕过；preflight 区分「不在会话」(10) 与「TCC 拒绝抓屏」(11)。已关闭的 A-08/A-09 是 `loginDone=1` 锁屏态，二者不等价 |

| 项 | Sequoia 15.5 | Tahoe 26.5.2 |
|---|---|---|
| V-02 | 未测 | ✅ **成立**（2026-11-18 10:49）：锁屏+屏亮态下虚拟屏 4128835 `online=1/active=1`；`--focus` 与无 focus 两轮，`disable` 后 active 只剩 `[4128835]`、恢复 OK；此前 `active=false` 是探针 `waitUntilUsable` 提前退出 + 脚本 `awk $3` 取错 ID 的假阴性（捕获从未执行） |
| V-02 采集（屏睡态） | 未测 | SCK `NO_FRAMES`；`CGDisplayCreateImage` `HAS_CONTENT` mean=163；截图仅壁纸（`/tmp/tahoe-r3-lockscreen.png`）。**屏睡态不满足 Path A 采集判据**，需 caffeinate 先于 lock 或等价防睡眠 |
| V-02 采集（屏亮态） | 未测 | 三路径全 `HAS_CONTENT`：SCK 50 帧；`CGDisplayCreateImage` mean≈148/var≈1650；`CGWindowListCreateImage` mean≈149/var≈1550（`/tmp/tahoe-20261118-r4-capture.json`） |
| V-04d | 未实现 | ✅ **成立**（2026-11-18 10:49/10:52 两轮）：禁掉全部物理屏后，**登录 UI 完整渲染到虚拟屏**——截图含 `Wed Nov 18`、时钟、`bemin` 头像与 `Enter Password` 输入框（`/tmp/tahoe-20261118-r5-shot.png.disabled.png`、`/tmp/tahoe-20261118-r6-shot.png.disabled.png`）。v0.3「仅壁纸、登录框未迁移」结论作废：此前探针只建屏未禁屏，登录 UI 仍留在物理屏上 |
| 登录框迁移触发条件 | — | **「零 active 物理屏」是充分条件，与光标聚焦无关**：r5 移光标+点击、r6 不移动，两轮禁屏后截图均出现完整登录框；`--focus` 非必需，产品实现可省略该步 |
| 证据 | — | `/tmp/tahoe-20261118-r4-t{0,1,2,3,5}.json`、`/tmp/tahoe-20261118-r5-{migrate,inject}.json`、`/tmp/tahoe-20261118-r6-{migrate,inject}.json`、两张 `.disabled.png` 截图 |

---

## 4. V-04 远程登录（D-08）

| 项 | Sequoia 15.5 | Tahoe 26.5.2 |
|---|---|---|
| root LaunchDaemon 路径 | ❌ 失败：TCC 只记路径条目（`client_type=1`），`axTrusted=0`，SCK 6s 超时；无 GUI 会话 | 未重测（已知门槛是 TCC 身份与 GUI 会话归属，不是 root 特权） |
| V-04a 用户态锁屏捕获 | ✅ 真实登录界面，`HAS_CONTENT` | ✅ 通过：`session.screenIsLocked=true`、`HAS_CONTENT`、17 帧、`minMean=134`、0 黑帧（`/tmp/tahoe-20261118-r2-v04a.json`） |
| V-04b 用户态定向注入 | ✅ `INJECTION_ACCEPTED_UI_CHANGED`，152/256 格变化 | ✅ **通过**（2026-11-18 10:49/10:52 两轮）：`INJECTION_ACCEPTED_AND_UNLOCKED`、256/256 格变化、`maxCellDiff=196`；注入全程由助手程序化执行，无人工干预（`/tmp/tahoe-20261118-r5-inject.json`、`r6-inject.json`） |
| V-04c 正确密码解锁 | ⏸ 主动跳过、记为未测（需真实凭据） | ✅ **通过**：用户提供真实凭据，经环境变量 `P0V_PW` 在运行时注入（`P0V-SessionRecon/run_patha_*.sh` 脚本与日志均不含明文）；两轮 `sessionAfter`：`screenIsLocked=false / available=true / loginDone=true / onConsole=true / auditID=100001` |
| V-04d 登录窗建屏+禁屏 | 未实现 | ✅ 通过：禁全部物理屏后登录 UI 完整出现在虚拟屏（见 §3.3） |
| 结论 | loginwindow 不阻止用户会话进程捕获/定向注入；推荐形态改为正确签名的用户态 App | ✅ **Path A 在 Tahoe 26.5.2 端到端成立（2026-11-18 10:52）**：全程锁屏+屏亮 → 建 active 虚拟屏 → 禁全部物理屏 → 登录 UI 迁移到虚拟屏且三路径可捕获 → 密码注入成功解锁。前置条件：必须先防显示睡眠（caffeinate 或产品内断言）；采集在屏亮态 SAF，屏睡态 SCK 无帧。D-08 四项全过，**不再需要回退 Path B** |

---

## 5. 替代采集路径（P0V-AltCapture）

| 路径 | Sequoia 15.5 | Tahoe 26.5.2 |
|---|---|---|
| SCK（基线） | 已知 V-03 `HAS_CONTENT` | ⚠️ 不稳定：V-03 中全黑/多数帧黑；`altprobe` 中虽 `HAS_CONTENT`，但禁屏后仅 2–4fps，不可用 |
| `CGDisplayCreateImage` | 未测 | ✅ 稳定 `HAS_CONTENT`：1280×720 时 `minMean=39/maxVar=1506`，1920×1080 时 `minMean=37/maxVar=1562`，0 黑采样；恢复 OK |
| `CGWindowListCreateImage` | 未测 | ✅ 稳定 `HAS_CONTENT`（修正禁屏后 bounds 重排导致区域错位后），数据与上者一致 |
| 执行入口 | `P0V-AltCapture/altprobe` | 同左 |
| 证据 | — | `/tmp/p0v-alt-tahoe3.json`、`/tmp/p0v-alt-tahoe-1080.json` |

**结论（v0.6 更正）**：公开抓屏 API 能稳定拿到内容，但**端到端帧率不成立**，见 §5.1。SCK 帧率读数必须区分「是否带编码环回」——不带编码的 55fps 是按内容变化送帧的假象，见 §5.2。

### 5.1 M1-Pre 采编链路实测（`M1-Pre-CaptureCodec`，2026-11-18 11:27–11:30）

把 `CGDisplayCreateImage → CVPixelBuffer → VT H.264 → VT 解码` 整条链路接起来实测（`capturecodec`）：

| 场景 | 分辨率 | verdict | 实际 fps | 抓帧 avg/p95 ms | 转换 avg/p95 ms | 编码入队 p50 ms | 整机 busy | 本进程核数 |
|---|---|---|---|---|---|---|---|---|
| `--no-disable` | 1920×1080 | PASS | 1 | 282 / 356 | 60 / 96 | 1.2 | 99% | 0.14 |
| 禁全部物理屏 | 1920×1080 | PASS | 4 | 125 / 168 | 47 / 94 | 0.1 | 99% | 0.21 |
| 禁全部物理屏 | 1280×720 | PASS | 7 | 95 / 124 | 17 / 23 | 0.1 | 77% | — |

三组均：抓帧/编码/解码计数一致（20/20/20）、0 黑帧、0 编码错误、恢复 OK；`minLumaMean=29/maxVar=1278`。证据：`/tmp/m1-pre-nodisable.json`、`/tmp/m1-pre-disable.json`、`/tmp/m1-pre-disable-720.json`，截图 `/tmp/m1-pre-nodisable.png`（真实桌面壁纸+菜单栏，非黑）。

**关键结论**：

1. **链路成立**：D-09 的路径选择正确，零物理屏下端到端可用、无黑帧、无编码错误。
2. **帧率不成立**：`CGDisplayCreateImage` 单次抓帧固定成本 95–282ms 是绝对瓶颈；降到 720p 只从 125ms 降到 95ms，说明不是像素拷贝开销而是 API 的系统级同步成本。**1080p60 / <30ms（NFR-01/03）达不到，差 4–8 倍。**
3. **CPU 记账**：整机 busy 77–99%，本进程仅 0.14–0.21 核 —— 开销在 WindowServer/系统合成侧，不在编码进程。NFR-05 若按整机口径不达标。
4. ~~**SCK 对照反转**：55fps~~ —— **v0.6 撤销此判断**：该 55fps 读数来自 `withEncoder:NO`，`encodedFrames=0`、首帧延迟 847ms，是 SCK 按内容变化推送的帧计数，不是可用编码帧率。带编码环回的真实数据见 §5.2。
5. **对 M1 的影响**：60fps 不能建立在这条同步抓屏路径上。**M1 帧管线参数暂不冻结**，需先评估：① 抓帧与编码流水线并行掩盖 100ms 延迟；② 对比 SCK 编码环回真实帧率（§5.2）；③ 按 NFR-04 降规格。

### 5.2 SCK 编码环回真实帧率（`--sck-only`，2026-11-18 11:32–11:35）

为排除「两条采集链路在同一进程串行、争抢 WindowServer」的污染，加 `--sck-only` 开关让 SCK 编码环回独占系统：`SCStream → VT H.264 → VT 解码`（复用 `PipelineProbe captureDisplayID:withEncoder:YES`）。

| 场景 | 编码 | verdict | 实际 fps | 帧数 | 编码/解码帧 | 首帧延迟 | 黑帧 | 编码入队 p50/p95 |
|---|---|---|---|---|---|---|---|---|
| 禁屏 1080p，`withEncoder:NO`（对照） | 否 | HAS_CONTENT | ~~55~~ 假象 | 55 | **0 / 0** | 847ms | 0 | — / — |
| 不禁屏 1080p，`withEncoder:YES` | 是 | HAS_CONTENT | 2 | 11 | 11 / 11 | 1031ms | 0 | 9.5 / 437ms |
| 禁屏 1080p，`withEncoder:YES` | 是 | HAS_CONTENT | **18** | 73 | 73 / 73 | 739ms | 0 | — / — |

证据：`/tmp/m1-pre-disable.json`（无编码对照）、`/tmp/m1-pre-sck-only-nodisable.json`、`/tmp/m1-pre-sck-only-disable.json`。

**关键结论（更正 §5.1 第 4 条）**：

1. **55fps 是假象**：不带编码时 SCK 按内容变化送帧，静态桌面下 1 秒内推 55 帧，但 `encodedFrames=0`、首帧要 847ms。它不代表可用帧率，不能作为路径选型依据。本项目历史上已两次栽在「静态 SCK fps 不可当结论」（README §15 性能警告、A-05），本次是第三次同类陷阱，已拦下。
2. **带编码的真实上限**：SCK 在禁屏独占下达 **18fps**（vs `CGDisplayCreateImage` 的 4fps），是更好的采集路径，但**同样远达不到 60fps**；不禁屏时降到 2fps，说明物理屏在线的合成负载会严重拖慢两条路径。
3. **首帧延迟 739–1031ms**：远超 NFR-FR-05「首帧 <1s」且贴近上限，双机场景会更差。
4. **D-09 决策修正**：SCK 不是「不可用」而是「绝对性能也不达标但相对更优」。M1 主路径应优先 SCK（原生 IOSurface、禁屏下 18fps、0 黑帧），`CGDisplayCreateImage` 降为兜底；**但两者都撑不起 60fps，必须同时决策降规格或流水线优化**，见 D-10。

---

### 5.3 负结果：首次禁屏独占实测导致整机黑屏（2026-11-18 16:05，Tahoe）

**现象**：`pipeline_kiosk_probe` 首次运行后屏幕全黑，键盘鼠标无响应，无法唤醒、无法重新进入系统，最终强制重启。重启后显示拓扑自动恢复（`P0VCommitScopeSession` 生效），无持久化损坏。

**结论**：不是 SPI 失效，也不是 WindowServer 崩溃，而是**探针自身的兜底链路四处断裂**，把一次可恢复的实测变成了整机不可用。详细根因与强制约束见 `DECISIONS.md` D-12，撤回/纠正如下：

| # | 断裂点 | 证据 | 修复 |
|---|---|---|---|
| 1 | 守护进程从未运行 | `./pipeline_kiosk_probe --guardian … --parent-pid 1` → `exit=2` + 打印 usage（探针 `main` 没有该分支）；同期守护日志缺失 | `--guardian` 分支 + `<snapshot>.guardian-ready` 就绪握手，握手失败即禁止禁屏 |
| 2 | 快照在虚拟屏创建后拍 | 快照文件里含 1920×1080 虚拟屏记录，`main` 为虚拟屏 | 快照前移到 `prepareSessionShieldError:`（建屏前） |
| 3 | 禁屏把虚拟屏一起禁掉 | 探针传 `keepIDs:@[]`，驱动按「active − keep」全禁 | keep 自动并入会话虚拟屏；禁屏后自检 active 非空 |
| 4 | 零显示通过了安全检查 | C-09 判据 `active ⊆ 虚拟屏` 对空集恒真 | 新增 `M1IsolationViolation()`，空 active 判违规 |

**恢复过程**（供以后再遇到时照抄）：`recover_displays` → `recover_v2`（清掉 1920×1080 ghost 1104977159）→ `recover_v4`（origin jitter 强制 commit）→ `recover_v5`（消除布局缺口）；最终仍需重启。教训是**这些工具都只能救「拓扑错位」，救不了「零显示 + 无兜底」**，所以正确做法是让这种状态无法发生。

**对 M1 的影响**：帧管线在禁屏条件下的性能数据仍为空（本次未取得有效数据）。重新开测前的强制前置：`./pipeline_kiosk_probe --preflight` 必须通过。D-10 的 20fps 目标档继续待实测。

### 5.4 禁屏独占下的帧管线真实性能（修复后首次有效数据，2026-11-18 16:34，Tahoe）

`pipeline_kiosk_probe --spec 1920x1080 --duration-ms 10000`，SCK `SCStream` → VT H.264 → 协议分片 → 环回重组/解码，全部物理屏禁用、只留虚拟屏（C-09 校验通过）。

| 指标 | 数值 |
|---|---|
| 采编发 | captured 182 / encoded 181 / sent 181（dropPreEnc 0、encFail 0、sendFail 0） |
| 环回解码 | decoded 181 / dropped 0 / decodeFail 0 / malformed 0（解码 1920×1080） |
| 关键帧 | 5（2s 间隔 + `ForceKeyFrame` 生效） |
| 分片 / 负载 | 908 片、973 289 B（平均 1072 B/片，未触发 255 片上限） |
| 码率 | 610 kbps（0.12 bpp @ 1080p20） |
| 报告帧率 | 14.2 fps（**含首帧 3924ms 启动开销**） |
| 稳态帧率 | ≈20.6 fps（首帧后 181 帧 / 8.8s），与目标 20fps 吻合 |
| 首帧延迟 | 3924ms（明显劣于 M1-Pre 的 739–1031ms，疑与禁屏后首次合成有关，待复测） |

**判读**：

1. **D-10 的 20fps 目标档在禁屏独占条件下可达**：稳态 ≈20.6fps、零丢帧、零解码失败，说明「禁物理屏 → SCK 满速」这条假设成立；14.2fps 的全窗口读数是被 3.9s 首帧拖低的算术结果，不能当作稳态能力。
2. **首帧 3.9s 是新的待查项**：M1-Pre 同链路首帧 739–1031ms，本次退到 3924ms。候选原因：禁屏后登录 UI 迁移引起的合成重建、或虚拟屏首次被 SCK 绑定。NFR-FR-05「首帧 <1s」仍不达标，需要单独复测（至少 3 轮取样）。
3. **60fps 仍无证据**：本次未测高帧率档，20fps 是当前唯一被证实可达的档位。
4. **A-02 保持开放**：本次是主机内环回，不含网络与客户端渲染，glass-to-glass 仍待 P2 双机打点。

数据：`/tmp/m1-kiosk-full.json`（环回）/ `/tmp/m1-kiosk-halfdisable.json`（半禁屏对照 1.8fps）。

---

### 5.5 QUIC datagram 帧通道实测（M1-A 第 1/2 步，2026-11-18 17:0x，Tahoe）

`quic_probe`：Network.framework QUIC datagram flow（D-13），本机环回 127.0.0.1，客户端与服务端同进程。
压测走的是生产同一条路径：`M1FrameSender`（16B 帧头 + 1150B 分片）直接接在 QUIC sink 上。

| 项 | 数值 |
|---|---|
| 协商 datagram 上限 | **1497 B**（`nw_quic_get_stream_usable_datagram_frame_size`） |
| 分片投递（400 帧 × 3000B，2ms 节奏） | 1200/1200 分片、**1,219,200 B**、完整帧 400/400 |
| 丢失 / 重复 / 乱序 / 载荷错 | **0 / 0 / 0 / 0** |
| 吞吐 | 9.6 Mbps（1.01s 跨度），全程无背压失败 |
| 超限拒发 | 3000B > 1497B → 本地拒绝（未交给 QUIC 截断） |
| 错误指纹 | 12–25ms 内 `failed`，报出期望/实际指纹前缀 |
| 握手耗时 | p50 ≈ 17ms（10 次：13.1–83.6ms），另有 2 次 **6.2s / 10.9s** 离群 |
| **瞬时突发 1200 分片** | 7.0ms 内全发完 → 完整 677、**整帧丢失 523（43.6%）**、零重复零乱序 |

**判读**：

1. **D-01 的 QUIC datagram 路径在 Tahoe 上成立**：零丢失零乱序，1500B 级 datagram 可用，
   1150B 分片距 1497B 上限还有 23% 余量。
2. **瞬时突发丢 43.6%** 是本次最关键的工程事实：QUIC datagram 没有重传，拥塞窗口满即丢，
   且是整帧级别的丢弃（分片同批发出，一起被丢）。⇒ 发送侧必须按 `targetFps` 节奏投递，
   「先攒后发 / 有多少发多少」的写法会直接毁掉画面。反过来，这也证明 PROTOCOL §4
   的「缺口 → 请求关键帧」不是过度设计。
3. **偶发 6–11s 握手**是 UX 级问题（用户看到「连接中」卡住），疑为 QUIC Initial 重传退避；
   在接控制通道（第 3 步）前必须定位，否则会被误判成「服务端没响应」。
4. 指纹拒绝路径必须**主动取消连接**：仅 `complete(false)` 时客户端会吊在 preparing，
   实测 20s 仍无结论（见 D-13 C-13.3）。

数据：`/tmp/m1-quic-probe-1200.json`、`/tmp/m1-quic-probe.json`。

---

### 5.6 控制通道端到端 + 三个负结果的更正（M1-A 第 3 步，2026-11-18 18:0x–18:5x，Tahoe）

`control_probe`：8 态状态机 + 控制帧跑在真实 QUIC 连接上，控制流走 `M1ControlLink`
（datagram 之上自建 seq/累计 ACK/重传，D-14），本机环回。

| 项 | 结果 |
|---|---|
| 同进程双端自检（`--self`） | **5/5 轮通过**；状态序列双端逐条一致 |
| 状态序列 | `DISCOVERED → TLS_CONNECTED → PAIRED → NEGOTIATED → DISPLAYS_READY → STREAMING` |
| sessionID | 双端一致（`session-ready` 协商值相同） |
| 控制帧计数 | client 发 2 / host 收 2；host 发 3 / client 收 3（含 `bye` 在关闭前送出） |
| 握手耗时 | **13.5–19.3ms**（修复后 p50≈15ms，10 轮无离群） |
| 两进程 `--host` / `--client` | 通过，握手 28–121ms，host 多一个终态 `CLOSED` |
| 单测 | `test_skeleton` **148 断言全过**（含粘包、逐字节拆包、坏长度前缀、TOFU 全序列、配对码、指纹不符拒绝） |
| loopback UDP 裸测 | 2000×1200B 突发 **0 丢包**（排除网络层） |

#### NEG-02（重要更正）握手「随机 6–11s 离群 / 必失败」的真因：securityd 授权阻塞

此前 §5.5 把偶发 6–11s 握手记为「疑为 QUIC Initial 重传退避」，并把同一身份时好时坏
归因于「证书材料随机损坏」。**两个判断都不对。** 卡住时 `sample` 抓到的主线程栈是：

```
SecKeyCreateSignature
  → SecKeyRunAlgorithmAndCopyResult → SecKeyCopyDigestForMessage
  → SecKeyRSACopyEMSASignature → SecCDSAKeyCopyOperationResult
  → CSSM_SignData → Security::SecurityServer::ClientSession::generateSignature
  → mach_msg                          ← 永久等待 securityd
```

服务端在 TLS 里发 `CertificateVerify` 时要签名，而签名被 keychain ACL 授权卡住：
securityd 拉起 SecurityAgent 授权框（实测进程存在），后台 CLI 永远等不到答复。
后果是 QUIC 服务端发不出证书，客户端 `nw_connection` 停在 `preparing`（state 2）
直到超时——**没有任何错误码**，表现与「对端没监听 / 网络不通」完全一样。

根因是 `SecPKCS12Import` 不带 `kSecImportExportKeychain` 时会把条目写进**登录钥匙串**并持久化，
ACL 里记的是「当时那个二进制」。ad-hoc 二进制每次重建 cdhash 都变，后续进程签名时
ACL 判定不符 → 走授权 → 阻塞。所以现象才会像「同一张证书时好时坏」「换个构建就好」。

**修复**（`M1QuicTransport.M1CopyIdentity`）：

1. 导入到**进程私有的一次性临时钥匙串**（`SecKeychainCreate` + `kSecImportExportKeychain`，
   `atexit` 删除），不再污染/复用登录钥匙串条目；
2. ACL 显式信任**当前进程**（`SecTrustedApplicationCreateFromPath(NULL)` → `SecAccessCreate`），
   签名不再问 securityd；
3. 同一 p12 在进程内只导入一次（按 路径+密码+size+mtime 缓存），避免重复条目。

修复后同一张曾「必挂」的证书 13.5–19.3ms 稳定握手。

> 副作用已清（2026-11-18 19:00）：早期实现写进登录钥匙串的 30 张 `CN=macOS-RDP M1 dev`
> 测试证书已删除，见 NEG-04。后续可用 `M1-Skeleton/cleanup_stale_identities.sh` 复查。

#### NEG-01（结论更正）QUIC stream 模式并非不可用

此前记「QUIC 普通流模式在本机永远握不上手（永远停在 `preparing`）」，据此定的 D-14。
用 `M1_QUIC_FORCE_STREAM=1` 复核：**握手正常完成，64.6ms / 80.4ms**。
当时的失败同样是 NEG-02 的签名阻塞，与 stream/datagram 无关。

D-14 因此改为按「一个 `nw_connection` 只能承载一条流」立论，而不是按「stream 模式坏」——
见 `DECISIONS.md` D-14。本次 stream 模式下控制帧计数为「发 1 / 收 0」属预期：
帧仍按 datagram 发送，stream 模式下没有 datagram flow。

#### NEG-03 走错方向的几次假设（记录以免重犯）

| 假设 | 证伪方式 | 结论 |
|---|---|---|
| 应用防火墙 / loopback UDP 丢包 | 裸 UDP 2000×1200B 突发 0 丢失 | 排除 |
| 证书材料随机损坏（重生成就好） | 同一 p12 在修复前 8 次全挂、修复后同文件稳定通过 | 排除，是 ACL 不是材料 |
| 重复导入 p12 破坏私钥 | 单次导入仍阻塞；临时钥匙串 + ACL 后两次导入也无碍 | 排除（缓存仍保留，理由变为避免重复条目） |
| 新编出的二进制才有问题 | 同一二进制在 securityd 条目被授权后行为改变 | 假象：真实变量是钥匙串里那条 ACL |

#### NEG-04 反复弹出「wants to sign using key "imported Private Key"」授权框

**现象**：修复 NEG-02 之后，运行探针时屏幕上仍会不断弹出钥匙串授权框：

```
quic_probe wants to sign using key "Imported Private Key" in your keychain.
The authenticity of "Imported Private Key" cannot be verified. To allow this,
enter the "login" keychain password.      [Password: ____]  [Always Allow] [Deny] [Allow]
```

一次压测会同时堆出十几二十个（每个握手一次），全部盖在桌面上。

**根因**（两个叠加）：

1. **仓库里有旧二进制**。所有探针共用 `M1QuicTransport`，但 NEG-02 只改了源码，
   `quic_probe`（18:01）、`pipeline_probe`（17:07）、`pipeline_kiosk_probe`（17:07）、
   `driver_probe`（16:27）都是修复前（18:48）编的，仍走「导入登录钥匙串 + 持久 ACL」的旧路径，
   每个握手都会触发一次授权判定。弹窗里出现 `quic_probe` / `rdpd` / `control_probe`
   三个不同进程名，正是这三拨二进制各自在跑。
2. **代码里留着降级分支**。临时钥匙串创建失败时，原实现会静默回退到默认（登录）钥匙串——
   那正好是产生持久 ACL 条目的路径。一次 `SecKeychainCreate` 失败就能让弹窗重新长出来。

**修复**：

1. 全部探针重建（`build_quic_probe.sh` / `build_pipeline.sh` / `build_kiosk_probe.sh` /
   `build_driver.sh` / `build_control_probe.sh` / `build_tests.sh`）；
2. `M1CopyIdentity` **删掉回退分支**：临时钥匙串拿不到就明确失败并给出原因，
   宁可不握手也不写登录钥匙串；
3. 临时钥匙串文件名含 PID，`kill -9` 会留残留导致下次 `SecKeychainCreate` 报「已存在」，
   创建前先 unlink（文件名含本进程 PID，不可能是别人的）；
4. 新增 `cleanup_stale_identities.sh`：默认只列出登录钥匙串里 `CN=macOS-RDP M1 dev` 的
   残留证书，`--delete` 才删（只删证书，不删私钥——删除私钥本身还会弹授权框且不可逆）；
5. 已执行清理：删除 30 张残留证书，`security find-certificate` 复查为 0。

**验证**（清理后同一台机器）：

| 项 | 结果 |
|---|---|
| `control_probe --self --rounds 5` | 5/5 通过，握手 12.4–14.7ms |
| `quic_probe` 默认参数（500 帧） | 退出码 0，500 帧→493 完整，缺片 0 |
| `test_skeleton` | 148 断言全过 |
| 跑完上述全部后 `pgrep -x SecurityAgent` | **无进程**（即未产生任何授权请求） |

**遗留**：登录钥匙串里仍有 29 条 `Imported Private Key` 私钥条目（对应已删的证书）。
它们已没有调用方，不会再弹框；删除需要 `SecItemDelete` 且会触发授权框，故未处理。
如需彻底清掉，可在「钥匙串访问 → 登录 → 密钥」里按标签手工删除。

---

### 5.7 跨进程推流落盘（M1-A 第 4 步，2026-11-18 19:5x–20:0x，Tahoe）

`stream_probe`：host 进程 SCK 采集 → VT 编码 → `M1FrameSender` → QUIC datagram；
client 进程重组 → VT 解码 → 落 PNG。控制通道与视频共用**同一条 datagram 连接**，
靠首字节魔数分流（`0x43 'C'` 控制 / `0x4D 'M'` 帧分片），即 D-14 C-14.2 的验证点。

两轮验收（1920×1080 降采样，20 fps 目标，双进程在同一台机器 loopback）：

| 指标 | round 1 | round 2 |
|---|---|---|
| 双端状态序列 | 一致到 STREAMING | 一致到 STREAMING |
| host 采集/编码/发送 | 113 / 112 / 112 帧 | 57 / 55 / 54 帧 |
| 分片数 / 载荷 | 379 / 374 KB | 241 / 237 KB |
| host 发送失败 | 0 | 0 |
| client 重组/解码/丢弃/解码失败 | 112 / 112 / 0 / 0 | 54 / 54 / 0 / 0 |
| 解码帧率 | 24.1 fps | 29.7 fps |
| **控制通道最大到达间隔** | **1033 ms** | **1033 ms** |
| 落盘 PNG | 6 张（1920×1080，可辨认桌面） | 6 张 |

控制最大间隔 1033 ms ≈ 心跳间隔 1 s，说明**推流没有挤掉控制通道**；
两端控制到达时间线都是严格 1 s 一拍（如 `1033,2004,3031,4030,5008,6011,7007`）。
采集帧率随屏幕内容变化（静止桌面时 SCK 只按变化出帧），不是链路瓶颈。

#### 两个把「控制被饿死」误判成链路问题的坑

第一轮实测出现 **控制心跳断 4.5 s**（`控制到达: 1011,2022,6519,6553,6582`），
当时看起来像 QUIC datagram 被视频流挤掉。实际是两个**自己造成的收包线程阻塞**：

1. **PNG 编码跑在接收路径上**。首版在 VT 输出回调里直接 `CIContext` + ImageIO 落盘，
   一帧 1080p 要几十到几百毫秒；6 张 PNG 就让心跳断了 4.5 s。
   改为「占槽 + `CVPixelBufferRetain`」后丢到独立串行队列编码，间隔立刻回到 1 s。
2. **重组/解码跑在 `nw_connection` 的收包队列上**。VT 输出回调**不保证异步**，
   且首个关键帧要现场建解码会话——实测单次 `acceptDatagram` 阻塞 **1092 ms**，
   其余控制包只能排在它后面。把整段帧处理 `dispatch_async` 到独立串行队列后，
   控制最大间隔从 1469 ms 降到 1033 ms，且不再随首帧抖动。

区分方法：`stream_probe` 同时打印「控制到达时间线」「帧队列单次处理最长」「传输 sendErr /
链路 retrans/dup」。判据是——**若 `sendErr=0`、`retrans` 很少，而 `帧队列单次处理最长`
与控制断流时间重合，就是自己堵住了收包线程，不是链路丢包。**

#### 遗留问题

- ~~**首帧延迟 2.8–4.1 s**~~ → 已拆解，见 §5.8：那 800–1274 ms 是 **VT 会话的进程内首次
  初始化**（与码流参数无关），已在两端用「空转会话预热」挪出关键路径
  （解码建会话 271→60 ms、编码建会话 406→56 ms）。剩余首帧延迟主要来自 SCK 出帧时机。
- **1 个分片级丢包仍会带来 1 s 级控制延迟**：`M1ControlLink` 的重传是 250 ms 起，
  但实测偶发一次心跳要 1 s 才补上（`retrans` 计数非 0 而控制间隔刚好跳过一个节拍）。
  在 3 s 判据内可接受，M1-C 做链路质量统计时再收紧。

---

### 5.8 首帧延迟：VT 会话预热（M1-A 第 5 步，2026-11-18 20:2x–21:0x，Tahoe）

§5.7 遗留的「首帧 2.8–4.1 s」中，有一段是首个关键帧上的 `VTDecompressionSessionCreate`
（单次 800–1274 ms）。原本的计划是「收到 SPS/PPS 就建会话，不等关键帧」，**该计划不成立**：
H.264 的参数集本来就随关键帧一起来，没有可提前的窗口——而且 `M1FrameReceiver`
早在 `rebuildFormatDescriptionWithParamSets:` 里就是收到参数集立刻建会话了。

真正的原因是另一回事：

| 观测 | 数值 | 说明 |
|---|---|---|
| 同进程**第一次** `VTDecompressionSessionCreate` | 260 / 1110 ms | 随系统冷热在 13 ms–1.1 s 间浮动 |
| 同进程**第二次**（同参数集） | 63 / 32 / 24 / 13 ms | 一次性开销，之后都是几十 ms |
| 用**裸 format desc**（无 SPS/PPS，仅 `CMVideoFormatDescriptionCreate(H264,1920,1080)`）建会话 | 1110 ms，**成功** | 与码流参数无关 ⇒ 预热不需要任何真实码流 |
| 同进程**第一次** `VTCompressionSessionCreate` | 343 / 1377 ms | 编码侧同理，第二次 112 ms |

结论：这是 **VT 会话子系统在进程内的首次初始化**（框架冷加载 + XPC 服务握手），
是进程级一次性成本，完全可以挪到握手期间做掉。

#### 实现

- `+[M1VideoEncoder prewarm]` / `+[M1FrameReceiver prewarmDecoder]`：各建一个空转会话
  立刻销毁，`dispatch_once` 保证一次，线程安全。
- 预热**不依赖分辨率**：解码侧用裸 format desc 就够（上表第 3 行已证明）。
- `stream_probe` 在 `main` 开头按角色丢到 **`QOS_CLASS_UTILITY`** 后台队列。
  用 `USER_INITIATED` 会反噬：两进程同时启动时，1.5 s 的预热和主机侧首次采集抢 CPU，
  实测出现首帧 1814 ms（比不预热的 1421 ms 还差）。

#### A/B 实测（3 轮 × 2 组，1920×1080 降采样，20 fps 目标，本机双进程环回）

| 指标 | A：关预热（`M1_NO_PREWARM=1`） | B：开预热 | 中位数变化 |
|---|---|---|---|
| 解码器真实建会话 | 271 / 270 / 306 ms | 60 / 13 / 62 ms | **271 → 60 ms** |
| 编码器建会话 + Prepare | 348 / 406 / 505 ms | 52 / 56 / 180 ms | **406 → 56 ms** |
| 端到端首帧延迟 | 992 / 1140 / 1623 ms | 783 / 419 / 1796 ms | 1140 → 783 ms |
| 解出帧数 / 丢帧 / 解码失败 | 全 PASS，0 丢 0 失败 | 全 PASS，0 丢 0 失败 | — |

首帧延迟的中位数只降了约 350 ms，是因为这一列**噪声极大**：SCK 只在画面变化时出帧，
静止桌面时实测只有 2.4–3.1 fps（活跃时 21.8 fps），首帧什么时候来取决于屏幕内容。
所以**判定预热是否生效要看确定性指标**（两端建会话耗时），不要看首帧延迟。
系统冷态（框架未加载）时，这一项每端最高能到 1.1–1.5 s，那才是预热真正省下的部分。

#### 顺带发现的两个缺陷

1. **并发双停导致 SIGILL（已修）**。对端 `bye` 触发的 `-[M1FramePipeline stop]` 跑在
   控制收包队列上，主线程收尾还会再停一次，两边同时进 `-[M1VideoEncoder stop]`，
   对 `_session` 二次 `CFRelease` → `EXC_BAD_INSTRUCTION` / SIGILL（崩溃报告栈：
   `CFRelease → -[M1VideoEncoder stop] → -[M1FramePipeline stop] → controlSession:didChangeState:`）。
   2026-11-18 20:08 起多次复现，属既有缺陷。修法：`stop` 幂等 + 把会话/对象先摘成快照
   再释放，保证同一会话只释放一次。
2. **单帧 255 片上限在 3440×1440 下被打穿（已修，帧头 v2）**。帧头里
   `fragIdx/fragCount` 是 **uint8**，单帧上限 255×1150 B ≈ 286 KB。3440×1440 的关键帧
   轻松超过，`P1FragmentPayload` 直接返回 `too many fragments (>255)` ⇒ 该帧整帧发不出去
   ⇒ 客户端只能等下一个关键帧（间隔 2 s）。实测一轮 3440×1440 首帧延迟 **4069 ms**、
   `sendFail=1`，就是这条。1920×1080 下不触发（见上表）。

   **修法**：帧头升到 **v2**，`fragIdx/fragCount` 由 1 字节扩到 2 字节，帧头 16B→18B，
   单帧上限 65535 片 ≈ 75 MB。另一条候选（把 `displayID` 压成 16 位、帧头仍 16B）
   **已排除**：实测本机 `CGMainDisplayID() = 2026701824`（0x78CD0400），32 位都嫌紧，
   压成 16 位会直接截断显示标识。`payloadLen` 上限仍是 1150，分片预算不变
   （18+1150=1168 < 1497 协商下限），MTU 与拥塞行为不受影响。

   验证（2026-11-18 21:0x）：
   - 原生 **3440×1440** 推流：30/30 帧、零丢零解码失败、**`sendFail=0`**、
     首帧 **1278 ms**（修复前同分辨率 4069 ms 且 `sendFail=1`）；
   - 编解码层：400 片大帧（≈460 KB）分片 → 重组逐字节一致；256 片现在合法、
     65535+1 片仍正确拒发；
   - 传输层：`quic_probe` 500 帧/500 片/575 KB 零丢零乱序；
   - 单测：P1 148 项、M1 全绿。
   - **限制**：本机静止桌面下 VT 会把关键帧压得很小（49 Mbps 档实测关键帧也只有 10 KB 级），
     所以「>255 片」这件事是在编解码层证明的，没能用自然码流复现超限关键帧。

#### 仍未闭环

- **`stop` 偶发长时间阻塞**：同一路径上偶尔在 `-[M1FramePipeline stop]` 里卡住
  （表现为该线程此后再无日志，主线程的二次 stop 因幂等直接返回）。已加
  `M1_STOP_TIMING=1` 可观测耗时，正常路径实测 capture 5 ms / encoder 16 ms，
  阻塞样本尚未抓到栈。不影响推流指标，但收尾路径不该阻塞网络线程。

### 5.9 M1-B：客户端上屏 + 输入回传（2026-11-18 21:2x–21:5x，Tahoe）

目标：把 §5.7 的「客户端只落 PNG」推进到「能用」——窗口实时出画面，鼠标键盘
走控制通道回到主机注入。**代码与单测已完成，端到端验证因屏幕锁定尚未执行**（见末段）。

#### 分工与实现

| 层 | 落点 | 说明 |
|---|---|---|
| 协议 | `M1ControlSession` | 补上 `sendInputEvent:` 与 Host 侧 `didReceiveInputEvent:` 回调。此前 `input` 消息在分发里被**静默忽略**（代码注释写着「属帧通道阶段」） |
| 上屏 | `M1FrameView`（新） | `CVPixelBuffer → CIContext → IOSurface（BGRA）→ layer.contents`，`contentsGravity=kCAGravityResizeAspect` 做 letterbox |
| 坐标 | `M1InputLogic`（扩充） | `M1AspectFitRect` / `M1NormalizedPointFromViewPoint`，纯函数、不依赖 AppKit，可单测 |
| 注入 | `M1InputInjector` + `M1RecordingEventSink`（新） | 真实 `CGEventPost` 与「只记录不注入」两种下沉；环回默认 record |
| 编排 | `stream_probe --window` / `--inject record\|real` | 窗口模式跑 `NSApplication` 事件循环；到点/Esc/关窗收尾 |

关键取舍：

- **上屏不走 `AVSampleBufferDisplayLayer`**。那条路要喂压缩 sample，等于绕开
  `M1FrameReceiver` 的解码统计；M1-B 要的是「同一条解码路径 + 一个显示出口」，
  所以选 CIContext 渲染。转换放在独立串行队列，只把 `layer.contents` 的赋值
  丢回主线程——否则又会重演 §5.7 的「在热路径上堵住收包线程」。
- **不用 `createCGImage` 贴图**。第一版是 `createCGImage → layer.contents = CGImage`，
  那是每帧一次 GPU→CPU 回读（3440×1440 BGRA = 19.8 MB/帧），实测单帧 **0.5–0.9 s**，
  不可用。改为 `render:toCVPixelBuffer:` 渲染到 IOSurface 承载的 BGRA 缓冲，
  再把 `layer.contents` 直接设成该 `IOSurfaceRef`（零拷贝），离屏实测 **10.4 ms/帧**
  （3440×1440），降了两个数量级。
- **渲染积压超过 2 帧直接丢新帧**，不排队。渲染跟不上时排队只会让看到的画面越来越旧。
- **单机环回默认 `--inject record`**。Host 与 Client 是同一个桌面，真 `CGEventPost`
  会把光标从窗口里移走、甚至点中背后的 app，验证本身就被污染。双机验收再开 `--inject real`。
- **`keyUp` 不单独发**：协议 `key` 事件没有 down/up 位，Host 侧本就成对注入
  （`M1CGEventSink` 一次 `postPlan` 发 down+up），客户端再发一次 up 会变成双注入。

#### 单元级验证（可离线，已通过）

`bash M1-Skeleton/build_tests.sh` → **193 项全过**。本轮新增 28 项：

| 组 | 断言 |
|---|---|
| 输入通路（24 项） | 鼠标/键盘/滚轮/flags 四类事件发出后 Host 原样收到；坐标与 displayID 不变；畸形事件（坐标 2.0）被拒且**不掀会话**；非 STREAMING 态静默丢弃（`inputEventsDropped`）；Host 不能反向发 input；`displayID` 写在消息层时也能取到 |
| letterbox 与坐标（12 项） | 1920×1080 → 1000×1000 视图 = 1000×562.5 居中（上下各 218.75）；竖屏源按高受限；退化尺寸不除零；视图中心→(0.5,0.5)、左上→(0,0)、右下→(1,1)；黑边上 clamp；**视图坐标 → 归一化 → 注入计划往返回到同一物理点** |
| 注入器（6 项） | `M1RecordingEventSink` 记录计划、`injectEvent:` 归一化→全局坐标（3440×1440 中心 = 1720,720）、flags 全量同步、reset |

#### 过程中发现的两个问题

1. **`displayID` 位置文档与实现不一致（已双向兼容）**。`PROTOCOL.md` §3.1 把 `displayID`
   写在消息层，而 `P1InputCodec` 把它放在 `event` 内。照文档实现的对端发过来
   `event.displayID` 缺失、归一化后变成 0，输入落不到目标屏。现在发送时两处都带、
   接收时 event 内缺失则回落到消息层，并加了单测钉住。
2. **窗口模式首次握手 12 s 超时（未复现）**。同一份二进制、同样参数，第二次运行
   握手 16.8 ms。怀疑与新进程首次创建临时钥匙串 + 首次 GUI 化的系统开销有关，
   但没抓到栈，**记录待观察**，不当作已解决。

#### 上屏渲染链路：离屏自检（已通过，无需解锁）

`tools/render_selftest.m` 不依赖可见窗口：造一张「左红右蓝」的 `CVPixelBuffer` 喂给
`M1FrameView`，等渲染队列贴上后**从 `layer.contents` 读回 CGImage 采样像素**。

```
=== M1FrameView 离屏自检（640x360 → 900x506 视图）===
[PASS] frame-rendered / layer-contents-set / image-size-matches-source
  左半像素 RGBA = 255,0,0,255      右半像素 RGBA = 0,0,255,255
[PASS] left-is-red / right-is-blue          ← R/B 互换会在这里暴露
  videoRect = (0.22, 0.00, 899.56, 506.00) in view (900x506)
[PASS] letterbox-height-full / width-scaled / vertically-flush / centered
[PASS] second-frame-applied                  ← 第二帧确实覆盖第一帧
=== ALL PASS ===
```

这组断言钉住的是三件最容易悄悄错的事：**CIContext 转不出来**（`cg == NULL`）、
**尺寸被裁**、**通道顺序反了**（红蓝互换在截图里不显眼，但输入坐标是对的、画面是错的）。

**顺带量到一个一次性成本**：同一进程的第一次 `createCGImage` 要 **623 ms**
（Metal 管线/着色器冷启动），之后 3.3 ms。和 D-15 的 VT 会话是同一类问题，
所以在 `M1FrameView` 构造时就排队跑一次 16×16 的空转转换，把这笔成本挪到握手期间。
预热后实测真实帧 `lastRenderMs 1.3 ms / maxRenderMs 2.1 ms`。
（注意：623 ms 那次是 GPU 管线**全系统首次**冷启动，系统热了以后连预热本身都只要 4.4 ms，
所以这个数字反映的是最坏情况，不是稳态。）

#### 端到端验证：待解锁执行

计划中的判据（`M1-Skeleton/verify_m1b.sh` 已实现，一条命令跑完）：

1. 客户端窗口至少贴上 1 帧（`framesRendered ≥ 1`）；
2. 用 `tools/cursor_move` 把光标移到窗口中心 / 左 200 / 右 200 三个位置；
3. 主机 `record` 模式收到的三次 `mouse` 计划里，x 分别落在「中心 ±3% 屏宽」与
   「中心 ∓ 按 letterbox 换算的 200 窗口像素」两侧，偏差 < 20%；y 偏离中心 < 8%。

**当前阻塞：这台机器的会话在反复自动锁定，无法稳定支撑窗口态验证。**

实测证据（不是一个孤例）：

| 时刻 | 现象 |
|---|---|
| 22:47 / 23:01 | `screencapture` 抓到的都是锁屏界面（时钟 + `bemin` 头像 + 密码框） |
| 端到端轮次内 | 客户端打印 `visible=1 key=0 active=0 occluded=1`——窗口「已创建并 orderFront」，但**没有真正显示**，因为登录窗在最上层 |
| 同一时刻 | SCK 采集正常、帧照常解码（说明进程与链路都没问题），只有「上屏 + 输入」这两条依赖可见窗口的路径拿不到 |
| 锁屏状态下 | `SCShareableContent.displays` 为空，主机管线直接报 `该 displayID 不在 SCShareableContent.displays 中` |

还观察到「解锁 → 数秒后又上锁」的反复（`cursor_move locked` 连续 3 次读成解锁、
脚本随即又失败）。因此 `verify_m1b.sh` 改成了**多轮短尝试**（默认 4 轮 × ~10 s），
命中解锁窗口即通过。12 轮回放的结论：推流、解码、上屏管线都正常，
但没有一轮同时满足「窗口可见 + 光标落在窗口内」。

**这不是代码结论，是环境前置条件。** 要跑通需要一次持续 ≥30 s 的解锁会话：
`./verify_m1b.sh`（一条命令）。若单机始终无法稳定解锁，端到端判据直接并入双机验收——
那时客户端窗口在另一台机器的屏幕上，不受本机会话锁屏影响。

#### 本轮从失败里挖到的三个真问题（已修）

1. **`createCGImage` 上屏不可用**：每帧 GPU→CPU 回读 19.8 MB，0.5–0.9 s/帧 →
   改 IOSurface 后 10.4 ms/帧（见上文取舍）。
2. **窗口不可见时 `layer.contents` 赋值会阻塞**。第一次端到端跑出 `943 / 1610 / 3233 ms`
   这类荒唐数字，一度以为是渲染慢，实际是窗口被登录窗遮住、CA 合成提交被挂住，
   赋值顺手把渲染队列堵死。现在赋值前检查 `occlusionState`，不可见就跳过并计入
   `framesSkippedOccluded`——既不堵队列，也让「画面没上屏」在统计里显式可见。
3. **CLI 应用的窗口拿不到 key window，tracking area 必须用 `NSTrackingActiveAlways`**。
   第一版用了 `NSTrackingActiveInKeyWindow`，端到端 `inputEmitted` 恒为 0，
   一个事件都收不到；另外 `NSWindow.acceptsMouseMovedEvents` 默认 NO，也要显式打开。

#### 5.9.1 补测：端到端判据已通过（2026-11-19 早晨，Tahoe）

上文的「阻塞」有一半是脚本自己造成的，不是环境：

1. **`verify_m1b.sh` 的锁屏判据写反了。** `cursor_move locked` 的约定是
   「锁定 → exit 1，解锁 → exit 0」，脚本却用 `&& return 1`（把 0 当锁定），
   于是屏幕明明解锁也判「锁定」，三轮一次都没真跑。改成 `||` 后立刻跑起来。
2. **真正的阻塞是「辅助功能」授权，不是锁屏。** 由 agent 拉起的命令行工具
   `AXIsProcessTrusted()=0`，此时：
   - `CGWarpMouseCursorPosition` 能改光标位置（`NSEvent.mouseLocation` 随之变），
     但**一条 `mouseMoved` 都不投递**；
   - `CGEventPost(kCGHIDEventTap)` 的合成事件被系统直接丢弃；
   - 最小复现（~60 行 AppKit 接收器）：`active=1 key=1 occl_visible=1`、
     光标确实在动、`mouseEntered` 收到 1 次，而 `mouseMoved` 连本地事件监听都是 **0**。

   ⇒ 光标位移与事件投递是两条独立的路，只看「光标动了」会误判成客户端没采集。

因此驱动端分流（`verify_m1b.sh` 自动探测 `cursor_move ax`）：

| 驱动 | 条件 | 覆盖到哪 |
|---|---|---|
| `physical` | `AXIsProcessTrusted=1` | 全链路，含「系统把事件交给 App」 |
| `synth` | 无辅助功能授权 | 除 OS 投递外的全链路：`NSWindow sendEvent:` → hitTest → `mouseMoved:` → 坐标换算 → 协议编码 → QUIC → 主机解析 → 注入计划 |

`synth` 模式实测（第 1 轮全过，`/tmp/m1b-local/run1`）：

| 项 | 实测 |
|---|---|
| 上屏 | **29 帧**，跳过 0、积压丢 0，单帧 8.0 / 峰值 21.7 ms |
| 上行输入 | 去重前：3 次移动 → 6 条 `mouse`；去重后：**3 次移动 → 3 条 `mouse`**（另有 1 条 `flags`），失败 0 |
| 坐标 | 三次移动 → x = 1720 / 955.6 / 2484.4，y 恒 720（3440×1440 的 0.5 / 0.278 / 0.722） |
| 换算 | 900×506 窗口内 ±200 px → 屏幕 ±764 px，与 letterbox 理论值一致 |

**顺带挖到的第 4 个真问题**：同一个 `NSEvent` 被投递两次（一次按 hit-test 命中视图，
一次按 tracking area 派给 owner，而视图两者兼具且开了 `NSTrackingMouseMoved`），
每次移动变成 2 条上行事件、白占一倍带宽。已按「时间戳 + 窗口内坐标相同即为同一事件」
去重（`M1FrameView mouseMoved:`）。

**仍未闭合**：`physical` 驱动那一跳（需给宿主进程授予「辅助功能」），以及真实主机的
`CGEventPost` 注入——两者是同一个授权前置，已列入双机验收清单。

**关于「辅助功能」授权，有个反直觉的坑**：授权是按**二进制 cdhash** 记的。
改一版工具就得重新授权一次——面板里的开关是开的，但它对应的是旧版本，
重建后签名变了，`AXIsProcessTrusted()` 照样返回 0。实测对照：
`/tmp/axtest/t`（加进列表后没再重建）→ `AX=1`，真把光标挪到了 (100,100)；
`cursor_move`（加进列表后我又加了个子命令重建过）→ `AX=0`。
所以：**需要发合成事件的工具要「先定稿、后授权」，之后别再重建**。

**锁屏判据也升级了**：原先只看 `CGSSessionScreenIsLocked`，屏保态/显示器睡眠态分不清，
容易被误读成「判断错了」。`cursor_move state` 现在一次打印
`locked / asleep / onConsole / loginDone / activeDisplays / ax`，
锁屏**或**显示器睡眠都返回 exit 1；`verify_m1b.sh` 跳过时会把这一行原样打出来。

#### 5.9.2 真光标驱动：卡在「窗口必须是前台」，不是代码问题

拿到辅助功能授权后（`AX=1`），`cursor_move move` 真的能产生系统级 `mouseMoved`——
用同窗口尺寸的最小接收器（`mouselog`）实测：3 次移动 → 3 次 `mouseMoved`，
坐标与驱动点一一对应。链路本身是通的。

但在 `verify_m1b.sh` 的循环里始终拿不到 3 条，逐层排下去挖出三个问题：

| # | 现象 | 真因 |
|---|---|---|
| 1 | 驱动到「屏幕中心」，视图收到 8 个 `mouseMoved`，主机 0 条 | 窗口内容里视频是 letterbox 的，**屏幕中心落在黑边上**；`normalizedPointForEvent` 按设计丢弃黑边事件。改成客户端首帧后打印 `[anchors]`（画面中心 ±200 的全局坐标），驱动端照着走 |
| 2 | 断言里的「中心」还拿全局像素比 | 主机收到的是归一化坐标，`x` 应为 `pw*0.5`、`y` 应为 `ph*0.5`，与驱动点在屏幕上的位置无关 |
| 3 | 窗口 `visible=1 key=1 active=1 occluded=0`，仍收不到 move | **WindowServer 只把 `mouseMoved` 投给前台应用**。脚本跑的时候实测 `frontmost=Google Chrome`；偶然收到的那几条，`locationInWindow=(1619,238)`，在 900 宽的窗口坐标里根本不成立——那是人手在动鼠标 |

过程中还排掉一个反直觉的尝试：把窗口设成 `NSFloatingWindowLevel` 想避免被遮挡，
结果**一条 `mouseMoved` 都收不到**（`mouseEntered` 仍然正常），已撤回。

结论：`physical` 驱动**需要客户端窗口成为前台、且人不碰鼠标**的一段窗口期；
这属于测试环境约束，不是产品缺陷（真实使用里客户端窗口本来就是前台的）。
`M1B_KEEP_FRONT=1` 可以每 300ms 重抢前台，但会打断正在用的应用，默认关闭。
自动化的验收判据仍以 `synth` 驱动为准（已验证全链路与坐标），
真鼠标那一跳改由 §5.9.3 的手动驱动补齐。

#### 5.9.3 手动驱动（真人）：真鼠标那一跳闭环（2026-11-19 10:0x）

`physical` 是「代码驱动的真光标」，卡在「窗口必须前台、且人不碰鼠标」；
`synth` 是「进程内造事件」，少了 OS 投递那一跳。两者之间还有第三条路：
**代码只负责发无歧义的信号，人真的去动鼠标**。缺的从来不是能力，是「什么时候该动」。

`stream_probe --client ... --manual 18` 在首帧上屏 +0.8s 后：

1. 连响 3 声（`NSBeep`）；
2. 窗口标题变成 `▶▶ 现在动鼠标：点一下窗口，在画面里左右划 18 秒`，
   之后逐秒显示「剩 N 秒 · 已采集 N 条」；
3. 终端打一段 `[manual]` 横幅（① 先点一下窗口 ② 在画面里左右慢慢划 ③ 18 秒后自动结束）；
4. 到点再响一声，标题变 `✓ 时间到，可以停手了`，日志打 `时间到，停手`（脚本靠它同步）；
5. 一条都没收到时，每 5 秒再响两声、标题前缀加 `？`——实测人的反应延迟有 7 s，
   第一轮 18 s 里前 7 s 采集恒为 0 条，单靠开场那三声容易被错过。

`verify_m1b.sh` 增加 `M1B_DRIVER=manual`（`M1B_MANUAL_SECS` 调时长，
时长自动放宽到 `秒数 + 12s`）。判据改为「横向跨度 ≥ 画面宽 10%」+ y 不越界，
**不判落点**——真人落点不可控，硬套 ±200 只会假失败。

实测（第 1 轮即 PASS）：

| 指标 | 值 |
|---|---|
| 客户端上屏 | 329 帧（丢 15 积压 / 跳过 147 不可见），单帧 31.3 ms / 峰值 89.7 ms |
| 窗口采集 → 上行 | 152 → 152 条（丢弃 0、拒绝 0） |
| 主机收到 | 153 条，其中 `mouse` 150 条 |
| 横向跨度 | 2563 px，占画面宽 75% |
| 人的反应延迟 | 提示后约 7 s 才开始动 |

结论：**真实鼠标 → 客户端窗口 → 归一化 → 控制通道 → 主机解析 → 注入计划**
整条链成立，`physical` 缺的那一跳（OS 把物理事件交给 App）也包含在内。
单帧 31.3 ms 高于离屏 10.4 ms，来源是「16 秒内 150 次鼠标事件 + 329 帧渲染 +
环回时客户端把自己也采集进去」的同进程竞争，不代表稳态。

#### 遗留

- 上屏走 `CIContext → IOSurface`，离屏实测 **10.4 ms/帧（3440×1440）**、**1.1 ms（640×360）**。
  20 fps 下占 21% 预算，可接受；要再快就得上 `CAMetalLayer` + `CVMetalTextureCache`（NV12 直采）。
- 环回时窗口本身会被采集进去，画面出现「画中画递归」，属预期现象，不影响判据。
- 输入限速（1000 event/s）只在 Host 侧生效；客户端没有本地节流，高刷鼠标
  （1000 Hz）会先把控制通道塞满再被对端丢弃。M1-C 做链路质量时应改为客户端节流。
- `keyUp` 不单独发（协议 `key` 无 down/up 位），客户端不支持长按修饰键逐次上报，
  只有 `flags` 全量同步；真机验收要确认 macOS 的 key repeat 行为符合预期。

### 5.10 P2 预演：走真实网卡（en0）的跨进程联调（2026-11-19 上午）

双机联调前先在本机用**局域网地址**跑一遍，把「回环特有的假设」提前排掉。
结论：能跑通，并挖出两个只在跨机会暴露的问题。

新增能力：

- `stream_probe --connect IP`：客户端对端地址原本写死 `127.0.0.1`，跨机无法使用。
- `stream_probe --preflight host|client`：本机能力自检（AX / 屏幕录制 / 锁屏 / 屏睡 /
  active 显示器 / 局域网 IP / 帧头版本）。放在 `stream_probe` 里而不是单独工具，
  是因为屏幕录制与辅助功能授权按**这个二进制**的 code requirement 记。
- host 启动后打印「给客户端的三项」：IP / 端口 / 证书指纹。
- `P2-Dual/p2.sh`：`preflight | host | client | summary` 四个子命令，见
  `docs/P2-CHECKLIST.md`。

挖出的两个真问题：

| # | 现象 | 真因 |
|---|---|---|
| 1 | `--port 46600` 启动，实际监听 **61174**，客户端连不上 | `nw_listener_create(params)` **完全忽略** init 传入的端口，每次随机分配。单机靠 `--port-file` 传递端口还能糊过去，跨机必须固定端口（防火墙规则、人工抄写都要它）。改用 `nw_listener_create_with_port` |
| 2 | 收尾打印时 `*** Collection was mutated while being enumerated` 崩进程 | `controlArrivals` 由收包队列追加、主线程枚举打印。单机慢，收尾时正好没有心跳；跨机握手 18 ms、收尾瞬间还有心跳/bye 进来就撞上。改为 `@synchronized` + 快照 |

实测（本机走 `192.168.10.23`，host `--inject record`）：

| 指标 | 值 |
|---|---|
| 握手 | 18.1 ms |
| 采集/编码/发出 | 273 / 272 / 272 |
| 客户端收齐/解出 | 272 / 272（丢 0，解码失败 0） |
| 客户端上屏 | 266 帧（跳过 0 不可见），渲染 12.9 ms / 峰值 74.3 ms |
| 首帧 | 主机 239 ms / 客户端 475 ms |
| 控制通道最大间隔 | 1004 ms（1 s 心跳） |

再跑一轮 `--inject real`（客户端用 `--input-synth` 造 3 个点）：
客户端采集 10 → 上行 10，主机**注入成功 10 次**、`inputInjectFails=0`、
光标位移 **768 px** —— 真注入路径（`CGEventPost`）在跨机条件下成立。

仍未闭合：真正的两台机器（对端 TCC 授权、网线/AP、单程时延）、
以及 glass-to-glass（需要相机或硬件打点，见 P2 清单 §7）。

**A-02 状态不变**：仍开放。本轮只证明跨机可跑通与指标可采集。

---

### 5.11 Sequoia 15.5 客户端侧离线验证（2026-11-19 20:1x，Sequoia）

跨网段 P2 联调前，先在**本机（Sequoia，本轮扮演 client）**跑一遍不依赖 TCC、
不需要对端的客户端路径。此前 M1-B 上屏/输入的验证全部只在 Tahoe 做过。

| 项 | 值 |
|---|---|
| 环境 | macOS **15.5 / 24F74** / Macmini8,1 / i5-9500 / x86_64 |
| 显示 | 3 块：6016×3384（UI 3008×1692 @60，主屏）、1440×2560 竖屏、1920×1080 |
| 网络 | en1 192.168.31.171；到公网端点 112.5.32.34 ICMP 8.2 ms（仅证明可达，不证明 UDP 映射） |
| 代码 | commit `624cd94`，SDK 15.5、部署目标 13.0，本地重建 |
| 会话 | `locked=0 asleep=0 onConsole=1 loginDone=1 activeDisplays=3` |

| 验证项 | 结果 |
|---|---|
| 构建 | `stream_probe` / `test_skeleton` / `render_selftest` / `cursor_move` 全部通过 |
| 单测 | **193/193**；`guardian_handshake_test` 的「无兜底拒绝禁屏」为 PASS |
| 离屏上屏自检 | **ALL PASS**（颜色、尺寸、letterbox、第二帧覆盖、IOSurface 承载） |
| 3440×1440 单帧渲染 | **66.5 / 74.0 / 77.2 ms**（3 次独立进程），Tahoe 同测试为 **10.4 ms** |
| client preflight | `ok=1`，`ax=1 capture=1`，proto v2 / 18B / 1150B |

**判读**：

1. **客户端功能在 15.5 上成立**：编解码/上屏/letterbox/输入逻辑的离线判据全过。
2. **渲染成本有显著 OS 差异**：同一份 `render_selftest`、同一颗 i5-9500 + UHD 630，
   Tahoe 10.4 ms → Sequoia 66–77 ms。存在显示拓扑混杂因素（这台是 3 屏、主屏 6K 级
   HiDPI，Tahoe 是 2 物理屏），但 20fps 的 50 ms 预算已被打穿是事实。
   ⇒ **若 host 按原生 3440×1440 推流，Sequoia client 的上屏上限约 13–15fps，
   且积压丢帧会先于链路问题出现**。本轮跨机建议 host 以 `--width 1920 --height 1080`
   编码，或把该 OS 分支记入 NFR-03。
3. **不得把 Tahoe 的 10.4 ms 客户端渲染值外推到 Sequoia**；反之亦然。
4. 本机 preflight 的 `ax=1/capture=1` 来自 Qoder 会话继承（见 V-04 记录），
   **不代表 `stream_probe` 作为独立 App 已获得授权**；本轮 client 角色不需要这两项。
5. 未在本机执行：host 侧的 V-02/V-03/V-04/SPI 验收、M1-B 真鼠标端到端、
   与 Tahoe host 的实际握手。A-02 状态不变。

---

### 5.12 P2 跨网段联调：边界 UDP 未通（2026-11-19 21:3x–21:4x）

第一次跨公网联调，**连接未建立**。结论是网络边界问题，不是 host 进程、指纹或 TCC。

| 项 | 值 |
|---|---|
| host | Tahoe **26.5.2** / Macmini8,1 / i5-9500 / x86_64；内网 `192.168.10.23`，WAN `112.5.32.34` |
| client | Sequoia **15.5 / 24F74** / Macmini8,1 / i5-9500 / x86_64；`en1 192.168.31.171` |
| 路径 | client → `112.5.32.34:46600/UDP` → host `:46600` |
| 代码 / 指纹 | 两端 commit `624cd94`；指纹 `3305dec4…b1604` 与 host 打印一致 |

**观察**：

- client 侧窗口正常打开，握手 **30s 超时**，无其他错误码。
- host 侧 `stream_probe --host --port 46600 --wait-ms 0` 持续运行；`lsof -nP -iUDP:46600`
  显示 `UDP *:46600`，系统防火墙 `State = 0`，控制台一直打印「仍在等待对端」。
- host 上 `tcpdump -ni en0 'udp port 46600'` 在 client 尝试期间捕获 **0 包**（pcap 0 字节）。
- 对照：从 client 向 `112.5.32.34:46601` 发 20 个 UDP 包，host 抓 `udp port 46601`
  同样 **0 包**；但 TCP 46601 的 SSH 登录正常。
- client 出向 UDP 正常：`stun.l.google.com:19302` 4s 内返回 32B。

**判读**：

1. 不是 host 未启动、指纹错误、TCC 或客户端防火墙：host 在监听、指纹一致、client 能发 UDP。
2. **边界设备没有可用的入站 UDP 映射**。TCP 46601 能转发只证明 TCP 路径；
   UDP 46600 与 UDP 46601 都零包到达，可能是只建了 TCP 规则、内部目标 IP 不对，
   或 CPE/ISP 对入站 UDP 有过滤。
3. 本轮**没有取得任何 P2 指标**；A-02 状态不变。
4. 待办：在边界设备加 `外部 UDP 46600 → 192.168.10.23:46600`，确认无 UDP 过滤；
   若外部端口不同，client 用 `--port <外部端口>`。

---

### 5.13 P2 跨公网联调：Tahoe 26.5.2 host × Sequoia 15.5 client（2026-11-19 21:4x–22:0x）

CPE 的入站规则从 TCP 改成 UDP 后，**首次跨公网端到端跑通**：握手、控制通道、视频、解码、上屏、输入回传全部成立。过程中挖出两个只在「长时间运行 + 重编」后出现的新根因（NEG-05、TCC 重编失效）。以下结论只属于 Tahoe host × Sequoia client 这一组合。

| 项 | 值 |
|---|---|
| host | Tahoe **26.5.2 / 25F84** / Macmini8,1 / i5-9500 / x86_64；LAN `192.168.10.23`；WAN `112.5.32.34:46600` |
| client | Sequoia **15.5 / 24F74** / Macmini8,1 / i5-9500 / x86_64；`en1 192.168.31.171` |
| 路径 | client → `112.5.32.34:46600/UDP` → host `:46600`（外部与内部同端口） |
| 代码 | 两端 `624cd94` + host 本地提交；`M1QuicTransport` 含 NEG-05 修复 |
| 指纹 | `3305dec4…b1604`（两端一致） |

**边界与握手**：CPE 改为 UDP 映射后，host 立刻出现 `已接受连接`，`lsof` 显示与 client 公网地址的 UDP 对；但握手仍 30s 超时且无错误码。

#### NEG-05 临时钥匙串空闲自动上锁 → 签名阻塞

- 现象与 NEG-02 同形：client 停在 preparing；host `sample` 卡在 `SecKeyCreateSignature`；securityd 日志同时出现 `unlocking for makeUnlocked()`、`code requirement check failed (-67050)`，随后拉起 SecurityAgent。
- 真因：进程私有临时钥匙串是**旧式钥匙串，会按空闲时间自动上锁**。host 启动 18 分钟后才来第一次握手，签名时钥匙串已锁；securityd 只能弹 SecurityAgent 要密码，后台 CLI 永等不到。
- 修法：创建后 `SecKeychainUnlock(..., promptUser=false)`；新增 `M1UnlockTempKeychain()`，在 `beginConnection`（客户端/入站共用）开头静默续解。**不要调用 `SecKeychainSetSettings`**——实测它自己会进 securityd 授权并卡住启动（sample 栈：`SecKeychainSetSettings → … → mach_msg`）。
- 修后握手 **60.3–103.9ms**，随后稳定进入 STREAMING。

#### TCC：ad-hoc 重编后屏幕录制授权失效

- 重编后 `--preflight host` 变成 `ax=0 capture=0`，SCK 报 `The user declined TCCs`。ad-hoc 签名下 TCC 不随 identifier 保留，重编换 cdhash 即失效。
- host 的 TCC 里 `com.apple.Terminal` 有 ScreenCapture（auth=2），而 `/usr/libexec/sshd-keygen-wrapper` 的 Accessibility 是 auth=0。于是用 `open -a Terminal /tmp/p2_host.command` 在 GUI 会话启动 host，继承 Terminal 的屏幕录制授权；AX 仍缺，故 host 用 `--inject record`（记录注入计划，不做真注入）。
- 未做：在 host 上给 `M1-Skeleton/stream_probe` 单独授予屏幕录制/辅助功能；要走 `--inject real` 必须先补 AX。

#### 实测 A：1920×1080 / 20fps（client 窗口 1280×720，20s）

| 项 | host | client |
|---|---|---|
| 握手 | — | **103.9 ms** |
| 采集 / 编码 / 发出 | 376 / 375 / 375 | 收齐 337 / 解出 54 / 上屏 32 |
| 丢弃 / 失败 | 编码前 0 / 发送 0 | 分片丢弃 2779 / 解码 0 |
| 首帧 | 524 ms | 1139 ms |
| 单帧耗时 | 编码初始化 182 ms | 解码 0.9 ms / 渲染 84.7 ms（峰值 199.5） |
| 控制通道最大间隔 | — | 1015 ms |
| 输入 | 收到 4 / 计划 4（record） | 发出 4 / 丢弃 0 / 拒绝 0 |

- `p2.sh summary`：结构性指标（STREAMING、解码>0、无发送失败、无畸形分片、控制间隔<3s）通过；但 **解码/发出 = 54/375 < 0.95 → 判定 FAIL**。
- 这不是丢包：host 发出 3263 个包，client 收到 3202（98.1%）；2779 是客户端主动丢弃的帧分片。瓶颈是 **Sequoia 客户端 1080p 渲染 84.7ms/帧**（三屏、主屏 3008×1692@2x），跑不满 20fps。

#### 实测 B：1280×720 / 10fps（client 窗口 1280×720，30s）

| 项 | client |
|---|---|
| 握手 / 首帧 | 60.3 ms / 302 ms |
| 收齐 / 解出 / 上屏 | 192 / 58 / 58（上屏积压丢 0） |
| 解码 / 渲染 | 0.8 ms / **41.6 ms**（峰值 170.0） |
| 控制通道最大间隔 | 1036 ms |
| 输入 | 发出 4 / 丢弃 0 / 拒绝 0 |

- 720p 源把客户端渲染压到 ~42ms，10fps（100ms 预算）有富余，上屏队列 0 积压；说明**网络与 720p 档本身可用**，A 的失败是客户端 1080p 渲染能力所限。
- 本轮 host 侧 `remote-gui-720/host.json` **未生成**：期间另有一个 21:57:59 启动的 `p2.sh host`（PID 65555，输出 `remote-2206`）占着同一 46600，host 进程被替换，故只有客户端侧指标；需在端口独占后补一轮 host+client 完整 JSON。

#### 补测 C/D：端口独占后的完整配对（22:0x，两轮 host+client JSON 都在）

| 项 | C：3440×1440 / 20fps / 20s | D：1280×720 / 15fps / 30s |
|---|---|---|
| 握手 | 58.7 ms | 74.1 ms |
| host 采集 / 编码 / 发出 | 392 / 391 / 391 | 444 / 443 / 443 |
| host 编码前丢弃 / 发送失败 | 0 / 0（key 10，分片 7638，载荷 8.63MB） | 0 / 0（key 15，分片 2173，载荷 2.21MB） |
| 首帧 | host 177 ms / client 2508 ms | host 110 ms / client 339 ms |
| client 收齐 / 解出 / 上屏 | 340 / **7** / 4 | 401 / **136** / 129 |
| client 分片丢弃 | 7444 | 1559 |
| 解码 / 渲染 | 1.3 ms / 9.1 ms（峰 79.2） | 0.5 ms / 16.6 ms（峰 143.6） |
| 控制通道最大间隔 | 1205 ms | 1806 ms |
| summary 判定 | FAIL：7/391 | FAIL：136/443 |

两轮都拿到 host+client 完整配对，`sendFailures=0`、状态序列两端一致、控制间隔 <2s，**结构性链路无问题**。同时更正实测 A 的解释：

- **公网 UDP 确实丢包，且被严格按序的重组放大。** host 发 2253 片 / client 收 2151（94.1%），host 发 3263 / client 收 3202（98.1%）。`P1FrameReassembler`（`P1-ClientProbe/src/ProtocolCodec.m:302`）要求分片严格 `fragIdx` 连续，任一片丢失/错位就整帧作废并置 `needsKeyframe`，之后**一直等到下一个关键帧**（host 每 2s 一个）才恢复。4–6% 的丢包因此变成长时间停顿：720p15 下 30s 只解出 136/443（0.31），1080p20 下只解出 7/391。
- **`framesDropped` 是分片计数，不是帧计数**：`M1FrameReceiver.m:208` 在等关键帧期间按 datagram 累加，所以出现 1559 > 443、7444 > 391 这种数字，不能除以 `framesCompleted` 解读。
- **渲染不是 720p 档的瓶颈**：D 轮单帧 16.6ms（峰值 143.6），另一次加 `caffeinate -d -u` 的重跑反而 83.8ms/帧、只上屏 43 帧，单帧耗时波动大；3440×1440 档 84.7ms 才是渲染瓶颈。上屏数 ≈ 解出数（129/136），说明积压发生在**解码之前**。

**结论（v0.27 更正）**：跨公网 P2 结构链路成立（Tahoe 26.5.2 host × Sequoia 15.5 client）；A-02（glass-to-glass 60fps）仍开放。P2 跨公网的首要缺口**不是渲染，而是"严格按序重组 + 丢一片等 2s 关键帧"**：在 4–6% 丢包的 WAN 上吞吐跌到 0.3 以下。下一步应做重组容错（分片位图 + 帧截止时间，乱序可用）和/或更密的关键帧/丢包后立即请求关键帧；这属于协议改动，需先定方案。Sequoia 渲染上限（3440×1440 下 84.7ms）是独立的第二瓶颈，不能外推 Tahoe 的 10.4ms。

---

### 5.14 P2.1 重组容错 + P2.2 虚拟屏会话（2026-11-19 22:2x–22:5x，Sequoia 本机环回）

只测 **Sequoia 15.5 / 24F74 / Macmini8,1（本机 host+client 环回）**；Tahoe 26.5.2 未跑本轮新代码。

**P2.1 落地**
- `P1FrameReassembler` 重写为 v3：按帧 bitmap 累积、容忍乱序/重复、以「120ms 无进展」判帧丢失（不是总年龄）、在飞帧上限 4、失序后从关键帧重启；单测覆盖帧内乱序、跨帧乱序、缺片超时、P 帧先到、重复片、换屏、请求限速。
- 指标改为帧口径：`framesDropped`（帧）、`fragmentsDiscarded`（片）、`awaitingKeyframeMs`、`keyframeRequestsSent/Received`。
- `keyframe-request` C→H 打通到编码器：客户端在等关键帧时 1s 重试（会话层仍 300ms 限速），主机 900ms 合并窗口后 `requestKeyframe`（`kVTEncodeFrameOptionKey_ForceKeyFrame`）。首次实现漏了 `host.onKeyframeRequest`，主机收 22 次请求但 key 仍是周期值；补上后同条件 key 从 4 升到 22。

**丢片矩阵（720p15，本机 `--sim-loss`，16s）**

| 分片丢包 | 解码/发出 | keyframeRequests | awaitingKeyframeMs | 备注 |
|---|---|---|---|---|
| 0% | 83/83 = 1.00 | 1 | 51 | 捕获静态屏 ≈7.5fps |
| 0.1% | 107/112 = 0.955 | 2 | 212 | 通过 |
| 1% | 15/112 = 0.13 | 14 | 12648 | IDR ≈360 片，存活率 ≈2.7% |
| 5% | 0/117 | 15 | 14975 | IDR 存活率 ≈1e-8，不可达 |

- 结论：v3 解决的是「乱序/重复不误杀」；**丢片仍然只能请求关键帧**，因为 H.264 参考链断了。无 FEC 时 `--sim-loss 5` 的 0.95 判据不成立，计划判据已改为 0%/0.1% 分层，1% 以上列入 P2.1-FEC。
- 1% 下请求确实生效（主机 key=14，周期基线 8），但每次 IDR 传输约 2s，重试过快只会互相打断；1s 重试 + 900ms 合并是当前折中。

**P2.2 虚拟屏会话（`--exclusive --keep-main` 安全冒烟）**
- 本机首跑卡住 10s+：新虚拟屏复用了残留槽位 `4128835`，处于镜像态，`M1RDPDriver` 却硬编码 Tahoe 的 `conservativeFirst:YES`，保守路径要等 mode 提交后才解除镜像 → 死锁。改为按 `P0OSPolicy()` 分流（Sequoia 直建目标分辨率、`promoteToTarget` 仅保守路径调用）。
- 修后：`虚拟屏就绪 ids=4128835`、`phase=Streaming`、采集 1280×720；client 31/31 解出、0 丢、首帧 445ms、控制间隔 1005ms、`PASS`；会话结束主机打印「已恢复物理屏并销毁虚拟屏」，状态序列完整到 `CLOSED`。
- 控制间隔门禁改为只统计 `STREAMING` 之后：建虚拟屏在 session-start 内同步耗时 ≈10s，此前被误判 10490ms 超限。建链期 10s 静默本身是真实现象，产品化时应提前心跳或异步建屏。
- 静态虚拟屏按变化送帧，2.7–4.2fps 不能当作性能结论。**未测**：全禁物理屏（去掉 `--keep-main`）在两种 OS 上的端到端、Tahoe host 跑本轮代码。

---

### 5.15 P2.1 公网门禁复测 + Tahoe kiosk 冒烟（2026-11-20 19:5x–20:1x）

代码基线 `ff7f922`（两端同一提交，均已重编）。host = Tahoe 26.5.2 / 25F84（Macmini8,1，公网 `112.5.32.34:46600`），client = Sequoia 15.5 / 24F74（Macmini8,1，本机）。镜像模式、`P2_INJECT=record`。host 经 Terminal 启动（`stream_probe` 本身无屏幕录制授权，SSH 直跑 capture=0；Terminal 有授权）。

**三轮门禁结果（`p2.sh summary`，WAN 阈值 0.85）**

| # | 规格 | 解码/发出 | awaitingKeyframe | 关键帧请求 | RTT | 帧丢弃 | 备注 |
|---|---|---|---|---|---|---|---|
| 1 | 1280×720@15 / 35s | 281/516 = 0.545 | 14000ms（40.0%） | 23/23 | 4348ms / 12 | 17.8% | 本机同时开着屏幕共享，渲染 272.7ms、接收队列最长 1149ms，数据受污染 |
| 2 | 1280×720@15 / 35s | 96/517 = 0.186 | 26743ms（76.4%） | 35/35 | 3212ms / 10 | 55.2% | 屏幕共享最小化后重跑，渲染 3.1ms；`fragmentsSent 3118 / 收到 3056`（≈2.0% 片丢失） |
| 3 | 640×360@15 / 30s | 284/443 = 0.641 | 8746ms（29.2%） | 17/17 | 3207ms / 10 | 14.4% | 降低 IDR 体积对照；`1057 / 1027`（≈2.8%） |

三轮共同点：握手 54–102ms、`sendFailures=0`、控制最大间隔 ≈1.05s、状态序列两端一致；**关键帧请求全部到达主机**（host `keyframeRequestsReceived` 与 client 发出数一致），host `keyframes` 分别为 30/23（含 2s 周期与请求强制 IDR），说明请求→编码器路径生效。三轮 `keyframeRequestRttMs` 都 ≈3.2s，呈"多次 IDR 重试"形态。

**链路对照测量（同一条 WAN 路径，Python UDP 直发，host 侧计数）**

| 形态 | 结果 |
|---|---|
| ICMP 60 × 0.2s | 60/60，RTT 7–55ms |
| UDP 1150B：100pps ×2000 + 400pps ×4000 | 6000/6000 |
| UDP 尺寸扫描：1150/1200/1250B 各 800 @200pps | 2400/2400 |
| UDP 突发：90 片 × 300 轮（每 100ms 一轮，1150B） | 27000/27000（≈2.5Mbps） |

**结论（v0.36）**
- **公网路径本身 0 丢包**（含 IDR 形态的突发）；应用层看到的 ≈2–3% 片丢失发生在 **QUIC datagram 收发层**，不是 NAT/ISP/MTU。`sendDatagram` 同步返回成功、`sendErr=0`，说明丢弃发生在 `nw_connection_send` 之后（异步失败/流控/接收回调未及时续读）。**下一步先给 `M1QuicTransport` 增加 tx 异步错误、rx 回调间隙、队列深度计数，并把重组/解码移出接收回调队列**，再决定是否需要 FEC；不要在未定位这 2–3% 前直接加 FEC。
- 该丢失率对当前"整帧齐全才交付 + 丢片即请求 IDR"的设计是致命放大：IDR 28–87 片，2–3% 片丢失使大多数 IDR 残缺，恢复靠反复请求；RTT 稳定在 ≈3.2s。0.85 门禁在本轮链路/传输条件下未通过，按计划记录，不调整阈值。
- 渲染已排除：干净轮次 3.1ms/帧、积压 1 帧；第一轮的 272.7ms 完全由本机屏幕共享会话造成。

**P2.2 Tahoe kiosk 冒烟（`--keep-main`，半禁屏）**
- `pipeline_kiosk_probe --preflight`：守护进程就绪、`预检通过`（rc=0）。
- 半禁屏冒烟：虚拟屏 `4128835`（1280×720）、采集 1280×720、首帧 `/tmp/kiosk-keepmain.png` 有画面（菜单栏+桌面壁纸）；结束打印「恢复成功」，总耗时 38.9s；之后 `activeDisplayCount=2`、未锁屏。判定 `DEGRADED`（静态虚拟屏 0.5fps）只反映按变化送帧，不作为性能结论。
- **仍未做**：去掉 `--keep-main` 的全禁物理屏 + C-09 端到端（有黑屏/WindowServer 风险，需现场确认）。

**操作注意**：远端仅 SSH 不可用——屏幕锁屏时 SCK 取不到桌面内容，需先唤醒并解锁；本次经 SSH 隧道 5901→远端 5900 用「屏幕共享」解锁。Session 断开后远端会重新锁屏，屏幕共享需保持连接（最小化即可，CPU 0.3%）。

---

### 5.16 P2.1 定向补片（frame-nack）：公网门禁 PASS（2026-11-20 20:4x–21:2x）

代码基线 `ff7f922` + 未提交的 NACK 改动（两端均已重编）。环境同 §5.15：host = Tahoe 26.5.2 / 25F84（Macmini8,1，公网 `112.5.32.34:46600`），client = Sequoia 15.5 / 24F74（本机），镜像模式、`P2_INJECT=record`、`p2.sh host/client` 经 Terminal 启动。

**设计：客户端补片 NACK + 主机定向重发**

| 环节 | 行为 | 参数 |
|---|---|---|
| 客户端检测 | 部分帧超过 `repairRequestMs` 未进展（或重试到期）时，从位图取缺失下标（≤64） | 60 ms |
| 上行请求 | 走可靠控制通道发 `{"type":"frame-nack", frameSeq, fragCount, indices[]}`；限速 5 ms/次 | — |
| 主机重发 | 分片缓存按帧保留最近 64 帧，只重发缺失分片，经 `sendPriorityDatagram:` 插到发送队列最前 | `M1_FRAG_CACHE=64` |
| 重试 | 同帧最多 3 次、间隔 120 ms；收到新分片即重置 | 120 ms × 3 |
| 帧期限 | 补片后期限改为 `max(repairGraceMs, frameDeadlineMs)`，基准取「最后进展 / 补片请求」较晚者 | 250 ms |
| 兜底 | 超过期限仍不全 → 判丢并请求关键帧；在飞 IDR 保护窗口内抑制重复请求 | 500 ms |
| 重组窗口 | 在飞帧上限 8 → 12，给补片留头寸 | `M1_FRAME_WINDOW` |

统计新增：client `repairRequests / repairRequestsSent / repairRttMs / frameNacksSent`，host `frameNacksReceived / frameNacksRepaired / frameNacksMissed / fragmentsResent`。

**三轮结果（`p2.sh summary`，WAN 阈值 0.85）**

| 轮次 | 形态 | 采集/编码/发出 | 解码/发出 | 丢帧率 | awaitingKeyframe | NACK | 关键帧请求 | 控制间隔 | 判定 |
|---|---|---|---|---|---|---|---|---|---|
| J | 720p15 / 40s，桌面有活动 | 587/586/586 | 526/586 = **0.898** | 4.0% | 3635ms（9.1%） | 60 发，修复 RTT 12ms/53，主机重发 99 片 | 6/6 | 1091ms | **PASS** |
| K | 同上，桌面静止 | 99/98/98 | 73/98 = 0.745 | 15.3% | 5236ms（13.1%） | 17 发 | — | 1053ms | 不计（采集仅 98 帧，样本不足，见下） |
| L | 同上 + 远程动画窗口 | 592/591/591 | **591/591 = 1.000** | **0.0%** | 119ms（0.3%） | **119/119 命中、0 未命中**，重发 241 片 | 0 | 1108ms | **PASS** |

三轮共同点：握手 62–69 ms、`sendFailures=0`、状态链完整、渲染解码失败 0。J 的丢帧尾部是数次 `gap-after-repair` 后的级联；L 无关键帧请求，说明补片已把丢片在帧期限内补齐。

**结论（v0.37）**
- 定向补片在不改协议阈值的前提下把 WAN 门禁从 0.186–0.641 拉到 **0.898–1.000**，等待关键帧 9.1%→0.3%，控制间隔 <1.2s。**不调 WAN 0.85 阈值**。
- 补片只重发缺失分片（L 轮 119 次请求共 241 片），代价远低于整帧 IDR（IDR 28–87 片且要等编码器），修复 RTT 12ms；无补片时同样的 2–3% 片丢失会触发 1.5–3.5s 的 IDR 重建。
- 仍待推进（P2.3）：L 轮平均渲染 73.2ms/帧、J 轮 806.7ms（窗口遮挡/积压干扰），上屏 329/526 帧，渲染是下一瓶颈；本轮不归因到协议层。

**操作注意（新增）**
- 采集按内容变化送帧：桌面静止时 40s 只有 99 帧（K），不能拿来判门禁。测试时在 host 跑 `/tmp/anim.swift`（全屏彩条动画，75s；经 `open /tmp/anim.command` 启动，首次 swift 编译约 10s），L 轮即由此取得 591 帧。
- host 锁屏会阻断 preflight（`CGSSessionScreenIsLocked=1`）；SSH 下无法解锁——CGEvent 无辅助功能授权会被登录窗丢弃，AppleScript 的 TCC 弹窗在锁屏下不可见；需人工解锁一次。

---

### 5.17 P2.2 独占会话 + C-09 跨机实测（2026-11-20 21:0x–21:4x）

环境同 §5.15/§5.16。host 以 `P2_EXCLUSIVE=1` 经 Terminal 启动（`stream_probe --exclusive`：建虚拟屏→禁全部物理屏→C-09 校验→用虚拟屏采集），client 传 `P2_SPEC` 做尺寸断言。为制造画面变化，host 上运行 `/tmp/anim.swift`（主屏自适应彩条窗口）。

**结果（WAN，40s）**

| 轮次 | 形态/规格 | 采集/编码/发出 | 客户端解码/发出 | 丢帧率 | awaitingKeyframe | 补片 | 关键帧请求 | 渲染/帧 | 判定 |
|---|---|---|---|---|---|---|---|---|---|
| A | **独占** 1280×720@15 | 529/528/528 | **511/528 = 0.968** | 0.8% | 2883ms（7.2%） | 134 帧命中 / 0 未命中 | 2/2 | 25.9ms | **PASS** |
| B | 独占 1920×1080@20，动画后启动 | **43**/43/43 | 6/43 | 5/6 帧（收齐仅 6） | — | 8 帧命中 / 0 未命中 | 1/1 | 31.6ms | FAIL（采集侧） |
| C | 独占 1920×1080@20，动画先启动 | **30**/29/29 | 6/29 | 同上 | — | 7 帧命中 / 0 未命中 | 1/1 | — | FAIL（采集侧） |
| D | 镜像 1920×1080@20（对照） | **778**/777/777 | 216/777 = 0.278 | 38.0% | 26249ms（65.6%） | 65 帧命中 / 0 未命中 | 35/35 | 64.9ms | FAIL（渲染瓶颈） |

**C-09 证据（A/B/C 三轮一致）**：`sessionMode=exclusive`、`c09Status=verified`、`virtualDisplayIDs=[4128835]`、`activeDisplayIDsAfterDisable=[4128835]`（仅虚拟屏）、`sessionRecovered=true`；结束后 host 打印「已恢复物理屏并销毁虚拟屏」，复测 `preflight host` 显示 `active=2`。客户端的 `请求规格/解码尺寸` 均一致（720p 轮 1280×720 → 1280×720）。

**结论（v0.38）**
- **P2.2 核心判据成立**：720p15 独占 + C-09 在 Tahoe host × Sequoia client 跨公网端到端 PASS；客户端解码 0.968、丢帧 0.8%、控制间隔 1.38s、补片 134/134 命中。物理屏会话期间仅虚拟屏 active，结束后恢复。
- **1080p 独占受采集侧阻塞**：同一 host、同一动画窗口，虚拟屏 1920×1080 时 SCK 只送出 30–44 帧/40s（≈0.8–1.1fps），客户端只能解出 6 帧；而镜像 1920×1080 采集 778 帧（≈19.4fps）。⇒ 是**零物理屏 + 1080p 虚拟屏的 SCK 送帧退化**（A-08 变体），不是传输/补片问题。
- **1080p20 客户端渲染仍超预算**：镜像对照 `lastRenderMs=64.9ms`（50ms 预算），导致 65.6% 时间在等关键帧、丢帧 38%；与独占无关，属 P2.3 渲染瓶颈。补片在这轮仍是 65/65 全命中、0 未命中。
- 不调阈值；1080p 独占/20fps 需先解决虚拟屏采集帧率与客户端渲染，再作为门禁档位。

**操作注意**：独占轮次中动画窗口若在禁屏前已存在，可能留在被禁物理屏上，虚拟屏只剩静态桌面（B/C 均 1fps 级）；即便独占后再启动（A）720p 正常，1080p 仍退化，故 B/C 的差异不是窗口位置能解释的。每轮结束用 `preflight host` 核对 `active` 屏数。

> **2026-11-20 21:5x 补正（已闭环）**：本机反证（§5.18）表明 1080p 虚拟屏在内容持续变化时可满 20fps。Tahoe 用按 displayID 贴窗的 `anim_display.sh 4128835 60` 复测（§5.19）：30s 采 450 帧、每秒 `complete=20 idle=0`、客户端解码 427/449=0.951、丢帧 1.4%，**PASS**。⇒ B/C 的 1fps 是动画窗口没落在虚拟屏（内容 idle），**「零物理屏 + 1080p 采集退化」的 A-08 变体结论撤回**，非采集侧缺陷。

### 5.18 1080p 虚拟屏采集反证：缺的是内容变化，不是送帧能力（2026-11-20 21:3x–21:4x，Sequoia 本机）

本机（Sequoia 15.5，Intel UHD 630，3 块物理屏：U28G2G6B 3008×1692pt 主屏 / M2427Q 1440×2560 竖屏 / HDMI 1920×1080）跑 `pipeline_kiosk_probe --spec 1920x1080 --fps 20`（虚拟屏 displayID 4128835），用新增的 `[capture]` 每秒状态行区分 complete/idle。

| 轮次 | 配置 | captured | 稳态 | 每秒 idle | 判定 |
|---|---|---|---|---|---|
| 对照 | `--keep-main`，动画窗口按 `NSScreen` 猜屏 | 48 / 20s（2.2fps） | 1–3 complete/s | 17–20 | 无效样本 |
| 定位 | 同上 + `tools/anim_display.sh 4128835`（按 displayID 贴窗） | **479 / 25s（18.5fps）** | **20 complete/s，idle=0** | 0 | **PASS** |
| 全禁 | 去掉 `--keep-main` + 同款贴窗动画 | — | — | — | C-09 拦下（见下） |

**结论**
1. **1080p 虚拟屏采集能力正常**：内容持续变化时 25s 采 479 帧（18.5fps，含启动开销），首帧 339ms，环回解码 478/478、零丢片；每秒 `complete=20 / idle=0`。
2. **§5.17 B/C 的 1fps 是测试内容问题**：SCK 按内容变化送帧，静止虚拟桌面每秒只给 ~1 个 complete 帧，其余是 idle（无像素缓冲，计入 rejected）。不是「零物理屏 + 1080p」的采集退化。
3. **工具缺口**：B/C 用的 `/tmp/anim.swift` 按 `NSScreen.main` 取屏，禁屏重排后窗口可能已不在虚拟屏上。新增 `P2-Dual/tools/anim_display.sh <displayID>`，按 `NSScreenNumber` 贴窗并在每次布局变化后重新贴回。
4. **本机全禁被 C-09 正确拦下**：本机 3 屏拓扑下禁屏呈 physical-leak（两块 Thunderbolt 屏仍在 active，HDMI 那块被禁），`verifyIsolation` 报违规并回滚，守护恢复成功（`恢复成功`）。这是安全网按设计工作，不是 Tahoe 结论。

### 5.19 独占 + C-09 复测：Tahoe host × Sequoia client（2026-11-20 21:5x–22:0x，WAN，30s）

前置：host 人工解锁，Terminal 内跑 preflight 确认 `capture=1`（SSH 下因 TCC 归 sshd 仍显示 0，必须由 GUI Terminal 侧验证）。host 以 `P2_EXCLUSIVE=1 P2_SPEC=1920x1080 P2_FPS=20` 启动，随后在虚拟屏就绪时运行 `./gui-run.sh ./tools/anim_display.sh 4128835 60`（按 `NSScreenNumber` 贴窗、每 tick 重锚）。

| 指标 | 数值 |
|---|---|
| 采集/编码/发出 | **450 / 449 / 449**（30s，15fps 平均含启动；稳态 `complete=20/s idle=0`） |
| 客户端收齐/解出 | 428 / 427 |
| 解码/发出 | **427/449 = 0.951**（门禁 ≥0.85） |
| 客户端丢帧 / awaitingKeyframe | 6（1.4%，门禁 ≤5%）/ 422ms（1.4%，门禁 <10%） |
| 补片 NACK | 发 58 / 命中 58 / 未命中 0，RTT 8ms（49 样本） |
| 关键帧请求 | 2 发 / 2 收，RTT 203ms |
| 控制通道最大间隔 | 1405ms（门禁 <3s） |
| 传输发送失败 / 队列丢弃 | 0 / 0 |
| 请求规格/解码尺寸 | 1920×1080 → 1920×1080（specMatch=1） |
| C-09 | `sessionMode=exclusive`、`c09Status=verified`、`virtualDisplayIDs=[4128835]`、`activeDisplayIDsAfterDisable=[4128835]`、`sessionRecovered=true` |
| 判定 | **PASS**（`p2.sh summary`） |

**结论**
- **P2.2 1080p20 独占门禁通过**：采集稳态满 20fps，WAN 解码率 0.951、丢帧 1.4%、等待关键帧 1.4%、补片 58/58 全命中；C-09 只留虚拟屏、结束后恢复（动画窗口随虚拟屏消失打印「display 4128835 已消失」，说明贴窗确实作用在虚拟屏上）。
- **校验夹具结论成立**：与 §5.18 本机反证一致，1080p 虚拟屏采集能力正常；此前的 1fps 是内容 idle，非 A-08 退化。
- **残留 P2.3**：客户端渲染仍高（lastRenderMs=81.8ms，max=262.5ms，上屏 207 帧），1080p 下渲染是下一步优化重点；不影响本轮结构性门禁。

**720p15 独占回归（同一晚 21:5x，`regress-720-excl-1120`）**

同一套 `anim_display` 贴窗夹具，host `P2_EXCLUSIVE=1 P2_SPEC=1280x720 P2_FPS=15`：

| 指标 | 数值 |
|---|---|
| 采集/编码/发出 | 442 / 441 / 441（`[capture]` 稳态 complete=15/s idle=0） |
| 客户端收齐/解出 | 414 / 414 |
| 解码/发出 | **414/441 = 0.939** |
| 客户端丢帧 / awaitingKeyframe | 4.8%（门禁 ≤5%）/ 2.3% |
| 补片 NACK | 发 25 / 命中 25 / 未命中 0 |
| 关键帧请求 | 5/5，RTT 136ms |
| 控制通道最大间隔 | 1016ms |
| C-09 | `verified`，`activeDisplayIDsAfterDisable=[4128835]`，`sessionRecovered=true` |
| 判定 | **PASS**（`p2.sh summary`） |

**720p 回归结论**：新构建下 720p15 独占 + C-09 仍 PASS，规格 1280×720 一致；丢帧 4.8% 贴近 5% 门禁，但补片 25/25 全命中、sendFailures=0，属 WAN 正常波动。客户端渲染 89.7ms **不可用作 P2.3 判据**——当日本机 Qoder 渲染进程 ~170% CPU、Spotlight `mds_stores` 44%（`/Volumes/Data-common` 索引 transitioning），渲染测量需在空闲机器上重做。

**1080p20 镜像对照（四轮，`mirror-1080-1120` / `1120b` / `1120c` / `1120d`）**

host 镜像主屏 3440×1440 → 编码 1920×1080@20；a/b 轮动画窗口 1200×700 贴在窗口丛林上，c/d 轮改为**全屏**动画条（覆盖所有窗口和壁纸，用来单独验证「窗口多/内容复杂」是否是根因）：

| 轮次 | 画面 | 采集/编码/发出 | 客户端解码/发出 | 丢帧 | awaitingKeyframe | 补片 NACK | 关键帧 RTT | 渲染/帧 | 判定 |
|---|---|---|---|---|---|---|---|---|---|
| a | 窗口+壁纸 | 589/588/588 | **482/588 = 0.820** | 3.7% | 4863ms（16.2%） | 37/37 | 1232ms | 69.6ms | FAIL |
| b | 窗口+壁纸 | 587/585/585 | **476/585 = 0.814** | 5.9% | 4902ms（16.3%） | 69/69 | 1418ms | 31.5ms | FAIL |
| c | 全屏动画条 | 589/588/588 | **461/588 = 0.783** | 10.4% | 4704ms（15.7%） | 45/45 | **124ms** | 19.3ms | FAIL |
| d | 全屏动画条 | 589/587/587 | **544/587 = 0.927** | 3.3% | 1434ms（4.8%） | 51/51 | 1168ms | 24.1ms | **PASS** |
| 720p 对照 | 全屏动画条 | 443/442/442 | **434/442 = 0.982** | 1.2% | 310ms（1.0%） | 50/50 | 148ms | 4.6ms | **PASS** |

**镜像对照结论**
- **窗口多不是根因**：c/d 轮用全屏动画条把窗口和壁纸全部遮住，画面对标虚拟屏的纯色条，结果仍是一轮 FAIL（0.783）、一轮 PASS（0.927）。关闭 host 窗口只能缩小 IDR，不能消除镜像 1080p20 的失败。
- **真正敏感的是「关键帧请求次数 × 恢复时延」**：c 轮 IDR 很小（RTT 124ms），但因缺口级联触发 10 次关键帧请求，累计 awaiting 4.7s；d 轮只请求 3 次，即使单次 RTT 1168ms（画面复杂时 IDR 大），总 awaiting 仅 1.4s 而过线。a/b 的窗口画面同时抬高 IDR 与请求次数，所以两轮都深跌。
- **补片链路正常**：四轮 37/37、69/69、45/45、51/51 全命中、0 未命中；丢帧明细是「1–3 片缺口 → 前帧判丢 → 后续 ready 帧连带作废」，说明败点在缺口发生后的关键帧重建级联，不是 NACK 没工作。
- **720p 镜像稳定**：同夹具 434/442=0.982、丢帧 1.2%、补片 50/50、仅 1 次关键帧请求，说明镜像链路本身与 3440→720 缩放没问题。
- **结论**：镜像 1080p20 在当前 ~2.5Mbps WAN 上属临界档（4 轮 1 过），暂不作为门禁；若作为研究项，应优化「缺片后快速恢复 IDR 缺片」或降低 20fps 档的级联触发率。**不需要为此关闭 host 窗口**；若想留余量，全屏简单画面/纯色壁纸可减小 IDR。
- **操作提示**：SSH 下用 `osascript` 控制/枚举窗口会弹 TCC 授权框（responsible app 是 sshd-keygen-wrapper）且无法远端点击，**不要用**；本次误触发的弹窗已通过重启 `UserNotificationCenter` 消除。

**1080p20 镜像复测（整帧补片修复后，`mirror-1080-1120f` / `1120g`）**

失败链路在失败轮次已定位到「`nextSeq` 整帧零分片 → 没有任何 partial 可做缺片补丁 → 120ms 后 `declareLoss` 清掉全部在途 partial 与已就绪帧 → 只能等下一个 IDR」。修复：

1. 重组器 `checkGapDeadlineAt` 对零分片缺口也先发补片请求（`frame-nack` + `all:true`，`fragCount=0`、缺片集合为空），60ms 首问、120ms 重问、最多 3 次，之后才判丢；发送端从分片缓存整帧重发。
2. `maxRepairFragments` 32→64，覆盖 1080p 大帧的尾部连续缺片。
3. 整帧补片使用独立 5ms 限流（环回实测与定向补片共用会被挤占，9 次请求只发出 3 次）。

同夹具（Tahoe 镜像主屏 → 1920×1080@20，全屏动画条，WAN，30s）：

| 轮次 | 采集/编码/发出 | 客户端解码/发出 | 丢帧 | awaitingKeyframe | 补片 NACK（整帧） | 关键帧请求 | 渲染/帧 | 判定 |
|---|---|---|---|---|---|---|---|---|
| f | 568/566/566 | **564/565 = 0.998** | 0.0% | 231ms（0.8%） | 35/35（0） | **0** | 182ms* | **PASS** |
| g | 589/588/588 | **586/587 = 0.998** | 0.0% | 84ms（0.3%） | 46/46（2） | **0** | 194ms* | **PASS** |

\* 渲染数字仍是本机负载下的失真值（Qoder/Spotlight 同机），P2.3 空闲环境重测前不作判据。

**复测结论**
- 两轮均 0 关键帧请求、0 丢帧；对照修复前同夹具 4 轮（0.820/0.814/0.783/0.927，c 轮 10 次关键帧请求）为决定性改善。
- g 轮真实触发 2 次整帧补片请求，主机全部命中（46/46），证明 `all:true` 路径在 WAN 上有效。
- 先前「镜像 1080p20 属临界档、暂不作为门禁」的结论撤回；补片修复后可作为 WAN 镜像门禁档。
- 单测新增整帧重发/零分片重试上限/补片后续传 3 组，全套 264/264 通过；本机环回 8% 模拟丢片下整帧请求 4/4 过线、19 次补片全命中。

---

## 6. 状态汇总

| 假设 | Sequoia | Tahoe |
|---|---|---|
| A-01 Tahoe SPI 可用 | — | ✅ 关闭 |
| A-04 虚拟屏容量与物理屏解耦 | — | ✅ 关闭 |
| A-08 物理屏全禁后仍可建屏/捕获/注入 | ✅ 核心关闭（SCK OK） | ✅ 关闭：V-01 通过；V-03 显示隔离+恢复成立（已登录零物理屏下 SCK 不可靠，但公开抓屏 API 稳定可用）；V-02 锁屏建屏成立；禁屏后登录 UI 完整迁移 |
| A-09 锁屏/登录窗可远程进入 | V-04a/b ✅、V-04c 未测、V-04d 未实现 | ✅ **关闭**：V-04a/b/c/d 全过，Path A 端到端成立；前置防显示睡眠（屏睡态 SCK 无帧，caffeinate 可避免） |
| A-02 glass-to-glass 延迟 | 未测 | ⚠️ 部分推进：M1-Pre 采集编码链路成立，但带编码的真实帧率 `CGDisplayCreateImage` 1–7fps / SCK 2–18fps，均远达不到 60fps；首帧延迟 739–1031ms；无编码时的 55fps 是假象。2026-11-19 跨公网已取得首批双机数据（§5.13，Tahoe host × Sequoia client）：1080p20 客户端渲染 84.7ms/帧、解码/发出 54/375；720p10 渲染 41.6ms、上屏 0 积压；补测 C/D 拿到完整配对（3440×1440 → 7 解出；720p15 → 136/443，丢包 4–6% + 严格按序重组等关键帧是主因）。无 60fps / glass-to-glass 证据，A-02 保持开放，见 D-10 |

---

## 7. 变更记录

- v0.43-draft 2026-11-20 23:0x：**整帧补片修复 + 镜像 1080p20 两轮 PASS，见 §5.19 补节**。零分片缺口改为 `frame-nack all:true` 请求整帧重发（60ms 首问/120ms 重试/上限 3 次后判丢），`maxRepairFragments` 32→64，整帧补片独立限流。f/g 两轮 564/565、586/587=**0.998**，丢帧 0、关键帧请求 **0**（修复前同夹具 0.820/0.814/0.783/0.927、c 轮 10 次请求）；g 轮整帧补片 2 次全部命中，补片共 35/35、46/46。单测 264/264；环回 8% 模拟丢片验证整帧路径 4/4 过线。镜像 1080p20 撤回「临界档」结论。
- v0.42-draft 2026-11-20 22:3x：**镜像 1080p20 四轮 + 720p 对照，窗口假设排除，见 §5.19**。a/b（窗口画面）解码 0.820/0.814；c/d 用全屏动画条遮住所有窗口与壁纸后仍 0.783 FAIL / 0.927 PASS；720p 镜像同夹具 0.982 PASS。⇒ 窗口数量只影响 IDR 大小，失败主因是「缺口→关键帧重建」级联次数（c 轮 10 次请求/awaiting 4.7s vs d 轮 3 次/1.4s），不需要关闭 host 窗口。补片四轮全命中（37/37、69/69、45/45、51/51）。`anim_display` 新增 `full` 参数（铺满整屏）。附操作坑：SSH 下 `osascript` 控制窗口会弹不可点的 TCC 授权框，误触弹窗用 `killall UserNotificationCenter` 清除。
- v0.41-draft 2026-11-20 22:2x：**1080p20 镜像对照两轮 FAIL，见 §5.19**。host 镜像 3440×1440→1920×1080@20 × Sequoia client，各 30s：a 采集 589/发 588/解码 482=**0.820**、丢帧 3.7%、awaiting 16.2%、关键帧 RTT 1232ms；b 587/585/476=**0.814**、丢帧 5.9%、awaiting 16.3%、RTT 1418ms（b 轮渲染仅 31.5ms，排除负载）。补片 37/37、69/69 全命中。当时判断镜像大 IDR 是 FAIL 主因；**该判断已被 v0.42 全屏对照修正**——遮住窗口后仍有一轮 FAIL，真正敏感的是关键帧请求级联次数。`anim_display` 增加 `0=主屏` 以便镜像测试。本轮还补入 720p15 独占回归（0.939 PASS）。
- v0.40-draft 2026-11-20 22:0x：**Tahoe 独占复测 PASS（1080p20 + 720p15），见 §5.19**。人工解锁 + GUI Terminal preflight `capture=1` 后，host × Sequoia client 各 30s、`anim_display` 按 displayID 贴窗：**1080p20** 采集 450、发出 449、解码 427/449=**0.951**、丢帧 1.4%、awaiting 1.4%、补片 58/58、控制间隔 1.4s、sendFailures=0，`c09Status=verified` 且 `sessionRecovered=true`，**PASS**；**720p15 回归** 采集 442、发出 441、解码 414/441=**0.939**、丢帧 4.8%、awaiting 2.3%、补片 25/25，同样 **PASS**。`[capture]` 稳态分别 complete=20/s、15/s，idle=0，证明动画确实贴在虚拟屏 4128835。⇒ **A-08 变体（零物理屏+1080p 采集退化）正式撤回**，§5.17 B/C 的 1fps 归因为内容 idle。残留：客户端渲染测量失真（本机 Qoder ~170% CPU + Spotlight 索引中，720p 也显示 89.7ms），P2.3 需在空闲环境重测。
- v0.39-draft 2026-11-20 21:5x：**1080p 虚拟屏采集反证，见 §5.18**。Sequoia 本机 `pipeline_kiosk_probe` 1920×1080 + 按 displayID 贴窗动画：25s 采 479 帧（18.5fps）、每秒 complete=20/idle=0、环回解码 478/478、PASS；同一探针不动画时只有 48 帧（2.2fps，idle 17–20/s）。⇒ SCK 在 1080p 虚拟屏上满速可用，§5.17 B/C 的 1fps 是「内容没落在虚拟屏」导致的 idle，不是采集退化；A-08 变体结论撤回，待 Tahoe 复测。新增 `[capture]` 每秒状态行、启动配置行、`M1_CAPTURE_RESOLUTION`（auto/best/nominal）、`P2-Dual/tools/anim_display.sh`；`frame-nack` 补 36 条单测（重发下标/越界/缓存淘汰/关闭、NACK 时限/重问 3 次/超缺失片上限/RTT），并修「缓存关闭仍重发旧条目」，单测 243/243 PASS。本机全禁被 C-09 拦下（3 屏拓扑 partial disable）并按设计恢复。另注：本机 `render_selftest` 各档位耗时在 Spotlight 高负载下抖动极大（1080p 33–74ms），暂不可用于优化判据。
- v0.38-draft 2026-11-20 21:4x：**P2.2 独占 + C-09 跨机实测，见 §5.17**。720p15 独占（Tahoe host × Sequoia client，WAN）：`c09Status=verified`、`activeDisplayIDsAfterDisable=[4128835]`、`sessionRecovered=true`，客户端解码 511/528=0.968、丢帧 0.8%、等待关键帧 7.2%、补片 134/134 命中，**PASS**；结束后物理屏恢复（active=2）。1080p20 独占两轮均被采集侧卡住：虚拟屏 1920×1080 时 SCK 只送 30–44 帧/40s，而镜像 1080p 同机采集 778 帧（19.4fps）⇒ 零物理屏 + 1080p 虚拟屏的送帧退化（A-08 变体），非传输问题。镜像 1080p 对照另暴露客户端渲染 64.9ms/帧（50ms 预算），解码率 0.278、丢帧 38%，归 P2.3。阈值未调整。
- v0.37-draft 2026-11-20 21:2x：**P2.1 定向补片（frame-nack）落地，公网门禁 PASS，见 §5.16**。客户端重组器对停滞帧发 `frame-nack`（缺失分片下标，≤64，走可靠控制通道，限速 5ms）；主机 64 帧分片缓存定向重发，经 `sendPriorityDatagram:` 插队；同帧重试 120ms × 3，补片后帧期限改 `max(repairGrace 250ms, frameDeadline 120ms)`，IDR 在飞 500ms 抑制重复请求；在飞帧窗口 8→12。WAN 720p15/40s：J 轮解码 526/586=**0.898**、丢帧 4.0%、等待关键帧 9.1%、NACK 修复 RTT 12ms；L 轮（host 加动画窗口）**591/591=1.000**、丢帧 0%、等待 0.3%、119/119 补片全部命中、0 次关键帧请求。`p2.sh summary` 两轮均 PASS，阈值未调整。单测 207/207 PASS。附操作坑：采集按内容变化送帧（静止桌面 40s 仅 98 帧），测试需在 host 跑动画窗口；host 锁屏阻断 preflight，需人工解锁。
- v0.36-draft 2026-11-20 20:0x：**P2.1 公网门禁复测（FAIL）+ Tahoe kiosk 冒烟（PASS），见 §5.15**。三轮 WAN（720p×2、640×360×1）解码/发出 0.186–0.641，等待关键帧 29–76%，关键帧 RTT 稳定 ≈3.2s；`sendFailures=0`、请求全部到达编码器、渲染干净轮 3.1ms/帧。同路径 ICMP 60/60、UDP 6000/6000、尺寸扫描 2400/2400、90 片突发 27000/27000 全收——**公网路径 0 丢包，应用层 ≈2–3% 片丢失发生在 QUIC datagram 层**（同步 send 返回成功、`sendErr=0`）；IDR 28–87 片使残缺 IDR 放大成 3s 级停顿。下一步先给 transport 加收/发计数与回调背压治理，再评估 FEC，不调整 WAN 0.85 阈值。P2.2：Tahoe `pipeline_kiosk_probe --keep-main` 冒烟通过（虚拟屏 4128835、1280×720、首帧有画面、恢复成功、2 屏恢复）；全禁物理屏 + C-09 仍未跑。操作记录：远端锁屏会阻断 SCK，需屏幕共享（SSH 隧道）解锁并保持会话。
- v0.35-draft 2026-11-20 10:1x：**补齐 P2.1 唯一未落地的观测指标 `keyframeRequestRttMs`**（纯开发，未跑实时测试）。`M1FrameReceiver` 新增 `noteKeyframeRequestSent()`：仅客户端成功把 keyframe-request 送上控制通道才记起点，同一等待周期的重复请求不重置；收到关键帧并完整重组时结算 RTT，记录最近值与样本数。口径为「首个成功请求 → 关键帧重组到达」，不含 VT 解码/上屏。`stream_probe` client JSON/控制台新增 `keyframeRequestRttMs / keyframeRequestRttSamples`，`p2.sh summary` 增加展示行但**不设门禁**。验证：build_stream_probe 无 warning、单测 207/207 PASS、summary 合成夹具正确显示 `412 ms / 3 次`。不改任何已测结论。
- v0.34-draft 2026-11-20 09:5x：**纯开发轮次——独占会话退出保护 + C-09 证据 + 联调门禁补齐**（未跑实时测试，按用户安排留到晚上）。① `stream_probe.m` 补三处 `endExclusive()`：等待客户端超时、`--inject` 非法、`--wait-ms 0` 单次接入失败；无限等待失败还会清掉 `virtualDisplayID`，防止下一次拿旧屏 ID 采集。② host JSON 新增 `virtualDisplayIDs / activeDisplayIDsAfterDisable / c09Status / sessionPhase / sessionRecovered / sessionEnded`，两端 JSON 新增 `streamDurationMs`；client 未传 `--spec` 时记 `effectiveWidth/Height/effectiveSpecMatch`（session-ready 里 host 实际建的屏规格），独占模式据此断言解码尺寸。keep-main 明确记 `skipped-keep-main`，不能谎报 C-09 通过。③ `p2.sh host` 新增 `P2_EXCLUSIVE / P2_KEEP_MAIN / P2_SIM_LOSS / P2_SIM_REORDER` 透传；`summary` 解码门禁按 LAN 0%=0.98 / LAN 0.1%=0.90 / WAN=0.85 / ≥1% 只记趋势分层，新增帧丢弃率、等待关键帧占比（分母 `streamDurationMs`）、keyframe-request 到达、独占 C-09 与恢复证据判定。验证：build_stream_probe 无 warning、单测 207/207 PASS、summary 12 组合成夹具（正常/三种超限/WAN 两档/0.1% 两档/独占 C-09 缺失与恢复失败/keyframe 未到达/实际屏规格一致与不一致/显式 spec 优先）全部符合预期。工程加固，**不改任何已测结论**。
- v0.33-draft 2026-11-20 09:4x：**P2.3.2 渲染自检多档位回归（Tahoe 26.5.2 / Macmini8,1 本机离屏）**。`render_selftest` 由写死的 640×360 + 3440×1440 重构为 `RunCase` 四档：640×360 / 1280×720 / 1920×1080 / 3440×1440，每档校验 color（左红右蓝、R/B 不互换）、输出尺寸=源、IOSurface-backed、letterbox 几何（独立公式算期望，覆盖高度受限与宽度受限两种方向）、单帧耗时护栏。本机 ALL PASS，离屏单帧：**VGA 5.8ms / 720p 8.6ms / 1080p 13.9ms / 3440×1440 32.5ms**（max 32.5ms，0 丢帧）。这是**纯 CIContext 转换成本**，不含窗口合成与 GPU 提交阻塞，不能当跨机上屏帧率结论（Sequoia 1080p ≥24fps 仍待实测）。据此确认 P2.3.1 IOSurface 直贴已落地、无 CGImage 回读。
- v0.32-draft 2026-11-20 08:5x：**补齐 P2.2 的规格断言**。client 新增 `requestedWidth/Height/specMatch`（`--spec WxH` / `P2_SPEC`），控制台打印「规格断言」；`p2.sh summary` 仅在 `sessionMode` 为独占时把尺寸不符判 FAIL，镜像模式不参与判定（镜像不建屏）。新增 `P2_SPEC` 环境变量透传。另补 `P2_WIDTH`/`P2_HEIGHT` 透传 host 编码输出尺寸（此前只有直接调 `stream_probe --host --width/--height` 才能降分辨率，`p2.sh` 不透传）——环回验证 host 输出 1280×720、client 解码 1280×720、40/40 帧；`usage` 同步补上这两个参数。环回验证三条路径：镜像模式请求 1280×720/解码 3440×1440 → 断言 FAIL 但 summary PASS（符合预期）；伪造独占 + 不符 → summary FAIL；伪造独占 + 一致 → summary PASS。单测 **207/207 PASS**。仍未测：Tahoe host 跑本轮独占代码、全禁物理屏 + C-09、跨公网 P2.1 门禁复测。
- v0.31-draft 2026-11-19 22:5x：**P2.1/P2.2 首轮落地（Sequoia 本机）**。重组器 v3（位图+帧期限+乱序容错）、帧级指标、keyframe-request 全链路（客户端 1s 重试、主机 900ms 合并）；720p 丢片矩阵 0%=1.00、0.1%=0.955、1%=0.13、5%=0。P2.2 修掉 Sequoia 上误用 Tahoe 保守建屏导致的残留槽位镜像死锁，`--exclusive --keep-main` 冒烟 PASS（虚拟屏 4128835、31/31、恢复成功）；控制间隔门禁改为仅统计 STREAMING 之后。详见 §5.14。
- v0.1-draft 2026-11-18：首次建立按 OS 分离的结论表；把 Sequoia 与 Tahoe 的 V-01/V-03/V-04 结论拆开，明确禁止跨版本外推。
- v0.2-draft 2026-11-18：补入 Tahoe V-02（锁屏态虚拟屏 `active=false`，不成立）、V-04a（通过）、V-04b（判据污染，未确认）、V-04d（不成立）；补入替代采集路径对照结果（`CGDisplayCreateImage`/`CGWindowListCreateImage` 稳定可用）。
- v0.3-draft 2026-11-18 10:40：**重要更正**。发现 v0.2 的 V-02 结论是假阴性——探针 `waitUntilUsable` 提前退出 + 脚本 `awk $3` 取错 ID，捕获从未执行。用户补充「锁屏 2-3 秒后屏睡」后重测：① 屏睡导致 SCK 无帧，caffeinate 先于 lock 可保持屏亮、SCK 恢复 50 帧；② 锁屏态虚拟屏实际 `active=1`（两种状态均是）；③ 截图显示虚拟屏上只有锁屏壁纸、无登录框。撤回「Path A 在 Tahoe 不成立」，改记「Path A 未验证」；V-04d 不成立理由从「不能建 active 屏」更正为「登录 UI 未迁移到虚拟屏」。
- v0.4-draft 2026-11-18 10:52：**Path A 端到端成立，结论翻转为通过**。v0.3 的「登录框未迁移」是假阴性——此前探针只建虚拟屏、未禁物理屏，登录 UI 自然留在物理屏。本次 r5/r6 两轮在锁屏+屏亮态禁掉全部物理屏后，虚拟屏截图出现完整登录 UI（日期/时钟/`bemin`/密码框），且无 focus 对照同样成立 → 迁移触发条件是「零 active 物理屏」，与光标无关。用户授权的真实凭据经 `P0V_PW` 环境变量在运行时注入，V-04b/c 干净通过（`INJECTION_ACCEPTED_AND_UNLOCKED`、256/256、会话 locked→unlocked），脚本/日志/文档均无明文密码。A-08/A-09 在 Tahoe 关闭，D-08 四项全过，不再回退 Path B。
- v0.5-draft 2026-11-18 11:30：新增 §5.1 M1-Pre 采编链路实测。D-09 路径端到端成立（0 黑帧、编解码一致），但 `CGDisplayCreateImage` 抓帧固定成本 95–282ms、实际 1–7fps，达不到 1080p60；一度记「SCK 55fps」。
- v0.6-draft 2026-11-18 11:35：**撤销 v0.5 的「SCK 55fps」判断**——经 `--sck-only` 带编码环回复测，55fps 来自 `withEncoder:NO` 的按内容送帧假象（`encodedFrames=0`、首帧 847ms）。真实带编码帧率：SCK 禁屏 18fps、不禁屏 2fps，`CGDisplayCreateImage` 禁屏 4fps，均不达 60fps。新增 §5.2。D-09 修正为「SCK 相对更优但绝对值也不达标，应回主路径 + 同时降规格/流水线优化」，见 D-10。
- v0.7-draft 2026-11-18 14:45：M1 骨架层完成（不依赖帧率部分）。新增 `M1-Skeleton/` 生产驱动 `M1RDPDriver`（IOKit 双断言+VDManager+P0VDisplayControl+C-09 隔离+CGEvent 凭据注入）、`M1InputInjector`（CGEvent seam+手势 tap）、驱动/输入纯逻辑（69 断言单测）；`RDPApp/` Swift 主+ObjC 静态库桥接端到端跑通（Swift 实现 ObjC protocol）。`driver_probe` 只读侦察确认现场 API 可用。真 loginwindow（`loginDone=0`）补测脚本 `P0V-SessionRecon/run_loginwindow_probe.sh` 已备好但未执行（需登出，交用户决策）。帧管线/Metal/双机延迟仍未开始。
- v0.8-draft 2026-11-18 15:35：**真 loginwindow 补测正式延后 M2 借测机（D-11）**，主力机不再承担需登出中断会话的测试。新增只读前置探针 `P0V-SessionRecon/gui_session_probe.m`——用 `CGSessionCopyCurrentDictionary` 判定是否在 GUI 会话、逐屏 `CGDisplayCreateImage` 采样算 luma，输出三态结论（`READY_FOR_LOGINWINDOW_PROBE` / `NOT_IN_GUI_SESSION` / `GUI_BUT_NO_CONTENT`），严格不动显示配置；实测当前主力机 2 屏 `HAS_CONTENT`、判定 READY，逻辑自洽。`run_loginwindow_probe.sh` 改造为借测机可一次跑通：前置检查移到日志重定向之前（失败原因可见）、preflight 自动区分「不在 GUI 会话」(exit 10) 与「在会话但 TCC 拒绝抓屏」(exit 11)、不在会话时遍历 `loginwindow` pid 逐个 `bsexec` 并自动重入自身。**A-09 在 `loginDone=1` 锁屏态的结论不变，仅 `loginDone=0` 场景待验。**
- v0.9-draft 2026-11-18 16:20：**新增 §5.3 负结果（首次禁屏独占实测致整机黑屏）**。不是 SPI/WindowServer 故障，而是探针兜底链路四处断裂：① 宿主未实现 `--guardian`，守护进程 exit(2) 后父进程仍禁屏；② 快照在建虚拟屏之后才拍，虚拟屏被当成 main；③ `keepIDs:@[]` 把虚拟屏一起禁掉 → 零显示；④ C-09 判据对空集恒真，零显示被放行。另 `@finally` 是唯一恢复出口，信号直接终止进程时不执行。已按 D-12 修完：守护就绪握手（`<snapshot>.guardian-ready`，失败即禁止禁屏）、快照前移建屏前、keep 并入会话虚拟屏并自检 active 非空、`M1IsolationViolation()` 拒绝空 active、信号自管道 + 看门狗、守护兜底额外清孤儿虚拟屏。新增负向测试 `tests/guardian_handshake_test.m` 与 `--preflight` 预检；单测 120 断言全过。禁屏条件下的帧管线数据仍为空。
- v0.10-draft 2026-11-18 16:40：**修复后首次取得禁屏独占有效数据（§5.4）**：1080p20 环回 181/181 帧、零丢零错、稳态 ≈20.6fps（全窗口 14.2fps 被 3.9s 首帧拖低），码率 610kbps、平均分片 1072B。D-10 的 20fps 档在禁屏条件下可达；首帧 3924ms 明显劣于 M1-Pre 的 739–1031ms，新增待查项；60fps 仍无证据，A-02 保持开放。同时修掉 `M1FramePipeline` 在 `stop` 后把采集尺寸报成 0×0 的问题（尺寸随统计一起固化）。
- v0.11-draft 2026-11-18 17:10：**新增 §5.5 QUIC datagram 帧通道实测（M1-A 第 1/2 步）**。400 帧/1200 分片/1.22MB 环回零丢失零重复零乱序，协商上限 1497B，9.6Mbps。两条硬结论：① 瞬时突发 1200 片丢 43.6%（整帧级），发送必须按帧节奏投递；② 指纹不符只 `complete(false)` 会吊在 preparing（20s 无结论），必须主动 cancel（D-13 C-13.3）。待查：偶发 6–11s 握手离群。
- v0.12-draft 2026-11-18 18:55：**新增 §5.6 控制通道端到端 + 两个结论更正**。控制通道 8 态在真实 QUIC 连接上跑通（`--self` 5/5、两进程 host/client 通过、148 单测全过、握手 13.5–19.3ms）。三处更正：① **§5.5 的「6–11s 离群疑为 QUIC Initial 退避」作废**——真因是 p12 私钥的 keychain ACL 触发 securityd 授权阻塞，`SecKeyCreateSignature` 卡在 `mach_msg`，服务端发不出 `CertificateVerify`，客户端永停 `preparing` 且无错误码（NEG-02）；② **「QUIC stream 模式不可用」作废**——复核握手 64.6/80.4ms 正常，此前失败同因（NEG-01），D-14 改按「一个连接一条流」立论；③ 「证书材料随机损坏」假象撤回。修复：临时钥匙串 + ACL 信任当前进程 + 进程内单次导入。
- v0.13-draft 2026-11-18 19:10：**新增 NEG-04 授权弹窗复发根因与清理**。NEG-02 修完之后弹窗仍在，原因是 ① 仓库里 `quic_probe`/`pipeline_probe`/`pipeline_kiosk_probe`/`driver_probe` 四份二进制是修复前编的，仍走登录钥匙串旧路径；② `M1CopyIdentity` 在临时钥匙串创建失败时静默回退到登录钥匙串。修法：全部重建、删除回退分支（失败即报错）、临时钥匙串先 unlink 防 PID 复用残留、新增 `cleanup_stale_identities.sh`，并清掉登录钥匙串里 30 张残留测试证书。验证：`--self` 5/5（12.4–14.7ms）、`quic_probe` 默认 500 帧退出码 0、148 断言全过，且跑完后 `SecurityAgent` 不再出现。
- v0.30-draft 2026-11-19 22:1x：**补齐同一轮跨公网的双端配对，并限定 v0.29「数据面 PASS」的范围**。v0.29 只有 host 侧；本轮在同一 host 上跑 client 并留档：3440×1440/20fps/20s → client 收齐 340 / 解出 **7** / 上屏 4；720p/15fps/30s → host 444/443/443、client 收齐 401 / 解出 **136** / 上屏 129，两轮 `sendFailures=0`、控制间隔 <2s。真因：公网 UDP 到达率 94–99%，而 `P1FrameReassembler` 严格按序、丢或乱一片即整帧作废，且 client 的 `onNeedKeyframe` 只计数、wire 上没有 `keyframe-request`，只能等 host 每 2s 的周期关键帧——丢一片被放大成 2s 停顿，解码率跌到 0.31（720p15）/0.02（3440×1440）。另更正 `framesDropped` 是分片计数（1559 > 443），不可当帧数；720p 渲染 16.6–83.8ms 波动，不是该档瓶颈。NEG-05（临时钥匙串空闲上锁阻塞签名）已在 §5.13 记录并修复。下一步见 `docs/P2-NEXT-PLAN.md`：P2.1 位图重组+关键帧请求+帧口径指标 → P2.2 虚拟屏会话接入 → P2.3 渲染。
- v0.29-draft 2026-11-19 22:0x：**跨网段端到端首次跑通（P2 数据面 PASS）**。Sequoia 那台从公网 `112.47.109.8:21026` 连入，状态链完整 `DISCOVERED → TLS_CONNECTED → PAIRED → NEGOTIATED → DISPLAYS_READY → STREAMING → CLOSED`。实测：采集 3440×1440、`captured=392 / encoded=391 / sent=391`、`dropPreEnc=0 / encFail=0 / sendFail=0`、keyframe 10、payload 8,626,350B、`fragmentsSent=7638`、协商 `maxDatagram=1176`；首帧发出 107ms（采集首帧 177ms）；控制包 100、最大控制间隔 1083ms；约 20.1s 内 391 帧 ≈ **19.5 fps（目标 20）**、约 **3.4 Mbps**。`stateLog` 结尾 `CLOSED` 是 client 主动按 Esc 结束（本次只测数据面）。**输入通路未验证**：`inputReceived=0 / inputInjected=0 / cursorMovedPx=0`——client 侧没有产生鼠标事件。上一轮 `-9858` 失败最可能原因是**两端二进制不同 commit**（client 未 `git pull` 重建），本轮同 commit 后一次握手通过；单客户端重连修复（C-17.27）本轮未被触发验证，需再做一次「先失败再重试」的用例。
- v0.28-draft 2026-11-19 22:0x：**首次跨网段实测有进展但握手未成**。host 以 `P2_WAIT_MS=0` 等 1070s 时出现 `[host] 已接受连接` —— 说明 `112.5.32.34:46600` 的 UDP 映射**通了**，client 的包确实到达本机；随后始终没有 `控制通道就绪`，直到 ~1400s 报 `连接失败：-9858`（当时只打裸码，无法区分 TLS/MTU/RST）。排查中发现两个真问题并已修：①**单客户端模型不接重连**——第一次入站连接失败后 `acceptedConnection` 一直非 nil，后续重试全被 cancel（`parentListener` + `rearmParentListener` 修复）；②错误日志缺 domain 与对端地址（`M1DescribeNWError` 补 tls 域、`peerDescription` 打印 `IP:port`）。另 `p2.sh host` 增端口占用预检（子进程会在父 shell 被杀后存活，导致 `监听失败：48`）。重建后单测 193/193 PASS，host 以 `M1_QUIC_DEBUG=1` + `P2_WAIT_MS=0` 重启等复测。
- v0.27-draft 2026-11-19 21:2x：host 支持**无限等待**——`--wait-ms 0` / `P2_WAIT_MS=0`，用 10s 切片等待并每片打印「仍在等待对端…已等 Ns」，不再因 15 分钟窗口到期退出；`p2.sh` 同步把 `caffeinate` 提到 86400s（无限等待时屏睡会导致 SCK 无帧）。实测 `--wait-ms 0` 在 46633 端口 10s 后正确打印心跳；单测 193/193 PASS；host 已用该模式在 46600 重启，等 Sequoia 侧重连。
- v0.26-draft 2026-11-19 21:2x：**远程 SSH 已打通并用于驱动 host**。用户在本机开启远程登录、加入 Sequoia 公钥（`SHA256:f3pQpQPFvqcLiPwpi0oZdUs8JGKpHDxKDV+osBk+uQA`），远程可正常登录。host 端以 `P2_ADVERTISE=112.5.32.34:46600`、`P2_INJECT=real`、`P2_WAIT_MS=900000` 启动，preflight 全部通过（`ax=1 capture=1 onConsole=1`），开始等 Sequoia 侧 client 接入。本轮把 `P2-Dual/out/` 加入 .gitignore（每次运行一个新目录，产物不入库）。**另记录一条环境坑**：本会话的本地代理 `127.0.0.1:61899` 对 GitHub 频繁返回 `CONNECT tunnel 502`/`Empty reply`，导致 push 连续失败；用 `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy git push` 直连（实测 github 200）即可稳定推送。
- v0.25-draft 2026-11-19 20:3x：**为本机加远程 SSH 接入能力**（供 Sequoia 远程驱动测试）。体检结论：macOS 自带 `OpenSSH_10.2p1`，**无需安装第三方软件**；当前远程登录关闭、无 `authorized_keys`、应用防火墙已关、FileVault 已关、`womp=1`。缺口收敛为「开开关 + 放公钥 + 一条 **TCP** 映射（建议外部 46601 → 192.168.10.23:22）」，§1.1 的 UDP 46600 规则对 SSH 无效。新增 `P2-Dual/enable_ssh.sh`（status/enable/add-key/harden，harden 空密钥时拒绝执行）与 `P2-Dual/gui-run.sh`（把命令塞回 gui/501，解决 SSH 无 WindowServer 导致采集/注入失败）。文档 `docs/SSH-SETUP.md`、清单 §1.2、DECISIONS C-17.24/25。
- v0.24-draft 2026-11-19 11:4x：用户在防火墙上新增映射后**复测本机回环仍失败**：UDP 自环（本端口发往 112.5.32.34:46600）3 次无回包；完整 QUIC 握手把超时放宽到 30s 后仍 `握手未在 30000ms 内完成`，host 侧日志停在「等待客户端接入」、无任何连接到达。结论不变：内侧无法验证映射，可能是 hairpin 未开、映射目标 IP/端口不对或防火墙仍丢 UDP；判据交给 Sequoia 从另一网段实测。
- v0.23-draft 2026-11-19 11:1x：**填入本轮实际公网端点 112.5.32.34:46600**（外部端口与内部一致），并把跨网段超时做成可配：`--wait-ms` / `--handshake-ms`（`P2_WAIT_MS=60000` / `P2_HANDSHAKE_MS=30000`）。本机经公网 IP 回环握手失败、UDP STUN 出向超时，确认无法从内侧验证映射，结论留待 Sequoia 从另一网段实测；已把「hairpin 假阴性」写入失败对照表。
- v0.22-draft 2026-11-19 10:5x：**跨网段打洞准备**。用户明确本轮不是同网段、而是跨网段且需在防火墙打洞，控制端换回 Sequoia 15.5 那台。答案收敛为「host 只需一个入站 UDP/46600（或映射后的外部 UDP 端口），不开 TCP，返回流量走同一连接」。代码新增 `--advertise HOST[:PORT]`（只改展示、不改本地监听；支持外部端口≠内部端口）与 `P2_ADVERTISE` 环境变量；host 同时打印「给客户端的三项」（对外）与「本机实际监听」（内网），便于核对 NAT 映射。`docs/P2-CHECKLIST.md` 增 §1.1 防火墙打洞清单与 Sequoia 客户端注意事项。分片 18+1150=1168B（整包约 1.2 KB < 1500 MTU），跨网段不会产生 IP 分片。
- v0.21-draft 2026-11-19 10:4x：**新增 §5.10 P2 预演（真实网卡 en0）**。为今晚双机联调补 `--connect`（客户端地址原本写死 `127.0.0.1`）、`--preflight host|client`（AX/屏幕录制/锁屏/屏睡/active 屏/局域网 IP/帧头版本自查）、host 打印「IP+端口+指纹」三项，以及 `P2-Dual/p2.sh`（preflight/host/client/summary）与 `docs/P2-CHECKLIST.md`。挖出两个只在跨机会暴露的问题：① `nw_listener_create(params)` 忽略 init 传入端口（`--port 46600` 实际监听 61174），改 `nw_listener_create_with_port`；② `controlArrivals` 收包队列追加、主线程枚举导致 `mutated while being enumerated` 崩溃，改 `@synchronized` + 快照。实测 LAN 环回：握手 18.1 ms、272/272 解出、上屏 266 帧、首帧 475 ms、控制间隔 1004 ms；`--inject real` 注入成功 10 次、光标位移 768 px。A-02 仍开放。
- v0.20-draft 2026-11-19 10:0x：**新增 §5.9.3 手动驱动，真鼠标那一跳闭环**。真光标(`physical`)受「窗口必须前台、人不碰鼠标」限制、`synth` 又少 OS 投递一跳，补第三条路：`--manual SECS` 只发信号（响 3 声 + 窗口标题倒计时 + `[manual]` 横幅），由真人动鼠标；没人动时每 5s 再响两声（实测反应延迟 7s）。`verify_m1b.sh` 加 `M1B_DRIVER=manual`，判据改为「横向跨度 ≥ 画面宽 10%」而非落点。第 1 轮 PASS：上屏 329 帧、采集 152→上行 152 条、主机收到 153 条（mouse 150）、横向跨度 2563px（75%），证明「真实鼠标 → 客户端 → 主机」全链成立。
- v0.19-draft 2026-11-19 09:0x：**§5.9.1 端到端判据通过，并更正 v0.18 的归因**。v0.18 把「端到端跑不动」全记在会话自动锁定上，实测有一半是脚本自己的 bug：`verify_m1b.sh` 把 `cursor_move locked` 的退出码判反（0=解锁被当锁定），三轮全是空转。修正后真正的阻塞浮现为**辅助功能授权**：`AXIsProcessTrusted=0` 时 `CGWarpMouseCursorPosition` 能改光标位置但不产生 `mouseMoved`，`CGEventPost` 的合成事件被丢弃（最小 AppKit 接收器复现：active/key/visible 全 1、光标在动、`mouseEntered` 1 次、`mouseMoved` 0 次）。据此把驱动分流为 `physical`/`synth`（新增 `--input-synth` 进程内投递），`synth` 下第 1 轮即 PASS：29 帧上屏、单帧 8.0 ms、三次移动 x=1720/955.6/2484.4、y 恒 720，与 letterbox 换算一致。另修掉同一 `NSEvent` 被投递两次（hit-test + tracking area owner 同体）导致上行事件翻倍的问题。单测 193 项仍全过。
- v0.18-draft 2026-11-18 23:1x：**§5.9 补齐端到端实测与三个真问题**。上屏从 `createCGImage`（每帧 GPU→CPU 回读 19.8 MB，实测 0.5–0.9 s/帧）改为 `render:toCVPixelBuffer:` 渲染到 IOSurface 再直接当 `layer.contents`（零拷贝），离屏 3440×1440 **10.4 ms/帧**。发现窗口不可见时 `layer.contents` 赋值会被 CA 阻塞（943–3233 ms 的假性能数字由此而来），改为 `occlusionState` 不可见则跳过并计 `framesSkippedOccluded`。发现 CLI 应用拿不到 key window，tracking area 改用 `NSTrackingActiveAlways` + `acceptsMouseMovedEvents`（此前 `inputEmitted` 恒为 0）。端到端仍被「会话反复自动锁定」挡住：窗口 `visible=1 key=0 active=0 occluded=1`，登录窗在最上层；已把 `verify_m1b.sh` 改为多轮短尝试，若单机无法稳定解锁则并入双机验收。
- v0.17-draft 2026-11-18 21:5x：**新增 §5.9 M1-B 客户端上屏 + 输入回传（代码与单测完成，端到端待解锁验证）**。补上此前被静默忽略的 `input` 消息收发（`sendInputEvent:` / `didReceiveInputEvent:`，含 STREAMING 门禁与 1000 event/s 限速）；新增 `M1FrameView`（CIContext→CGImage→layer，letterbox 与坐标映射共用 `M1AspectFitRect`/`M1NormalizedPointFromViewPoint` 纯函数）、`M1RecordingEventSink`（环回不真注入）、`tools/cursor_move` 与 `verify_m1b.sh`。单测 193 项全过（输入通路 24、letterbox/坐标 12、注入器 6 为新增）；另有离屏渲染自检 `render_selftest` 全过（颜色/尺寸/letterbox/覆盖），并量出 CIContext 首次转换 623 ms，已按同样思路预热到 2 ms 级。顺带修掉 `displayID` 文档与实现位置不一致（两处都带 + event 缺失回落消息层）。阻塞：屏幕锁定导致 SCK 无 display、窗口收不到事件，端到端判据未执行。
- v0.16-draft 2026-11-18 21:20：**帧头升 v2，修掉 3440×1440 打穿 255 片上限的缺陷**。`fragIdx/fragCount` 由 1 字节扩到 2 字节、帧头 16B→18B，单帧上限从 286 KB 提到 75 MB。先验证并**排除**了「`displayID` 压 16 位、帧头保持 16B」这条更小的改动——实测 `CGMainDisplayID()=2026701824`（0x78CD0400），32 位都紧，压 16 位会截断。`payloadLen` 仍 1150，分片预算不变，不影响 MTU。验证：原生 3440×1440 推流 30/30 帧、`sendFail=0`、首帧 1278 ms（修复前 4069 ms）；400 片大帧重组逐字节一致；`quic_probe` 500 片零丢零乱序；P1 148 项 + M1 全绿。顺带修掉 `quic_probe` 的位图越界隐患（原本固定 32B 位图只够 fragIdx 0..255）。已有二进制必须全部重建，新旧帧头不兼容。
- v0.15-draft 2026-11-18 21:00：**新增 §5.8 VT 会话预热（M1-A 第 5 步）**。原计划「收到 SPS/PPS 就建会话」不成立（参数集本就随关键帧而来，且代码早已如此）；真因是 **VT 会话子系统的进程内首次初始化**：首次 `VTDecompressionSessionCreate` 260–1110 ms、`VTCompressionSessionCreate` 343–1377 ms，第二次起降到 13–63 ms，且用**不含 SPS/PPS 的裸 format desc 也能建成功** ⇒ 与码流无关、可提前预热。新增 `+[M1VideoEncoder prewarm]` / `+[M1FrameReceiver prewarmDecoder]`（`dispatch_once`、UTILITY 队列，用 USER_INITIATED 会与首次采集抢 CPU 而反噬）。A/B 3×2 轮：解码建会话 271→60 ms、编码建会话 406→56 ms，端到端首帧 1140→783 ms（该列噪声大，判定看确定性指标）。顺带修掉既有崩溃：对端 bye 触发控制队列与主线程**并发双停**，`M1VideoEncoder stop` 二次 `CFRelease` → SIGILL（20:08 起多次复现），改幂等 + 先摘快照。新发现待决：**帧头 `fragIdx/fragCount` 是 uint8，单帧上限 255×1150≈286 KB，3440×1440 关键帧打穿后整帧发不出**（实测首帧 4069 ms、`sendFail=1`），需扩到 16 位或压缩 `displayID`。
- v0.14-draft 2026-11-18 20:10：**新增 §5.7 跨进程推流落盘（M1-A 第 4 步）**。`stream_probe` 双进程打通 SCK→编码→QUIC→重组→解码→PNG，1920×1080 两轮各 112/54 帧、零丢弃零解码失败、零发送失败，落盘 PNG 可辨认。控制与视频共用一条 datagram 连接（C-14.2）经实测成立：两端心跳最大间隔 1033/1046 ms ≈ 心跳周期。另记录两个把「控制被饿死」误判成链路丢包的坑：PNG 编码与重组/解码都跑在收包线程上（单次阻塞 1092 ms → 心跳断 4.5 s），分别移到独立队列后恢复。遗留：首帧延迟 2.8–4.1 s（解码会话创建仍在关键路径）。
