# VeilRD（Veil Remote Desktop）实测结论（按 OS 分离）

| 项 | 值 |
|---|---|
| 版本 | v0.47-draft |
| 日期 | 2026-11-21 |
| 原则 | **结论绑定具体 OS build 与机器，禁止跨版本外推**。同一判据在 Sequoia 与 Tahoe 分别记录，未测就写未测。 |
| 上位文档 | `docs/DESIGN.md` §8、`docs/DECISIONS.md` |

---

## 1. 环境标识

| 标签 | OS | Build | 机器 | 备注 |
|---|---|---|---|---|
| **Sequoia** | macOS 15.5 | 24F74 | Macmini8,1 / i5-9500 / x86_64 | 2026-11-17 晚间实测机；屏幕 3 块（含竖屏） |
| **Tahoe** | macOS 26.5.2 | 25F84 | Macmini8,1 / i5-9500 / x86_64 | 2026-11-17/18 白天实测机；物理屏 2 块 |
| **Ventura** | macOS 13.6.7 | 22G720 | iMac17,1 / x86_64 4 核 / 192.168.34.213 | 2026-11-21 新增测试机（iMac-3）；仅 CLT 14.3.1 / 13.3 SDK；**编译与单测已验证，独占会话未实测** |

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

### 5.20 回归复跑 + 窗口外分片锁死治理：720p/1080p × 镜像/独占（2026-11-20 22:5x–23:4x，WAN，30s）

**先修正一条证据口径。** §5.19 补节（v0.43）里镜像 1080p20 的 f/g 两轮 0.998，实际每帧只有 4.2–4.4KB（4 篇/帧），画面接近空白——那是小载荷档，**不能当作大帧/真实桌面场景的证据**。本轮所有结论都改为同时记录 `fragmentsSent` 与 `payloadBytes`（即每帧片数/字节数）。

**新增诊断（永久保留）**：客户端 `receiver:` 行增加 `分片丢弃去向: wipe/ahead/winFull/stale`，并输出 `重组状态`（`haveNext/next/kf/partials/ready/inflight/nextPartial`）。JSON 增加 `discardBreakdown`、`reassemblerState`。

**发现并修复的缺陷：窗口外分片静默锁死。** 高熵内容（14–34KB/帧）下，客户端偶发整段流锁死：`_nextSeq` 落后超过 12 帧窗口后，所有更新帧的分片都在 `seq > _nextSeq + maxFramesInFlight` 分支被丢弃，这些分片没有 partial，补片无从发起，也等不到关键帧 → 30s 里只交付了 31–85 帧，`ahead` 丢弃数千片（复现轮 `ahead=6919`、`31/563`；另一轮 `85/562`）。修复：自上次交付起累计 ≥64 片被超前窗口拒收即视为"追不上"，立即 `declareLoss` 并转关键帧重建，把永久锁死换成一次 ~0.2s 的重启；`drainInto` 交付后、`declareLoss`/`restartAtKeyframeSeq`/`reset` 时清零计数。

| 轮次 | 形态/规格 | 采集/发出 | 客户端收齐/解出 | 每帧片数/字节 | 丢帧去向 | 关键帧请求 | C-09 | 判定 |
|---|---|---|---|---|---|---|---|---|
| j | 镜像 720p15 | 443/442 | **442 / 442** | 3.5 片 / 3.2KB | 全部 0 | 0 | - | **PASS** |
| i | 独占 720p15 | 426/425 | **425 / 424（0.998）** | 4.4 片 / 4.2KB | 全部 0 | 0 | verified / recovered | **PASS** |
| k | 镜像 1080p20 | 588/586 | **586 / 585** | 7.8 片 / 8.1KB | 全部 0 | 0 | - | **PASS** |
| h5 | 独占 1080p20 | 575/574 | **573 / 573** | 14.0 片 / 14.9KB | ahead=0 | 0 | verified / recovered | **PASS** |
| h6 | 独占 1080p20 | 571/570 | **550 / 549（549/570=0.963）** | 15.2 片 / 16.3KB | **ahead=64（阈值触发一次）** | 1（RTT 208ms） | verified / recovered | **PASS** |

**结论**
- 第 1 步回归全部 PASS：720p 镜像/独占、1080p 镜像/独占；两轮 1080p 独占均 `c09Status=verified`、`activeDisplayIDsAfterDisable=[4128835]`、`sessionRecovered=true`。
- h6 是修复路径的现场证据：`ahead=64` 到阈值后判丢 1 次、关键帧请求 1 次、208ms 恢复，解码率仍 0.963；修复前同等条件会整段流锁死（31–85 帧/30s）。
- 失败轮（23:00 h、h3 首轮）的 `payloadBytes/frames` 达 34KB/14.6KB，与正常轮 4.4–15KB 属不同内容档；**高低内容档都要在门禁记录里带 payload 数据**，否则无法区分"链路通过"与"画面近似空白"。
- 本机负载仍会压低上屏（渲染 36–238ms、上屏 287–406/550+），不影响结构性门禁判据，留待 P2.3 在空闲环境重测。

### 5.21 矩阵补测（v2b9ec03）：720p15 WAN 镜像/独占（2026-11-20 23:2x，30s，全屏动画夹具）

**目的**：把 P2.3 矩阵的 WAN 行补齐到同一代码版本（`2b9ec03`，含 ahead 锁死修复），避免 720p15 只有修复前数据（§5.17 的 0.968/0.939）。host 先 `git stash push -u`（保存为 `host-snapshot-20261120-2325-before-pull-2b9ec03`，工作区改动与本机 2b9ec03 几乎一致、仅缺 ahead 修复）再 `pull --ff-only`，重建 `stream_probe` 后运行。

| 轮次 | 形态/规格 | 采集/发出 | 客户端收齐/解出 | 每帧片数/字节 | 补片 请求/命中 | 关键帧请求 | 上屏 | C-09 | 判定 |
|---|---|---|---|---|---|---|---|---|---|
| m | 镜像 720p15 | 444/442 | **442 / 441（0.998）** | 3.5 片 / 3.29KB | 30 / 30 帧（39 片） | 0 | 183（积压 256） | - | **PASS** |
| n | 独占 720p15 | 441/440 | **440 / 440（1.000）** | 4.2 片 / 3.95KB | 25 / 25 | 0 | 413（积压 27） | verified / recovered | **PASS** |

- 两轮 `sendFailures=0`、分片丢弃全部为 `stale`（m=5、n=36），`ahead=0`、`winFull=0`；控制通道最大间隔 1064ms / 1019ms。
- n 轮输入通道同轮验证：窗口采集 81 → 发出 81 → host 注入成功 79、光标位移 1342px；`activeDisplayIDsAfterDisable=[4128835]`，结束后物理屏恢复。
- **矩阵缺口（如实记录）**：{720p15, 1080p20} × {LAN, WAN} 中 **LAN 行不可得**——本机（Sequoia 15.5，192.168.31.171）与 host（Tahoe 26.5.2，112.5.32.34，NAT 后 192.168.10.23）不在同一局域网，现网无第二台同 LAN 机；LAN 列只能引用此前的环回数据（§5.4 / §5.10，非跨机），不与 WAN 行混算。
- **P2.3 渲染基线仍未取得**：本轮 m 轮客户端单帧 273.8ms（峰值 468.2ms）、n 轮 9.6ms（峰值 165.8ms），同机同代码差 28 倍——期间本机 `Screen Sharing` 进程常驻 60%+ CPU、Qoder 渲染进程 40%+；`render_selftest` 同负载下 1080p 单帧三次采样 14.8 / 95.4 / 86.1ms。**P2.3 必须在空闲机器（无 Screen Sharing/Qoder/Spotlight 索引）重测**，当前数字只作“负载敏感”证据。
- A-02（glass-to-glass）状态不变：仍缺同框相机实测，本轮未新增该项证据。

### 5.22 G2 收口：host 默认按客户端规格建屏，`--mirror` 降为诊断开关（2026-11-20 23:3x，WAN，720p15，30s）

**变更**：`stream_probe --host` 默认走 `M1SessionCoordinator`（虚拟屏 + 禁物理屏 + C-09 + 恢复），`--mirror` 显式回退采物理主屏，`--exclusive` 仍接受；`p2.sh` 增加 `P2_MIRROR=1` 透传，runbook 已加注。这样 P2 工具与 FR-00/FR-01 的“控制端看到按规格新建的桌面”一致，不再依赖 `--exclusive` 记忆负担。

| 轮次 | 启动方式 | 采集/发出 | 客户端收齐/解出 | 每帧片数/字节 | 补片/关键帧 | C-09 | 判定 |
|---|---|---|---|---|---|---|---|
| p | 默认（无 `--exclusive`） | 442/441 | **441 / 441（1.000）** | 4.2 片 / 3.99KB | 34/0（stale=6，awaiting 176ms） | verified / recovered，`[4128835]` | **PASS** |
| q | `P2_MIRROR=1` | 432/431 | **428 / 428（1.000）** | 3.5 片 / 3.27KB | 23/0（stale=2，awaiting 172ms） | mirror / - | **PASS** |

- 两轮 `sendFailures=0`、`ahead=0`、`winFull=0`、`wipe=0`；控制通道最大间隔 1310ms / 1055ms。
- 1080p20 的默认路径即此前的 `--exclusive` 路径（h5/h6，§5.20），代码分支未变，无需重跑；下次 1080p 重测直接免旗标即可。
- 客户端渲染仍受本机负载影响（p 轮 51.4ms、q 轮 95.2ms，上屏 405/169 帧并分别积压 35/258），P2.3 结论仍以空闲环境为准。

### 5.23 Ventura 13.6.7 新增测试机：编译与单测验证（2026-11-21 14:5x–15:0x，iMac17,1）

**目标**：验证「Intel 13–26 双角色」目标中的**下界**能在只有旧 SDK 的机器上自洽构建（C-01 / C-17.38 / `DESIGN.md` §2.4.1）。本机只有 CLT 14.3.1 / macOS 13.3 SDK，无法安装新版 CLT/Xcode；改动前对 14+ API 做了审计，确认只有 3 处文件、7 个编译错误点，且全在既有 `@available` 运行时守卫内，因此只补编译期守卫，不改任何运行时行为。

| 项 | 26.5.2 Tahoe（本机 Xcode 26.5 SDK） | 13.6.7 Ventura（iMac-3，CLT 14.3.1 / 13.3 SDK） |
|---|---|---|
| `M1-Skeleton/build_stream_probe.sh` | ✅ | ✅ `built: ./stream_probe` |
| `P0-TahoeProbe/build.sh` | ✅ | ✅ `构建完成：./p0probe`（脚本明确提示「当前 macOS 大版本是 13，verify 结论仅供参考」） |
| `P0V-RootDaemon/build.sh` | ✅ | ✅ 产出 `build/P0VRootProbe.app` |
| `M1-Skeleton/build_tests.sh`（268 断言 + 守护负向） | ✅ 268 passed, 0 failed | ✅ 268 passed, 0 failed |
| `P1-ClientProbe/build_tests.sh` | ✅ ALL PASS | ✅ ALL PASS |
| `stream_probe --preflight client` | 已有实测通过记录 | ✅ 15:4x 人工解锁后 `ok=1`：`locked=0` / `asleep=0` / `active=1` / `onConsole=1`；`ax=0 capture=0` 对 client 不是失败项 |

- 两端同为 commit `e118f89`；Ventura 侧先 `git pull --ff-only`，旧临时补丁已删除，现为干净工作区。
- 15:0x 首次预检 `ok=0`（`locked=1` / `asleep=1` / `active=0`）。用 `caffeinate -d -u` 可远程唤醒显示器（`asleep=0 active=1`），但**锁屏无法远程解除**：`sysadminctl -screenLock off` 只改延迟不解锁，自动登录写入被 `SACSetAutoLoginPassword error:22` 拒绝，内置 VNC 因 SIP 无法激活，`CGEventPost` / `osascript` / GUI Terminal 的 `AXIsProcessTrusted` 均为 0。15:4x 由人在控制台解锁后立即重跑，`ok=1`。
- 13 的远程解锁能力属于 D-08 Path A（客户端呈现登录界面 + 凭据注入），**不是 VNC，也尚未在 13 上实测**；当前 `stream_probe` 的 P2 工具链仍是 `needsLogin:NO`，凭据注入只在 coordinator/driver 单测与 Tahoe V-04 探针里验证过。
- **边界**：本轮证明「13 上可本机编译 + 纯逻辑测试通过 + client 预检通过」。13 host 的建虚拟屏 / 禁物理屏 / C-09 隔离、13 作为 client 的真实收流上屏、以及 13 上的远程登录（Path A），**均未实测**，仍按 A-07 待回归处理；不得从本节的结论外推到独占会话可用性。

### 5.24 首次双真机跨网段 LAN 实测：Tahoe host × Ventura client（2026-11-21 15:5x，iMac17,1）

**背景**：新增 iMac 后，host（Macmini8,1 / 26.5.2，en0 `192.168.10.23`）与 client（iMac17,1 / 13.6.7，en0 `192.168.34.213`）分处两个路由互通的网段（网关 `.10.1` ↔ `.34.1`，ping 2.2ms）。这是项目首次拥有两台可互达的物理机，§5.21 里「LAN 行因无同 LAN 第二台机不可得」的前提就此解除。本轮用**镜像模式**（host 采物理主屏，不建虚拟屏、不黑屏）先补 LAN 结构性证据；两端同为 commit `20ff227`。

**配置**：host `P2_MIRROR=1 P2_PORT=46600/46601 P2_WAIT_MS=60000 P2_INJECT=record P2_SECONDS=30`，host 端用 `anim_display 0`（贴主屏动态彩条，3440×1440）喂内容；client `bash ./p2.sh client --host 192.168.10.23 --port ... --fingerprint 3305dec4...`。两端 `env -u http_proxy...` 去掉代理（避免劫 UDP 路由）。

| 轮次 | 采集/编码/发出 | 客户端解出 | 解码/发出 | 丢帧 | 等待关键帧 | 补片 | 渲染/帧 | 首帧 | 输入 收/注入 | 判定 |
|---|---|---|---|---|---|---|---|---|---|---|
| a · 720p15 | 279 / 278 / 278 | 276 | 0.993 | 0 | 14ms（0.0%） | 38/38 | 14.5ms | 1127/1546ms | 0/0（record 计划 0） | **PASS** |
| b · 1080p20 | 86 / 85 / 85 | 85 | 1.000 | 0 | 164ms（0.5%） | 14/14 | 26.5ms | 172/524ms | 2/2（计划 2） | **PASS** |

- 两轮 `sendFailures=0`、无畸形分片、控制通道最大间隔 1057/1292ms（<3s）、关键帧请求 0（走补片路径）、C-09 不适用（mirror）。握手 55/44ms。
- **P2.3 渲染基线刷新**：此前 §5.21 记录的 84.7ms/帧是在本机 Qoder ~170% CPU + Spotlight 索引污染下测得。本轮 client 是空闲的 iMac：720p 上屏 14.5ms/帧、1080p 26.5ms/帧（峰值 41.3ms，1080p20 预算 50ms）。⇒ 渲染不是瓶颈，P2.3 的「需空闲环境重测」条件已部分满足（Ventura 侧）。
- 1080p 只发出 85 帧（2.9fps）**不是网络/采集退化**：`[capture]` 每秒 `complete≈2 idle≈17`，`anim_display` 的 1200×700 窗口没盖住 3440×1440 主屏，SCK 对静止区域按 idle 丢弃——与 §5.19/5.20 的 idle 归因一致。要用 1080p 满帧作门禁，需 `anim_display 0 60 full` 铺满整屏后复跑（本轮未跑）。
- a 轮输入 0 条是 record 注入计划本就为 0；b 轮 2/2 到达并注入成功，`cursorMovedPx=1399`。
- **client 规格断言**：两轮都是 mirror，host 日志「请求规格 1920x1080(实际屏)→1280x720/1920x1080（未一致/未判定）」符合预期（C-17.31：镜像不建屏，尺寸断言不参与判定）。
- **边界**：本节证明的是「13 作为 client 的真实收流→解码→上屏→输入回传」在跨网段 LAN 上成立（关闭 A-07 的 client 侧），以及 LAN 行结构性证据。**不代表** 13 host 的建屏/禁屏/C-09、13 的 Path A 远程登录已验证（仍待 A-07 host 侧）。`p2.sh` 的相对路径 summary 与脚本执行位问题在本轮暴露并修复（见 §7 v0.48）。

**补测（16:0x，1080p20 满帧门禁）**：为排除 idle 干扰，用 `anim_display 0 60 full`（1200×700→铺满 3440×1440）复跑两轮，坐实了 §5.24 的 idle 归因，并定位到真正的满帧开关：

| 轮次 | SCK 路径 | 采集/编码/发出 | 解出 | 每秒稳态 | 上屏 | 判定 |
|---|---|---|---|---|---|---|
| c · full + `res=auto` | 3440×1440 原生 → 缩放 1080p | 172/171/171 | 171 | complete≈4 / idle≈16，5.7fps | 146 帧 | PASS（解码率 1.000，但帧率不达标） |
| d · full + `M1_CAPTURE_RESOLUTION=best` | SCK 直接出 1080p | 530/525/525 | 525 | complete≈18–20 / idle≈0 | 493 帧 | **PASS（18–20fps 满帧）** |

- **根因**：`res=auto` 让 SCK 送原生 3440×1440 再在 host 降采样到 1920×1080，i5-9500 上转录/缩放把采集压到 ~5fps；`M1_CAPTURE_RESOLUTION=best`（macOS 14+ 的 `SCCaptureResolutionBest`，`stream_probe.m:1137`）让 SCK 直接输出目标分辨率，采集稳在 18–20fps。`nominal` 未测。这是 host 编码前的采集侧参数，不是传输或 client 问题。
- d 轮发送 525 / 解出 525（1.000）、丢帧 0、`sendFailures=0`、补片全命中、关键帧 0、控制间隔 1060ms、首帧 858/1769ms、渲染 25.9ms/帧、输入 2 收到但注入 0（该轮 record 计划为 0，光标未动；§5.24 b 轮已单独证明 2/2 注入 + 1399px 位移成立）。⇒ **P2.3 的 1080p20 满帧（20fps 级）首次在双真机 LAN 上达成**，A-02 的「真实帧率」证据前进一步（glass-to-glass 延迟仍未测，A-02 保持开放）。
- **部署含义**：3440×1440 等高分辨率物理屏上做镜像推流时，必须显式设 `M1_CAPTURE_RESOLUTION=best`，否则采集会被降采样路径拖垮。建议写进 host 启动脚本/操作单。

### 5.25 Ventura 13 host 角色实测：TCC 已授权但 SCK 建流被系统拒绝（2026-11-21 16:1x–16:3x，iMac17,1）

**结论：13 作为 host 仍不可用，卡在 macOS 13 系统层，不是本项目代码或配置问题；13 作为 client 可用（§5.24）。**

**人工授权步骤（用户完成）**：在 iMac「系统设置 → 隐私与安全性 → 屏幕录制」勾选 `~/macOS-RDP/M1-Skeleton/stream_probe`。授权后：

| 检查 | 结果 |
|---|---|
| GUI 会话内 `stream_probe --preflight host` | `capture=1 ax=0 locked=0 asleep=0 active=1 ok=1` |
| SSH 内同一命令 | `capture=0 ok=0`（SSH 无 TCC 责属，预期；host 必须从 GUI 会话启动） |
| `gui-run.sh`（launchctl asuser） | `onConsole=1` 但 `capture=0`——13 上该路径拿不到 TCC 责属 |
| 屏幕内容枚举 | `preflight=1`、`displays=1`、`display 1920x1080`、`addStreamOutput=1`（成功） |
| `SCStream startCapture` | **失败**：`CoreGraphicsErrorDomain Code=1003 "Start stream failed" / "The stream is nil."` |

**故障隔离证据**（均为 GUI Terminal 上下文）：
- 统一日志定位到系统 daemon：`replayd[pid] [SCCaptureSession startWithCompletionHandler:598] startError=CoreGraphicsErrorDomain Code=1003 "The stream is nil."`——失败发生在 replayd 创建底层 CG stream 时，早于本项目任何帧处理。
- 用**独立最小 SCK 程序**（不链接本项目任何代码）复现：5 种配置（minimal / width-height / +pixelFormat / +scalesToFit / 完整项目参数）全部同样 `1003 The stream is nil` ⇒ 与 stream 配置无关。
- TCC 正常：`tccd` 对 `kTCCServiceScreenCapture` 返回 `authValue=2`（allowed）；`screencapture -x` 可出图。
- 杀掉 `replayd` / `screensharingd` / `ARDAgent`（早期 VNC 尝试残留）后仍失败；`remotemanagementd` 受 SIP 保护无法 bootout。排除「第二个采集者占用」假设。
- 对照：Tahoe 26.5.2 上同一份 ad-hoc 签名二进制采集正常（§5.24）。

**修复的真实 bug（与上述系统限制独立）**：原 `M1CapturePipeline.m:355` 在 `startCapture` 失败后调用 `[stream removeStreamOutput:...]`，macOS 13 上从未 start 成功的 SCStream 底层为空，该调用 `EXC_BAD_ACCESS` 崩溃（crash report：`-[M1CapturePipeline start:] (M1CapturePipeline.m:355)` → `SCStream removeStreamOutput`，`SIGSEGV / KERN_INVALID_ADDRESS at 0x0`）。已改为失败时直接返回、由 ARC 释放局部 stream/output（commit `52ab8b8`）。复测确认：host 现在优雅退出 `rc=5` + `管线启动失败: startCapture 失败: Start stream failed`，无 segfault、无新 crash report。

**16:5x 复测（用户已恢复「屏幕共享」）**：本机 `nc -zvw3 192.168.34.213 5900` 成功，确认 VNC/Remote Management 已开。两端仍为 commit `1d1ef27`，iMac 从 GUI Terminal 以镜像模式重跑（1920×1080→1280×720@15、`P2_INJECT=record`、端口 46611），Tahoe 侧跑 client。结果与上表完全一致：iMac preflight `capture=1 locked=0 asleep=0 active=1 ok=1`，握手 `TLS_CONNECTED → PAIRED → NEGOTIATED → DISPLAYS_READY → STREAMING` 全过，随即 `[capture] ... res=auto` 后报 `管线启动失败: startCapture 失败: Start stream failed`，host rc=5、未写出 host.json；client 收到 0 帧包、解出 0 帧、上屏 0 帧、rc=2（`P2-Dual/out/ventura-host-recheck/`）。统一日志再次锁定同一系统层链路：`replayd` → `SLContentStreamCreate: Failed to create content stream (0x3e8)` → `-[SLContentStream initWithFilter:...]: stream = 0x0` → `-[SCCaptureSession startWithCompletionHandler:]:598 startError=CoreGraphicsErrorDomain Code=1003 "The stream is nil."`。⇒ **开启 Screen Sharing / Remote Management 并不改变 SCK 建流失败**；问题仍在 Ventura 13.6.7 的 SkyLight/replayd，而不是本项目的 TCC、配置、网络或 VNC 服务状态。

