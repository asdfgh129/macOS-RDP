# macOS-RDP 控制协议 v1（草案）

| 项 | 值 |
|---|---|
| 版本 | protocol v1 |
| 日期 | 2026-11-16；2026-11-18 11:20 冻结 |
| 状态 | **已冻结（2026-11-18 11:20），作为 M1 基线**。D-01（QUIC datagram）、D-09（采集主路径）已确认；帧通道握手/ALPN/拥塞控制在 M1 实现中按 §7 落地，不再阻塞冻结 |
| 上位文档 | `docs/DESIGN.md` §3.2 / §4.3 / §5 |

---

## 1. 通道与端口

| 通道 | 传输 | 默认端口 | 内容 |
|---|---|---|---|
| 控制通道 | TLS 1.3 over TCP | 47990 | 配对、信令、输入事件、心跳、关键帧请求 |
| 帧通道 | **QUIC over UDP（unreliable datagram，D-01 已定）** | 47991/udp | 编码帧分片 |
| 发现 | Bonjour/mDNS `_macos-rdp._tcp` | — | Host 广播：名称、协议版本范围、配对状态 |

控制通道消息：4 字节大端长度前缀 + UTF-8 JSON。帧通道二进制头见 §4。
协议版本协商：`hello` 携带 `protoMin/protoMax`，双方取交集最大值；无交集 → `bye{reason:"PROTO_MISMATCH"}`。

## 2. 会话状态机

```
DISCOVERED → TLS_CONNECTED → PAIRED → NEGOTIATED → DISPLAYS_READY → STREAMING
     任意状态 ──bye/error──► CLOSED；STREAMING ──心跳超时──► SUSPENDED ──重连──► NEGOTIATED
```

- 配对（首次）：Host 生成 6 位配对码（本地日志/接屏显示），Client `pair-request{code}` → Host `pair-confirm{certFingerprint}`；双方存对方证书指纹（Keychain），后续连接 TOFU 校验，指纹变更必须重新配对。
- 已配对重连：TLS 握手后 `hello` 携带指纹，校验通过直接 `session-resume`，Host 保留虚拟屏与桌面状态。
- 心跳：双向 `heartbeat` 每 1s；5s 未收到 → 判断断线。Client 指数退避重连（1s 起，上限 10s）；Host 会话待命 60s 不销毁桌面，超时后 `teardown` 但保留配对。

## 3. 控制消息（JSON）

公共字段：`{"v":1, "type":"...", "seq":N, ...}`；`seq` 单调递增，响应消息带 `ack:N`。

| type | 方向 | 载荷 | 说明 |
|---|---|---|---|
| `hello` | 双向 | `protoMin, protoMax, certFingerprint, role, osVersion, arch` | TLS 建立后首条；arch 必须 x86_64 |
| `pair-request` | C→H | `code` | 仅首次配对 |
| `pair-confirm` | H→C | `certFingerprint, hostName` | 配对成功 |
| `capabilities` | H→C | `maxDisplays, maxResolution, hidpi, encoders[], safePoints[]` | 协商依据；safePoints 含 4096×2304@55 |
| `session-start` | C→H | `specs:[{w,h,hidpi,refresh}], bitrateKbps, fps` | 请求建屏 |
| `session-resume` | C→H | `sessionID` | 重连恢复 |
| `session-ready` | H→C | `sessionID, displays:[{displayID,w,h}]` | 全部屏 liveness+SCK 可见后才发 |
| `session-update` | C→H | `specs[]` | 动态改分辨率/屏数；Host 事务性执行，失败回滚并 `session-error` |
| `session-error` | H→C | `code, detail, recoverable` | 错误码见 §5 |
| `input` | C→H | 见 §3.1 | 高频，不要求 ack |
| `keyframe-request` | C→H | `displayID` | 丢帧/解码失败/重连后 |
| `keyframe-sent` | H→C | `displayID, frameSeq` | 响应确认 |
| `heartbeat` | 双向 | `ts` | 1s |
| `time-sync` | C→H | `t0` | 客户端本地 epoch 微秒；仅 STREAMING 态 |
| `time-sync-reply` | H→C | `t0, t1` | Host 收到即回：原样带回 `t0`，`t1` 为 Host 本地 epoch 微秒 |
| `bye` | 双向 | `reason` | 正常关闭 |

