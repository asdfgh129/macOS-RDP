# Scripts

统一入口（第 1 轮建立，第 4 轮补齐工程生成器）：

- `build.sh`：`bash Scripts/build.sh` 构建 `RDPKit`、`ProtocolCodec` 两个静态库与 `veild-host-daemon`、`veild-host-agent`、`VeilRD` 三个入口；也可传单个 scheme。默认 `Debug`，可用 `CONFIGURATION=Release` 与 `DERIVED_DATA=<path>` 覆盖。
- `test.sh`：`bash Scripts/test.sh` 依次跑 `M1-Skeleton/build_tests.sh`、`P1-ClientProbe/build_tests.sh` 与 `Tests/integration_selftest.sh`（含 QUIC 环回建链自检），仅纯开发自检，不触发双机真机。
- `generate_xcodeproj.py`：`python3 Scripts/generate_xcodeproj.py` 重新生成 `VeilRD.xcodeproj/project.pbxproj`（五个 target）。新增模块 / 框架 / 头文件路径时改这里再重跑，勿手改 pbxproj。

原始探针脚本仍保留在各目录内（`M1-Skeleton/build_*.sh`、`P1-ClientProbe/build_tests.sh`、`RDPApp/build.sh`、`P2-Dual/p2.sh`），双机 runbook 路径不受影响。第 2 轮源码迁到 `Packages/` 后，这些脚本通过旧 `src/` 兼容软链继续找到头文件与源码，无需改路径。
