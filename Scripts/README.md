# Scripts

第 1 轮工程骨架已落地的统一入口：

- `build.sh`：`bash Scripts/build.sh` 构建 `veild-host-daemon`、`veild-host-agent`、`VeilRD`；也可传单个 scheme。默认 `Debug`，可用 `CONFIGURATION=Release` 与 `DERIVED_DATA=<path>` 覆盖。
- `test.sh`：`bash Scripts/test.sh` 依次跑 `M1-Skeleton/build_tests.sh` 与 `P1-ClientProbe/build_tests.sh`，仅纯开发单测，不触发双机真机。

原始探针脚本仍保留在各目录内（`M1-Skeleton/build_*.sh`、`P1-ClientProbe/build_tests.sh`、`RDPApp/build.sh`、`P2-Dual/p2.sh`），双机 runbook 路径不受影响。第 2 轮源码迁到 `Packages/` 后，这些脚本通过旧 `src/` 兼容软链继续找到头文件与源码，无需改路径。
