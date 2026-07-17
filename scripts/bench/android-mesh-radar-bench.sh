#!/usr/bin/env bash
# Measures Compose mesh-peer → Radar publish cost on a connected Android device
# using Debug-only SONAR_BENCH markers from PR #316 / R-008.
#
# Matches the Signal-style invalidation shape the feature implements:
#   verified bitchat announce → conflated off-main snapshot → Radar state paint
# (same 1-in-flight + 1-trailing pattern as WalletBridge balance refresh).
#
# Requires: DEBUG APK of chat.bitchat.sonar, onboarded, Bluetooth on, Radar
# (Nearby) visible or reachable, and ideally a stock bitchat peer in range
# (e.g. permissionlesstech/bitchat-android) so announce→paint samples appear.
#
# Usage:
#   scripts/bench/android-mesh-radar-bench.sh [--serial SERIAL] \
#     [--peer NICK] [--seconds N] [--open-radar] [--cold-start]
#
# Output:
#   announce→paint ms (min/median/max) when mesh_announce + radar_peer_paint pair
#   invalidate→refresh_end ms (Signal-style invalidation lag)
#   mesh_refresh off_main_ms / total_ms (min/median/max)
#   conflation dropped counts, RSS samples, ANR check
#
# Prefer --cold-start when measuring first Radar appearance: re-announces of
# already-visible peers do not re-emit radar_peer_paint (change-only publish).
set -euo pipefail

SERIAL=""
PEER=""
SECONDS_N=60
OPEN_RADAR=0
COLD_START=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --peer) PEER="$2"; shift 2 ;;
    --seconds) SECONDS_N="$2"; shift 2 ;;
    --open-radar) OPEN_RADAR=1; shift ;;
    --cold-start) COLD_START=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

ADB=(adb)
[[ -n "$SERIAL" ]] && ADB=(adb -s "$SERIAL")

PKG=chat.bitchat.sonar
if ! "${ADB[@]}" shell pm list packages | grep -q "^package:$PKG$"; then
  echo "error: $PKG is not installed on the target device" >&2
  exit 1
fi

# Debug builds emit SONAR_BENCH; Release never does.
if ! "${ADB[@]}" shell dumpsys package "$PKG" | grep -q 'DEBUGGABLE'; then
  echo "error: $PKG is not DEBUGGABLE — rebuild/install a Debug APK" >&2
  exit 1
fi

OUT_DIR="${OUT_DIR:-/tmp/sonar-bench/mesh-radar}"
mkdir -p "$OUT_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$OUT_DIR/logcat-$STAMP.txt"
MEM="$OUT_DIR/meminfo-$STAMP.txt"
SUMMARY="$OUT_DIR/summary-$STAMP.txt"

export BENCH_SERIAL="$SERIAL" BENCH_PEER="$PEER" BENCH_SECONDS="$SECONDS_N" \
  BENCH_OPEN_RADAR="$OPEN_RADAR" BENCH_COLD_START="$COLD_START" \
  BENCH_LOG="$LOG" BENCH_MEM="$MEM" BENCH_SUMMARY="$SUMMARY" BENCH_PKG="$PKG"

python3 - <<'PYEOF'
import os
import re
import statistics
import subprocess
import sys
import threading
import time
from datetime import datetime

SERIAL = os.environ.get("BENCH_SERIAL") or ""
PEER = (os.environ.get("BENCH_PEER") or "").strip()
SECONDS = int(os.environ["BENCH_SECONDS"])
OPEN_RADAR = os.environ.get("BENCH_OPEN_RADAR") == "1"
COLD_START = os.environ.get("BENCH_COLD_START") == "1"
LOG = os.environ["BENCH_LOG"]
MEM = os.environ["BENCH_MEM"]
SUMMARY = os.environ["BENCH_SUMMARY"]
PKG = os.environ["BENCH_PKG"]
ADB = ["adb"] + (["-s", SERIAL] if SERIAL else [])

ANNOUNCE = re.compile(
    r"SONAR_BENCH mesh_announce nick=(\S+) fp=(\S+) direct=([01])"
)
PAINT = re.compile(
    r"SONAR_BENCH radar_peer_paint nick=(\S+) fp=(\S+) sonar=([01])"
)
INVALIDATE = re.compile(r"SONAR_BENCH mesh_peer_invalidate")
REFRESH_END = re.compile(
    r"SONAR_BENCH mesh_refresh_end peers=(\d+) profiles=(\d+) "
    r"off_main_ms=([0-9.]+) total_ms=([0-9.]+) published=([01]) dropped=(\d+)"
)
# logcat -v threadtime: 01-02 03:04:05.678
TS = re.compile(r"^(\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})")


def nick_matches(token: str, needle: str) -> bool:
    if not needle:
        return True
    from urllib.parse import unquote
    decoded = unquote(token).replace("+", " ")
    return needle.lower() in decoded.lower() or needle.lower() in token.lower()


