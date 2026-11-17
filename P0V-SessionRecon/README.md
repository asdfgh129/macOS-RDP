# P0V-SessionRecon — 独占式会话能力侦察（2026-11-17）

## 为什么有这个工程

2026-11-17 需求澄清推翻了一份文档结论：

> 起初就说不要 VNC 式的镜像模式。被控端的屏幕跟控制端的屏幕可能完全不一样，而且无论被控端有几块屏幕，
> 在控制端都显示在一块屏幕中，使用体验非常差。**我所要的就是会话模式：控制端登录了，被控端就锁屏。
> 完全不需要去捕获物理屏。**

因此本工程要回答一个此前从未被认真问过的问题：

**在 Intel Mac 上，「客户端登入 → 被控端置黑/锁定 → 客户端看到自己规格的桌面」这件事，到底能不能做？**

答案（本机实测 + 官方文档 + entitlement 取证）：**行为能，Windows RDP 式的"多会话并发"不能。** 两者不是同一件事。

---

## 一、决定性事实

### 1.1 Apple 自己就是这么做的（官方文档原文）

Apple 支持文档《Screen sharing type options on Mac》（macOS 14+）：

> If you sign in as the user logged in to the Mac you want to access, **the hardware displays connected to that
> Mac are blanked**, which gives you privacy … This also means **no one else can use that Mac** while you're using
> High Performance screen sharing.
>
> Display Type — **The number of virtual displays.** This option is only available with High Performance screen sharing.
> **High Performance is available on Mac computers with Apple silicon and macOS Sonoma 14 or later.**

三条关键信息：

1. **客户端选虚拟屏数量与分辨率，物理屏直接置黑** —— 这正是本项目要的语义，不是镜像。
2. 它**没有新建会话**：同一个登录会话，物理屏被置黑而已（"别人不能用这台 Mac"就是独占）。
3. **仅 Apple Silicon**。Intel 上 Apple 不提供，所以只能自己实现等价能力 —— 这就是我们存在的理由。

### 1.2 真正的"多会话并发"在 macOS 上不存在（第三方不可得）

本机 entitlement 取证（`codesign -d --entitlements -`）：

| 二进制 | 相关 entitlement | 含义 |
|---|---|---|
| `loginwindow` | **`com.apple.private.aqua.createSession`** | 创建 Aqua 会话的**唯一**授权方 |
| `loginwindow` | `com.apple.private.sessionagent.sessionowner` | 对应 `SLSessionOwner` |
| `loginwindow` | `com.apple.private.SkyLight.displaycontrol` | 显示控制 |
| `ARDAgent` | `com.apple.private.screensharing.screenControl` | 屏幕控制 |

`com.apple.private.aqua.createSession` 是 Apple 私有 entitlement，**第三方签名无法获得**。
所以 Windows RDP 那种「一个新会话、独立桌面、可与 console 并存」在 macOS 上对第三方封闭。

但**产品不需要它**：用户要的是"我登入后别人不能用、我看到的是自己规格的桌面"，
这在单会话内用「虚拟屏 + 物理屏置黑 + 锁定」即可达成，且 Apple 自己就是这条路。

### 1.3 需要的私有能力，本机全部存在

`bash run.sh --test-config` 实测（26.5.2 / 25F84 / x86_64）：

| 组 | 能力 | 结果 |
|---|---|---|
| 会话 | `SLSCopySessionList` / `SLSCopyCurrentSessionDictionary` | **可调**，返回真实数据（`kCGSSessionOnConsoleKey=1`） |
| 会话 | `SLSCreateSession*` / `SLSMoveSessionToConsoleTemporaryBridge` | 符号存在（不作为产品路径） |
| 会话 | `SLSessionOwner +sessionOwnerForNewSessionWithAuditSessionID:` | 存在（需 Apple 私有 entitlement，**放弃**） |
| 显示 | **`SLSConfigureDisplayEnabled`** | 存在 —— 这就是"禁用/置黑物理屏"的入口 |
| 显示 | `SLSConfigureDisplayMirrorOfDisplay` / `Mode` / `Origin` | 存在 |
| 显示 | `CGBeginDisplayConfiguration` → `CGCancelDisplayConfiguration` | **实测可开事务并可取消**（`cancel=0`），说明我们能进入配置事务 |
| 锁屏 | `SACLockScreenImmediate`（login.framework） / `SLSDeviceLock` | 存在 |
| 建屏 | `CGVirtualDisplay`（P0 已验证） | 可用，2 物理 + 4 虚拟 = 6 屏同时在线 |

结论：**实现独占式会话所需的每一块积木都在本机可得**，唯一已知封锁点是"新建会话"，而我们不需要它。

---

## 二、因此架构怎么定

```
启动：auto-login 到专用账号 → 立即锁屏（SACLockScreenImmediate）
连接：客户端认证（账号口令 / 已配对密钥）
  ├─ 解锁会话（凭据，非"绕过"）
  ├─ 按客户端规格建 N 块 CGVirtualDisplay（客户端要几块、多大，就几块多大）
  ├─ 把物理屏禁用/置黑（SLSConfigureDisplayEnabled，事务提交）
  ├─ 只捕获虚拟屏（SCK），H.264 硬编 → QUIC datagram
  └─ 注入键鼠到会话
断开：销毁虚拟屏 → 恢复物理屏 → 重新锁屏
```

被控端有几块物理屏、什么分辨率，**完全不参与**客户端看到的画面。这就是"会话模式"。

## 三、还没证明的两件事（P0-V 必须关掉）

| 编号 | 待验证 | 风险 | 验证方式 |
|---|---|---|---|
| **V-01** | `SLSConfigureDisplayEnabled` 禁用物理屏后，虚拟屏仍可正常捕获、桌面不重排错乱 | 中（会把显示器关掉，需人工在场） | 事务内禁用一块物理屏 → 采集仍 `HAS_CONTENT` → 恢复 |
| **V-02** | 会话处于锁屏状态时，能否建虚拟屏并采集；解锁时机与凭据流程 | 高（若锁屏即阻断，需改为"先解锁再建屏"） | 锁屏 → 建屏 → 采集，观察 SCK 行为 |

失败回退：V-01 若私有入口被 WindowServer 拒绝，退化为**公开 API 方案** ——
`CGDisplayCapture` 独占物理屏 + 高窗口层不透明遮罩覆盖，并把"非绝对安全"写入产品说明。

---

## 四、与上一版文档的冲突（已修正）

`P0-TahoeProbe/README.md` §16.2/§16.3 曾把「捕获优先：有屏就直接采」写成 D-03 决策。
**那是镜像模式，与产品定位直接冲突，已作废**，由 `docs/DECISIONS.md` 的 D-04 取代。
§16.1 的多屏容量实测（虚拟屏不占 Intel DDI 通道）仍然有效且有用：它证明客户端要几块就能给几块。

## 五、运行

```bash
bash run.sh                 # 只读侦察
bash run.sh --test-config   # 额外验证「开显示事务 → 取消」（不提交变更）
```