**边界**：本节证明「13 已能完成 TCC 授权并在 GUI 会话启动 host，握手到 STREAMING 全程正常；但 13 的 SCK 无法创建采集流」，A-07 的 host 侧（建屏/禁屏/C-09）继续未验证。13 上 client 侧不受影响（§5.24 两轮 PASS）。`DECISIONS.md` C-17 关于 ad-hoc 签名只能产生 path 级 TCC 条目、正式形态需正确签名用户态 App 的结论与本结果一致，进一步说明 13 host 可能需要正式签名才能在 SCK 层通过。

### 5.26 13 host 替代采集路径调研：CGDisplayStream 在本机可用（2026-11-21 17:1x，iMac17,1）

**上一节的结论需要修正一个关键点：13 的失败是 SCK/SkyLight 专属，不是「macOS 13 不能抓屏」。** 联网核对与本机实测都指向 `CGDisplayStream` 作为可行替代。

**开源实现对照**
- **OBS Studio**（当前 master `plugins/mac-capture/mac-display-capture.m`）仍用 `CGDisplayStreamCreateWithDispatchQueue` + `IOSurface`，没有 SCK 路径。
- **RustDesk / `scrap`**（`libs/scrap/src/quartz/capturer.rs`）同样用 `CGDisplayStreamCreateWithDispatchQueue`，回调里包装 `IOSurfaceRef`。
- **SideScreen**（`MacHost/Sources/ScreenCapture.swift`）是 **SCK 优先 + CGDisplayStream 兜底**：`startCapture()` 抛错、流中止、或 5s 无帧都触发 `attemptFallbackCapture()`；没有按 OS 版本分支。
- **flutter_screen_share** 也采用 SCK(12.3+) / CGDisplayStream 双后端。

**本机实测**：在 iMac 13.6.7 上用 12.3 SDK 可编译的最小 Objective-C 程序（不链接项目代码）调用 `CGDisplayStreamCreateWithDispatchQueue` 抓主屏，GUI Terminal 内结果：

```text
preflight=1
display=1535231424 1920x1080
create=OK
start=0                      // kCGErrorSuccess
frame=1 status=0 surface=0x600002e80100
frame=2 status=0 surface=0x600002e884e0
total_complete_frames=2      // 6s 静态屏，只有内容变化时才出帧，符合 Quartz 语义
RC=0
```

源码与日志留在 `P2-Dual/out/cgdisplay-probe-13/`（该目录被 gitignore，不入库）。同一台机器、同一 TCC 状态下 SCK `startCapture` 必失败，而 CGDisplayStream 能建流并交付 `IOSurface`，因此**13 host 有可行替代路径**。

**边界与后续**：`CGDisplayStream` 在 macOS 14 标记 deprecated、15 对虚拟屏 obsoleted（RustDesk issue #26：15 上对 BetterDisplay 等虚拟屏返回 nil）；所以不能全局替换，做成**版本/能力门控的后端**：14+ 继续 SCK，13 且 SCK 失败时回退 CGDisplayStream。该后端已在 §5.27 集成并跑通。

### 5.27 13 host CGDisplayStream 回退后端集成 + 双机全链路 PASS（2026-11-21 17:2x–17:4x）

**实现**（`M1-Skeleton/src/M1CapturePipeline.m` / `.h`）：
- `M1CapturePipeline` 现在有两个采集后端，共用同一个 `M1CaptureOutput` 统计/分发对象（新增 `-deliverPixelBuffer:ptsMs:`），下游 VT 编码 / 分片 / QUIC 完全不感知后端差异。
- 版本门控：13 SDK 编译期直接 `useSCK=NO`；14+ 运行时 `@available(macOS 14.0, *)` 优先 SCK，**SCK 的 content 获取 / addStreamOutput / startCapture 任一失败即回退 CGDisplayStream**。诊断开关 `M1_CAPTURE_BACKEND=cg|sck` 可强制指定（默认按版本自动）。
- `CGDisplayStream` 后端以 `kCVPixelFormatType_32BGRA` 输出，`IOSurfaceRef` 用 `CVPixelBufferCreateWithIOSurface` 包一层后走原有编码链；`kCGDisplayStreamMinimumFrameTime=1/fps`、`kCGDisplayStreamShowCursor=config.showsCursor`；`CGDisplayStreamStart/Stop` 严格配对，回调 block 用 weakSelf 避免循环引用。
- 编译期兼容：`CGDisplayStream*` 在 26 SDK 标注 obsoleted-15，靠 `-mmacosx-version-min=13.0` + 局部 `#pragma clang diagnostic ignored "-Wdeprecated-declarations"` 保留；13.3 SDK 与 26.5 SDK **均构建通过**，两端各 268 项单测 ALL PASS。

**双机配置**：iMac17,1 / 13.6.7 当 host，从 **GUI Terminal** 启动（`ssh` 会话拿不到 TCC 责属），`P2_MIRROR=1 P2_WIDTH=1280 P2_HEIGHT=720 P2_FPS=15 P2_PORT=46611 P2_INJECT=record`，`anim_display 0 90 full` 喂动态内容；Macmini8,1 / 26.5.2 当 client，`--spec 1280x720`。host preflight `capture=1 locked=0 asleep=0 onConsole=1 active=1 ok=1`。

| 轮次 | 采集后端日志 | 采集/编码/发送 | 客户端收齐/解出/上屏 | 丢帧 | 输入回传 | 判定 |
|---|---|---|---|---|---|---|
| 1（25s 视频） | `[capture] backend=CGDisplayStream display=1535231424 out=1280x720 fps=15` | 90 / 81 / 81 | 81 / 81 / 81 | 0 | 未注入（record 无事件） | PASS |
| 2（18s + 合成输入） | 同上 | 62 / 53 / 53 | 53 / 53 / 53 | 0 | 6 发出 / 6 收到 / 6 注入成功 | PASS |

两轮 `encFail=0 sendFail=0 decodeFail=0`，规格断言 1280x720 → 1280x720 一致；第二轮 `p2.sh summary` 判定 PASS。证据：`P2-Dual/out/cg-fallback-13/`、`P2-Dual/out/cg-fallback-13-input2/`（两端同名目录，含 wrapper/host/client 日志与 json）。

**帧率归因**：客户端只有 3.7fps，不是回退后端缺陷。独立最小 CGDisplayStream 程序在同一台 iMac、同一动画夹具下 10s 仅 38 帧（3.8fps），说明 `anim_display` 全屏动画在这台弱 GPU 上的实际内容更新率就是 ~4fps；CGDisplayStream 按内容变化出帧（静态屏 6s 只有 2 帧，§5.26），符合 Quartz 语义。需要在更强 GPU 或更高更新率夹具上另测帧率上限，本轮只把「全链路可用性」作为门禁。

**后续补充**：帧率上限、真实输入注入、独占安全变体与 Path A 见 §5.28；§5.27 里「未覆盖」的边界以 §5.28 为准。

### 5.28 A-07 剩余项：13 host SPI / 独占安全变体 / 帧率 / 真实注入 / Path A（2026-11-21 20:0x–21:0x）

**1) 私有 SPI 在 13 上可用（A-07 的 SPI 部分关闭）**。GUI Terminal 内 `p0probe probe --capabilities`：`allClassesResolved=true`、`spi-signature-check ok=1 missing=[]`、`isLoggedInGUI=true`；`p0probe verify` 成功建 2 块虚拟屏（1920×1080、2560×1440），mode-commit / liveness / visibility 全过并干净销毁。OS 策略仍为 13 专属的 `conservativeFirst=0 identityWalk=0 maxRetries=1`。SCK 采集同样失败（`startCapture: Start stream failed`），与 §5.25 一致。

**2) 完整独占会话（禁物理屏 / C-09）在 13 上被 WindowServer 崩溃阻断**。两次 `stream_probe --host` 默认独占（1280×720 和 1920×1080）都在虚拟屏 mode-commit 后、禁用物理屏的显示重配置阶段崩溃：

```text
WindowServer  EXC_BAD_ACCESS / SIGBUS
  DisplayStreamStateSW::CopyFrame
  displaystream_update → CGXDisplayStreamStart
  CGXDisplaysDidReconfigure → CGXRestoreDisplayConfiguration
```

两次 WindowServer 都重启，第二次把控制台踢回 loginwindow（`/dev/console` owner=root）；用户手动重新登录才恢复。guardian 的 `.done` 握手在第二次是正常收尾，但无法阻止 WindowServer 自身崩溃。对照：单独建 1280×720 虚拟屏（`p0probe verify --spec 1280x720x0`）不崩。⇒ 当时判定 **13 上「建虚拟屏」可用，「禁物理屏」是 OS 层阻塞，C-09 无法在 13 验证**，不再重试。**该结论已于 §5.30 更正**：崩溃是 ScreensharingAgent 显示流竞态，加竞态规避后完整独占 C-09 PASS。

**3) 独占安全变体 `--keep-main` PASS**。`P2_KEEP_MAIN=1` 下保留物理主屏、只建虚拟屏，host 日志：

```text
[独占] 虚拟屏就绪 ids=4128832  phase=Streaming  physicalDisabled=保留主屏
[capture] backend=CGDisplayStream display=4128832 out=1280x720 fps=15
host json: sessionMode=exclusive-keep-main c09Status=skipped-keep-main sessionRecovered=true
```

客户端收齐 279 / 解出 278 / 上屏 251，丢帧 0，规格 1280×720 一致，`p2.sh summary` PASS。证明 CG 回退后端能直接采虚拟屏，不只是物理屏。证据：`P2-Dual/out/a07-keepmain-13/`。

**4) 帧率上限**：上述虚拟屏 + 全屏动画夹具下客户端解码 **14.8 fps**（1280×720），达到 15fps 目标档；镜像物理屏夹具只有 3.7fps，已归因于 iMac17,1 弱 GPU 上动画的实际更新率（§5.27），不是后端上限。⇒ CG 回退后端在本机可支撑约 15fps@720p。

**5) 真实系统级输入注入 PASS**。用户手动在 iMac「系统设置 → 隐私与安全性 → 辅助功能」里勾选 Terminal（`AXIsProcessTrustedWithOptions` 弹窗未生效，`tccutil` 不能增权），GUI Terminal 内 `stream_probe --preflight host --inject real` → `ax=1 capture=1 ok=1`。`P2_INJECT=real` + client `--input-synth` 5 点：首轮 6/6 收到并注入、光标位移 1055px；复测 6 收到 / 3 注入成功、位移 1154px（部分合成点在收尾窗口内被丢弃，属夹具时序）。两轮 `p2.sh summary` 均 PASS。证据：`P2-Dual/out/a07-realinput-13/`、`a07-realinput-13-r2/`。

**6) Path A（锁屏进入）首轮被黑帧阻断（后于 §5.29 推翻）**。`p0vprobe lock` 成功上锁，锁屏期间 CGDisplayStream 仍以 ~2fps 出帧，但落盘截图是**纯黑 + 光标**（`P2-Dual/out/a07-patha-13/before.png`）；`screencapture` 直接失败，p0vprobe 的 `inject-test` verdict 依赖 SCK、在 13 上不可用。为绕开 verdict 依赖给 `p0vprobe` 新增 `type` 子命令（只做 `CGEventPostToPid` 键入 + Return，不依赖 SCK）。**当时把黑帧归因为 OS 层限制是错误的**：未先确认显示是否睡眠，且未区分 CGDisplayStream 与 CGDisplayCreateImage 两条路径，见 §5.29 更正。

**A-07 收敛口径（§5.29 更新前）**：client 全角色 PASS；host 镜像 + 虚拟屏 keep-main 全链路 PASS，真实输入注入 PASS，SPI 建屏 PASS；完整独占禁屏 / C-09 为 OS 层阻塞（WindowServer 崩溃）。

### 5.29 13 锁屏黑屏根因更正：显示睡眠 + CGDisplayStream 后端，新增 CGDisplayCreateImage 后端

用户指出「锁屏几秒后无输入会黑屏」，逐项对照实验后确认**§5.28 第 6 点的 OS 层结论不成立**，黑屏有两个独立成因：

| 条件 | `CGDisplayCreateImage` | `CGDisplayStream`（项目当时的回退后端） |
|---|---|---|
| 锁屏 + 显示器睡眠（`asleep=1 active=0`） | 返回 `NULL`，无帧 | 黑帧或极低频 |
| 锁屏 + 显示保持唤醒（`caffeinate -d -u`） | ✅ `1920x1080 mean=107.8 nonblack=100%`，截图含 `bemin` / `Enter Password` / 时钟（`/tmp/a07-lock-after-caf.png`、iMac `P2-Dual/out/a07-lock-caffeinate/after.png`） | ❌ 仍交付纯黑帧；客户端落盘 `a07-patha-cafstream2/frame-001.png` 全黑 |
| 对照：镜像模式未锁屏 | ✅ 有画面 | ✅ 有画面（§5.27） |

即：**睡眠解释「截图直接失败」，后端选择解释「为什么 stream 仍有帧却是黑的」**。Tahoe 的 Path A 早有「caffeinate 先于 lock」的前置条件（§3.3/§4），13 同样需要防睡眠断言；`M1RDPDriver` 已有 `kIOPMAssertionTypePreventUserIdleDisplaySleep` 断言（p2 测试由 `caffeinate -d -u` 等价提供），不是新需求。

**实现**：`M1CapturePipeline.m` 增加第三条后端 `M1CGImageSource`——`CGDisplayCreateImage` 定时快照 → `CGBitmapContext` 画进 BGRA `CVPixelBuffer` → 复用既有 `M1CaptureOutput -deliverPixelBuffer:`。锁屏态运行时自动切换（用公开 `CGSessionCopyCurrentDictionary()` 的 `CGSSessionScreenIsLocked` 键监测，每秒一次；解锁后恢复原首选后端），也可用 `M1_CAPTURE_BACKEND=cgimage` 强制。13.3 / 26.5 SDK 双构建与两套 268 单测均通过。

**验证（13 host 锁屏 + Tahoe client，镜像 1280x720@15）**：
- host 首帧即选 `backend=CGDisplayCreateImage`，客户端收 2756 帧包 / 解出 359 / 上屏 359 / 丢 1（积压）/ 0 解码失败，解码 14.9fps，`p2.sh summary` 判定 PASS。
- 保存帧 `P2-Dual/out/a07-patha-cgimage/frame-002.png` 清楚显示登录壁纸、`bemin` 头像、`Enter Password` 输入框和时钟（证据已同步到本机同名目录）。
- **键盘注入也得到确认**：锁屏 + caffeinate 下 `p0vprobe type --text zzzzzzzz` 返回 `ok=true loginwindowPID=16094`，前后 `CGDisplayCreateImage` 截图哈希由 `dc1e1eb6…` 变为 `6b88690e…`；后一张密码框出现输入圆点（iMac `P2-Dual/out/a07-patha-inject/`）。⇒ 13 的 Path A「看见登录界面 + 定向键入」在镜像模式已可用。

**补测：真实口令解锁 PASS（2026-11-21 21:28）**。用户提供真实口令后，经临时文件（600 权限、执行后立即删除）传入 GUI 会话，`p0vprobe type` 输出不再包含明文。首轮暴露新问题：Unicode 事件投递过密，10 字符口令只有 2 个圆点落到密码框（错误口令 8 字符同样只落 2 个）。修复 `P0V-RootDaemon/src/p0vprobe.m`：逐字符间隔 30ms，键入前先发 32 次 Delete（键码 51）清空残留输入。复测：锁屏 + `caffeinate -d -u` → `p0vprobe lock` → 前置 `locked=1` → 注入真实口令 → 后置 **`locked=0 / ok=1`、截图为已解锁桌面**（`P2-Dual/out/a07-unlock-real-r2/`）。⇒ 13 上 Path A 的「看见登录界面 + 定向键入 + 正确口令解锁」端到端成立（镜像模式）。

**边界**：① 仍必须持有防显示睡眠断言，否则 `CGDisplayCreateImage` 返回 NULL；② 完整独占禁屏 / C-09 的 WindowServer 崩溃（§5.28 第 2 点）已由 §5.30 的 ScreensharingAgent 竞态规避解决，不再是 OS 层阻塞；③ `CGDisplayCreateImage` 自 14 deprecated，只作锁屏态专用后端，未锁屏仍用 SCK/CGDisplayStream；④ 合成键入必须逐字符延时，否则 loginwindow 会丢弃事件（已修入 `p0vprobe`）。

**A-07 最终口径（§5.30 更正后）**：client 全角色 PASS；host 镜像 / keep-main 虚拟屏全链路 PASS，真实输入注入 PASS，SPI 建屏 PASS，锁屏态看见登录界面 + 键盘注入 + 真实口令解锁 PASS；**完整独占禁屏 / C-09 也已 PASS（§5.30）**。A-09 在 13 从「不可行」更新为「镜像模式 Path A 端到端 PASS（V-04a/b/c 等价）」。

### 5.30 13 完整独占禁屏 / C-09 通过：ScreensharingAgent 显示流竞态规避（2026-11-21 22:1x–22:3x）

**§5.28 第 2 点「OS 层阻塞、不再重试」被本轮更正。** 崩溃报告与系统日志给出新证据：

| 轮次 | 崩溃时刻 | 栈顶 | 触发点 |
|---|---|---|---|
| 原 r1/r4（20:38/20:41） | 虚拟屏 mode-commit 后 | `_platform_memmove` → `DisplayStreamStateSW::CopyFrame` → `CGXDisplayStreamStart` → `_XDisplayStreamStart` | 崩溃前 0.1–0.5s `ScreensharingAgent` 正在重启自己的 `CGDisplayStream` |
| 本轮 v1 守卫（22:10） | 22:10:34，仍在建屏阶段、`C-09` 校验之前 | `layer_blit_byte_ANY` → `layer_blit_entry` → `_dispatch_root_queue_drain` | 同一显示重配置窗口，另一条 WindowServer 绘制路径；v1 守卫只覆盖「禁屏事务」，未覆盖建屏，故未生效 |

⇒ 根因不是「禁屏 API 在 13 不可用」，而是 **屏幕共享 agent 的显示流与虚拟屏 mode 提交 / 禁屏重配置竞态**。

**修复（C-17.40）**：`M1RDPDriver` 在 macOS 13 上把 `ScreensharingAgent` 的 `SIGSTOP` 窗口前移到 `createVirtualDisplays` 的 `createAll` 之前，一直保持到禁屏事务提交 + 1s settle 后 `SIGCONT`；建屏失败、无需禁屏、恢复物理屏及 guardian 异常兜底路径都无条件解冻。`M1_C09_QUIESCE_SS=0` 可关闭该规避。只冻结进程，不卸载/禁用屏幕共享服务。

**验证（13 iMac host × 26 Mac mini client，LAN，1280×720@15，25s）**：

```text
[22:35:41] C-09: 冻结 ScreensharingAgent (26682)
[独占] 虚拟屏就绪 ids=4128832  phase=Streaming  physicalDisabled=是
[独占] C-09=verified  禁屏后 active=(4128832 仅虚拟屏)
[22:35:45] C-09: 恢复 ScreensharingAgent (26682)
[22:36:10] C-09: 恢复 ScreensharingAgent (26682)   # 会话收尾兜底
[独占] 已恢复物理屏并销毁虚拟屏
```

- `host.json`：`sessionMode=exclusive`、`c09Status=verified`、`virtualDisplayIDs=[4128832]`、`activeDisplayIDsAfterDisable=[4128832]`、`sessionRecovered=true`、`sessionEnded=true`。
- host 采集 172 / 编码 163 / 发出 163，`sendFailures=0`；client 收齐 163 / 解出 163 / 上屏 161，丢帧 0、解码失败 0，规格 1280×720 一致，`p2.sh summary` **PASS**。
- 会话后 WindowServer PID 未变（25994）、`/dev/console` 仍为 `bemin`、物理主屏恢复 `1920x1080+0+0 active=1 main=1`、`ScreensharingAgent` 正常运行、TCP 5900 可达。**全程无崩溃**。
- 证据：`P2-Dual/out/c09-quiesce-r3/`（两端 JSON/日志已同步到本机同名目录）。13.3 / 26.5 SDK 双构建 + 各 268 单测通过。

**边界**：① 规避只在 `osMajor==13` 生效，26/Tahoe 不冻结任何进程；② 冻结窗口内屏幕共享会短暂停顿（本轮约 3.5s），会话结束即恢复；③ 本轮仅验证 1280×720 单屏，多屏/1080p 独占未在本轮覆盖；④ 崩溃后登录态恢复仍需人工登录或屏幕共享（SSH 侧无法在 loginwindow 启动 GUI 终端），属操作规程而非产品缺陷。

### 5.31 C-09 剩余边界补测：1080p 独占与连续建屏的 OS 层崩溃（2026-11-21 23:0x–2026-11-22 13:4x）

承接 §5.30 边界③，尝试补测 1080p 独占、独占态 Path A、多屏独占。结论：**三项均未能完成，暴露两条新的 OS 层边界，iMac 显示栈在反复 mode-commit 后进入不稳定态，故停止真机重试**。

| 尝试 | 配置 | 结果 | 证据 |
|---|---|---|---|
| 1080p 独占 C-09 | 1920×1080，`M1_C09_QUIESCE_SS=1` + `M1_CAPTURE_RESOLUTION=best`，agent 已冻结 | ❌ 虚拟屏 `mode-commit ok=true` 后 WindowServer 崩溃（PID 25994→32283，console→root），登录界面中断 | `c09-quiesce` 无此问题；崩溃 `WindowServer-2026-11-21-230756.ips` |
| 独占态 Path A（首次，健康态） | 720p 独占，日志标记触发锁屏 | ❌ 未进流：建屏 mode-commit 期间客户端控制通道 `seq=2 重传 8 次仍未确认` 提前放弃（8×250ms=2s 重传窗口被建屏阻塞踩线） | `P2-Dual/out/patha-exclusive-r1/` |
| 独占态 Path A（重跑，带病态） | 同上 720p 配置 | ❌ 虚拟屏 `create` 后、`mode-commit` 前 WindowServer 崩溃（PID 32283→37968），栈 `layer_blit_byte_ANY→layer_blit_entry` | 崩溃 `WindowServer-2026-11-22-134044.ips`（该 WS 进程 23:07 1080p 崩溃时启动，已带病运行） |
| 多屏独占 | — | ⏸ 未执行：连续崩溃后显示栈不稳定，停止重试 | — |

