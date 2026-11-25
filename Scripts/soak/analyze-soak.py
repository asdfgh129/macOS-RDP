#!/usr/bin/env python3
"""汇总 72h soak 产物（NFR-06）：会话统计 + 内存斜率 + WindowServer 稳定性。

用法：python3 analyze-soak.py /tmp/veilrd-soak [host 产物目录 /tmp/veil-soak]
"""
import glob, json, os, sys, statistics

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None

def rss_slope(csv_path, process=None):
    """线性回归 RSS(KB)→per-hour 斜率，返回 (首值, 末值, KB/h)。"""
    xs, ys = [], []
    with open(csv_path) as f:
        next(f)
        for line in f:
            parts = line.strip().split(",")
            if len(parts) < 3:
                continue
            if process and process not in parts:
                continue
            try:
                xs.append(int(parts[0])); ys.append(int(parts[-1]))
            except ValueError:
                continue
    if len(xs) < 3:
        return None
    n = len(xs); mx = sum(xs)/n; my = sum(ys)/n
    den = sum((x-mx)**2 for x in xs)
    if den == 0:
        return None
    slope_per_s = sum((x-mx)*(y-my) for x, y in zip(xs, ys)) / den
    return ys[0], ys[-1], slope_per_s * 3600 / 1024

def main():
    cdir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/veilrd-soak"
    hdir = sys.argv[2] if len(sys.argv) > 2 else "/tmp/veil-soak"

    runs = [load(p) for p in sorted(glob.glob(os.path.join(cdir, "client-*.json")))]
    runs = [r for r in runs if r]
    print(f"客户端轮次: {len(runs)}")
    if runs:
        reconnects = sum(r.get("reconnects", 0) for r in runs)
        decoded = sum(r.get("framesDecoded", 0) for r in runs)
        dropped = sum(r.get("framesDropped", 0) for r in runs)
        gaps = [r.get("maxControlGapMs", 0) for r in runs if "maxControlGapMs" in r]
        print(f"  断线重连合计: {reconnects}")
        print(f"  帧 decoded={decoded} dropped={dropped} 丢帧率={dropped/max(decoded+dropped,1):.4%}")
        if gaps:
            print(f"  控制面最大间隔: max={max(gaps):.0f}ms median={statistics.median(gaps):.0f}ms")
        bad = [r for r in runs if r.get("framesDecoded", 0) == 0]
        print(f"  零解码轮次（连上没出图）: {len(bad)}")

    cslope = rss_slope(os.path.join(cdir, "client-rss.csv"))
    if cslope:
        print(f"客户端 RSS: {cslope[0]}KB → {cslope[1]}KB（{cslope[2]:+.1f} KB/h）")

    hcsv = os.path.join(hdir, "host-rss.csv")
    if os.path.exists(hcsv):
        a = rss_slope(hcsv, "veild-host-agent")
        w = rss_slope(hcsv, "WindowServer")
        if a: print(f"agent RSS: {a[0]}KB → {a[1]}KB（{a[2]:+.1f} KB/h）")
        if w: print(f"WindowServer RSS: {w[0]}KB → {w[1]}KB（{w[2]:+.1f} KB/h）")
    wcsv = os.path.join(hdir, "ws-pid.csv")
    if os.path.exists(wcsv):
        pids = set()
        with open(wcsv) as f:
            next(f)
            for line in f:
                pids.add(line.strip().split(",")[-1])
        print(f"WindowServer PID 变化: {len(pids)} 个（>1 即发生过重启）: {sorted(pids)}")

if __name__ == "__main__":
    main()
