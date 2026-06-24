#!/usr/bin/env python3
# Shared parser/aggregator for the Sonar cold-start benchmark.
# Reads $OUT_DIR/run_*.ndjson (+ run_*.launch) and prints a per-phase table.
import json, os, re, statistics
from datetime import datetime

out_dir = os.environ["OUT_DIR"]
runs = int(os.environ.get("RUNS", "0")) or 9999

def parse_ts(s):
    return datetime.strptime(s, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()

MARKERS = ["t0_launch", "t1_local_paint", "t2_relay_connect_begin",
           "t3_relay_connected", "t4_first_drain"]

rows = []
for i in range(1, runs + 1):
    f = os.path.join(out_dir, f"run_{i}.ndjson")
    if not os.path.exists(f):
        continue
    launch_f = os.path.join(out_dir, f"run_{i}.launch")
    launch_epoch = None
    if os.path.exists(launch_f):
        try: launch_epoch = float(open(launch_f).read().strip())
        except Exception: pass
    times, drain_meta = {}, ""
    for line in open(f):
        line = line.strip()
        if not line:
            continue
        try: obj = json.loads(line)
        except Exception: continue
        msg, ts = obj.get("eventMessage", ""), obj.get("timestamp", "")
        for m in MARKERS:
            if m in msg and m not in times:
                try: times[m] = parse_ts(ts)
                except Exception: pass
                if m == "t4_first_drain":
                    mm = re.search(r"woke=(\d+) notif=(\d+)", msg)
                    if mm: drain_meta = f"woke={mm.group(1)} notif={mm.group(2)}"
    times["_launch"] = launch_epoch
    times["_drain_meta"] = drain_meta
    rows.append((i, times))

def fmt(ms):
    return "    n/a" if ms is None else f"{ms:8.0f}"

PHASES = [
    ("launch → t0  (process+SwiftUI init)", "_launch", "t0_launch"),
    ("t0 → t1      (open DB, local paint) ", "t0_launch", "t1_local_paint"),
    ("t1 → t2      (pre-relay delay)      ", "t1_local_paint", "t2_relay_connect_begin"),
    ("t2 → t3      (relay quorum connect) ", "t2_relay_connect_begin", "t3_relay_connected"),
    ("t3 → t4      (initial sync drain)   ", "t3_relay_connected", "t4_first_drain"),
    ("TOTAL launch → t4 (cold → synced)   ", "_launch", "t4_first_drain"),
    ("TOTAL t0 → t4     (in-app → synced) ", "t0_launch", "t4_first_drain"),
]

print()
print("=" * 78)
print(f"  Sonar iOS cold-start + Marmot sync benchmark — {len(rows)} run(s)")
print("=" * 78)
for i, t in rows:
    print(f"  run {i}: t4 {t.get('_drain_meta') or '(no t4 captured)'}")
print("-" * 78)
print("  phase".ljust(40) + "    min      med      max   (ms)")
print("-" * 78)
for label, a, b in PHASES:
    vals = []
    for _, t in rows:
        ta, tb = t.get(a), t.get(b)
        if ta is not None and tb is not None:
            vals.append((tb - ta) * 1000.0)
    if vals:
        print(f"  {label}".ljust(40) +
              f"  {fmt(min(vals))} {fmt(statistics.median(vals))} {fmt(max(vals))}")
    else:
        print(f"  {label}".ljust(40) + "       n/a      n/a      n/a")
print("=" * 78)
print("  'synced' (t4) = first relay event burst applied to local DB.")
print("  woke=1 → relay replayed stored group events (real re-sync path);")
print("  woke=0 → nothing new to sync this run (empty subscription EOSE).")
print("=" * 78)