**崩溃栈对比（关键证据）**：

| 崩溃 | 时刻 | 信号 | 栈顶 |
|---|---|---|---|
| 1080p 独占 | 23:07:54 | SIGBUS `KERN_PROTECTION_FAILURE` | `layer_blit_byte_ARGB8_ARGB8_RGB8 → layer_blit_entry → _dispatch_root_queue_drain` |
| 720p 重跑（带病态） | 13:40:41 | SIGSEGV `KERN_INVALID_ADDRESS` | `layer_blit_byte_ANY → layer_blit_entry → _dispatch_root_queue_drain` |

两次都崩在 WindowServer 的 **layer blit**（图层合成/拷贝），而非 §5.30 已修复的 `DisplayStreamStateSW::CopyFrame`（显示流创建），且都发生在虚拟屏 mode 提交窗口内。1080p 与 §5.30 成功的 720p 用**完全相同的建屏策略**（`conservative=false`、`applySettings=true`、`conservativeFirst=false`、agent 已 `SIGSTOP`），唯一差别是 framebuffer 尺寸（1920×1080 vs 1280×720）。⇒ 这是 iMac（i5-9500 + 弱 GPU）上 **WindowServer 图层合成对大/反复 mode-commit 的脆弱性**，与 ScreensharingAgent 竞态是两条独立问题，`M1_C09_QUIESCE_SS` 规避对它无效。

**新增边界（按 OS 分离，仅 Ventura 13 / 此机型）**：
- **V-补1**：13 上 1280×720 独占 C-09 可稳定复现 PASS（§5.30），但**1920×1080 独占会触发 WindowServer layer-blit 崩溃**，不属已修复竞态，判定为该机型 OS 层边界，不重试、不外推。
- **V-补2**：13 上虚拟屏 mode-commit 期间（实测约 1.4–1.6s）会阻塞控制通道 ACK，8×250ms 重传窗口踩线可能导致客户端提前放弃；这是建屏慢与控制可靠性的耦合，非流数据问题，健康态下 r3 未触发。
- **V-补3**：**连续 mode-commit 会使该机 WindowServer 显示栈累积不稳定**——首次崩溃后重启的 WS 进程在后续 720p 建屏时再次崩溃（栈同为 layer blit）。⇒ 真机排障纪律：每次独占建屏崩溃后，须让机器充分恢复（重新登录/重启窗口服务）再测，不可连续重试。
- 独占态 Path A（V-04d 等价）、多屏独占：**仍未覆盖**，本轮未能取得任何正向或明确负向结论（前者被建屏崩溃/重传放弃阻断，后者因稳定性停止）。

**对 harness 的唯一改动**：`P2-Dual/p2.sh` 新增可选 `P2_SAVE_FRAMES`（默认 0，保存客户端解码前 N 帧用于视觉证据），不改变既有测试行为；两端已同步、语法校验通过。产品代码未改动。

**环境收尾**：iMac 两次回到 loginwindow，均以 `kickstart -activate -restart -agent -console` 恢复屏幕共享，TCP 5900 / RFB 003.889 可达；临时口令文件 `/tmp/c09pw` 待登录后清理。本机与 iMac 仓库均在 `7054bc5` 基线，本机仅有 p2.sh 未提交改动。

### 5.32 健康态独占复测 PASS + Path A 根因定位（2026-11-22 13:5x–14:0x）

用户手动登录后 iMac 显示栈已充分恢复（WS PID 37968 稳定运行、console=bemin、ScreensharingAgent 正常、5900 可达）。据此重跑并定位根因。

**① 健康态 720p 独占 C-09 全链路 PASS（推翻 §5.31「连续建屏必崩」的悲观判断）**：
- `P2-Dual/out/patha-exclusive-r4/`，13 host × 26 client LAN 1280×720@15、50s：
  - host：`C-09=verified`，禁屏后 active 仅虚拟屏 `4128832`，`sessionRecovered=true`；冻结窗口 13:54:53 起、13:54:57 恢复；**全程 WindowServer PID 37968 未变，无崩溃**。
  - client：状态序列 `DISCOVERED→…→STREAMING`，datagrams=3623 / decoded=511 / dropped=0 / decodeFail=0；上屏 25 帧；规格断言 PASS；`p2.sh` 判定 **PASS**；保存 8 张 PNG 作为视觉证据。
- ⇒ **V-补3 修正**：连续 mode-commit 的累积不稳定不是必然；健康态（充分恢复）下 720p 独占可稳定 PASS。真机纪律仍是「崩溃后须充分恢复再测」，但不因历史崩溃否定健康态结果。

**② 建屏阻塞控制 ACK 的稳健规避（V-补2 缓解）**：
- `M1-Skeleton/stream_probe.m` 在 `attachSessionTo:` 增两个诊断开关 `M1_CTRL_RETRY_MS`、`M1_CTRL_MAX_ATTEMPTS`（默认 250ms×8 不变）。r4 客户端设 `500ms×16`（8s 窗口）后，实测控制通道最大到达间隔 1018ms 未踩线，进流成功。属 harness 诊断开关，默认行为不变。

**③ Path A 独占态根因定位（V-04d 等价仍未通过，但已从「OS 崩溃」改为「明确的 API 上下文限制」）**：
- r4 的 wrapper 在**独占态**（物理屏全禁、仅虚拟屏 active）调用 `p0vprobe lock`：返回 `{"ok":true,"called":"SACLockScreenImmediate"}`，但锁屏后 probe 仍 `screenIsLocked=false`，保存帧全是动画/桌面，**登录 UI 从未呈现**。
- 对照实验（恢复物理单屏后）：同样的 `p0vprobe lock` 在 GUI Terminal（Aqua session）里调用，8 秒后 `screenIsLocked=true`；而 SSH 进程直接调用同 API 静默无效（不在 Aqua session）。⇒ **`SACLockScreenImmediate` 必须在 Aqua/GUI session 中调用，且在物理屏全禁的独占态下不生效**。
- 镜像模式 §5.29 的 Path A 成功，正是因为物理屏仍在、lock 在 GUI Terminal 有效；独占态禁掉物理屏后这条锁屏触发路径失效。⇒ 独占态 Path A 要成立，需另找触发锁屏/登录窗的路径（例如登录窗迁移本身应由「零 active 物理屏」触发，见 §5 V-04d Tahoe 结论；13 上该迁移是否自动发生尚未验证）。
- 锁屏后一度进入「`screenIsLocked=true` 但登录框未呈现」的过渡态（`kCGSessionSecureInputPID=none`、截图纯壁纸），SSH 侧 `type` 注入无效；已清理残留进程。**该状态下恢复登录需人工/屏幕共享**。
- 补充：在 r4 成功后，又连续做了多次 lock / lock-probe / 屏睡唤醒扰动显示栈，随后尝试独占态 lock 复现验证（`excl-locktest-r1`）时，720p 独占在建屏 `mode-commit ok=true` 后再次 WindowServer 崩溃（PID 37968→42282）。⇒ 再次印证 V-补3：显示栈对「显示重配置类操作」的累积扰动很敏感，健康态 PASS 之后也不宜连续叠加 lock/屏睡/建屏；崩溃后须重新登录充分恢复。该次复现验证失败不影响上面①②的独立证据（r4 PASS 与 Aqua-session lock 对照）。

**边界口径不变**：13 上只有 1280×720 单屏独占 C-09 有真机 PASS；1080p 独占为 OS 层边界；多屏独占与独占态 Path A（V-04d 等价）仍未覆盖。本轮未改产品代码（仅 stream_probe 两个默认关闭的诊断环境变量 + 既有 p2.sh `P2_SAVE_FRAMES`）。

### 5.33 采集分辨率默认改 `best` + 本机 Sequoia 镜像环回冒烟（2026-11-22 20:3x，本机环回）

**变更**：`M1FramePipelineConfig.captureResolution` 默认值 0（auto）→ **1（best）**。macOS 14+ 走 `SCCaptureResolutionBest`；macOS 13 由既有编译期守卫忽略，行为不变。`M1_CAPTURE_RESOLUTION=auto|nominal|0|2` 仍可覆盖（诊断用）。依据 §5.24：3440×1440 物理屏镜像到 1080p 时，auto 把缩放压给 host，采集跌到 5.7fps，best 让 SCK 直出目标尺寸、稳在 18–20fps。这样 host 启动不再依赖手动环境变量。

**验证（本机 Sequoia 15.5，镜像模式环回，不建屏/不禁屏）**：
- `build_stream_probe.sh` 无 warning；`test_skeleton` **268/268 PASS**。
- 720p15 × 20s：采集 71 / 编码 69 / 发出 69，客户端收齐 69 / 解出 69、丢帧 0、解码失败 0，`p2.sh summary` **PASS**；`[capture]` 行确认 `res=best`（`mode=3008x1692@60`、`out=1280x720`、`scale=2.00`）。
- 同负载 A/B（10s，主机仍在 mds 索引 + Qoder 渲染负载下）：best 22 帧、auto 6 帧。绝对吞吐远低于正常基线（WindowServer 被负载拖慢），**不能作为性能结论**，但可排除 `best` 在当前内容/负载下比 auto 更差。
- 客户端渲染 189.8ms/帧仍是负载污染值（Qoder + mds），P2.3 空闲基线继续留待本机安静时重测；解码 16.4ms 正常。

**部署含义**：高分辨率物理屏镜像推流默认即用 best；只有排查 SCK 分辨率选择时才显式设 `auto`/`nominal`。

**Tahoe 真机复测（2026-11-22 22:3x，Tahoe 26.5.2 host × Sequoia 15.5 client，WAN）**：3440×1440 → 1920×1080 镜像 20fps / 20s，host `backend=ScreenCaptureKit`、`mode=3440x1440`、`out=1920x1080`、**`res=best`**，capture complete=20/s、idle=0，framesCaptured 488 / encoded 487 / sent 487；client decoded 485 / 19.6fps、规格断言 PASS、summary PASS、首帧 106ms。确认 `best` 在 Tahoe + 超宽屏镜像路径生效且不掉帧。

**P2.3 干净基线（2026-11-22 21:39–21:47，本机 Sequoia 15.5；Qoder 最小化 + mds 暂停 + 测试进程 nice -20）**：
- 离屏 `render_selftest` 8 轮（每档 n=8）：vga min/p50/p95 = 2.3/2.3/2.4ms，720p = 3.0/3.2/3.4ms，1080p = 5.2/5.3/10.4ms，ultrawide = 10.3/13.2/22.2ms，**0 条失败**。此前 20–50ms 的离屏值主要是 Qoder UI/WindowServer 竞争，不是 CI 转换成本。
- 真实 client 1080p20 镜像 30s（Tahoe 26.5.2 host 主屏 3440×1440→1920×1080 + 全屏动画）：host `complete=20/s idle=0`、framesCaptured 589 / sent 588；client 解码 19.2fps、上屏 504、积压丢弃 66、`lastRenderMs=3.9`、`maxRenderMs=209.4`（启动尖峰）、规格断言 PASS、`p2.sh summary` PASS。
- ⇒ 1080p20 的客户端渲染下限约 **4ms**，相对 50ms 帧预算有 10× 余量；积压丢弃来自重组/队列而非渲染成本。当前 harness 只有 last/max，p50/p95 需后续加分位数统计。

**P2.3 上屏积压收口（2026-11-22 22:0x，同环境，1080p20 镜像 30s）**：
- 复现与定位：上轮 `renderDropped=66`，但转换 p50 仅 4.5ms、主线程贴层等待约 0.2ms，说明不是渲染慢。根因是积压上限 2 帧：网络/解码突发时转换队列短暂超过 2，新帧被误判丢弃；且主线程贴层完成前槽位不释放，进一步压缩余量。将槽位改为转换完成即释放（主线程等待单独计量）后，上限 2 仍丢 67；上限 8 降至 2；上限 12 为 0，保留 12（极端突发理论排队上限约 54ms，实测峰值 8 帧）。
- 新增观测：`presentPixelBuffer` 记录 pending 峰值、转换耗时 1ms 直方图 p50/p95、入队等待、主线程贴层等待；client JSON/log 输出 `renderDroppedBacklog`、`renderFailed`、`maxPendingRenders`、`renderP50Ms/P95Ms`、`maxRenderQueueWaitMs/MainWaitMs`。
- 最终 `p23-client-1122f` / `p23-mirror-1122f`：host 589 采集 / 588 发出，client 587/587 解出并上屏，积压丢 0、无 surface 0，`maxPendingRenders=8`，转换 p50/p95 = **4.5/20.5ms**，主线程贴层等待峰值 0.1ms，解码 **19.8fps**，summary PASS。`maxQueueWaitMs=241.5`（`maxRenderMs=242.6`）只出现在首帧 1080p 冷转换，之后稳态无积压；`render_selftest` ALL PASS，单测 280/280。
- ⇒ P2.3「1080p20 跨机满帧 + 上屏队列 0 积压」达成；A-02 glass-to-glass 仍开放。

**P2.3 测量环境要点**：Qoder 常驻时即使 `nice -20` 也会出现 500–875ms 调度尖峰（nice 不约束 GPU/WindowServer）；把 Qoder 窗口最小化后 WindowServer 从 24% 降到 5%，配合暂停 mds 才能得到上述稳定值。专用户会话是更彻底的隔离方式。

### 5.34 M1 窗口布局快照/恢复落地：纯逻辑计划器 + AX 注入 + Tahoe 独占闭环（2026-11-22 21:1x 实现与 Sequoia 只读验证；22:0x–22:3x Tahoe 26.5.2 闭环）

**背景**：D-05 的副作用——物理屏被移出空间时 WindowServer 把窗口搬到剩余屏，恢复后不会自动回原位。此前只有 display 快照，没有窗口级还原。

**实现**（`M1-Skeleton/src/M1WindowLayout.{h,m}`，新模块）：
- 采集：`CGWindowListCopyWindowInfo(OnScreenOnly|ExcludeDesktopElements)`，取 `layer==0`、非本进程、alpha>0.01 的窗口；frame 换算到全局左上坐标，按「中心所在屏 → 最大交叠屏」映射 `displayID`；同时记录各 active 屏 bounds。
- 计划（纯逻辑，可离线测）：以 `pid#windowNumber` 精确匹配；只处理「快照时在本次被禁物理屏上、当前 frame 已变、窗口仍存在」的窗口；目标位置按快照所在屏夹取，至少保留 120pt 宽 × 40pt 高可见（负坐标屏也能正确夹回）。
- 执行：`AXUIElement` 按 `AXWindowNumber` 匹配；Terminal 与系统设置不暴露该属性（`AXError=-25205`），回退用 position/size，并以 `CGWindowListCopyWindowInfo(IncludingWindow)` 取**当前** frame 做 8pt 容差比对（不再用快照 frame 比当前 AX 窗口）。先 size 后 position，单窗口消息超时 2.0s；`AXWindows` 枚举为空时 150ms 后重试一次（恢复显示后立即查询常返回空）。AX 未授权时只计划不搬，计 `skipped` 而非 `failed`。整轮预算 `max(3, min(10, 0.7×N))` 秒，best-effort。
- 接线（`M1RDPDriver`）：窗口快照与 display 快照同在 `prepareSessionShieldError` 内、建虚拟屏之前拍摄；恢复顺序为「启用物理屏 → 销毁虚拟屏 → settle **1.0s** → 搬窗」（0.3s 时 AX 查询仍频繁超时，见 §5.34 现场记录），摘要写入 `lastWindowRestoreSummary`，`stream_probe` 的 host JSON 新增 `windowLayoutRestore` 字段。
- 快照 JSON 与 display bounds 用 `valueWithBytes:objCType:@encode(CGRect)` 装箱，保持 Foundation-only 单测可编译。

**验证**：
- `build_tests.sh` **280/280 PASS**，新增 12 条：JSON 往返（含负坐标 frame / 负原点屏）、位移计划、原位跳过、保留屏跳过、窗口已关闭跳过、同 pid 不同 windowNumber 不误配、负坐标夹取（期望 x=-680）、授权执行搬窗与目标 frame、未授权 skip。
- `build_stream_probe.sh` / `build_driver.sh` / `build_kiosk_probe.sh` 均无 warning。
- `driver_probe` 只读环境（本机 Sequoia 15.5）：`axTrusted=true`、采集到 4 个窗口、`knownDisplayCount=3`、4 个窗口均映射到已知屏，证明采集链路在本机真实环境可用。

**Tahoe 26.5.2 host 独占闭环（2026-11-22 22:0x–22:3x，WAN，Sequoia 15.5 client）**：
- r3/r4 首次接入暴露两处实现问题：Terminal 的 AX 窗口枚举返回「应用没有可访问窗口」后整轮 `deadline`；系统设置窗口因拿快照 frame 比当前 AX frame 而误判「窗口已不存在」。按上面「当前 CG frame + 8pt 容差」「2s 超时 + 枚举重试」「预算随 N 缩放」修复。
- **r5（自然场景）**：`captured=18 planned=0 restored=0 failed=0 trusted=1`。Tahoe 26.5.2 的 WindowServer 在显示恢复约 1s 内已把窗口全部搬回原位，**D-05 的「不还原」现象在该版本未复现**；因此自然会话无法证明我们的搬回逻辑，只能证明它不误搬。
- **r6（诱导场景）**：在快照前用 AX 把 Terminal 窗口 `m1-gui-excl-r6.command` 从 (0,186) 强移到 (150,306)，再跑独占会话。host `captured=23 planned=7 restored=7 failed=0 skipped=0 trusted=1`，`C-09=verified`、`sessionRecovered=true`；client PASS。恢复后的 AX dump 显示该窗口位于 **464,131（即快照位置）**、已不在 150,306，其余 6 个被计划窗口也都复位。⇒「禁屏 → 窗口被搬走 → 恢复 → 搬回快照位置」端到端成立。
- 7 个 planned 除被强移窗口外，还包含恢复瞬间被 WindowServer 挪动过的几个 Terminal 窗口；全部 restored，说明计划器不会误伤未位移窗口，也能处理位移方向/幅度不一致的情况。

**仍未覆盖**：Ventura 13 的独占窗口恢复（今晚不测 Ventura）；多屏独占下的窗口布局恢复；AX 未授权时整轮 skip 的产品态行为（单测覆盖，未在 Tahoe 真机验证）。Sequoia 本机未跑完整独占（禁物理屏会黑屏），采集/计划/执行链路已由单测 + 只读探针 + Tahoe 闭环覆盖。

### 5.35 A-02 打点落地：帧头 v3 内嵌采集时刻 + time-sync，单机环回冒烟与首轮跨机 capture→render（2026-11-22 22:1x–23:0x）

**结论先说**：A-02 的测量手段（capture→render）已落地，并在 Tahoe 26.5.2 host 解锁后取得**首轮跨机数据**：1080p20 镜像、WAN 路径，p50 ≈ **94–95ms**（两轮 583/767 帧），p95 206–231ms。测量路径本身先暴露了一个符号错误（见下），修正后样本完整。**glass-to-glass 仍未测**（无相机/硬件打点），A-02 保持开放。

**实现（协议 + 两端）**：
- 帧头 **v2(18B) → v3(26B)**：偏移 18 起 8 字节大端 `capturedAtUs`（Host 采集时的 Unix epoch 微秒，0=未知）。Host 在像素缓冲进编码器时打点，编码回调按 PTS 回填 `M1EncodedFrame`；Client 把它作为解码 sample buffer 的 PTS，VT 输出回调带回，`M1FrameView` 在主线程贴层时与本地 `CLOCK_REALTIME` 相减。
- 控制通道新增 `time-sync {t0}` / `time-sync-reply {t0,t1}`，仅 STREAMING 态；Client 收 `t2` 后算 `offset=t1−(t0+t2)/2`，只保留最小 RTT 样本，RTT>5s 丢弃。v3 与 v2 不兼容，双端必须同版本重建。
- `M1FrameView` 新增 256×1ms 原始延迟直方图、样本数、last/max；`stream_probe` client JSON 新增 `timeSyncOffsetUs/RttMs/Samples/hasClockOffset` 与 `captureToRenderP50Ms/P95Ms/LastMs/MaxMs`。
- 验证：本机与 Tahoe host 单测均 **291/291 PASS**；host 构建无错误（仅两条无害 VLA 折叠 warning）。

**Sequoia 15.5 单机环回（host/client 同机，1080p20 镜像，25s/20s，`/tmp/m1-clock` 制造动态内容，Qoder 最小化，Screen Sharing 窗口隐藏但连接保持）**：
- host：SCK `3008x1692@60`、`scale=2.00`、`out=1920x1080`、`res=best`；captured 385 / encoded 383 / sent 383，`dropPreEnc=0 encFail=0 sendFail=0`，firstFrame 288ms。
- client：382/382 解出并上屏、积压丢 0、无 surface 0，解码 **19.8fps**，规格断言 PASS，`p2.sh summary` PASS；转换 p50/p95 = 29.5/47.5ms，pending 峰值 4，主线程贴层等待 0.2ms。
- capture→render：样本 382，时钟差 **+54µs**（RTT 0.7ms / 8 样本），p50 **49.4ms**、p95 187.4ms、last 45.6ms、max 429.3ms（首帧冷启动尖峰）。
- 前一环回（Screen Sharing 可见、静态桌面）host 25s 仅 97 帧、解码 5.0fps、capture→render p50 255.5ms（时钟差 39µs / RTT 1.3ms），仅证明打点通路，**数值作废**。

**首次跨机运行暴露符号错误（2026-11-22 22:5x，Tahoe host 已从锁屏恢复：console=bemin、`IOConsoleLocked=No`）**：
- r1（修正前）1080p20 镜像 30s：client 586/586 解出、19.7fps、0 丢、summary PASS，但 `capture→render` 只有 **380/586** 样本且 p50=0.0。原因有二：① 原始差 `client_now − capturedAtUs` 在主机时钟超前时为负，旧直方图直接丢弃负样本（被丢的 206 帧恰是延迟较低的帧，样本偏向慢帧）；② 报告端把 host−client 时钟差 **减去**了，正确方向是 **加回**（`capturedAtUs` 是主机时钟）。r1 的 raw p50 恰好≈时钟差 87.2ms，减去后归零。
- 修正：`M1FrameView` 的 capture→render 直方图改为 **-512ms 起的 2048 桶有符号 1ms 直方图**，`stream_probe` 报告端改为 `raw + offset` 并钳到 ≥0。双端重建后单测仍 291/291。