**时钟差估计（A-02 打点）**：客户端发送记 `t0`，Host 收到即回并记 `t1`，客户端收到记 `t2`；
`RTT = t2 − t0`（含 Host 处理，通常 <1 ms），`offset = t1 − (t0+t2)/2`，只保留 **最小 RTT** 的样本，
`RTT > 5000 ms` 丢弃。该 offset 用于把帧头里的采集时刻换算到客户端时基；不逐帧修正，
也不参与渲染调度。

### 3.1 input 载荷

```json
{"type":"input","seq":N,"displayID":4128835,"event":{
  "kind":"mouse|key|scroll|flags",
  "displayID":4128835,        // 与消息层同值；两处都带，读任一处均可（见下）
  "x":0.0,"y":0.0,            // 归一化 0..1（相对目标虚拟屏，Renderer 已做坐标变换）
  "button":"left|right|other", "action":"down|up|move|drag",
  "keyCode":0, "unicode":"",   // key：keyCode 为主，IME 组合串走 unicode（A-03）
  "flags":{"cmd":0,"shift":0,"opt":0,"ctrl":0,"caps":0},
  "dx":0.0,"dy":0.0            // scroll
}}
```

- **`displayID` 的位置**：消息层与 `event` 内**都写**，接收方读任一处均可。
  冻结时（2026-11-17）文档写在消息层，而 `P1InputCodec` 实现放在 `event` 内；
  2026-11-18（D-17 C-17.3）改为发送时两处都带、接收时 `event` 内缺失则回落到消息层，
  消除「照文档实现就对不上」的坑。`kind:"flags"` 的 `displayID` 记为 0（不参与屏坐标）。
- 坐标一律归一化传输，Host 侧乘以目标屏实际 points 尺寸——分辨率协商变化不影响输入通路。
- 仅 STREAMING 态收发：非该态发送方丢弃并计数，接收方丢弃并计数，都不视为协议错误。
- 修饰键采用**状态同步**而非逐事件转发：Client 维护状态机，变化时发 `kind:"flags"` 全量；重连后必发一次全量复位。
- Host 注入速率限制：单会话 ≤ 1000 event/s，超限丢弃 move 类（保留 down/up/key）。

## 4. 帧通道二进制头（v3：26 字节，大端）

| 偏移 | 字段 | 宽度 | 说明 |
|---|---|---|---|
| 0 | magic `MR` | 2 | 0x4D52 |
| 2 | version | 1 | 当前 **3**（与控制通道 JSON 的 `v` 相互独立） |
| 3 | flags | 1 | bit0=keyframe, bit1=帧末分片, bit2=含 SPS/PPS |
| 4 | displayID | 4 | 对应虚拟屏（`CGDirectDisplayID` 是 32 位，实测可达 0x78CD0400，不能压成 16 位） |
| 8 | frameSeq | 4 | 单调递增，重组与丢帧判据 |
| 12 | fragIdx | 2 | 分片序号 |
| 14 | fragCount | 2 | 总分片数（≤65535，单帧 ≈75MB） |
| 16 | payloadLen | 2 | 本分片载荷字节数（≤1150，见下方 D-01 说明） |
| 18 | capturedAtUs | 8 | Host 采集时刻（Unix epoch 微秒）；0 表示未知 |

**v1 → v2 变更（2026-11-18）**：`fragIdx/fragCount` 由 1 字节扩为 2 字节，帧头 16B→18B。
原因是 v1 的单帧上限 255×1150 B ≈ 286 KB，而 3440×1440 的关键帧会超过它，
`P1FragmentPayload` 直接拒发 ⇒ 整帧发不出去 ⇒ 接收端只能等下一个关键帧（实测首帧 4069 ms）。

