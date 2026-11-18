# macOS-RDP 实测结论（按 OS 分离）

| 项 | 值 |
|---|---|
| 版本 | v0.2-draft |
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
| V-02 | 未测 | ⚠️ **更正为「建屏成立、登录 UI 未验证」**：此前 `active=false` 是探针在 `waitUntilUsable` 提前退出 + 脚本 `awk $3` 取错 ID 造成的**假阴性**（捕获从未执行）。修正探针后：锁屏+屏睡态与锁屏+屏亮态，虚拟屏均为 `online=1 / active=1`；`/tmp/tahoe-20261118-r3-sleep-direct.json`、`/tmp/tahoe-20261118-r4-capture.json` |
| V-02 采集（屏睡态） | 未测 | SCK `NO_FRAMES_TCC_OR_STALE`；`CGDisplayCreateImage` `HAS_CONTENT` mean=163；但截图仅为**锁屏壁纸、无登录框**（`/tmp/tahoe-r3-lockscreen.png`） |
| V-02 采集（屏亮态） | 未测 | SCK `HAS_CONTENT` 50 帧；`CGDisplayCreateImage` / `CGWindowListCreateImage` 均 `HAS_CONTENT`（mean 148/149 var 1639/1514）；截图仍**仅壁纸、无登录框**（`/tmp/tahoe-20261118-r4-lockscreen.png`） |
| V-04d | 未实现 | ⚠️ **不成立但理由更正**：虚拟屏能 active，但登录 UI 没有迁移到虚拟屏（两态截图均只有壁纸）。`CGWindowListCreateImage` 在屏亮态 `HAS_CONTENT` 是壁纸内容，不是登录框 |
| 证据 | — | `/tmp/tahoe-20261118-r4-t{0,1,2,3,5}.json`、`/tmp/tahoe-20261118-r4-capture.json`、`/tmp/tahoe-r3-lockscreen.png`、`/tmp/tahoe-20261118-r4-lockscreen.png` |

---

## 4. V-04 远程登录（D-08）

| 项 | Sequoia 15.5 | Tahoe 26.5.2 |
|---|---|---|
| root LaunchDaemon 路径 | ❌ 失败：TCC 只记路径条目（`client_type=1`），`axTrusted=0`，SCK 6s 超时；无 GUI 会话 | 未重测（已知门槛是 TCC 身份与 GUI 会话归属，不是 root 特权） |
| V-04a 用户态锁屏捕获 | ✅ 真实登录界面，`HAS_CONTENT` | ✅ 通过：`session.screenIsLocked=true`、`HAS_CONTENT`、17 帧、`minMean=134`、0 黑帧（`/tmp/tahoe-20261118-r2-v04a.json`） |
| V-04b 用户态定向注入 | ✅ `INJECTION_ACCEPTED_UI_CHANGED`，152/256 格变化 | ⚠️ **未确认**：r1 的 `aa`+Return 后用户手动解锁，判据被污染；r2 改用长错误密码但抓屏时会话已解锁、256/256 格无变化。需在全程锁屏下重测 |
| V-04c 正确密码解锁 | ⏸ 主动跳过、记为未测（需真实凭据） | 同样跳过，不向助手提供密码 |
| V-04d 登录窗建屏+禁屏 | 未实现 | ⚠️ 不成立：虚拟屏可 active，但登录 UI 未迁移到虚拟屏（见 §3.3） |
| 结论 | loginwindow 不阻止用户会话进程捕获/定向注入；推荐形态改为正确签名的用户态 App | **2026-11-18 10:40 更正**：撤回「Path A 在 Tahoe 不成立」的过度推论。已证：① 锁屏态虚拟屏可 active；② 锁屏+屏亮时 SCK 可捕获 50 帧；③ 屏睡是 SCK 无帧的原因，caffeinate 先于 lock 可避免。未证：登录框是否渲染到虚拟屏（截图仅壁纸）、V-04b 干净重测、V-04c。**Path A 应记为「未验证」，不是「失败」** |

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
| A-08 物理屏全禁后仍可建屏/捕获/注入 | ✅ 核心关闭（SCK OK） | ⚠️ 部分：V-01 关闭；V-03 机制通过但 SCK 采集不可靠；V-02 建屏成立、登录 UI 未证；替代采集路径可行但未接入 |
| A-09 锁屏/登录窗可远程进入 | V-04a/b ✅、V-04c 未测、V-04d 未实现 | V-04a ✅、V-04b 未确认、V-04c 未测、V-04d ⚠️ 登录 UI 未迁移到虚拟屏；**Path A 未验证（非失败）**；关键新发现：锁屏后 2-3s 显示睡眠导致 SCK 无帧，caffeinate 可避免 |
| A-02 glass-to-glass 延迟 | 未测 | 未测 |

---

## 7. 变更记录

- v0.1-draft 2026-11-18：首次建立按 OS 分离的结论表；把 Sequoia 与 Tahoe 的 V-01/V-03/V-04 结论拆开，明确禁止跨版本外推。
- v0.2-draft 2026-11-18：补入 Tahoe V-02（锁屏态虚拟屏 `active=false`，不成立）、V-04a（通过）、V-04b（判据污染，未确认）、V-04d（不成立）；补入替代采集路径对照结果（`CGDisplayCreateImage`/`CGWindowListCreateImage` 稳定可用）。
- v0.3-draft 2026-11-18 10:40：**重要更正**。发现 v0.2 的 V-02 结论是假阴性——探针 `waitUntilUsable` 提前退出 + 脚本 `awk $3` 取错 ID，捕获从未执行。用户补充「锁屏 2-3 秒后屏睡」后重测：① 屏睡导致 SCK 无帧，caffeinate 先于 lock 可保持屏亮、SCK 恢复 50 帧；② 锁屏态虚拟屏实际 `active=1`（两种状态均是）；③ 截图显示虚拟屏上只有锁屏壁纸、无登录框。撤回「Path A 在 Tahoe 不成立」，改记「Path A 未验证」；V-04d 不成立理由从「不能建 active 屏」更正为「登录 UI 未迁移到虚拟屏」。