**跨机复测（修正后，Tahoe 26.5.2 host × Sequoia 15.5 client，WAN `112.5.32.34:46600`，host 主屏 `2026701824` 全屏彩条动画，镜像 1080p20，Qoder 最小化、Screen Sharing 隐藏）**：

| 轮次 | host 采集/编码/发出 | client 解出/上屏 | 解码 fps | 时钟差 / RTT | capture→render p50 / p95 / max | 渲染 p50 / p95 | summary |
|---|---|---|---|---|---|---|---|
| r2 30s | 588 / 587 / 587 | 583 / 583（丢 0） | 19.7 | +88.6ms / 7.1ms | **95.1 / 231.1 / 549.2ms** | 4.5 / 37.5ms | PASS |
| r3 40s | 785 / 784 / 784 | 767 / 767（丢 0） | 19.2 | +87.7ms / 8.7ms | **94.2 / 206.2 / 637.7ms** | 4.5 / 6.5ms | PASS |

- 两轮 p50 稳定在 94–95ms；样本数与上屏帧数一致（583/583、767/767），说明负样本丢失已修掉。r3 入队等待峰值仅 38.3ms、主线程贴层等待 1.5ms，渲染不是瓶颈；r2 有一次 434ms 入队尖峰（对应 p95 尾部）。
- 主机时钟比客户端快约 **88ms**（两轮一致），控制通道 RTT 7–9ms，说明这段 WAN 单程很低；p95 的 200ms 级尾部更像编码/SCK 批次与偶发排队，而不是网络 RTT。
- 首帧延迟 105ms（r2）/ 93ms（r3），补片 36/64 次全部命中，关键帧请求 0。

**口径**：① 单机环回中采集编码与解码渲染争同一条 GPU/WindowServer，且 Screen Sharing 仍在解码 Tahoe 3440×1440 画面，p50≈一个帧间隔（50ms）更像排队节拍，p95 尾部是竞争噪声，**仅作冒烟**；② 跨机数字是 **capture→render**，不含显示器扫描、摄像头采样，**不等于 glass-to-glass**；③ 跨机样本仅来自一轮会话的两种时长（30s/40s），尚未做多时段/多网络条件采样。

### 5.36 产品入口补齐 `--guardian` 兜底握手；Tahoe keep-main 双机 WAN 闭环（2026-11-23 21:4x–22:2x）

**背景**：产品入口 `veild-host-agent --serve` 跑 keep-main/独占档时被自身安全门禁拒绝：`M1RDPDriver.prepareSessionShield` 调 `P0VStartGuardian`，后者用同一二进制 re-exec `--guardian` 并等待 `<snapshot>.guardian-ready`；第 4 轮产品化后的 `Apps/HostAgent/Sources/main.m` 没有该分支，守护子进程打印用法后退出，握手超时即报「守护进程启动即退出（exit=0）…禁止在无兜底的情况下禁屏」。探针入口（`stream_probe` 等）一直有该分支，属 C-12.2 的收口遗漏。

**修复（`17f9883`）**：`Apps/HostAgent/Sources/main.m` 在 `main` 最前拦截 `--guardian <snapshot> --parent-pid <pid>` 并转调 `P0VRunGuardian`（+13 行）。`HostDaemon` 目标不链接 RDPKit、也不执行显示配置，未改。五个 target 重建，`Scripts/test.sh` ALL PASS；两端 `--guardian` 缺参均退出码 3，确认分支生效。

**本机 Sequoia 15.5（host/client 同机，`127.0.0.1`，产品入口）**：
- 镜像档 r0（720p15，静态桌面，30s/18s）：握手 55.3ms，host captured 43 / encoded 42 / sent 28（drop 0），client 28/28 解出上屏，解码/发送 = 100%，控制最大间隔 1046ms，上屏 p50/p95 = 92.5/320.5ms，时钟 offset 10µs，`c09=not-started`。
- 镜像档 r1（720p15，主屏 `anim_display 0` 彩条动画，26s/18s）：握手 65.3ms，host captured 265 / encoded 264 / sent 223，动画期间 `[capture] complete=12–15 idle=0–3`；client 220/220 解出上屏、0 丢帧，**解码/发送 = 220/223 = 98.7%**，控制最大间隔 1051ms，上屏 p50/p95 = 113.5/366.5ms。
- keep-main 门禁（修复后）：守护进程启动并完成就绪握手（快照旁生成 `.guardian-ready`），但本机被已知陈旧虚拟槽位 `4128835` 阻断——建屏即处于镜像态，`unmirror 超时(8s) → WindowServer 疑似挂起`，keeper 中止全部建屏动作（非本次改动引入）。强制终止 host 后守护日志记录「父进程未正常收尾 → 兜底恢复成功」。副作用：主屏模式从 3008×1692（Looks like）落到 3840×2160，已用 `CGDisplaySetDisplayMode` 恢复并核对三块物理屏。**本机 keep-main/独占仍需登出清理槽位后再测**。

**Tahoe 26.5.2 host × Sequoia 15.5 client（WAN `112.5.32.34:46600`，keep-main 720p15）**：
- 启动：SSH 下 `launchctl asuser` + `open -a Terminal host-serve.command`，沿用 Terminal 的屏幕录制授权；两端指纹 `3305dec…` 一致。本机 `192.168.31.171 → 192.168.10.23` ICMP 100% 丢包，LAN 路径本轮不通，改走公网。
- r1（虚拟屏静态，30s/18s）：握手 59.8ms，host captured 31 / encoded 30 / sent 16，client 15/15 解出上屏、0 丢帧，`c09=skipped-keep-main`，结束打印 `已恢复物理屏并销毁虚拟屏`。
- r2（虚拟屏全屏彩条动画，40s/25s）：host captured 343 / encoded 342 / sent 325（drop 0），动画期间 `[capture] complete=15 idle=0` 稳定；client 解码 321 / 上屏 320、0 丢帧，**解码/发送 = 321/325 = 98.8%**，控制最大间隔 **1062ms**，上屏 p50/p95 = 188.5/405.5ms，时钟 offset -53ms（8 样本）；结束销毁 1 块虚拟屏、物理屏恢复为 2 块。

**口径问题（已修）**：host JSON 的 `maxControlGapMs` 曾把 client 退出到 host 时长结束的空窗计入（r2 15.1s ≈ 40s−25s，r1 18.9s 同理），不能当门禁值。修复：`M1StreamSession` 在会话进入 CLOSED 时停止间隔记账并清 `lastControlArrivalMs`，host JSON 追加 `maxGapAtOffsetMs`（同时打印到 stdout）。本机 Sequoia 15.5 镜像环回复测（20s/12s，与 r2 同构）：host 控制最大间隔 **1044.6ms**、offset 3047ms（即最大间隔发生在 +3s 推流中段，+12s CLOSED 后 8s 尾部不再计入）；client 侧 201–1052ms。**操作坑**：把 host 挂到 Qoder 后台任务会被节流，QUIC 握手卡在 `preparing`（两端各只到 state 2）；host/client 放在同一个前台 shell 里先后启动即正常（握手 53.9ms），后续本机环回按此方式跑。

- r3（虚拟屏彩条动画，40s/25s，修复后首轮）：host captured 392 / encoded 391 / sent 359，`c09=skipped-keep-main`，守护就绪握手通过；client 解码 354 / 上屏 326、0 丢帧，**解码/发送 = 354/359 = 98.6%**，控制最大间隔 1274.5ms，上屏 p50/p95 = 364.5/1294.5ms，时钟 offset 47.8ms。**指标仍有残留**：host `maxControlGapMs=18146.9` 而 `maxGapAtOffsetMs=308.2`——STREAMING 前最后一包握手消息（建屏/守护阶段到达）被首包心跳当成一次 18s 间隔。该轮前半还有一次握手瞬断（`连接失败：60`，重试即过）和一次停在 DISPLAYS_READY 的失败尝试（SIGTERM 后守护兜底恢复、物理屏复原）。
- 残留修复（`4a37d1d`）：`M1StreamSession` 进入 STREAMING 时清 `lastControlArrivalMs`，首包心跳只播种不记账（与 CLOSED 停记同口径）。Tahoe host 已重建。
- r4（复测，同构 40s/25s）：host captured 403 / encoded 402 / sent 356，`maxControlGapMs=1300.9`、`maxGapAtOffsetMs=9331.7`（发生在推流中段，口径正常）；窗口布局快照 11 个（keep-main 不搬窗，restored=0）、守护就绪握手通过、结束销毁 1 块虚拟屏并恢复 2 块物理屏。client 解码 351 / 上屏 316、0 丢帧，**解码/发送 = 351/356 = 98.6%**，控制最大间隔 1025.1ms，上屏 p50/p95 = 767.5/1110.5ms，时钟 offset 2.3ms（8 样本）。⇒ **§2 keep-main WAN 门禁通过**（解码/发送 ≥0.85、0 丢帧、两端间隔 <3000ms）。

**仍未覆盖**：本机 Sequoia 的 keep-main/独占（需先清陈旧槽位）；LAN 路径；`--inject real`。（C-09 全独占档走产品入口已由 §5.37 覆盖。）

### 5.37 产品入口 WAN 对照：全独占（C-09）与 `--mirror` 诊断档（2026-11-23 22:4x–22:5x）

**档位口径**：产品 `--serve` 默认档为**全独占**（按客户端规格建虚拟屏并禁物理屏，C-09=verified）；`--keep-main` 见 §5.36；`--mirror` 是诊断档，仅采物理主屏、不建虚拟屏、不碰 C-09（not-started）。

**环境**：Tahoe 26.5.2 host × Sequoia 15.5 client（WAN `112.5.32.34:46600`，握手指纹 `3305dec…`），720p15，host 20s / client 18s，远端物理主屏跑 `anim_display 0` 彩条动画。host 均在 Tahoe GUI 经 Terminal 启动（沿用屏幕录制授权）。

**§3 全独占 + C-09（产品入口，原计划 `--mirror` 未加，实为默认独占档）**：
- host captured 284 / encoded 283 / sent 260；`[独占] 虚拟屏（1280x720）C-09=verified`，守护就绪握手通过；窗口布局快照 12 个，结束恢复 `planned=2 restored=1 failed=1`。
- client 255/255 解出上屏、0 丢帧，**解码/发送 = 255/260 = 98.1%**，两端控制最大间隔 1021/1014ms，上屏 p50/p95 = 102.5/225.5ms，时钟 offset 3.1ms（8 样本）。
- 结束「已恢复物理屏并销毁虚拟屏」；`system_profiler` 核对 2 块物理屏（3440×1440 + 1080×1920）在位。⇒ **§3 全独占 + C-09 走产品入口、双机 WAN PASS**。遗留：窗口布局恢复 1 个失败（planned=2），下轮取失败窗口与原因。

**§1 `--mirror` 诊断档三轮（各 20s/18s，c09 均 `not-started`）**：
- r1：host sent 262；client 257 解出、0 传输丢帧，**98.1%**，间隔 1032/1028ms，p50/p95 477.5/657.5ms，上屏 139（渲染积压丢 106）。
- r2：host sent 263；client 245 解出、4 丢帧，**93.2%**，间隔 1172/1005ms，p50/p95 601.5/1182.5ms，上屏 129（积压丢 104）。
- r3：host sent 264；client 244 解出、3 丢帧，**92.4%**，间隔 1041/1300ms，p50/p95 174.5/752.5ms，上屏 241（积压丢 3）。
- ⇒ **§1 镜像档 WAN 门禁通过**（解码/发送 ≥0.85、两端控制间隔 <3s、`c09=not-started`）。三轮传输丢帧 0–4（WAN 抖动；同期 keep-main/独占档为 0，mirror 档画面源为 3440×1440 物理主屏降采样，码流构成差异未取字节证据，暂记现象）。r1/r2 上屏积压 100+ 帧、r3 恢复正常：本机渲染压力显著波动，属 Qoder/WindowServer 竞争（§5.33 口径），交 P2.3 基线（D）定位；不影响网络侧门禁。

### 5.38 P2.3 本机 Sequoia 渲染基线复测（2026-11-23 23:0x–23:1x）

**环境**：本机 Sequoia 15.5（i5-9500 / UHD 630，主屏 3008×1692 HiDPI，capture `scale=2.00`）。Qoder 与 Screen Sharing 用 System Events 隐藏（`visible=false`）、Finder 保留，`mds/mds_stores/mdsync` 临时 SIGSTOP，离屏轮 `nice -20`；测毕全部恢复。

**离屏 `render_selftest` 8 轮（每档 n=8，min/p50/p95 ms）**：
- vga 2.2/2.3/2.4；720p 3.2/3.3/5.0；1080p 5.4/5.5/6.1；ultrawide 13.5/13.9/21.1。8 轮 `ALL PASS`。
- 与 §5.33 基线（720p 3.2、1080p 5.3、ultrawide 13.2）一致，离屏转换成本无回退。

**真实 client 镜像环回（产品入口，1920×1080@20，host 32s / client 30s，窗口化彩条动画）**：
- **SCK 本机限流确认**：`--mirror` 走 SCK 时主屏 HiDPI 采集仅交付 3–5 帧/秒（r1 全屏动画 delivered≈3/s；r2 窗口化 delivered≈4–5/s），与既有「SCK 2–18fps」结论一致；r1 中全屏动画把 client 窗口完全遮住，AppKit 遮挡态不绘制，出现 `解码=30 / 渲染=0`（非渲染成本问题；r2 把窗口移入可视区后恢复 125/127 上屏）。**隐藏/被遮挡窗口不渲染是预期行为，远程桌面场景不受影响**。
- **CG 后端干净轮（`M1_CAPTURE_BACKEND=cg`）**：采集稳定 20fps（`delivered=20/s`、lastInterval 51ms），host captured 628 / encoded 627 / sent 584；client **解码 579 / 上屏 579、0 丢帧、0 渲染积压丢**，上屏 p50/p95 = 81.5/144.5ms，控制最大间隔 1052/1027ms，时钟 offset 50µs，`c09=not-started`。
- ⇒ **P2.3 渲染下限复验一致**：1080p 离屏 ~5.5ms，真实 20fps 持续流下渲染 100% 无积压丢失。上一轮 WAN mirror 出现的 100+ 帧积压确认为本机负载波动（Qoder/WindowServer 竞争），Qoder 隐藏 + mds 暂停后不再出现。后续本机 20fps 采集基线优先用 `M1_CAPTURE_BACKEND=cg`，SCK 仅用于功能验证。

### 5.39 M2 多屏双机实测：keep-main 与全独占（C-09）双档（2026-11-24 20:5x–21:0x）

**环境**：Tahoe 26.5.2（25F84）host（112.5.32.34，WAN UDP 46600）× Sequoia 15.5（24F74）client；基线 `3e18538`（M2 多屏），两端同提交；host 由 Terminal 在 Aqua 会话启动，`caffeinate -d -u` 全程挂起。规格 1280×720 ×2 屏、15fps、`--inject record`，client 30–35s，host 45–55s，两块虚拟屏均由 `anim_display.sh` 喂动画。

**A. `--keep-main` 双屏（不黑物理屏）**
- host 建 2 块虚拟屏（4128835 / 4128834），2 条管线并行；`c09=skipped-keep-main`。
- 采集/编码/发出：4128835 346/345/119、4128834 32/31/23；`framesDroppedBeforeEncoder=0`。
- client：4128835 收齐 115 / 解 115 / 上屏 115，4128834 收齐 23 / 解 23 / 上屏 23；合计 **138/138，0 丢帧、0 渲染丢帧**；p50 50.5ms / p95 1031.5ms（4128834 首帧启动尖峰）；控制最大间隔 1045.9ms。
- 结束：`销毁 2 块虚拟屏`、物理屏恢复（active=2）、`[窗口布局] captured=5 planned=0 restored=0`（WindowServer 自动还原）。
- 注：第二个动画命令 cwd 写错未起窗，4128834 只推了静止屏的 idle 帧（~1/s）；不影响双屏路由判定。

**B. 全独占双屏（C-09）**
- host 建 2 块虚拟屏、禁物理屏，`c09=verified`；结束恢复物理屏（active=2），`[窗口布局] captured=7 planned=7 restored=7 failed=0`。
- 采集/编码/发出：4128835 686/685/497、4128834 676/675/492；`framesDroppedBeforeEncoder=0`（host 比 client 多跑 20s，故 encoded≫sent）。
- client：4128835 收齐 493 / 解 493 / 上屏 493，4128834 488/488/488；合计 **981/981，0 丢帧、0 渲染丢帧、0 遮挡跳过**；p50 129.5ms / p95 308.5ms；控制最大间隔 1159.6ms；时钟 offset −49.7ms（样本 8）。
- PNG 按屏命名 `frame-d<displayID>-NNN.png`，两屏各取 1 张确认是 Tahoe 桌面实时内容（非黑帧）。
- 输入：本轮 record 且未在窗口内操作，`inputSent=0`；按屏注入路由由 `inject-multi-*` 单测覆盖，真机输入待补。

**结论**：双机双屏在 keep-main 与全独占两档均 PASS（结构性指标）。仍按约定不与其它 OS 混记；`maxGapAtOffsetMs` 的 18–33s offset 是建屏前空窗，门禁以 client 侧间隔为准。**Tahoe 的多屏独占已覆盖（A-07 表中 Ventura 的「多屏独占未覆盖」仍保持）。**

**操作备注**：host 空闲后物理屏会 DPMS 睡眠，`CGDisplayIsActive=0` 导致 `prepareSessionShield` 报「当前没有任何 active display」；先 `caffeinate -d -u` 唤醒再跑。host 日志经文件重定向时是全缓冲，需用 `script -q /dev/null` 包一层才能实时看到 displayID。

### 5.40 双屏真输入注入 + P2.3 渲染基线复核（2026-11-24 21:0x）

**环境**：同 §5.39（Tahoe 26.5.2 host × Sequoia 15.5 client，WAN，2×1280×720@15）；代码 `3e18538`。host `--keep-main --inject real`；client 两窗口；本地用 CGEvent（AX 已授权）向两个 VeilRD 窗口各投 3 次 mouseMoved + down/up，再发 3 次键事件，共 15 条。

**真注入结果**：
- host `input ok=15 fail=0 record=0`；host 光标从 (10,10) 移到 (4133,395)，确认是真实 `CGEventPost` 而非仅计数。
- client `inputSent=15 / inputFailed=0`；两屏收齐/解码/上屏 636+637=**1273/1273，0 丢帧**；p50/p95 = **26.5 / 155.5ms**；host 发出 1287 → 解码 1273（98.9%）。
- `c09=skipped-keep-main`；2 块虚拟屏销毁、物理屏恢复（active=2）、窗口布局 1/1 恢复。
- ⇒ 按屏注入（`displayRects` + 窗口归属 displayID）在 Tahoe 真机成立；上次 §5.39 的 record 未覆盖项已补齐。

**P2.3 渲染基线复核（本机 Sequoia，Qoder 隐藏 + mds 暂停 + `nice -20`，离屏 8 轮，min/p50/p95 ms）**：
- vga 2.2/2.35/2.7；720p 3.2/3.35/3.7；1080p 5.1/5.45/6.2；ultrawide 10.2/13.3/17.0；8 轮 `ALL PASS`。
- 与 §5.38（vga 2.2/2.3/2.4、720p 3.2/3.3/5.0、1080p 5.4/5.5/6.1、ultrawide 13.5/13.9/21.1）一致，无回退。
- 对照：Qoder 可见时首轮 vga **35.0ms** 超出 25ms 护栏；隐藏后立即回到 2.x ms，再次确认该指标对前台负载敏感，基线取数时 Qoder 不可前台可见（取数条件的进一步收敛见 §5.41）。

### 5.41 P2.3 基线取数条件收敛：Qoder 仅最小化（2026-11-24 21:2x）

**缘起**：§5.38/§5.40 的基线要求「Qoder 隐藏 + mds 暂停」，日常不可执行（Qoder 无法关闭或长期隐藏，索引也不宜长期暂停）。按「仅最小化后结果可接受即视同无 Qoder 负载」重新取数。

**环境**：本机 Sequoia 15.5；Qoder 窗口最小化（`AXMinimized=true`，进程未挂起——测试时两个主进程采样 `%cpu` 17.1 / 7.8，仍在后台运行）；mds/mds_stores/mdsync 均未暂停；Finder 正常；离屏轮 `nice -20`；`render_selftest` 由 `M1-Skeleton/build_render_selftest.sh` 在新 HEAD 重新构建。

**离屏 `render_selftest` 8 轮（每档 n=8，min/p50/p95 ms）**：
- vga 2.30/2.50/2.77；720p 3.10/3.65/4.60；1080p 5.30/5.85/7.50；ultrawide 13.40/14.80/17.15；**8/8 `ALL PASS`**，各档余量充足（最紧的 ultrawide max 17.6 vs 护栏 100ms）。
- 与 §5.40 隔离口径（2.2/2.35/2.7、3.2/3.35/3.7、5.1/5.45/6.2、10.2/13.3/17.0）相比 p50 差 ≤0.5ms，结论不变。

**决定**：P2.3 基线取数条件定为「Qoder 最小化即可」，不再要求隐藏 Qoder 或暂停 mds；仅当 vga 出现 10ms 级异常时才回退到隐藏 + 暂停做对照。Qoder 前台可见时仍不可取数（§5.40 对照 35.0ms）。

### 5.42 M2 收口：FR-07 会话内换屏 + FR-06 完整输入真机（2026-11-24 21:3x–22:2x）

**环境**：Tahoe 26.5.2（25F84）host（Mac-mini.local，WAN，SSH 走 TCP 46601 → :22）× Sequoia 15.5（24F74）client；代码 `7d7041b` + 控制交付修复 `7f664b6`（host 同步后重建）；720p15、`--keep-main`，host 由 GUI 会话内 Terminal 启动，`caffeinate -d -u` 防屏睡。