def adb(*args, check=False):
    r = subprocess.run(ADB + list(args), capture_output=True)
    out = r.stdout.decode(errors="replace")
    if check and r.returncode != 0:
        raise RuntimeError(out or r.stderr.decode(errors="replace"))
    return out


def parse_ts(line: str):
    m = TS.search(line)
    if not m:
        return None
    # Year is missing; use current year (device local).
    year = datetime.now().year
    try:
        return datetime.strptime(f"{year}-{m.group(1)}", "%Y-%m-%d %H:%M:%S.%f")
    except ValueError:
        return None


def ui_texts():
    xml = adb("exec-out", "uiautomator", "dump", "/dev/tty")
    return [(m.group(1), m.group(2)) for m in
            re.finditer(r'text="([^"]+)"[^>]*bounds="(\[[^"]+\])"', xml)]


def bounds(b):
    return tuple(map(int, re.findall(r"\d+", b)))


def center(b):
    x1, y1, x2, y2 = bounds(b)
    return (x1 + x2) // 2, (y1 + y2) // 2


def find(rows, needle):
    for t, b in rows:
        if needle.lower() in t.lower():
            return center(b)
    return None


def tap(x, y):
    subprocess.run(ADB + ["shell", "input", "tap", str(x), str(y)], capture_output=True)


def ensure_radar():
    """Best-effort: open Nearby/Radar via the rings icon or an on-screen Nearby label."""
    for _ in range(5):
        rows = ui_texts()
        texts = [t for t, _ in rows]
        # Radar screen usually shows "Nearby" / peer list chrome; chat list shows MESSAGES.
        if any("nearby" in t.lower() for t in texts) and not any(t == "MESSAGES" for t in texts):
            return True
        # Home bottom nav: rings / Nearby affordance is often content-desc free; try text.
        target = find(rows, "Nearby") or find(rows, "Radar")
        if target:
            tap(*target)
            time.sleep(1.2)
            continue
        # Relaunch app then try again.
        subprocess.run(
            ADB + ["shell", "monkey", "-p", PKG, "-c",
                   "android.intent.category.LAUNCHER", "1"],
            capture_output=True,
        )
        time.sleep(3)
    return False


def sample_rss():
    out = adb("shell", "dumpsys", "meminfo", PKG)
    # Prefer TOTAL RSS; fall back to TOTAL.
    for pat in (r"TOTAL RSS:\s+(\d+)", r"TOTAL:\s+(\d+)"):
        m = re.search(pat, out)
        if m:
            return int(m.group(1))  # kB
    return None


def fmt_stats(values, unit="ms"):
    if not values:
        return f"(n=0)"
    return (
        f"min={min(values):.1f} median={statistics.median(values):.1f} "
        f"max={max(values):.1f} {unit} (n={len(values)})"
    )


print(f"clearing logcat; sampling for {SECONDS}s…", flush=True)
adb("logcat", "-c")

if COLD_START:
    print("cold-start: force-stopping then relaunching…", flush=True)
    adb("shell", "am", "force-stop", PKG)
    time.sleep(0.5)

# Start logcat before launch so first-paint markers are not missed.
stop = threading.Event()
rss_samples = []


def mem_loop():
    while not stop.is_set():
        kb = sample_rss()
        if kb is not None:
            rss_samples.append(kb)
            with open(MEM, "a") as f:
                f.write(f"{time.time():.3f} rss_kb={kb}\n")
        stop.wait(2.0)


mem_thread = threading.Thread(target=mem_loop, daemon=True)
mem_thread.start()

proc = subprocess.Popen(
    ADB + ["logcat", "-v", "threadtime", "-s", "SonarCore:I", "MeshGatt:I"],
    stdout=open(LOG, "w"),
    stderr=subprocess.STDOUT,
)

subprocess.run(
    ADB + ["shell", "monkey", "-p", PKG, "-c", "android.intent.category.LAUNCHER", "1"],
    capture_output=True,
)
time.sleep(4)
if OPEN_RADAR:
    print("opening Radar/Nearby…", flush=True)
    if ensure_radar():
        print("Radar/Nearby appears visible", flush=True)
    else:
        print("warning: could not confirm Radar is open; continuing anyway", flush=True)

try:
    time.sleep(max(0, SECONDS - 4))
finally:
    stop.set()
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
    mem_thread.join(timeout=3)

