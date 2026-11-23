# RDPKit

ObjC 可复用库，host / client 共享逻辑。**第 2 轮已按职责分层，源码物理落在本目录**；旧 `M1-Skeleton/src/` 下是相对软链，不是副本。

| 子目录 | 模块 | 职责 |
|---|---|---|
| `Common/` | `M1PipelineTypes`、`M1WallClock` | 帧/错误类型、时间基准 |
| `Capture/` | `M1CapturePipeline` | SCK / CGDisplayStream / CGDisplayCreateImage 门控采集 |
| `Codec/` | `M1VideoEncoder` | VideoToolbox H.264 硬编、关键帧与 SPS/PPS |
| `Frame/` | `M1FramePipeline`、`M1FrameSender`、`M1FrameReceiver` | 帧管线编排、分片发送、重组与解码 |
| `Transport/` | `M1QuicTransport`、`M1DatagramSink`、`M1MessageSink`、`M1ControlLink`、`M1ControlChannel`、`M1ControlSession` | QUIC 数据面与控制消息通道 |
| `Control/` | `M1Pairing`、`M1Takeover`、`M1SessionCoordinator` | 配对、现场接管、独占会话生命周期 |
| `Display/` | `M1RDPDriver`、`M1DriverLogic`、`M1WindowLayout`、`M1ScreenLock`、`M1FrameView` | 建屏/禁屏驱动、隔离判定、布局、锁屏、零拷贝上屏 |
| `Input/` | `M1InputLogic`、`M1InputInjector` | 坐标/flags 映射、注入计划与 CGEvent 注入 |
| `Session/` | `M1StreamSession`（`M1StreamNode` / `M1StreamClientNode`） | QUIC + 控制链路 + 会话状态机 + 重组解码的共享节点层；第 4 轮从 `stream_probe` 抽出，产品两端与探针共用 |
| `Platform/`（工程分组） | `P0VDisplayControl`、`VDManager`、`ProbeUtil` | 来自探针目录的三个平台源文件，仅为让 `M1RDPDriver` 在静态库中解析符号；源码未搬动 |

每个子目录同时放 `.h` / `.m`；`#import` 仍使用裸文件名，头搜索路径由各构建脚本的 `-I` 与 Xcode 的 `HEADER_SEARCH_PATHS` 提供。新增模块时按职责选目录，不要写回旧 `src/` 软链层。

新增模块后须先改 `Scripts/generate_xcodeproj.py` 再重跑生成 pbxproj，勿手改工程文件（D-21）。

设计约束见 `docs/DESIGN.md` §2.4.1 / §4.1 与 `docs/DECISIONS.md` D-09 / D-10 / D-17 / D-21。
