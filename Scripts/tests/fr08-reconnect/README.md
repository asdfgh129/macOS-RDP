# FR-08 断网重连验收（客户端侧 pf 阻断）

把「拔网线」做成可复现的本地实验：pf 双向 drop 目标 host + 清 UDP states。
单项 `ifconfig down`、blackhole route、单向 pf 都验证过**无效**（见 RESULTS-BY-OS §5.45 A）。

## 前置

- 客户端先 `sudo -v` 取得 pf 授权（脚本用 `sudo -n`，不会交互、不含任何口令）。
- host 已以 `--max-sessions 0 --duration-ms 86400000` 常驻，客户端 `VeilRD` 已构建。

## 用法

```bash
sudo -v
bash Scripts/tests/fr08-reconnect/run-reconnect-test.sh \
  112.5.32.34 46600 <HOST_FP_HEX> 12          # 默认双向断路 12s
bash Scripts/tests/fr08-reconnect/run-reconnect-test.sh ... 12 --one-way
```

产物：`/tmp/fr08/{reconnect.log,reconnect.json}`。

## 判定

- 断路期间：ping 100% 丢；客户端 ≤8.8s 打印 `控制面静默`；
- 恢复后：`重连成功`，JSON `reconnects>=1`、`framesDropped` 不随时间恶化；
- 断言：**不得**出现 `控制链路失败 ... 断线重连 0 次`（僵尸 STREAMING 回归）。