**A. FR-07 会话内换屏（2 屏 → 1 屏，keep-main，WAN）**
- client `--spec 1280x720 ×2`、`--update-at 30000 --update-spec 1024x768`；host 初始 2 块虚拟屏（4128835 / 4128834）并行推流，`c09=skipped-keep-main`。
- 换屏：host 打印 `[换屏] 2 屏 → 1 屏（首屏 displayID=4128833）`，旧屏 4128835/4128834 标记 retired 并销毁，新屏 4128833（1024×768）建齐后才进入管线。
- client 收到 `session-update-result ok:true`，打印「换屏 #1 成功：1 屏」「窗口 1 → displayID=4128833（1024×768）」；旧窗口关闭、新窗口重绑后持续解码上屏，PNG 采样为新屏实时内容（非黑），0 传输丢帧。
- 控制链路存活：两端控制最大间隔 client 1.44s / host 1.19s（<3s 门禁），换屏后心跳与输入继续。
- **根因与修复（`7f664b6`）**：换屏事务在建屏/验屏上耗时 ~2.2s；原实现把控制消息在 QUIC 收包线程上同步交付，处理期间双方 ACK 停摆，250ms×8 = 2s 重传预算耗尽后 `M1ControlLink` 静默置 failed——帧流照常、控制链路已死（首轮实测：换屏后两端心跳同时消失、`session-update-result` 丢失）。现改为专用串行交付队列（`m1.stream.control-delivery`），收包线程只入队；修复后同场景 PASS。

**B. FR-06 文本注入（host `--inject real`，keep-main 1×1280x720）**
- 发端：client `--send-text 15000:HelloVeilRD --send-text 22000:中文输入测试`（与 IME `insertText:` 同一 `kind:"text"` 事件）；收端：host 置前 Terminal 以 raw 模式 `cat > /tmp/m2-typed.txt`。
- 首轮“失败”定位：收端 Terminal 处于行规程 canonical 模式，无换行不落盘（host 端 `inputOK=2` 注入已成功、文件却 0B）——收端问题，非协议或注入问题。
- raw 模式复跑：`/tmp/m2-typed.txt` = `HelloVeilRD中文输入测试`（29B UTF-8，与发端逐字节一致）；host JSON `inputOK=2 / inputFail=0`；client 收齐 39 / 解码 39 / 上屏 39、0 丢帧，p50/p95 = 30.5/1085.5ms，控制最大间隔 1058ms。
- 说明：IME 本地组字候选窗无法脚本化，仍由单测覆盖（`M1FrameView` 完整 `NSTextInputClient` + marked text 子层）；本轮真机验证的是「提交后整串文本 → HID 层 CGEvent 注入 → 目标应用落字」。

**C. 沉浸模式（待补测）**
- 实现与单测同批（`7d7041b`）：`Cmd+Opt+F` 切换 borderless 全屏 + 自动隐藏 Dock/菜单栏，退出恢复。
- 真机目测未完成：准备阶段 host WindowServer 进入「虚拟屏 `online=true / active=false`」脏态（连续建屏/销毁后遗留，agent 进程重启无效），已按用户确认重启 host，待补测。
- 顺带观察（待复核）：未进入 STREAMING 的失败会话里，沉浸窗口在 CGWindowList 中呈 0×0/不在屏上；已加「沉浸窗口 i: x,y WxH」落位打印，重启后一并确认是否仅为失败会话副作用。

**D. 备注**
- 同一 host agent 进程内「会话结束 → 新客户端重连」路径有旧管线/旧 displayID 帧残留迹象（复测中 client 绑新屏 4128834，却持续出现旧屏 4128835 的接收器与 0 帧会话）；正式档仍按「一客户端一 agent」执行，重连清理项记入待办。
- SSH 入口为 TCP 46601 → host :22（`PRODUCT-DUAL-RUNBOOK.md` §0.3）；本轮曾误探 22 端口导致一度判 host 失联。

### 5.43 M2-C 收口：沉浸模式 PASS + FR-07 复测 5/5 + 画面冻结/控制面静默两个根因修复（2026-11-25）

**环境**：Tahoe 26.5.2（25F84）host（Mac-mini.local，WAN，SSH TCP 46601 → :22）× Sequoia 15.5（24F74）client；基线 `62e9ddc` + 本轮工作区改动（`M1FrameView` 双缓冲、控制链路重传预算、控制面看门狗）；host agent 与 client 均重建，host 由 GUI 会话内 Terminal 启动，`caffeinate -d -u` 防屏睡。

**A. 沉浸模式真机目测（§5.42 C 项补测，PASS）**
- `Cmd+Opt+F` 切换：`NSApp.presentationOptions=[.autoHideDock,.autoHideMenuBar]`、窗口转 borderless 并铺满该屏；host 侧打印 `沉浸窗口 1: 0,0 3008×1692`，本机 Dock/菜单栏自动隐藏，退出恢复标题栏与原 frame。
- **顺带定位并修复画面冻结（长期存量 bug）**：`M1FrameView` 每帧把同一个 IOSurface 指针赋给 `layer.contents`，CA 按对象身份判定“没变化”不再提交，窗口停在首帧；而 `framesDecoded/framesRendered` 照常增长、遮挡跳过为 0，指标看起来完全健康。修复：双缓冲（两块 BGRA IOSurface 交替出图，尺寸变化时整组重建），仅在 `renderQueue` 上操作。
- 修复后验证（WAN，720p15，窗口 + 沉浸两种形态）：相隔 5s 的两张截图像素不同（修复前逐字节相同）；沉浸态全屏画面实时、Dock/菜单隐藏；675/675 解码并上屏、渲染丢帧 0、传输丢帧 9、控制最大间隔 1.0s、上屏 p50/p95 = 176.5/380.5ms；单测 `M1-Skeleton/build_tests.sh` 341/341。

**B. FR-07 会话内换屏复测（keep-main 2 屏 → 1 屏，WAN，5/5 PASS）**
- 统一脚本：host `--keep-main --fps 15 --duration-ms 60000`，client `--spec 1280x720 ×2 --update-at <12s|25s> --update-spec 1024x768`；主机按 60s 推流、客户端 30–45s。
- 五轮（`m2c-fr07-1125d/e/f/g/h`）结果一致：host `[换屏] 1 屏 → 1024x768（首屏 displayID=4128833）`、旧屏 4128834/4128835 retired 并销毁；client 打印 `窗口 1 → displayID=4128833（1024×768）`、`换屏 #1 成功：1 屏`，新屏持续解码上屏（51/60/25/55/41 帧），旧屏上屏 0（窗口已重绑，属预期）；两端控制最大间隔 ≤1.12s；d/e/g/h 轮传输丢帧 0，f 轮新屏重组丢 4。
- 结论：§5.42 的 FR-07 PASS 可重复；换屏事务本身（建新屏→起管线→成功才拆旧屏）无回归。

**C. 首轮复测失败的根因：控制链路重传耗尽 → 控制面永久静默（已修复）**
- 现象（首轮 20:58，与 §5.42 同配置）：client 打印 `换屏请求 #1` 后不再收到任何控制消息（此后再无 `[client] STREAMING` 心跳行），但画面继续解码；host 侧换屏成功且继续收到 client 心跳。`session-update-result` 永远没到 client。
- 根因：控制链路是“序号 + 累计确认 + 250ms×8 重传”的自建可靠层，跑在不可靠 datagram 上。WAN 上与画面抢带宽时 RTT 尖峰和乱序常态（本轮实测单次 30s 会话 retransmits 111/46 条、乱序暂存 81、重复 25–46）。一旦丢的是换屏结果，后续消息全部卡在乱序暂存等那一条；8 次重传（2s）耗尽后链路静默置 failed、拒绝后续发送，而**没有任何一方检测控制面是否还活着**——帧流照常，于是表现为“假在线”。
- 修复（两处）：
  1. `M1ControlLink` 默认重传预算 8 → 20（250ms×20 ≈ 5s；`M1_CTRL_MAX_ATTEMPTS`/`M1_CTRL_RETRY_MS` 诊断覆盖保留）。
  2. `M1StreamNode` 控制面看门狗：STREAMING 中连续 8s 无任何控制消息即打印 `控制面静默 Xs，判定控制链路失效`、记录 error、关闭会话并放行等待中的信号量（两端同规则）；链路/会话失败改为 stderr 显式打印，不再静默。
  3. 诊断面：client/host JSON 增 `control` 对象（datagram 分流、链路 sent/delivered/retransmits/duplicates/held/acks/pending/failed、通道收发/解析错误），摘要同步打印到 stdout；这是本轮能把“没到/被扣住/解析错”分开定位的关键。
- 修复后同配置连跑（f/g/h 及 d/e 复跑）全 PASS，未再出现控制面静默。

**D. 备注**
- 一客户端一 agent 的口径不变；「会话结束 → 新客户端重连」的旧管线/旧 displayID 清理仍记为待办（P2.3 → M3）。
- 每轮结束确认：虚拟屏已销毁、物理屏 2 块在位、无遗留 agent 进程。

### 5.44 M2 重连清理：多会话常驻真机 PASS + Tahoe「销毁后重建虚拟屏必挂」根因与复用方案（2026-11-25）

**环境**：Tahoe 26.5.2（25F84）host（Mac-mini.local，WAN，SSH TCP 46601 → :22）× Sequoia 15.5（24F74）client；基线 `62e9ddc` + 本轮改动（收尾移出控制交付队列、显示事务串行队列、会话间复用虚拟屏）；两端重建，host 由 GUI 会话内 Terminal 启动。

**A. 两个根因（均已修复）**
1. **控制面被显示收尾饿死**：会话结束的还屏/恢复（秒级，实测 16s+）原本跑在控制交付队列上，下一轮客户端的 attach/hello 排在它后面；客户端先报 `seq=1 重传 20 次仍未确认`，再报 `57`。修复分三层：
   - 节点 `M1StreamNode`：会话关闭时**同步**摘掉本轮控制对象（link/session/channel/conn）再异步去 nil 委托/取消连接/通知入口；新连接 `attachSessionTo:` 就地执行不再排队；新增 `endCurrentSession`（正常挥手 0.2s 后拆连接），`prepareForNextSession` 只复位标量。
   - 入口：新增 `veild.display-tx` 串行队列，建屏/禁屏/恢复/会话收尾全部在其上串行；`onSessionClosed` 先放行主线程判定，再把收尾入队。
   - 时长到：`endCurrentSession` + 同队列收尾；进程退出时统一 `endExclusive`（还屏 + 窗口布局恢复）。
2. **Tahoe 上「销毁虚拟屏后再建」必失败**：同一 agent 进程里把虚拟屏销毁后再 `initWithDescriptor:`，新建的屏**永远 `online=0`**（bounds 1×1、mode 1×1，10s mode-wait 超时，报 `建屏失败或超时`）；两次尝试复现，identity offset 0→1 无效。对照：首次建屏必成功、FR-07 换屏（create-then-destroy，进程内始终有存活虚拟屏）必成功 ⇒ 进程内虚拟屏注册不能从「有」回到「零」再重建。方案：**会话之间不还屏**，下一轮 session-start 复用：
   - 规格相同 → 直接沿用现有 displayID；
   - 规格不同 → `coordinator applySpecs:`（先建新屏、成功才拆旧屏）。
   - 物理屏在整个常驻期保持禁用，进程退出才恢复（行为变化，M3 无人值守档按此口径）。

**B. 真机验证（`--max-sessions 2`，1920×1080 → 1280×720）**
- 会话 1（`1920x1080`，client 8s）：`[建屏] 用时：建屏 8.35s，禁屏/校验 11.54s`；`[会话 1] STREAMING`，收齐/解码/上屏 17/17/0 丢；客户端离开后 `[会话 1] 结束（客户端离开），收尾`，显示保留。
- 会话 2（`1280x720`，client 20s）：`[独占] 换屏 (4128834)（首屏 1280x720）`，`[会话 2] STREAMING`，收齐/解码/上屏 23/23/0 丢；host `--duration-ms 12000` 到点 `[会话 2] 结束（时长到），收尾`。
- 汇总 `host.json`：`sessions=2`、`framesCaptured=42 / encoded=40 / sent=40 / dropped=0`、`fragmentsSent=633`；控制面 `delivered=27 acks=26 chanErrors=0 dgramUnrouted=0 pending=0 retransmits=2`；退出 `EXIT=0`，`[独占] 已恢复物理屏并销毁虚拟屏`，两块物理屏 active、无遗留 agent/guardian 进程。
- 单测 `M1-Skeleton/build_tests.sh` 341/341。

**C. 备注 / 遗留**
- 首轮建屏 20s（禁屏/校验 ~11.5s）仍是重连首帧的主要成本；复用后重连换屏不再走禁屏事务，client 侧握手 110ms 即进入 STREAMING。
- host 侧物理屏在会话间保持禁用属有意行为；若 M3 要求「无人值守但人在场时恢复」，需单独设计空闲恢复策略。
- 会话间复用显示后，「旧 displayID 残留」不再存在（同一块屏继续用），但**旧管线必须每轮退休**（本轮 `cleanupSession` 保留此项）。

### 5.45 M3 开工：FR-08 断网重连真机（部分）+ 对称断路缺陷修复 + Tahoe 显示脏态事故与 host 失联（2026-11-25 21:4x–22:4x）

**环境**：Tahoe 26.5.2（25F84）host（Mac-mini.local，WAN 112.5.32.34:46600，SSH 46601）× Sequoia 15.5（24F74）client（WAN）；基线 `7b63413` + FR-08 客户端重连改动（`ac196c5`）。host 由 GUI 会话内 Terminal 启动（`--max-sessions 0`，会话时长 `--duration-ms` 由客户端决定），客户端 `VeilRD --reconnect --reconnect-window-ms 60000`，两端 720p15~20。

**A. 断网注入方法（本地 macOS 客户端侧）**
- ❌ `ifconfig en1 down`：configd 数秒内自动拉起，会话不断，不可用。
- ❌ `route add -host 112.5.32.34 -blackhole`：报 `Invalid argument`；改走网关 `.254` 黑洞也被网关正常转发。
- ❌ 单向 `pf` block（仅 client→host）：ping 已 100% 丢，但 QUIC 会话仍存活（`client.log`：287/287 帧、`reconnects=0`）——已建立的 UDP 流有 pf state 条目（`pfctl -s states`），规则不命中，且 host→client 方向仍通。
- ✅ **双向 pf block + 清 state**：`/tmp/fr08-pf.conf` =
  `block drop quick inet from any to 112.5.32.34` + `block drop quick inet from 112.5.32.34 to any` + `pass`；
  `pfctl -e; pfctl -f conf; pfctl -F states` 后 ping 100% 丢（`ping-probe.log` 3/6 → `ping3.log` 0/6），会话在 8s 级判死。恢复 = `pfctl -f /etc/pf.conf; pfctl -F states; pfctl -d`。
- 日志实时性：客户端 stdout 重定向到文件是块缓冲，必须 `script -q /dev/null <cmd> >> log`；`script` 的 stdout 再接管道会报 `tcgetattr: Operation not supported on socket`，时序标记直接追加进日志文件。
- 复现脚本已归档：`Scripts/tests/fr08-reconnect/`（预先 `sudo -v`，无明文口令；支持双向/单向断路器）。

**B. FR-08 单向/近对称断路验证（PASS，3 轮）**

| 轮 | 断法 | 判死/重连时序 | 结果（client JSON） |
|---|---|---|---|
| r1 `test.sh`（21:54） | 12s（3+6+3s）双向 block + 清 state | `控制面静默 8.8s` → 第 1 次重连握手 8000ms 超时（网络仍断）→ 第 2 次成功 | 195/195 解码上屏、**0 丢帧**、`reconnects=1`、断后沿用 `displayID=4128835`、控制最大间隔 1034ms、p50/p95 32.5/767.5ms |
| r2 `test10.sh`（21:56） | 10s 双向 block + 清 state | 判死 → 重连成功 | 118/118、0 丢帧、`reconnects=1`、间隔 1318ms、p50/p95 29.5/688.5ms |
| r3 `diag.sh`（21:47） | 10s 单向 block（未清 state，仍靠判死兜底） | 判死 → 重连成功 | 103/103、0 丢帧、`reconnects=1`、间隔 1042ms、p50/p95 19.5/463.5ms |

- 退避实测：`0.5s → 1s → 2s…` 封顶 5s，窗口 60s；首轮重连握手超时（8s）不掀窗口，下一轮继续。
- 关键点：重连后**沿用同一虚拟屏 4128835**（§5.44 的会话间复用策略），不再有 20s 首轮建屏成本。

**C. 对称断路暴露的产品缺陷（已修，`75e976c`，待复测）**
- 现象（`final.sh`，22:00，12s **双向** block + 清 state）：客户端 `控制面静默 8.0s，判定控制链路失效` → `控制链路失败: seq=18 重传 20 次仍未确认`，随后 **`断线重连 0 次`**，会话停在僵尸 STREAMING；JSON：63/63、丢帧 20、间隔 154.7ms、`reconnects=0`。host 侧仍显示流在跑。
- 根因：单向断路时 host→client 仍有帧到达，`M1StreamNode` 的 `controlLink:didFailWithError:` 只记错误、不关会话；对称断路后收包线程死亡，状态机永远停在 Streaming，客户端不会触发重连。
- 修复：`M1ControlSession abortWithReason:`（尽力发 bye → 本地转 Closed → 走同一条 `didChangeState: Closed` 收尾通知）；`controlLink:didFailWithError:` 与 8s 看门狗均改走 `abortWithReason:`（`control-link-failed` / `control-timeout`）。单测 343/343 PASS。
- **复测被 host 失联阻塞**（见 D），恢复后按同一脚本预期：判死 ≤8s → 重连 → host 复用 VD、`reconnects=1`。

**D. Tahoe 显示脏态事故与 host 失联（21:5x–22:4x）**
1. 收尾阶段用 `SIGTERM` 杀掉 host agent（无信号处理 → 不走 `endExclusive`、guardian 没收到 `.done`）。
2. guardian 兜底恢复失败：`enable 817925634 -> CGError 1001`（Tahoe 上该状态不可恢复）；两块物理屏 displayID 变为无效（`-1`），只剩合成内建屏 1104977159（1280×720）为主屏。
3. 尝试 disable 该合成屏后主机完全无头，再 enable 仍 1001 → 唯一解为重启；重启前补配无人值守前提：FileVault 已 Off，写 `/etc/kcpassword`（root:wheel 0600）+ `defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser bemin`（读回确认）。
4. 22:08 `sudo shutdown -r now`；至 22:38 **SSH 46601 仍拒连**。WAN ping「通」是路由器代答（不可信）；同网段 192.168.31.0/24 ARP+端口全扫（含 .92/.106/.219 等 8 个活跃邻居）无 22/5900/46601 ⇒ host 未完成启动/掉电或卡在更新，**需物理检查**。
- 教训（已入代码）：kill 路径必须有序收尾（见 E1）；guardian 恢复失败仍是无头风险，M3 需补「恢复失败 → 不 disable 物理屏」的预检。

**E. M3 代码侧同步落地（`3c06c1c`，已推送）**
1. host agent 捕获 SIGTERM/SIGINT（dispatch_source）→ `[host shutdown]` → 停管线 → 还物理屏 → 销毁 VD → 摘 guardian → `exit(0)`（真机待验）。
2. NFR-06：显示事务死线 20s→**8s**（`M1DisplayTxTimeoutSec`，`P0VPerformTransaction` 默认值同步），超时只置 `WindowServerHung` 不重试。
3. NFR-07：host `--allow-fingerprint HEX` 按 hello 指纹钉死客户端；客户端以 `.state/rdp-identity.p12` 持久身份接入并上报指纹；新增单测 `ctl-host-pins-client-fingerprint`（343 PASS）。未给钉死值时 host 启动横幅显式告警。
4. FR-09 资产：`Scripts/host-deploy/`（LaunchAgent 经 Terminal 继承 TCC、10s 崩溃自重启、pmset/锁屏关闭）；`Scripts/soak/`（72h 驱动/采样/汇总）；`docs/SECURITY-CHECKLIST.md`（A–F 28 项渗透自查）。

**F. 遗留**
- FR-08 对称断路 12s 复测（新二进制）待 host 恢复。
- guardian 失败兜底与「恢复失败不 disable」预检、FR-09 真机装载、8s 熔断故障注入、72h soak 全部待 host。

### 5.46 新增两台 Intel 测试机：Sonoma 14 首次基线 + Ventura 13 当前 HEAD 补测 + 13↔14 同 LAN（2026-11-26 17:2x–18:1x）

**环境**：本地与两端仓库统一 `3dcba66`（原 Ventura 机停在 `e7bb64a`，已快进）。
- **Sonoma（新增）**：iMac20,1 / i5-7500 / 4C / 8GB / 1920×1080 / en0 `192.168.34.212`，macOS **14.5 (23F79)**，仅 CLT 16.0.0 / Swift 6.0.3；`git clone --depth 1` 到 `~/macOS-RDP`，项目 SSH 公钥已加入 `authorized_keys`。`Scripts/test.sh` 的 M1/P1 单测、`M1-Skeleton/build_stream_probe.sh`、`RDPApp/build.sh` 与 `rdpapp --selftest` 均通过；`Scripts/test.sh` 末尾的跨模块集成目标因无完整 Xcode（`xcodebuild` 不可用）不参与 CLT-only 门禁。
  - **CLT 16 构建坑**：`/Library/Developer/CommandLineTools/usr/include/swift/` 下 `module.modulemap` 与 `bridging.modulemap` 同时定义 `SwiftBridging`，Swift 桥接头编译报 `redefinition of module 'SwiftBridging'`。本机把重复的 `bridging.modulemap` 改名为 `.disabled` 后 `rdpapp` 正常构建（仅改测试机工具链，未改源码）。
- **Ventura（已有）**：iMac17,1 / `192.168.34.213`，13.6.7 (22G720)，CLT 14.3.1；快进到 `3dcba66` 后重建 `stream_probe`/`rdpapp`，单测与 `rdpapp --selftest` PASS。两机 SSH 均加窄化 sudoers（仅允许 `launchctl asuser 501`），以便从 GUI Aqua 会话启动采集/上屏。
- 两端初始均锁屏且屏睡；用 `p0vprobe type` 定向注入解锁（口令不落日志）。LAN 路径 `.212 ↔ .213` 直连；TCP 22 通、同网段 ping 通。

**A. Sonoma 14 只读侦察（P0-R 部分，A-07 未关闭）**
- `v01probe probe`（GUI 会话）：`osVersion=14.5.0 / iMac20,1`，`SLSConfigureDisplayEnabled` 可解析，`activeIDs=[]`（当时屏睡），`onlineIDs=[818512064]`，SLS 残留虚拟槽位 `4128829–4128835`，`SCShareableContent` 被 TCC 拒绝。
- 解锁后 `stream_probe --preflight client` `ok=1`（`locked=0 asleep=0 active=1`），证明 14 上 client 角色前置条件成立；`--preflight host` 仍 `ok=0`：唯一失败项「缺屏幕录制授权」。在 GUI Terminal 里调用 `CGRequestScreenCaptureAccess()` 未获授权，`capture=0` 保持。⇒ **Sonoma host 采集/C-09 真机未测，需用户在 GUI 里对相关二进制/Terminal 点一次「屏幕录制」授权**；本次不把 14 host 结论外推。

