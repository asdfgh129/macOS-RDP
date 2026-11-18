# macOS-RDP 实测结论（按 OS 分离）

| 项 | 值 |
|---|---|
| 版本 | v0.4-draft |
| 日期 | 2026-11-18 |
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
| 真登录窗（loginwindow / 未登录） | `loginDone=0` 或不同 auditID | 未测 | 未测 | 未测 |

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

**结论**：Tahoe 零 active 物理屏下，公开抓屏 API 能稳定拿到内容，可作为 M1 的采集候选路径；但帧率/编码链路尚未接 VideoToolbox，需在 P2 双机联调验证。SCK 仍应保留为对照，不应作为该场景的唯一路径。

---

## 6. 状态汇总

| 假设 | Sequoia | Tahoe |
|---|---|---|
| A-01 Tahoe SPI 可用 | — | ✅ 关闭 |
| A-04 虚拟屏容量与物理屏解耦 | — | ✅ 关闭 |
| A-08 物理屏全禁后仍可建屏/捕获/注入 | ✅ 核心关闭（SCK OK） | ✅ 关闭：V-01 通过；V-03 显示隔离+恢复成立（已登录零物理屏下 SCK 不可靠，但公开抓屏 API 稳定可用）；V-02 锁屏建屏成立；禁屏后登录 UI 完整迁移 |
| A-09 锁屏/登录窗可远程进入 | V-04a/b ✅、V-04c 未测、V-04d 未实现 | ✅ **关闭**：V-04a/b/c/d 全过，Path A 端到端成立；前置防显示睡眠（屏睡态 SCK 无帧，caffeinate 可避免） |
| A-02 glass-to-glass 延迟 | 未测 | 未测 |

---

## 7. 变更记录

- v0.1-draft 2026-11-18：首次建立按 OS 分离的结论表；把 Sequoia 与 Tahoe 的 V-01/V-03/V-04 结论拆开，明确禁止跨版本外推。
- v0.2-draft 2026-11-18：补入 Tahoe V-02（锁屏态虚拟屏 `active=false`，不成立）、V-04a（通过）、V-04b（判据污染，未确认）、V-04d（不成立）；补入替代采集路径对照结果（`CGDisplayCreateImage`/`CGWindowListCreateImage` 稳定可用）。
- v0.3-draft 2026-11-18 10:40：**重要更正**。发现 v0.2 的 V-02 结论是假阴性——探针 `waitUntilUsable` 提前退出 + 脚本 `awk $3` 取错 ID，捕获从未执行。用户补充「锁屏 2-3 秒后屏睡」后重测：① 屏睡导致 SCK 无帧，caffeinate 先于 lock 可保持屏亮、SCK 恢复 50 帧；② 锁屏态虚拟屏实际 `active=1`（两种状态均是）；③ 截图显示虚拟屏上只有锁屏壁纸、无登录框。撤回「Path A 在 Tahoe 不成立」，改记「Path A 未验证」；V-04d 不成立理由从「不能建 active 屏」更正为「登录 UI 未迁移到虚拟屏」。
- v0.4-draft 2026-11-18 10:52：**Path A 端到端成立，结论翻转为通过**。v0.3 的「登录框未迁移」是假阴性——此前探针只建虚拟屏、未禁物理屏，登录 UI 自然留在物理屏。本次 r5/r6 两轮在锁屏+屏亮态禁掉全部物理屏后，虚拟屏截图出现完整登录 UI（日期/时钟/`bemin`/密码框），且无 focus 对照同样成立 → 迁移触发条件是「零 active 物理屏」，与光标无关。用户授权的真实凭据经 `P0V_PW` 环境变量在运行时注入，V-04b/c 干净通过（`INJECTION_ACCEPTED_AND_UNLOCKED`、256/256、会话 locked→unlocked），脚本/日志/文档均无明文密码。A-08/A-09 在 Tahoe 关闭，D-08 四项全过，不再回退 Path B。