text = open(LOG, encoding="utf-8", errors="replace").read().splitlines()
announces = []
paints = []
invalidates = []
refresh_ends = []
refresh_off = []
refresh_total = []
dropped_vals = []
for line in text:
    ts = parse_ts(line)
    if (m := ANNOUNCE.search(line)):
        nick, fp, direct = m.group(1), m.group(2), m.group(3)
        if not nick_matches(nick, PEER):
            continue
        announces.append((ts, nick, fp, direct, line))
    if (m := PAINT.search(line)):
        nick, fp, sonar = m.group(1), m.group(2), m.group(3)
        if not nick_matches(nick, PEER):
            continue
        paints.append((ts, nick, fp, sonar, line))
    if INVALIDATE.search(line) and ts is not None:
        invalidates.append(ts)
    if (m := REFRESH_END.search(line)):
        refresh_off.append(float(m.group(3)))
        refresh_total.append(float(m.group(4)))
        dropped_vals.append(int(m.group(6)))
        if ts is not None:
            refresh_ends.append(ts)

# Pair each announce with the next paint for same nick/fp within 5s.
latencies = []
used_paints = set()
for ats, anick, afp, adirect, _ in announces:
    if ats is None:
        continue
    matched = None
    for j, (pts, pnick, pfp, psonar, _) in enumerate(paints):
        if j in used_paints or pts is None or pts < ats:
            continue
        dt = (pts - ats).total_seconds() * 1000.0
        if dt > 5000:
            continue
        if pfp == afp or pnick == anick:
            matched = (dt, anick, afp, adirect, psonar)
            used_paints.add(j)
            break
    if matched:
        latencies.append(matched[0])
        print(
            f"announce→paint nick={matched[1]} fp={matched[2]} "
            f"direct={matched[3]} sonar={matched[4]} ms={matched[0]:.1f}",
            flush=True,
        )

# Signal-style invalidation lag: mesh_peer_invalidate → next mesh_refresh_end.
inv_latencies = []
ri = 0
for its in invalidates:
    while ri < len(refresh_ends) and refresh_ends[ri] < its:
        ri += 1
    if ri >= len(refresh_ends):
        break
    dt = (refresh_ends[ri] - its).total_seconds() * 1000.0
    if dt <= 2000:
        inv_latencies.append(dt)
        print(f"invalidate→refresh_end ms={dt:.1f}", flush=True)
        ri += 1

# ANR / input-dispatch check in the captured window + recent dumpsys.
anr_hits = [
    line for line in text
    if "ANR in" in line or "Input dispatching timed out" in line
]
anr_dump = adb("shell", "dumpsys", "activity", "processes")
anr_pkg = [
    line for line in anr_dump.splitlines()
    if PKG in line and re.search(r"\bANR\b", line, re.I)
]

rss_mb = [k / 1024.0 for k in rss_samples]
lines = []
lines.append(f"Pixel mesh/Radar bench — {SECONDS}s window")
lines.append(f"log: {LOG}")
lines.append(f"mesh_announce events: {len(announces)}")
lines.append(f"radar_peer_paint events: {len(paints)}")
lines.append(f"mesh_peer_invalidate events: {len(invalidates)}")
lines.append(f"announce→paint: {fmt_stats(latencies)}")
lines.append(f"invalidate→refresh_end: {fmt_stats(inv_latencies)}")
lines.append(f"mesh_refresh off_main_ms: {fmt_stats(refresh_off)}")
lines.append(f"mesh_refresh total_ms: {fmt_stats(refresh_total)}")
if dropped_vals:
    lines.append(
        f"conflation dropped/request-batch: "
        f"min={min(dropped_vals)} median={statistics.median(dropped_vals):.0f} "
        f"max={max(dropped_vals)} (n={len(dropped_vals)})"
    )
else:
    lines.append("conflation dropped/request-batch: (n=0 refreshes)")
if rss_mb:
    lines.append(
        f"RSS MB: min={min(rss_mb):.1f} median={statistics.median(rss_mb):.1f} "
        f"max={max(rss_mb):.1f} (n={len(rss_mb)})"
    )
else:
    lines.append("RSS MB: (no samples)")
lines.append(f"ANR lines in logcat window: {len(anr_hits)}")
lines.append(f"ANR mentions for package in dumpsys: {len(anr_pkg)}")
if PEER:
    lines.append(f"peer filter: {PEER}")
# Signal / bitchat comparison notes for the report.
lines.append("")
lines.append("Pattern check (expected after #316):")
lines.append("  - announce→paint median << 1500 ms (capability settle must NOT gate Radar)")
lines.append("  - off_main_ms carries native peers()/decode; UI thread stays responsive")
lines.append("  - dropped > 0 under BLE bursts (1 in-flight + 1 trailing), no ANR")
lines.append("  - RSS stable (broken loop was ~552 MB with 200+ MB GC reclaim cycles)")

report = "\n".join(lines) + "\n"
open(SUMMARY, "w").write(report)
print(report, end="", flush=True)

if not announces and not refresh_off:
    print(
        "warning: no mesh SONAR_BENCH markers captured. "
        "Is Radar open with Bluetooth on, and is this the instrumented Debug build?",
        file=sys.stderr,
    )
    sys.exit(1)
PYEOF