**B. 13 host → 14 client，同 LAN，四轮（均 `3dcba66`，720p15 请求，`--inject record`）**

| 轮 | 档 | host 采集/编码/发出 | client 收齐/解出/上屏 | 判定 |
|---|---|---|---|---|
| r1 | 镜像（`P2_MIRROR=1`） | 415 / 406 / 406 | 405 / 405 / 405 | **PASS** |
| r2 | 独占 keep-main | 413 / 404 / 404 | 404 / 404 / 404 | **PASS**（`c09=skipped-keep-main`，解码 1280×720 规格一致） |
| r3 | 镜像 + 产品客户端 `rdpapp --connect` | 360 帧发出 | 360 / 360 / **0** | 部分：解码与 PNG 成立，上屏计数 0 |
| r5 | 镜像 + `--input-synth` | 318 / 317 / 317 | 317 / 317 / 317 | **PASS**（输入 7/7 上行） |

- r1：客户端 14.9fps、丢帧 0、补片 22/22、控制最大间隔 1038ms、`sendErr=0`；镜像档请求 1280×720 而解码 1920×1080 属预期（`summary` 不判规格）。落盘 PNG 为 Ventura 物理桌面 + 彩色动画柱，非黑帧。
- r2：虚拟屏 `displayID=4128832`，动画贴窗成功；客户端规格断言 PASS、p50/p95 渲染 3.5/3.5ms、0 积压、控制间隔 1003ms；结束后物理屏 1920×1080 在位。**新增回归**：收尾日志出现 `[17:48:31] 显示配置事务 8s 未返回：WindowServer 疑似挂起`（M3 把死线 20s→8s），host JSON `sessionRecovered=false`；但 guardian 日志 17:48:33 记「父进程已正常恢复并写 done」，物理屏实际正常，`p2.sh summary` 仍判 PASS。⇒ Ventura 13 的正常收尾可超过 8s，当前 `sessionRecovered` 口径会把「恢复实际成功」误报为失败，需开发轮次修正或按 OS 放宽死线；本轮不改代码。
- r3：Sonoma 上用 CLT 编译的 `rdpapp --connect` 能握手、收齐 360 帧、解出 360 帧、落盘 3 张非黑 PNG，但 `framesRendered=0` / `上屏=0`（`framesSkippedOccluded=0`）。疑为后台应用窗口未绘制（§5.38 同类现象），**不把产品客户端在 14 上的上屏判为 PASS**；需要 GUI 前台/可见性复核。
- r5：客户端合成 6 组鼠标坐标 → 上行 7 条（`--input-synth` 额外产生 1 条），host `注入计划 7 条`、注入成功 7、记录模式无真实光标位移（预期）。Sonoma 客户端输入回传路径成立。
- 三轮 `p2.sh summary` 均为结构性 PASS；capture→render 样本显示主机时钟差约 **+2.1s**（两机系统时钟未同步），p50 数值不可作延迟基线，时钟校准另记待办。

**C. 13 host 全独占 720p 在当前 HEAD 失败（r4，OS 边界，不重试）**
- 客户端状态到 `DISPLAYS_READY` 后 `15s 内未进入 STREAMING`（rc=4）；host 日志停在虚拟屏 `4128832` 的 `stage=create`，未打印 `虚拟屏就绪`；动画夹具未启动。
- guardian 17:52:01 判定父进程未正常收尾并兜底恢复，17:52:02 记录「恢复失败」；控制台切到 `loginwindow`（`uid=88 / loginDone=FALSE`），物理屏不可用。与 §5.31 同机型显示栈边界一致，但本轮触发点是 `3dcba66` 的 8s 显示事务死线与建屏慢路径叠加，**不重复捶打 WindowServer**。
- 恢复：该机 FileVault 已 Off、`autoLoginUser=bemin` 但缺 `/etc/kcpassword`；补齐 root:wheel 0600 的 kcpassword 后重启，18:02 自动登录回 bemin 控制台，`stream_probe --preflight host` 恢复 `ax=1 capture=1 locked=0 asleep=0 active=1`、`screencapture` 成功，SLS 仍留 4 个陈旧虚拟槽位（不影响当前 active/online 集）。未留明文口令于日志或产物。

**D. 结论与口径**
- A-07 在 **13** 上按当前 HEAD 补齐：client 收流/上屏/输入回传、host 镜像与 keep-main 虚拟屏双机全链路 PASS；全独占 720p 在该机型当前 HEAD 仍为 OS 边界（与 §5.30 旧 commit 的正向结论分开记录，不撤销历史结论）。
- **14 Sonoma** 只关闭了构建/单测/client 前置/client 收流上屏与输入；host 侧采集、虚拟屏、C-09 未测，A-07 不因本轮关闭。
- 本轮所有结论仅限同 LAN `192.168.34.0/24`，不写 WAN；13→14 一个方向，反向（14 host → 13 client）待 Sonoma 屏幕录制授权。

### 5.47 Sonoma 授权后反向链路：14 host → 13 client（2026-11-27 08:2x，同 LAN）

**前置核对**：本机即 Tahoe host（Macmini8,1 / 26.5.2 / en0 `192.168.10.23`，`console=bemin`，`ax=1 capture=1 active=2`），与两台远程测试机分开记录。Sonoma 用户在 GUI 授予屏幕录制后，`stream_probe --preflight host` 在 GUI Terminal 内 `capture=1 / ok=1`（SSH/launchctl 上下文仍 `capture=0`，属 TCC 按进程继承的预期）；`v01probe probe` 仍只有物理屏 `activeIDs=[818512064]`。两端仓库 `3dcba66`。

| 轮 | 档 | host 采集/编码/发出 | client 收齐/解出/上屏 | 判定 |
|---|---|---|---|---|
| r6 | 镜像 1080p15 | 414 / 413 / 413 | 413 / 413 / 412 | **PASS** |
| r7 | 独占 keep-main 720p15 | 411 / 410 / 410 | 408 / 408 / 408 | **PASS**（规格一致 1280×720） |
| r8 | 全独占 720p15 | 建屏后禁屏事务 8s 熔断 | 停在 `DISPLAYS_READY`，15s rc=4 | **FAIL**（开发项，不重试） |

- r6：镜像档请求 1280×720、实际 1920×1080 属预期；0 丢帧，PNG 是 Sonoma 真实桌面 + 彩条动画窗；`p2.sh summary` PASS。Sonoma 作为 host 的屏幕采集路径成立。
- r7：虚拟屏 `4128835`，1280×720 规格一致、0 丢帧、guardian 正常写 done；客户端 PNG 为真实桌面。动画夹窗口虽贴屏，落盘帧未见彩条（不计入结构判定）。
- **8s 死线误报扩大**：r7 的正常收尾日志出现 `显示配置事务 8s 未返回`，host JSON `sessionRecovered=false`，但 guardian 写 done、物理屏恢复；`p2.sh summary` 对 keep-main 不检查该字段故仍 PASS。结合 §5.46 Ventura r2，该缺陷在 **13 与 14 两版均复现**，不是单机偶发；需开发轮次修正（见待办）。
- r8：`stage=mode-commit ok=true` 之后禁屏提交超过 8s 触发熔断，客户端等不到 STREAMING；无 WindowServer 崩溃、控制台仍 `bemin`，守护进程恢复后物理屏 `activeIDs=[1104977159]` 在位。与 §5.46 的 13 全独占失败同因，**不再对两台测试机重复捶打显示栈**。为兜底，已给 Sonoma 配 `autoLoginUser=bemin` + root:wheel 0600 的 `/etc/kcpassword`（与 13 同口径，口令未入文档/日志）。
- 口径：A-07 在 **14** 上补齐 host 镜像与 keep-main 全链路；全独占在 13/14 当前 HEAD 均由 M3 8s 死线阻断，不能判为关闭。反向链路与 §5.46 的正向链路合并后，13↔14 同 LAN 双向（镜像 + keep-main）均已实测；延迟数字受两机时钟差影响，不作基线。

**E. Sonoma 产品客户端「上屏 0」复核（r9/r10）**
- 13 host 镜像 + 14 `rdpapp --connect`，两轮均收齐/解出 657 帧、0 丢帧、PNG 非黑；JSON `framesRendered=0 / presentP50=0`。在客户端会话中从 Sonoma GUI Terminal 截取整屏，VeilRD 窗口内**确实显示远端 Ventura 桌面与彩色动画柱**（截图 `/tmp/veild-r10-sonoma-desktop.png`），故「上屏 0」不是黑屏/未渲染。
- 根因在**统计口径**：窗口按 host 屏表绑定到 `displayID=1000`，实际帧流/接收器用 `displayID=1535231424`；汇总时 `slots.first { $0.displayID == displayID }` 查不到对应 slot，于是 `framesRendered/presentP50` 读 0。`DisplayRouter` 的单视图兜底仍让画面正常上屏。
- 该问题只影响产品客户端 JSON 指标，不影响画面；修复建议：单屏时按唯一 slot 兜底统计，或在 `bindSlots` 同时绑定 `receiverDisplayIDs`。本轮不改产品代码。

**F. 本机 Tahoe（26.5.2）环境与安全项**
- 本机即 Tahoe host（Macmini8,1 / en0 `192.168.10.23` / `console=bemin` / `ax=1 capture=1 active=2`），`3dcba66` 全量重建（host-agent、VeilRD、stream_probe、P0V）与单测 `ALL PASS` / 两个 selftest PASS。
- 尝试从 13 client 跨网段连本机 `192.168.10.23:46610`（host-agent `--mirror` + `--allow-fingerprint`）：ICMP 1.8–2.6ms 正常，但 host 未收到任何 UDP 包（日志无 `已接受连接`），客户端 8s 握手超时。**跨网段 UDP 路径在本轮不可用**，不能据此判 NFR-07；指纹钉死的接受/拒绝两侧仍待在可达链路上补测。未在本机跑全独占（会禁物理屏并可能中断当前会话），留待有人在场的窗口。

### 5.48 8s 死线误判修复后：13/14 全独占 720p 双向 PASS + FR-08 对称断路复测 + FR-09 无人值守装载（2026-11-27 10:5x–11:2x，同 LAN）

**背景**：§5.46/§5.47 把 13/14 的全独占 720p 全部阻断在 M3 的 8s 显示事务死线（真机正常提交 8.3–10.0s，被当成 WindowServer 挂起后既熔断本事务、又用 `gWindowServerHung` 拒绝后续 restore）。本轮先修再测，改动 `f216f90`（只改显示控制层与客户端统计，不动协议）。

**A. 修复口径（`P0VPerformTransactionV`）**
- 两级死线：8s 软死线到点**只报慢提交**，随后在 `P0V_TX_GRACE_SEC`（默认 12s）内每 250ms 用公开 CG 状态收敛判定（禁用屏不再 active / 启用屏 active）；状态也没收敛才置 `WindowServerHung` 并按 NFR-06 语义熔断、不重试。
- 事务开始前目标态已成立时**不使用**状态收敛判据，避免把真挂起判成成功；收敛但提交线程未回时按成功返回并标注 `commitConfirmed=false`，明确禁止重复提交。
- 驱动层兜底：禁屏/恢复后以实际 active 集合复核，状态已恢复则解除误判的挂起标志（`sessionRecovered` 不再由事务返回值单点决定）。

**B. 14 host（Sonoma 14.5）全独占 720p15 → 13 client**

| 观察点 | 结果 |
|---|---|
| 禁屏事务 | 8s 软死线 → **8.3s 迟到生效**，按状态判成功（修复前此处直接熔断） |
| 虚拟屏 / C-09 | `4128835`，`c09Status=verified`，禁屏后 `activeDisplayIDsAfterDisable=[4128835]`（物理屏全禁） |
| host 采集 | captured=409 / encoded=408 / sent=408，dropPreEnc=0 encFail=0 sendFail=0 |
| client | 解码 408 / 上屏 408 / 丢帧 0，12.3fps，1280×720 规格断言 PASS，首帧 855ms |
| 收尾 | 恢复事务同样 8.3s 迟到生效；`sessionRecovered=true`、`sessionEnded=true`，teardown 后 `activeIDs=[818512064]`（物理屏回来），guardian「父进程已正常恢复并写 done」 |
| 判定 | `p2.sh summary` **PASS**；落盘 PNG 为真实桌面（菜单栏/程序坞/Terminal 窗口） |

**C. 13 host（Ventura 13.6.7）全独占 720p15 → 14 client**

| 观察点 | 结果 |
|---|---|
| 禁屏事务 | 8.3s 迟到生效 → 判成功；虚拟屏 `4128832`，`c09Status=verified` |
| host 采集 | captured=294 / sent=285 |
| client | 解码 285 / 上屏 285 / 丢帧 0，8.7fps（13 采集后端上限，低于 15fps 目标），1280×720 规格断言 PASS |
| 收尾 | 恢复事务 8.3s 与 10.0s 两级均迟到生效；`sessionRecovered=true`，物理屏 `1535231424` 回到 active；`~/Library/Logs/DiagnosticReports` **无 WindowServer 崩溃报告** |
| 判定 | `summary` **PASS** |

> 两机各只有一块物理屏，全独占期间 `active` 集合只剩虚拟屏，C-09 判据（active ⊆ 本会话虚拟屏且非空）成立。

**D. FR-08 对称断路复测（13 client × 14 常驻 host，只断 UDP 46600）**
- 网络手法：客户端 pf 规则按「协议 + 端口」收窄（`block drop quick on en0 proto udp ... port 46600`），**TCP 22 不受影响**，断路 12s 期间两端仍可 SSH 观测——这是相对既有 `Scripts/tests/fr08-reconnect`（整 IP 阻断、必然切断 SSH）的改进。
- 时间线：11:17:28 断路 → `控制链路失败: seq=17 重传 20 次仍未确认` → `CLOSED` → 自动重连第 1 次（0.5s 后，仍在断路内，握手失败）→ 11:17:40 恢复网络 → 第 2 次握手 **15ms** → `✓ 重连成功（第 1 次），恢复推流`。
- 结果：`reconnects=1`，解码/上屏 80/80、丢帧 0；**没有再出现 §5.45 的僵尸 STREAMING（`断线重连 0 次`）**。

**E. FR-08 的负向发现（host 形态决定能否验收）**
- 用 `p2.sh host`（单次会话、会话结束即退出）时，重连 7 次全部握手失败，最终「重连窗口 60s 内未恢复」。
- 用独占 host 时，链路断开后 host 需 10–12s 完成还屏 + 销毁虚拟屏，期间新会话在 `DISPLAYS_READY` 后立即 `CLOSED`。
- ⇒ FR-08 验收必须用常驻 host（`veild-host-agent --serve --max-sessions ≥2`，或 `--wait-ms > 0` 的多会话 host）；单次 host / 独占 teardown 窗口内的失败不构成客户端重连缺陷。

**F. FR-09 无人值守装载（14）**
- 二进制：本机（Tahoe，Xcode）构建的 `veild-host-agent`（`minos 13.0`）拷到 14 的 `.state/bin/`，`selftest PASS`；CLT-only 机器本机跑不了 `xcodebuild` 是已知限制。
- 装载：`~/Library/LaunchAgents/com.veild.host.plist`（`RunAtLoad` + `LimitLoadToSessionType=Aqua`）经 `open -a Terminal run-host.command` 拉起，继承 Terminal 的屏幕录制授权；agent 参数 `--serve --port 46600 --max-sessions 3 --mirror --fps 30 --inject record`。
- 装载即监听 46600，指纹 `b09c8b0e…`；重启后 `console=bemin` 且 agent 自动拉起（pid 761/762），13 侧客户端接入 `DISCOVERED → … → STREAMING`，33 帧上屏、判定 **PASS** ⇒ 无人值守链路成立（重启后无须人工开 Terminal 或登录）。
- 备注：重启后两机时钟差约 1.9s，该轮 `capture→render` 数值不作延迟基线。
- 收尾：验证完成后已在 14 上 `launchctl bootout gui/501/com.veild.host` 并删除 `~/Library/LaunchAgents/com.veild.host.plist`，避免测试机长期开放一个未钉指纹的接入端口（日志与二进制保留，`run-host.command` 留在 `~/host-deploy-test/` 便于复现）。

**G. 上屏计数口径修复验证（对应 §5.47 E 的 #9）**
- 客户端汇总改为「按 displayID 精确查不到时，单屏按唯一 slot 兜底」，与 `DisplayRouter.view(for:)` 同口径。
- 复测：408/408、285/285、80/80 三组 `framesRendered` 与解码数一致（修复前恒 0），无需再靠截图判读。

**H. 环境与前置（两机）**
- 两机初始均为锁屏 + 屏睡。合成按键在锁屏上被系统整体丢弃（`CGEventPostToPid` 与 HID tap 两级注入、root 与 GUI 会话两条路径都无效果，屏幕无回显、光标不移动）：这类机器**不能靠注入解锁**。
- 可用做法：`defaults write /Library/Preferences/com.apple.loginwindow autoLoginUserScreenLocked -bool false` + `askForPassword=0`（含 `-currentHost`）+ 自动登录（`/etc/kcpassword`），重启后直接落到未锁桌面。两机均已按此配置。
- 构建/单测：Sonoma（CLT 16）、Ventura（CLT 14.3.1）在 `f216f90` 上 `v01probe`/`stream_probe`/`rdpapp` 全构建通过，两端各 5 套单测 `ALL PASS`；本机 Tahoe 同步重建 + 单测 `ALL PASS`。

**I. 本轮仍未闭合（含理由）**
- **真挂起（WindowServer 冻结）的硬熔断故障注入**：需要人为冻结 WindowServer，历史上会连带崩显示栈并踢回 loginwindow，须有人在场的窗口；本轮只覆盖了「慢提交」侧（8.3s/10.0s 共 6 次自然触发）。
- **多屏独占**：两台 Intel 测试机各只有一块物理屏，无法构造双物理屏独占；Tahoe 本机双屏独占留待有人在场窗口。
- **72h soak** 与 **A-02 玻璃到玻璃**：前者需要长窗口占用机器，后者需要相机/外部计时硬件，均不在本轮范围。

### 5.49 §5.48 I 剩余项收敛：真挂起故障注入 / 多屏独占 / 独占态 Path A 修正（2026-11-27 14:34–15:05，Tahoe 本机 + 13/14 同 LAN）

**背景**：§5.48 I 列了四项不可达：真挂起注入、多屏独占、独占态 Path A、72h soak。本轮用「换注入点 + 换被测拓扑」的方式把前三项的可测部分做完，并把 §5.32 ③ 的一个错误结论纠正过来。

**A. 真挂起硬熔断：改在事务层注入（不冻结 WindowServer）**

先补一个实现缺口：软死线后的收敛判据 `verify()` 本身也是 WindowServer IPC（`CGDisplayIsActive`）。真挂起时它会**永久阻塞**，于是「8s 软死线 + 12s 宽限期」永远不会走完——熔断反而永远不触发。修复（`P0VDisplayControl.m`）：

- 新增 `P0VProbeVerify`：把「探活 IPC + verify」放进**同一个 1s 有界窗口**；窗口内没回来即判 WS 不可响应，立即熔断，不再等满 12s。
- 熔断 detail 增加 `reason`：`ws-unresponsive`（探活超时）或 `state-not-converged`（WS 活着但状态不收敛）。

注入手段：`P0V_FAULT_TX=hang|wsfreeze` —— 事务线程永不返回、且**不提交任何显示配置**（物理屏不受影响），语义与真挂起一致。测试脚本 `Scripts/tests/tx-breaker/`（`run.sh` 构建 + 三模式）。

| OS | normal（幂等 enable） | hang（WS 正常、事务卡死） | wsfreeze（WS 无响应） |
|---|---|---|---|
| Tahoe 26.5.2（本机） | 0.02s 成功 | **20.18s** 熔断，`state-not-converged` | **9.27s** 熔断，`ws-unresponsive` |
| Ventura 13.6.7（.213） | 0.01s 成功 | **20.19s** 熔断 | **9.27s** 熔断 |
| Sonoma 14.5（.212） | 0.01s 成功 | **20.15s** 熔断 | **9.26s** 熔断 |

三机共同判据全部 PASS：熔断后 `P0VWindowServerHung()==YES`；**第二次调用被拒（code 10，<200ms，不再发 SPI）**；前后 active display 集合一致（注入没有改动物理屏）。

> 口径澄清（记入 C-17.43）：NFR-06 的「SPI 挂起 8s 内熔断」对应 `wsfreeze` 档——实测 8.3–9.3s（8s 软死线 + ≤1s 探活）。`hang` 档是「WS 正常但事务线程卡死」，要用满 8s + 12s 宽限才熔断，这是为兼容 13/14 真机 8.3–10.0s 的慢提交（§5.48 B/C 六次自然触发）而付的代价；两种档位都不再可能无限阻塞。
>
> 局限：注入发生在事务层，没有真的冻结 WindowServer（历史会连带崩显示栈并踢回 loginwindow）。`wsfreeze` 档覆盖的正是「探活超时」这条真挂起必然经过的代码路径。

**B. 多屏独占（1 物理屏 + 1 块「外部」虚拟屏）**

两台测试机各只有一块物理屏，因此用 `Scripts/tests/multi-display/extra_display`（独立进程持有 800×600 虚拟屏，identity offset +32 避开被测会话）构造出「session 开始时有 2 块 active 屏，其中 1 块不属于本会话」的拓扑。Sonoma 14 host × loopback client，独占 1280×720@15：

| 观察点 | 结果 |
|---|---|
| session 前 active | `818512064`（物理 1920×1080）+ `4128835`（外部虚拟屏） |
| 禁屏后 active | **`[4128834]`** —— 只剩本会话虚拟屏，物理屏与外部虚拟屏都被关掉 |
| C-09 | `verified` |
| 推流 | captured 51 / encoded 50 / sent 50；client 50/50 上屏、0 丢帧，`summary` **PASS** |
| 收尾 | `sessionRecovered=true`；active 回到 `[4128835, 818512064]`（**两块都恢复**），外部虚拟屏进程存活、屏仍在 |

⇒ 禁屏集合是「active − 本会话虚拟屏」的全量差集，不是只关主屏；恢复同理。**局限**：这不是双物理屏。两块真实显示器的 mode-commit 时序与显示栈竞态仍未覆盖（本机 Tahoe 有双物理屏 3440×1440 + 1080×1920，需在场窗口，见 F）。

**C. 独占态 Path A：锁屏生效、登录 UI 画在虚拟屏上（修正 §5.32 ③）**