**v2 → v3 变更（2026-11-22，A-02 打点）**：新增 64-bit `capturedAtUs`，帧头 18B→26B。
Host 在把像素缓冲交给编码器时打点，编码回调按 PTS 回填到 `M1EncodedFrame`；Client 用该值作为
解码 sample buffer 的 PTS，VT 输出回调带回，最终在 `M1FrameView` 贴层处与本地 epoch 相减，
得到 **capture→render** 延迟（原始差可能为负，报告时再加回 `time-sync` 估出的 host−client 时钟差）。
该指标不含显示器扫描与摄像头采样，不能等同于 glass-to-glass，只用于定位管线内延迟。

v2 及更早帧头一律按 `BadVersion` 拒绝，不做兼容回退（双端始终同版本构建）。
`payloadLen` 上限仍是 1150，分片预算不变：26+1150=1176 < 1497 协商下限。

载荷：AVCC（长度前缀 NALU）；关键帧分片带 SPS/PPS（flags bit2）。`capturedAtUs` 随帧头传，仅用于延迟打点，不参与渲染调度。

丢帧策略：FrameReceiver 检测 frameSeq 缺口 → 丢弃该帧全部分片 → `keyframe-request`；解码器在关键帧到达前不产出。旧帧迟到直接丢弃（实时性优先）。已由 `P1FrameReassembler` 实现并单测。

**D-01 补充**：帧通道已定为 QUIC datagram（`nw_quic_set_stream_is_datagram`）。QUIC short header + AEAD tag 约 20–30 B，分片上限已按 **1150 B** 下调（`P1FrameMaxPayload`），为 1200 B MTU 留出头部余量；帧头 payloadLen 与分片器共用该常量，并已同步单测。

## 5. 错误码（session-error.code）

| code | 含义 | recoverable |
|---|---|---|
| `CREATE_FAILED` | 建屏失败（identity 被拒等） | 是（换 identity/降规格） |
| `MODE_COMMIT_FAILED` | mode 未落地 | 是 |
| `LIVENESS_FAILED` | online/active/镜像异常 | 是 |
| `VISIBILITY_FAILED` | SCK 不可见 | 是（Tahoe identity walk） |
| `ENCODER_STALLED` | 编码会话无产出（PR #288 陷阱） | 是（降分辨率重建） |
| `WINDOWSERVER_SPI_TIMEOUT` | SPI 熔断 | **否，Host 整体重建，Client 停连并提示** |
| `PROTO_MISMATCH` / `AUTH_FAILED` / `SPEC_UNSUPPORTED` | 协商类 | 否 |

## 6. 安全要求

- 控制通道强制 TLS 1.3；帧通道由 **QUIC 的 TLS 1.3** 提供加密与身份校验（D-01 已定，不再自研 AES-GCM）。
- 未配对指纹的连接在 `hello` 后即断；配对码 5 分钟有效、试错 5 次锁定 10 分钟。
- 输入注入仅接受 STREAMING 态会话；`bye`/断线后立即清空修饰键状态。

## 7. 待决与变更

- D-01 已决（2026-11-17，QUIC datagram）；**v1 已冻结（2026-11-18 11:20）**。帧通道实现细则（ALPN `macos-rdp-v1`、idle timeout 30s、max UDP payload 1200B、分片上限 1150B）见 D-01 与 §4，由 M1 按此实现，不再作为冻结前置；拥塞控制使用 Network.framework 默认策略，P2 双机实测后再评估调优。
- 光标通道（FR-10, P2）预留 `type:"cursor"`，本期不实现。
- 变更记录：v1.1-draft 2026-11-18 **§3.1 明确 `displayID` 位置（两处都带）+ 只在 STREAMING 态收发**，实现见 D-17；v1-draft 2026-11-16 首次起草；2026-11-17 按 D-01 更新 §1/§4/§6/§7（帧通道 = QUIC datagram）；2026-11-18 分片上限由 1200 下调为 1150 B，并补齐 §3.1 输入编解码与 §2 状态机的单测实现；2026-11-18 11:20 **冻结为 v1**（评审通过，M1 基线），QUIC 实现细则以 D-01 为准，双机端到端实测转入 P2 验收；2026-11-22 **帧头 v3（26B，内嵌 `capturedAtUs`）+ 控制通道 `time-sync`/`time-sync-reply`**，为 A-02 提供 capture→render 打点（JSON `v` 不变）。