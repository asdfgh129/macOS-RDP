# soak 工具链（NFR-06）

72h 连续运行验收的驱动与采样脚本。

**拓扑（2026-11-27 定）**：**Sonoma 14 host（192.168.34.212）× Ventura 13 client（192.168.34.213）**。
选专用测试机而不是本机 Tahoe，是为了不把工作机独占 3 天；两台机同网段，不受 WAN 链路抖动干扰。
若要跑原定的 Tahoe host × Sequoia client 形态，脚本无需改动，换 IP/指纹即可（结论需按 OS 分开记录）。

## 组成

| 文件 | 跑在哪 | 作用 |
|---|---|---|
| `soak-client.sh` | client | 循环起 `VeilRD --connect --reconnect` 会话（每轮 30min），落每轮 JSON + 日志 + RSS 采样；自带 `caffeinate -d -i -u` 防屏睡 |
| `soak-host.sh` | host | 每 60s 采 `veild-host-agent` / `WindowServer`（+ `SOAK_EXTRA_PROCS`）的 CPU+RSS，每 10min 记 WindowServer PID，agent 消失/重生记事件 |
| `analyze-soak.py` | 任意 | 汇总：会话数、重连、丢帧率、控制面最大间隔、内存斜率、WindowServer 是否重启过 |

## 前置条件（缺一项 soak 就会给出假结论）

1. **host 走 GUI 会话启动 agent**（TCC 只对 GUI Terminal 继承）：
   `open -a Terminal /tmp/veild-run-host.command`，agent 以 `--max-sessions 2` 常驻，不要用 `p2.sh host`（单次会话即退出）。
2. **host 记下 `veild-host-agent` 启动横幅里的身份指纹**，client 的 `--fp` 必须是它（`host 证书指纹` 那行）。
3. **client 必须先关掉屏睡**：脚本自己会起 `caffeinate`，但机器若已锁屏仍要人工解锁一次。
4. **CLT-only 机器没有 Xcode**：`VeilRD` 客户端二进制要从本机 `/tmp/veilrd-xcode/Build/Products/Debug/VeilRD` 拷过去，用 `--bin` 指定路径。
5. host 侧不要跑任何独占测试/其他会话，soak 期间这两台机只做这件事。

## 跑法

host（agent 已常驻后）：

```bash
bash Scripts/soak/soak-host.sh 72 >/dev/null 2>&1 &
```

client（14 作 host 时的例子）：

```bash
bash Scripts/soak/soak-client.sh --host 192.168.34.212 --port 46600 --fp <FP_HEX> \
     --hours 72 --spec 1280x720 --bin /tmp/VeilRD
```

收尾 + 出报告：

```bash
python3 Scripts/soak/analyze-soak.py /tmp/veilrd-soak /tmp/veil-soak
```

## 判据（DESIGN NFR-06）

- 无内存泄漏：agent / client / WindowServer 的 RSS 小时斜率均 < ~10 MB/h（且 72h 总增幅 < 500MB）
- WindowServer PID 全程不变（一旦变化即拖挂事故，需按 RESULTS-BY-OS 记录）
- 丢帧率不随时间恶化；控制面最大间隔 < 8000ms（熔断阈值）
- 任何 SPI 挂起 8s 内熔断：日志中出现 `显示配置事务` 超时后进程不得再发起显示事务
- `host-events.csv` 里 `agent_missing` / `agent_restarted` 应为 0 条（无人值守可靠性）