§5.32 把「独占态 lock 返回 ok 但没锁上」归因为「物理屏全禁时 `SACLockScreenImmediate` 不生效」，但同时记录了对照组是「GUI Terminal（Aqua）里有效、SSH 进程无效」。两者混在一起，**变量没分离**。本轮把调用上下文固定在 Aqua（GUI Terminal 里跑 `Scripts/tests/patha/patha_probe`），只留「物理屏全禁」一个变量：

| 观察点 | 结果 |
|---|---|
| 前置 | Sonoma 14 独占 1280×720，`active=[会话 VD]`，`console=bemin`，`loginDone=1` |
| 锁屏调用 | `SACLockScreenImmediate rc=0`（GUI Terminal / Aqua 上下文） |
| 5s 后状态 | **`CGSSessionScreenIsLocked=1`**、`CGSSessionScreenLockedTime` 写入、`kCGSSessionSecureInputPID=168` |
| 画面 | 会话虚拟屏（1280×720）截图**完整呈现登录界面**：`bemin` 头像、密码输入框、时钟 14:55、右上「你的屏幕正在被观察」 |
| 推流 | 锁屏期间 host 仍 `delivered=15–16/s`、状态保持 `STREAMING`，客户端看到的就是这张登录界面 |
| 收尾 | 60s 会话结束后恢复物理屏（1920×1080 截图可读） |

⇒ **§5.32 ③ 的结论不成立**：独占态（物理屏全禁、只剩虚拟屏）**可以**上锁，登录 UI 也会画在虚拟屏上。此前失败的真实变量是调用上下文（非 Aqua 的 wrapper 静默无效），不是独占态。

同时确认了一条**新的、更硬的边界**：锁屏态（`loginDone=1` 且 `screenIsLocked=1`、secure input 生效）下，用 `CGEventPostToPid` 向 loginwindow 注入「10 字符 + Return」**被系统丢弃**，`screenIsLocked` 仍为 1。§5.29 的「键入成功」发生在**登录窗**（`loginDone=0`，注销/重启后的登录界面），是另一种状态。⇒ 远端解锁锁屏需要 HID 级注入或认证插件路径，属 V-04d 剩余部分，本轮不做（见 F）。

恢复：锁屏无法用合成事件解锁，走重启 + 自动登录。14 于 14:58 重启，15:00 回到未锁桌面（`console=bemin`、单屏 active）；13 曾在「屏睡 + 锁屏」态，15:01 重启后同样恢复（`screenIsLocked=nil`）。

**D. soak：仍未执行，前置已列清**

72h soak 本轮**没有跑**，理由是不需要试跑就能判定的：它要求两台机器连续 72h 不被占用、且 client 侧不锁屏屏睡；本轮只有几十分钟窗口。已就绪的资产与执行前置：

- `Scripts/soak/soak-host.sh`（host 侧 RSS/CPU + WS PID）、`soak-client.sh`（每轮 30min 会话 + 重连）、`analyze-soak.py`（会话数/丢帧/控制间隔/内存斜率/WS 重启）。
- 拓扑按 README 固定 Tahoe host × Sequoia client（WAN）；14 无 Xcode，产品二进制需从 Tahoe 构建后拷入 `VEILRD_BIN` 指向的路径。
- 前置条件（本次实测都踩过）：host 侧 agent 必须由 GUI Terminal/LaunchAgent 启动才有采集授权（§5.48 F）；client 侧必须先 `caffeinate -d -u` 并保持未锁屏，否则 preflight 直接 `locked=1 / asleep=1` 拒绝（本轮 13 就是被这条挡住）。
- 判据见 `Scripts/soak/README.md`：RSS 斜率 < ~10MB/h、WS PID 全程不变、丢帧不恶化、控制间隔 < 8000ms。

**E. 环境事实（本轮新增）**

- 本机 Tahoe 是**双物理屏**：`2026701824` 3440×1440（main）+ `817925634` 1080×1920 竖屏，另有 6 个 `0xFFFFFFFF` 残留虚拟槽位（`4128829…4128835`），`v01probe probe` 只读即可复现。
- 14 重启会清空 `/private/tmp`（本轮测试脚本与二进制需重新分发）；13 默认 1 分钟内屏睡，任何 client 测试前都要先 `caffeinate -d -u`。

**F. 双物理屏独占（本机 Tahoe 26.5.2，17:02）——OS 层边界，已加安全闸**

本机是唯一能构造双物理屏的机器（`2026701824` 3440×1440 + `817925634` 1080×1920）。独占 720p 一次实测：

| 阶段 | 结果 |
|---|---|
| host 准备 | 快照 8 个窗口（AX trusted=1）、guardian 就绪握手通过、虚拟屏 `4128835` 建成且 mode-commit ok |
| 客户端 | 握手 335ms → `DISPLAYS_READY` → **`CLOSED`**（25s 未进 STREAMING）；host 侧 40s 无客户端退出 |
| 事后显示栈 | WindowServer 注册表只剩 **8 个 `vendor=0x756e6b6e`（"unkn"）合成屏**：7 个 1×1 offline + 1 个 1280×720 online/active；**两块物理屏从 WS 列表消失** |
| 硬件层 | `ioreg -c IODisplayConnect` 仍枚举到两块显示器（ProductID 13328 / 568）——**线没掉，是 WS 丢了显示列表** |
| guardian | 父进程未正常收尾 → 兜底恢复**失败**（快照里的 displayID 在新注册表中已不存在） |
| 恢复尝试 | `pmset displaysleepnow` + 唤醒无效；`recover_displays`（enable all + 重设 mode）`commit=1001` 失败 ⇒ 只能重启 WindowServer / 整机 |

判读：这与 13 机型 1080p 独占的 `layer_blit` 崩溃同族——**把全部物理屏一次性禁掉**会让 WS 进入「无物理屏」合成态，显示 ID 全部失效，任何软件层恢复（含 guardian）都无从下手。它不是「禁屏 API 不可用」，而是「双物理屏独占在本项目的 Intel GPU 上不可恢复」的 OS 层边界。多屏独占的**逻辑**仍按 B 的证据成立（1 物理 + 1 外部虚拟屏，禁屏集合 = active − 本会话虚拟屏）。

**处置**：`M1RDPDriver` 增加默认拒绝的安全闸——`physical.count > 1` 时直接拒绝独占并给出重启提示，只有显式 `M1_ALLOW_MULTI_DISPLAY_EXCLUSIVE=1` 才放行（`M1RDPDriver.m`；单测 343/343 PASS）。本机显示栈需重启恢复。

**事后复核（17:49 重启后，17:56 复测）**：整机重启后两块屏自动回到在线态（`2026701824` 3440×1440@60 main + `817925634` 1080×1920@60，`Mirror: Off`、`Online: Yes`），无需任何人工干预；`/Library/Logs/DiagnosticReports` 中**本时段没有 WindowServer 崩溃报告**（最新一份仍是 11-25 22:06）⇒ 本次是**显示列表丢失**，不是 WS 崩溃（与 13 机型 1080p 的 `layer_blit` SIGBUS 崩溃区别明确）。本机未安装任何 veild/p0v LaunchAgent，重启后无 `stream_probe`/guardian/`v01probe` 残留进程；重启清空了 `/private/tmp`，p2 本轮日志已丢失，故障时段的"WS 注册表实况"以当年 `v01probe probe` 与 `sls_dump` 输出为准（已记入上表）。

**G. 本轮仍未闭合（含理由）**

- **双物理屏独占**：已按 F 判为 OS 层边界并加闸，不再作为待测项；若后续换 AMD/Apple Silicon 平台需重新评估。
- **锁屏态远端解锁**（C 的新边界）：需要 HID 级注入（`CGEventPost` 到 HID tap 亦被 secure input 拦）或认证插件，属产品能力缺口，不是测试缺口。
- **72h soak** 与 **A-02 玻璃到玻璃**：前者需跨日窗口，后者需相机/外部计时硬件。

## 6. 状态汇总

| 假设 | Sequoia | Tahoe | Ventura |
|---|---|---|---|
| A-01 Tahoe SPI 可用 | — | ✅ 关闭 | — |
| A-04 虚拟屏容量与物理屏解耦 | — | ✅ 关闭 | — |
| A-07 13–26 双角色 | — | — | ⚠️ 部分收敛：client 全角色 PASS（§5.24）；host 的 SCK 被系统拒绝但 CG 回退可用，镜像 + 虚拟屏 keep-main 双机全链路 PASS（§5.27/§5.28），真实系统输入注入 PASS（光标位移 >1000px），SPI 建虚拟屏 PASS，帧率 ~14.8fps@720p；锁屏态改用 CGDisplayCreateImage 后端后可看见登录界面并接受键入，14.9fps@720p（§5.29）；**1280×720 完整独占禁屏/C-09 加 ScreensharingAgent 竞态规避后已 PASS（§5.30）**，健康态复测再次全链路 PASS（§5.32）；1920×1080 独占触发 WindowServer layer-blit 崩溃为该机型 OS 层边界、不重试；多屏独占未覆盖（§5.31）；**当前 HEAD `3dcba66` 补测（§5.46）**：镜像/keep-main 双机全链路 PASS、Sonoma 客户端输入回传 PASS；全独占 720p 在建屏阶段停滞并触发 guardian 恢复失败，仍属该机型 OS 边界；**`f216f90` 修 8s 死线误判后 720p 全独占双向 PASS（§5.48 B/C）**：C-09 verified、`sessionRecovered=true`、物理屏恢复、无 WindowServer 崩溃，13 侧采集 8.7fps 为该机型上限；当轮多屏独占与独占态登录窗迁移未覆盖，**§5.49 B/C 补测（2026-11-27）**：多屏独占在「1 物理 + 1 外部虚拟屏」拓扑上 PASS（禁屏后 active 仅会话虚拟屏、收尾两块都恢复），真挂起硬熔断用事务层注入在三机 PASS；独占态 Path A 纠正为「Aqua 上下文下可上锁、登录 UI 画在虚拟屏上」，仅锁屏态远端解锁仍缺 HID 级路径 |
| A-08 物理屏全禁后仍可建屏/捕获/注入 | ✅ 核心关闭（SCK OK） | ✅ 关闭：V-01 通过；V-03 显示隔离+恢复成立（已登录零物理屏下 SCK 不可靠，但公开抓屏 API 稳定可用）；V-02 锁屏建屏成立；禁屏后登录 UI 完整迁移 |
| A-09 锁屏/登录窗可远程进入 | V-04a/b ✅、V-04c 未测、V-04d 未实现 | ✅ **关闭**：V-04a/b/c/d 全过，Path A 端到端成立；前置防显示睡眠（屏睡态 SCK 无帧，caffeinate 可避免） | ✅ 镜像模式 Path A 端到端 PASS（V-04a/b/c 等价）：锁屏且防睡眠下 CGDisplayCreateImage 后端看到完整登录界面（14.9fps），定向键入使密码框出现圆点，真实口令注入后 `locked=0 / ok=1`、回到桌面（§5.29）。**独占禁屏下的登录窗迁移（V-04d 等价）仍未实测**：补测被建屏阶段的控制通道重传放弃与 WindowServer layer-blit 崩溃阻断（§5.31）；健康态独占全链路虽 PASS，但独占态下 `SACLockScreenImmediate` 静默失效（须 Aqua session 且物理屏全禁时不生效），登录 UI 未呈现（§5.32）；**§5.49 C 修正该结论**：把调用上下文固定在 Aqua 后，独占态（active 仅会话虚拟屏）`SACLockScreenImmediate rc=0`、`screenIsLocked=1`，且 1280×720 截图完整呈现登录界面（头像/密码框），推流未中断 ⇒ 失效变量是调用上下文而非独占态；剩余缺口仅「锁屏态远端解锁」——secure input 生效时 `CGEventPostToPid` 键入被丢弃（登录窗 `loginDone=0` 下 §5.29 的键入仍成立），需 HID 级或认证插件 |
| A-02 glass-to-glass 延迟 | 未测 | ⚠️ 部分推进：M1-Pre 采集编码链路成立，但带编码的真实帧率 `CGDisplayCreateImage` 1–7fps / SCK 2–18fps，均远达不到 60fps；首帧延迟 739–1031ms；无编码时的 55fps 是假象。2026-11-19 跨公网已取得首批双机数据（§5.13，Tahoe host × Sequoia client）：1080p20 客户端渲染 84.7ms/帧、解码/发出 54/375；720p10 渲染 41.6ms、上屏 0 积压；补测 C/D 拿到完整配对（3440×1440 → 7 解出；720p15 → 136/443，丢包 4–6% + 严格按序重组等关键帧是主因）。无 60fps / glass-to-glass 证据，A-02 保持开放，见 D-10。**2026-11-22 打点落地（§5.35）**：帧头 v3 内嵌 `capturedAtUs` + 控制通道 `time-sync`；Tahoe 26.5.2 host × Sequoia 15.5 client（WAN，1080p20 镜像）两轮 capture→render **p50 94–95ms / p95 206–231ms**（时钟差 ~88ms、RTT 7–9ms），玻璃到玻璃仍未测 |

> **Sonoma 14.5（23F79，iMac20,1，2026-11-26 新增）**：上表未单列。CLT 16 本机构建/单测、`v01probe` 只读侦察、client 前置与 13→14 同 LAN 收流/上屏/输入回传均成立（§5.46 A/B）；授权后 14→13 反向镜像与 keep-main 全链路 PASS（§5.47 r6/r7）。**`f216f90` 后 14 的 host 档位已补齐（§5.48）**：全独占 720p `c09Status=verified`、408/408 上屏 0 丢帧、`sessionRecovered=true`、物理屏恢复，A-07 在 14 上按 720p 关闭（1080p 独占未测，不跨分辨率外推）。

---

## 7. 变更记录

