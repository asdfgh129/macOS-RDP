# soak 工具链（NFR-06）

72h 连续运行验收的驱动与采样脚本。拓扑固定为 **Tahoe host × Sequoia client**（WAN）。

## 组成

| 文件 | 跑在哪 | 作用 |
|---|---|---|
| `soak-client.sh` | client | 循环起 `VeilRD --reconnect` 会话（每轮 30min），落每轮 JSON + 日志 + RSS 采样 |
| `soak-host.sh` | host | 每 60s 采 `veild-host-agent` / `WindowServer` 的 CPU+RSS，每 10min 记 WindowServer PID |
| `analyze-soak.py` | 任意 | 汇总：会话数、重连、丢帧率、控制面最大间隔、内存斜率、WindowServer 是否重启过 |

## 跑法

host（agent 由 `Scripts/host-deploy/run-host.command` 常驻）：

```bash
bash Scripts/soak/soak-host.sh 72 >/dev/null 2>&1 &
```

client：

```bash
bash Scripts/soak/soak-client.sh 112.5.32.34 46600 <FP_HEX> 72 --spec 1280x720
```

收尾：

```bash
python3 Scripts/soak/analyze-soak.py /tmp/veilrd-soak /tmp/veil-soak
```

## 判据（DESIGN NFR-06）

- 无内存泄漏：agent / client / WindowServer 的 RSS 小时斜率均 < ~10 MB/h（且 72h 总增幅 < 500MB）
- WindowServer PID 全程不变（一旦变化即拖挂事故，需按 RESULTS-BY-OS 记录）
- 丢帧率不随时间恶化；控制面最大间隔 < 8000ms（熔断阈值）
- 任何 SPI 挂起 8s 内熔断：日志中出现 `显示配置事务 8s 未返回` 后进程不得再发起显示事务