- v0.79-draft 2026-11-27 15:0x：**§5.48 I 剩余项收敛（§5.49）**。①真挂起硬熔断改用事务层注入（`P0V_FAULT_TX=hang|wsfreeze`，不冻结 WindowServer、不改物理屏）：先补实现缺口——收敛判据 `verify()` 本身是 WS IPC，真挂起会永久阻塞、熔断永不触发；改为「探活+verify 同一个 1s 有界窗口」，超时即判 `ws-unresponsive`。三机实测：`wsfreeze` 8.3–9.3s 熔断、`hang` 20.2s 熔断、熔断后新事务 code 10 即时拒绝（<200ms），normal 基线 0.01–0.02s。②多屏独占用「1 物理 + 1 外部虚拟屏」构造 PASS：禁屏后 active 仅会话虚拟屏（两块非会话屏全关）、C-09 verified、50/50 上屏 0 丢帧、收尾两块都恢复。③**纠正 §5.32 ③**：Aqua 上下文下独占态可上锁（`screenIsLocked=1`、secure input pid 168），登录 UI 完整画在会话虚拟屏上、推流不中断；此前失败的真实变量是调用上下文。新边界：锁屏态远程解锁被 secure input 拦住（登录窗态仍可键入）。④soak 未执行，前置与判据已列清（需跨日窗口 + client 保持未锁屏）。本机 Tahoe 确认为双物理屏（3440×1440 + 1080×1920）；**双物理屏独占实测判为 OS 层边界**：一次禁 2 块物理屏后 WS 只余 `vendor=0x756e6b6e` 合成屏、物理屏从 WS 列表消失（IOKit 仍在）、guardian 恢复失败，只能重启 ⇒ 已加默认拒绝的安全闸（`M1_ALLOW_MULTI_DISPLAY_EXCLUSIVE=1` 才放行）。
- v0.78-draft 2026-11-27 11:2x：**8s 死线误判修复 + 13/14 全独占 720p 双向 PASS + FR-08/FR-09 闭合（§5.48，代码 `f216f90`）**。显示事务改为「8s 软死线 + 12s 状态收敛观察期」，只有状态也没收敛才熔断；驱动层以实际 active 集合复核禁屏/恢复，解除误判的挂起标志。真机：14 host 独占 720p 采集 409/发 408、client 408/408 上屏 0 丢帧、C-09 verified、恢复 8.3s 迟到生效、物理屏回来；13 host 独占 720p 采集 294/发 285、client 285/285、无 WS 崩溃。FR-08 用「只断 UDP 46600」的 pf 规则（SSH 全程可达）复测：判死→重连第 2 次握手 15ms→`reconnects=1`、80/80 上屏 0 丢帧；同时定位两种不能用于验收的 host 形态（单次 host、独占 teardown 窗口）。FR-09：14 装载 LaunchAgent 经 Terminal 继承 TCC，重启后 agent 自动拉起并被 13 接入 STREAMING（33 帧 PASS）。另修客户端上屏计数（单屏按唯一 slot 兜底），`framesRendered` 与解码数一致；记录锁屏机器无法靠注入解锁，需 `autoLoginUserScreenLocked=false` + 自动登录。
- v0.77-draft 2026-11-27 08:5x：**产品客户端上屏计数根因（§5.47 E）**。13 host + 14 `rdpapp` 两轮 657 帧、0 丢帧，会话中整屏截图确认 VeilRD 窗口真实显示远端桌面；`framesRendered=0` 源于窗口绑定 `displayID=1000` 与帧流 `1535231424` 不一致导致汇总查不到 slot，属指标口径缺陷，不改产品代码。另记录本机 Tahoe 重建/单测 PASS，及跨网段 UDP 未达导致 NFR-07 指纹钉死未测（§5.47 F）。
- v0.76-draft 2026-11-27 08:3x：**Sonoma 授权后反向链路入档（§5.47）**。本机确认为 Tahoe host 并先核对环境；Sonoma GUI Terminal `capture=1` 后 14 host → 13 client：镜像 413/412、keep-main 408/408 规格一致，两项 `summary` PASS；全独占 720p 在禁屏事务 8s 熔断、客户端 rc=4，无 WS 崩溃且物理屏恢复，按开发项记录不重试。8s 死线「恢复成功却报失败」在 13/14 均复现；Sonoma 已补自动登录兜底。
- v0.75-draft 2026-11-26 18:1x：**两台 Intel 测试机补测入档（§5.46）**。新增 Sonoma 14.5 / iMac20,1（CLT 16，本地构建+单测+client 前置 PASS，host 采集被 TCC 挡住）；Ventura 13 快进到 `3dcba66` 重建。13→14 同 LAN：镜像 405/405、keep-main 404/404 规格一致、合成输入 7/7 上行，三项 `summary` PASS 且 PNG 非黑；产品 `rdpapp` 在 14 上 360/360 解出但上屏计数 0（待可见性复核）。全独占 720p 当前 HEAD 建屏停滞、guardian 恢复失败并踢回 loginwindow，补齐 `/etc/kcpassword` 后重启恢复；发现 M3 8s 显示事务死线在 Ventura 正常收尾误触发（`sessionRecovered=false` 但实际恢复成功）。时钟差 ~2.1s，capture→render 不作延迟基线。
- v0.74-draft 2026-11-25 22:4x：**M3 开工（§5.45）**。FR-08 断网重连真机 3 轮 PASS（10–12s 双向 pf 阻断 + 清 state）：判死 8.8s、退避 0.5→1→2s、重连后沿用 VD 4128835，0 丢帧、`reconnects=1`（195/195、118/118、103/103）。对称断路暴露僵尸 STREAMING（`控制链路失败 seq=18 重传 20 次` 后 `断线重连 0 次`），修复 `75e976c`（`abortWithReason:` 接入链路失败与 8s 看门狗），复测被 host 失联阻塞。同轮落地（`3c06c1c`）：host SIGTERM/SIGINT 有序还屏、显示事务死线 8s（NFR-06）、`--allow-fingerprint` 客户端指纹钉死 + 客户端持久身份、无人值守/soak 资产、安全自查清单；单测 343 PASS。事故：SIGTERM 杀 agent → guardian 恢复 `CGError 1001` → 物理屏 ID 失效、仅合成主屏 → 配好自动登录后 22:08 重启，至 22:38 SSH/WAN/LAN 全不可达，待物理检查。
- v0.73-draft 2026-11-25 21:2x：**M2 重连清理 PASS（§5.44）**。Tahoe 26.5.2 host（WAN）× Sequoia 15.5 client，`--max-sessions 2`：会话 1 1920×1080 17/17 上屏、客户端离开；会话 2 1280×720 `[独占] 换屏 4128834` 23/23 上屏、host 时长到收尾；`sessions=2`、sent=40、fragments=633、控制面 0 异常、退出 0、物理屏恢复、无遗留进程。两个根因：① 显示收尾（16s+）占着控制交付队列，饿死下一轮 attach/hello（`57`/重传耗尽）；② Tahoe 同进程销毁虚拟屏后再建必 `online=0`，身份 offset 无效——改为会话间复用虚拟屏（规格变则 create-then-destroy 换屏），物理屏常驻期保持禁用。
- v0.72-draft 2026-11-24 22:3x：**M2 收口真机（§5.42）**。FR-07 keep-main 2→1 WAN 换屏 PASS：host `[换屏] 2→1（4128833 1024×768）`、旧屏 retired、client 结果 ok 并重绑窗口、0 丢帧、两端控制间隔 1.44s/1.19s；根因定位为控制消息在 QUIC 收包线程同步交付，换屏 ~2.2s 拖死 ACK、2s 重传预算耗尽后控制链路静默失效，修复 `7f664b6`（专用交付队列）。FR-06 真机文本注入 PASS：client `--send-text` 两串 → host `inputOK=2`、落盘 `HelloVeilRD中文输入测试` 29B 逐字节一致、39/39 上屏 0 丢帧；首轮收端 canonical 模式不落盘已定位。沉浸模式真机目测与 FR-07 取档因 host WindowServer 虚拟屏 `active=false` 脏态延后，已重启 host 待补。
- v0.71-draft 2026-11-24 21:2x：**P2.3 基线取数条件收敛（§5.41）**。Qoder 仅最小化（进程未挂起、mds 未暂停）8 轮离屏：vga 2.3/2.5/2.77、720p 3.1/3.65/4.6、1080p 5.3/5.85/7.5、ultrawide 13.4/14.8/17.15ms，8/8 ALL PASS，与隔离口径 p50 差 ≤0.5ms；此后基线只需最小化 Qoder。
- v0.70-draft 2026-11-24 21:1x：**双屏真注入 + P2.3 基线复核（§5.40）**。Tahoe host `--keep-main --inject real` × Sequoia client 双窗口：host input 15/0、光标 (10,10)→(4133,395)，client 上送 15、0 失败，1273/1273 解码上屏、0 丢帧、p50/p95 26.5/155.5ms；恢复与窗口布局正常。P2.3 隔离负载 8 轮：vga 2.2/2.35/2.7、720p 3.2/3.35/3.7、1080p 5.1/5.45/6.2、ultrawide 10.2/13.3/17.0，ALL PASS，与 §5.38 一致；Qoder 可见时 vga 35ms 超护栏，再次证明负载敏感性。
- v0.69-draft 2026-11-24 21:0x：**M2 多屏双机实测（§5.39）**。Tahoe 26.5.2 host × Sequoia 15.5 client（WAN，1280×720×2@15，`3e18538`）：keep-main 档 client 138/138 解码上屏、0 丢帧、`c09=skipped-keep-main`、物理屏恢复；全独占档 `c09=verified`、client 981/981 解码上屏、0 丢帧、p50/p95 129.5/308.5ms、控制间隔 1.16s、窗口布局 7/7 恢复、物理屏 2 块在位。PNG 按 `frame-d<displayID>-` 命名且两屏内容非黑。备注：host 屏睡会令 CG active=0 阻断建屏（caffeinate 唤醒）；重定向日志需 `script -q /dev/null` 才实时。
- v0.68-draft 2026-11-23 23:1x：**P2.3 渲染基线复测（§5.38）**。Qoder/Screen Sharing 隐藏 + mds 暂停后：离屏 8 轮 min/p50/p95 为 vga 2.2/2.3/2.4、720p 3.2/3.3/5.0、1080p 5.4/5.5/6.1、ultrawide 13.5/13.9/21.1ms（ALL PASS，与 v0.61 一致）；真实 client 1080p20 本机镜像环回用 `M1_CAPTURE_BACKEND=cg`（本机 SCK HiDPI 仅 3–5fps）后采集稳定 20fps，client 579/579 解出并上屏、0 丢帧 0 积压、p50/p95 81.5/144.5ms ⇒ 渲染下限无回退；WAN mirror 积压确认为本机负载。另确认隐藏/被遮挡的 client 窗口不绘制（r1 `渲染=0` 属 AppKit 遮挡态）。
- v0.67-draft 2026-11-23 22:5x：**产品入口 WAN 对照：全独占 + C-09 PASS、`--mirror` 诊断档 PASS（§5.37）**。Tahoe 26.5.2 host × Sequoia 15.5 client（WAN，720p15，20s/18s）：默认独占档 `C-09=verified`、解码/发送 255/260=98.1%、0 丢帧、间隔 ~1.0s、物理屏恢复 2 块在位（窗口布局恢复 failed=1 待查）；`--mirror` 三轮 `c09=not-started`、解码/发送 98.1/93.2/92.4%、传输丢帧 0–4、间隔 <1.4s，上屏积压受本机渲染压力波动为本机负载所致。另确认产品档位口径：默认=全独占，`--keep-main` 见 §5.36。
- v0.66-draft 2026-11-23 22:5x：**host 间隔指标二次收口 + §2 keep-main WAN 复测通过（§5.36 r3/r4）**。v0.65 修 CLOSED 空窗后仍有残留：建屏/守护阶段（Tahoe 上约 13–18s）的最后一包控制消息把 STREAMING 前的空窗算进首包心跳（r3 host 18.1s / offset 308ms）。`4a37d1d` 在进入 STREAMING 时清 `lastControlArrivalMs`；r4 复测 host 1300.9ms@+9.3s、client 1025.1ms、解码/发送 351/356=98.6%、0 丢帧、`c09=skipped-keep-main`、虚拟屏销毁物理屏恢复 ⇒ §2 keep-main WAN 门禁通过。
- v0.65-draft 2026-11-23 22:4x：**host 控制间隔指标口径修复**。`M1StreamSession` 在 CLOSED 后继续记账，把 client 退出到 host 时长结束的空窗算成心跳被挤（§5.36 r2 15.1s）；改为 CLOSED 即停记并清 `lastControlArrivalMs`，host JSON 增 `maxGapAtOffsetMs`。本机 Sequoia 15.5 镜像环回（20s/12s）复测 1044.6ms、最大间隔 offset 3047ms，尾部 8s 不再计入。另记：Qoder 后台任务会节流 host，导致 QUIC 握手卡在 preparing；本机环回须同前台 shell 起两端。
- v0.64-draft 2026-11-23 22:2x：**产品入口补齐 `--guardian`，keep-main 双机 WAN 闭环（§5.36）**。产品 `veild-host-agent --serve` 的 keep-main/独占档此前被自身门禁拒绝：`M1RDPDriver` 的 `P0VStartGuardian` 用同一二进制 re-exec `--guardian`，产品入口缺该分支导致握手超时、禁止禁屏（探针入口一直有，属 C-12.2 收口遗漏）。`Apps/HostAgent/Sources/main.m` 补分支并转调 `P0VRunGuardian`（`17f9883`），`HostDaemon` 不链接 RDPKit、不碰显示配置，未改。本机 Sequoia 15.5 镜像环回两轮（静态 28 帧；动画 220/223=98.7%、p50 113.5ms）通过；keep-main 被陈旧虚拟槽位 4128835 阻断（unmirror 超时），守护兜底恢复成功，主屏模式已手工恢复 3008×1692。Tahoe 26.5.2 host × Sequoia 15.5 client（WAN，keep-main 720p15）：静态轮 15/15、动画轮 321/325=98.8%、0 丢帧、控制间隔 1062ms、`c09=skipped-keep-main`、虚拟屏销毁且物理屏恢复。发现 host 侧 `maxControlGapMs` 把 client 退出后的空窗计入，门禁应以 client 值为准。
- v0.63-draft 2026-11-22 23:0x：**A-02 打点落地 + 首轮跨机 capture→render（§5.35）**。帧头 v2→v3（26B，偏移 18 起 8B `capturedAtUs`），Host 采集打点经编码 PTS 回填、Client 用其作解码 PTS 并在贴层处算原始差；控制通道新增 `time-sync`/`time-sync-reply`（最小 RTT 估时钟差）。首次跨机暴露符号错误：原始差为负的帧被直方图丢弃、报告端又减了时钟差，导致 p50=0、样本仅 380/586；改为 -512ms 起的有符号直方图并改回 `raw+offset` 后，Tahoe 26.5.2 host × Sequoia 15.5 client（WAN，1080p20 镜像）两轮：r2 583 帧 p50/p95 95.1/231.1ms、r3 767 帧 94.2/206.2ms，时钟差 ~88ms、RTT 7–9ms、解码 19.2–19.7fps、0 丢、summary PASS。单测双端 291/291。glass-to-glass 仍开放。
- v0.62-draft 2026-11-22 22:1x：**P2.3 上屏积压收口（§5.33）**。上轮 66 帧丢弃来自 2 帧积压上限而非渲染成本（转换 p50 4.5ms）：槽位改为转换完成即释放，上限 8 时剩 2 帧、12 时归零。1080p20 镜像最终轮 host 589 采集/588 发出，client 587/587 解出并上屏、积压丢 0、`maxPendingRenders=8`、p50/p95 4.5/20.5ms、主线程等待 0.1ms、解码 19.8fps、summary PASS；新增 pending/直方图/入队与主线程等待指标及 client JSON 字段。单测 280/280、render_selftest ALL PASS。⇒ P2.3 完成判据达成，A-02 仍开放。
- v0.61-draft 2026-11-22 21:5x：**P2.3 干净基线（§5.33）**。Qoder 最小化 + mds 暂停 + nice -20 后，离屏 8 轮：720p 3.2ms、1080p 5.3ms（p95 10.4ms）、ultrawide 13.2ms，0 失败；真实 client 1080p20 镜像 30s：host complete=20/idle=0、589→588 帧，client 19.2fps、上屏 504、`lastRenderMs=3.9`、`maxRenderMs=209.4`（启动尖峰）、summary PASS。⇒ 1080p20 渲染下限 ~4ms，积压丢弃不来自渲染；Qoder 常驻时的 500–875ms 尖峰是 WindowServer/GPU 竞争，nice 无法消除，需最小化或专用户隔离。该轮 66 帧积压已在 v0.62 收口。
- v0.60-draft 2026-11-22 22:4x：**M1 窗口布局恢复 Tahoe 独占闭环（§5.34）+ best 镜像真机复测（§5.33）**。Tahoe 26.5.2 host 独占：r5 自然场景 `planned=0`（该版本 WindowServer 自动还原，D-05 未复现）；r6 强移 Terminal 窗口到 (150,306) 后 `captured=23 planned=7 restored=7 failed=0`，恢复后窗口回到快照位置 (464,131)，C-09 verified、client PASS。修复：AX 枚举空重试、当前 CG frame + 8pt 容差匹配、2s 单窗超时、预算 `max(3,min(10,0.7N))` 秒、恢复 settle 1.0s。3440×1440→1080p20 镜像真机 `res=best` 生效，20fps 采集、client 19.6fps 全 PASS；P2.3 空闲渲染基线仍被本机负载污染，未收口。
- v0.59-draft 2026-11-22 21:1x：**M1 窗口布局快照/恢复落地（§5.34）**。新增 `M1WindowLayout`：禁屏前采集 CGWindowList 窗口布局 + 屏幕 bounds，恢复后按 `pid#windowNumber` 精确匹配、只搬被禁屏上位移过的窗口，目标 frame 夹取到可见区域；AX 未授权时只计划不搬。驱动接线在建屏前拍快照、恢复并销毁虚拟屏后执行搬窗，`stream_probe` 输出 `windowLayoutRestore` 摘要。单测 280/280（新增 12 条），四个构建目标无 warning；本机 Sequoia 只读探针 `axTrusted=true`、4 窗口全部映射到已知屏。真实禁屏闭环留待下一轮 Tahoe 独占会话验证。
- v0.58-draft 2026-11-22 20:3x：**采集分辨率默认 best，见 §5.33**。`M1FramePipelineConfig.captureResolution` 默认 0→1，macOS 14+ 直接让 SCK 输出目标尺寸（13 由编译期守卫忽略）；`M1_CAPTURE_RESOLUTION=auto|nominal` 保留为诊断覆盖。本机 Sequoia 镜像环回 720p15/20s：69/69 解出、0 丢帧、summary PASS、`res=best` 生效；同负载 best 22 帧 vs auto 6 帧（负载污染，仅排除回退）。单测 268/268。P2.3 空闲渲染基线仍待测。
- v0.57-draft 2026-11-22 14:0x：**健康态独占复测 PASS + Path A 根因定位（§5.32）**。iMac 充分恢复后 13 host × 26 client 1280×720 独占 C-09 全链路再次 PASS（C-09=verified、511 帧解出/0 丢弃、8 张 PNG、WS 未崩），修正 §5.31「连续建屏必崩」的悲观判断。定位独占态 Path A 失败根因：`SACLockScreenImmediate` 须在 Aqua session 调用且物理屏全禁的独占态下静默失效，登录 UI 未呈现——非 OS 崩溃。harness 增 `M1_CTRL_RETRY_MS`/`M1_CTRL_MAX_ATTEMPTS` 两个默认关闭的诊断开关缓解建屏阻塞 ACK；产品代码未动。1080p 独占 OS 边界、多屏与独占态 Path A 未覆盖的口径不变。
- v0.56-draft 2026-11-22 13:4x：**C-09 剩余边界补测遇 OS 层崩溃，收敛为边界（§5.31）**。尝试 1080p 独占、独占态 Path A、多屏独占：1080p（1920×1080）虚拟屏 mode-commit 后 WindowServer 崩在 `layer_blit_byte_ARGB8_ARGB8_RGB8`（SIGBUS），与已修复的 ScreensharingAgent/`CopyFrame` 竞态是两条独立问题，`M1_C09_QUIESCE_SS` 无效；首次 720p 独占态 Path A 因建屏期间控制通道 `seq=2 重传 8 次` 踩线提前放弃（未进流）；带病态重跑 720p 又崩在 `layer_blit_byte_ANY`（SIGSEGV，WS 进程自 1080p 崩溃后带病运行）。⇒ 新增三条 Ventura 13/此机型边界（1080p 独占层 blit 崩溃、mode-commit 阻塞控制 ACK、连续 mode-commit 累积不稳定），停止连续真机重试；独占态 Path A（V-04d 等价）与多屏独占保持未覆盖。harness 仅加 `P2_SAVE_FRAMES` 可选参数，产品代码未动。
- v0.55-draft 2026-11-21 22:3x：**13 完整独占禁屏 / C-09 PASS（§5.30）**。WindowServer 崩溃报告证明两次旧崩溃与一次新崩溃都由 ScreensharingAgent 的 `CGDisplayStream` 与虚拟屏 mode 提交 / 禁屏重配置竞态触发（栈顶 `DisplayStreamStateSW::CopyFrame` 或 `layer_blit_byte_ANY`），且发生在建屏阶段，故把 `SIGSTOP` 窗口从禁屏事务前移到建屏前（C-17.40），提交 + settle 后 `SIGCONT`，所有异常/兜底路径解冻；`M1_C09_QUIESCE_SS=0` 可关闭。13 host × 26 client LAN 1280×720@15：C-09 verified、active 仅虚拟屏、采集 172/编码 163/发出 163、client 解出 163/上屏 161、summary PASS，WindowServer 未重启、物理屏恢复、屏幕共享仍可达。§5.28「OS 层阻塞、不再重试」结论作废。
- v0.54-draft 2026-11-21 21:2x：**13 Path A 真实口令解锁 PASS（§5.29 补测）**。用户给出真实口令；发现合成 Unicode 事件投递过密导致 10 字符只落 2 个圆点，修复 `p0vprobe.m`：逐字符 30ms 间隔 + 键入前 32 次 Delete 清场，并从输出里去掉明文口令。复测 `p0vprobe lock` → 前置 `locked=1` → 注入 → 后置 `locked=0 / ok=1`，截图为已解锁桌面，证据 `P2-Dual/out/a07-unlock-real-r2/`。A-09 在 13 更新为镜像模式端到端 PASS；完整独占禁屏下的登录窗迁移仍受 C-09 阻塞。
- v0.53-draft 2026-11-21 21:2x：**13 锁屏黑屏根因更正 + CGDisplayCreateImage 后端，见 §5.29**。用户指出锁屏数秒无输入会黑屏；对照实验证明有两层原因：① 显示睡眠时 `CGDisplayCreateImage` 直接返回 NULL（`caffeinate -d -u` 可解，Tahoe 早有此前置）；② 即使屏亮，CGDisplayStream 在锁屏态仍交付黑帧，而 `CGDisplayCreateImage` 能看到完整登录界面。`M1CapturePipeline.m` 新增第三条后端 `M1CGImageSource`（定时快照 → BGRA CVPixelBuffer），按 `CGSessionCopyCurrentDictionary()` 锁屏状态自动切换、解锁后恢复，`M1_CAPTURE_BACKEND=cgimage` 可强制；13/26 SDK 双构建 + 各 268 单测通过。13 host 锁屏 × Tahoe client 镜像 1280x720@15：359 帧上屏、14.9fps、落盘图含 `bemin`/密码框，PASS；`p0vprobe type --text zzzzzzzz` 后密码框出现圆点、截图哈希变化，确认登录 UI 收到键入。§5.28「13 Path A OS 层不可行」结论作废，A-09 更新为镜像模式视觉+注入 PASS、真实口令解锁未测；完整独占禁屏/C-09 仍是 OS 阻塞。
- v0.52-draft 2026-11-21 21:0x：**A-07 剩余项收敛，见 §5.28**。13 上私有 SPI 探测与建虚拟屏 PASS；完整独占禁屏/C-09 两次触发 WindowServer 崩溃（崩溃栈 `DisplayStreamStateSW::CopyFrame / CGXRestoreDisplayConfiguration`），第二次踢回 loginwindow，判定 OS 层阻塞、不再重试。`--keep-main` 安全变体下虚拟屏 + CG 回退后端全链路 PASS（278 解出 / 251 上屏 / 0 丢帧），帧率 ~14.8fps@720p。用户手动给 Terminal 辅助功能授权后 `--inject real` PASS（6 收到 / 3–6 注入，光标位移 1055–1154px）。Path A 锁屏态 CG 帧全黑、`screencapture` 失败，远程看见登录界面不可行；为绕开 SCK verdict 给 `p0vprobe` 增加 `type` 子命令（只键入 + Return）。A-07 按 OS 分离收敛，13 的独占禁屏与 Path A 保持开放为 OS 限制。
- v0.51-draft 2026-11-21 17:4x：**13 host 回退后端集成 + 双机全链路 PASS，见 §5.27**。`M1CapturePipeline.m` 加版本/能力门控的 `CGDisplayStream` 后端（13 直接走 CG，14+ SCK 失败自动回退），`IOSurface→CVPixelBuffer` 复用原编码链；`M1_CAPTURE_BACKEND=cg|sck` 可强制。13.3/26.5 SDK 双构建 + 各 268 单测通过。iMac13 host × Tahoe client 镜像 1280x720@15 两轮：81/81、53/53 收齐解出上屏，0 丢帧，输入 6/6 回传，均 PASS。3.7fps 归因于 iMac 弱 GPU 上动画夹具的内容更新率（独立 CG 探针 3.8fps），非后端缺陷。修 `P2-Dual/p2.sh` client 丢弃 `--input-synth/--manual/--keep-front` 的工具 bug。A-07 更新为「13 host 镜像模式可用，独占/锁屏未测」。
- v0.50-draft 2026-11-21 16:3x：**Ventura 13 host 实测 + 修复 startCapture 失败崩溃，见 §5.25**。用户完成屏幕录制授权后，GUI 会话内 host preflight `capture=1 ok=1`，握手到 STREAMING 正常，但 `SCStream startCapture` 被系统 `replayd` 以 `CoreGraphicsErrorDomain 1003 "The stream is nil."` 拒绝；独立最小 SCK 程序 5 种配置全部同样失败、TCC authValue=2、杀采集 daemon 无效 ⇒ 13 的 SCK 建流是 OS 层阻塞，非本项目代码/配置。13 host 角色仍不可用（A-07 host 侧未关闭），13 client 不受影响。修复 `M1CapturePipeline.m` 在 startCapture 失败时 `removeStreamOutput` 导致的 `EXC_BAD_ACCESS`（commit `52ab8b8`）：改为直接返回由 ARC 释放，复测优雅退出 rc=5、无新 crash report。
- v0.49-draft 2026-11-21 16:0x：**1080p20 满帧门禁达成 + 定位采集侧瓶颈，见 §5.24 补测**。`anim_display 0 60 full` 两轮对照：`res=auto` 时 SCK 送原生 3440×1440 再降采样，i5-9500 上采集仅 ~5fps（171 帧/30s、上屏 146）；`M1_CAPTURE_RESOLUTION=best` 让 SCK 直出 1080p，采集稳 18–20fps，发 525/解 525=1.000、上屏 493 帧、丢帧 0、`sendFailures=0`，`p2.sh summary` PASS。⇒ P2.3 的 1080p20 满帧首次在双真机 LAN 达成；确认瓶颈在采集侧转录/缩放而非网络/client，高分辨率物理屏镜像推流必须显式设 `M1_CAPTURE_RESOLUTION=best`。A-02 延迟仍未测、保持开放。
- v0.48-draft 2026-11-21 15:5x：**首次双真机跨网段 LAN 实测 + 工具链修复，见 §5.24**。Tahoe host × Ventura client，720p15 解码 276/278=0.993、1080p20 解码 85/85=1.000，两轮 `p2.sh summary` PASS，`sendFailures=0`，1080p 输入 2/2 注入、光标位移 1399px。client 空闲环境渲染基线刷新：720p 14.5ms、1080p 26.5ms/帧（此前 84.7ms 是本机负载污染）。LAN 行从「不可得」变为有实测证据（镜像模式）。修两个实测中暴露的工具链 bug：① `P2-Dual/p2.sh` 的 `summary` 相对路径在 `cd SKEL` 后失效，改为按调用方 cwd 解析；② 本地 `core.filemode=false` 导致全部脚本以 100644 入库，新克隆（filemode=true）拿不到执行位，`./p2.sh` 报 Permission denied——用 `git update-index --chmod=+x` 修正 7 个文档直接调用的脚本。**未证明** 13 host 建屏/禁屏/C-09、13 上 Path A；capture 授权无法远程授予（`CGRequestScreenCaptureAccess` 静默失败、SIP 保护 TCC.db），13 host 仍需人工在系统设置里点一次屏幕录制。
- v0.47-draft 2026-11-21 15:0x：**Ventura 13 编译验证，见 §5.23**。新增 iMac17,1 / 13.6.7 测试机；3 个构建目标 + 2 套单测在 13.3 SDK 与 26.5 SDK 上均通过。14+ SCK API 补 `#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 140000` 编译期守卫（与既有 `@available` 并存），并在 `DESIGN.md` §2.4.1 / `DECISIONS.md` C-17.38 明确 13–26 Intel 双角色目标。13 的 client 预检因屏幕锁定未通过，host 独占会话未实测。
- v0.46-draft 2026-11-20 23:3x：**G2 收口，见 §5.22**。`stream_probe --host` 默认按客户端 `session-start specs` 建虚拟屏并禁物理屏（`--mirror` 降为诊断开关，`p2.sh` 增 `P2_MIRROR=1`）。默认路径 720p15（p）：441/441、C-09 verified/recovered、补片 34/34、关键帧 0、控制间隔 1310ms；镜像对照（q）：428/428、补片 23/23、控制间隔 1055ms；均 PASS。
- v0.45-draft 2026-11-20 23:2x：**矩阵补测（2b9ec03）720p15 WAN 镜像/独占，见 §5.21**。m 442/441=0.998、n 440/440=1.000（C-09 verified/recovered、输入 81/79、光标 1342px），补片 30/30 与 25/25 全命中、关键帧 0、sendFailures 0。LAN 行因无同 LAN 第二台机如实标注不可得。P2.3 渲染基线被本机 Screen Sharing/Qoder 负载污染（同代码两轮 273.8ms vs 9.6ms、render_selftest 1080p 14.8–95.4ms），需空闲环境重测。
- v0.44-draft 2026-11-20 23:4x：**回归复跑 + 窗口外分片锁死治理，见 §5.20**。修正 v0.43 镜像 f/g 的证据口径（4.2–4.4KB/帧≈空白画面，不能代表大帧档）。新增分片丢弃去向与重组状态诊断。修复「`_nextSeq` 落后超窗后所有新分片静默丢弃、整段流锁死」：连续 ≥64 片 ahead 拒收即判丢并请求关键帧。回归：720p 镜像 442/442、720p 独占 424/425（C-09 verified）、1080p 镜像 585/586、1080p 独占 h5 573/574、h6 549/570（ahead=64 触发一次、关键帧 RTT 208ms），全部 PASS；单测 268/268。
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
