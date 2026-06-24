#!/usr/bin/env bash
#
# device-bench.sh — cold-start + relay-sync benchmark on a PHYSICAL iPhone,
# against the REAL account (real chats). No provisioning, no env hooks: the
# device build is properly signed so Keychain works and the real identity + DB
# load normally. Install a Debug build first (markers are #if DEBUG).
#
#   xcodebuild -project ios/bitchat.xcodeproj -scheme "bitchat (iOS)" \
#     -configuration Debug -destination 'platform=iOS,id=<UDID>' \
#     -derivedDataPath <dd> -allowProvisioningUpdates build
#   xcrun devicectl device install app --device <UDID> <dd>/.../Sonar.app
#   scripts/bench/device-bench.sh
#
# Marker timestamps are read from the BitLogger `[HH:MM:SS.mmm]` prefix embedded
# in each line (device-local, ms precision) — robust to host/device clock skew.
#
# Env: UDID (hardware udid), BUNDLE, RUNS, TIMEOUT (per-run wait for t4), OUT.
set -euo pipefail

UDID="${UDID:-00008120-00011DE63453C01E}"
BUNDLE="${BUNDLE:-sh.hedwig.sonar}"
RUNS="${RUNS:-5}"
TIMEOUT="${TIMEOUT:-120}"
OUT="${OUT:-/tmp/sonar-bench/device}"
mkdir -p "$OUT"
LOG="$OUT/syslog.log"
: > "$LOG"

command -v idevicesyslog >/dev/null || { echo "idevicesyslog not found (brew install libimobiledevice)" >&2; exit 1; }

echo ">> streaming device syslog (filtered to SONAR_BENCH)…" >&2
idevicesyslog -u "$UDID" -m "SONAR_BENCH" -o "$LOG" >/dev/null 2>&1 &
SP=$!
trap 'kill $SP 2>/dev/null || true' EXIT
sleep 2

for ((i=1; i<=RUNS; i++)); do
  echo ">> run $i/$RUNS: cold launch (--terminate-existing)…" >&2
  before=$(grep -c "t4_first_drain" "$LOG" 2>/dev/null || true); before=${before:-0}
  xcrun devicectl device process launch --terminate-existing --device "$UDID" "$BUNDLE" >/dev/null 2>&1 || \
    echo "   launch error (continuing)" >&2
  waited=0
  while (( waited < TIMEOUT )); do
    now=$(grep -c "t4_first_drain" "$LOG" 2>/dev/null || true); now=${now:-0}
    (( now > before )) && break
    sleep 1; waited=$((waited+1))
  done
  if (( now > before )); then echo "   t4 after ${waited}s" >&2; else echo "   TIMEOUT (${TIMEOUT}s)" >&2; fi
  sleep 4
done
kill $SP 2>/dev/null || true; wait $SP 2>/dev/null || true

LOG="$LOG" python3 - <<'PY'
import os, re, statistics
log = os.environ["LOG"]

ts_re = re.compile(r"\[(\d{2}):(\d{2}):(\d{2})\.(\d{3})\]")   # BitLogger device-local ms
mk_re = re.compile(r"SONAR_BENCH (t\d[a-z]?_[a-z_]+)")        # t0_..t4_, incl. t3a/t3b
ann_re = re.compile(r"(groups=\d+|woke=\d notif=\d+)")

def ms_of_day(m):
    h, mi, s, ms = map(int, m.groups())
    return ((h*60+mi)*60+s)*1000 + ms

events = []   # (ms, marker, annotation)
for line in open(log, errors="ignore"):
    if "SONAR_BENCH" not in line: continue
    tm = ts_re.search(line); mk = mk_re.search(line)
    if not tm or not mk: continue
    ann = ann_re.search(line)
    events.append((ms_of_day(tm), mk.group(1), ann.group(1) if ann else ""))

# split into runs at each t0_launch
runs, cur = [], None
for ms, mk, ann in events:
    if mk == "t0_launch":
        if cur: runs.append(cur)
        cur = {}
    if cur is None: cur = {}
    if mk not in cur: cur[mk] = (ms, ann)
if cur: runs.append(cur)
# keep only complete-ish runs that reached at least t3
runs = [r for r in runs if "t0_launch" in r]

def d(r, a, b):
    if a in r and b in r:
        v = r[b][0] - r[a][0]
        # Only treat a LARGE negative as a real midnight wrap; small negatives
        # are just async marker ordering (t1/t2 fire within a few ms).
        if v < -43200000: v += 86400000
        return v
    return None

PHASES = [
    ("t0 → t1   (open DB, local paint)", "t0_launch", "t1_local_paint"),
    ("t1 → t2   (pre-relay window)    ", "t1_local_paint", "t2_relay_connect_begin"),
    ("t2 → t3   (relay quorum connect)", "t2_relay_connect_begin", "t3_relay_connected"),
    ("t3 → t3a  (publish keypkg+prof) ", "t3_relay_connected", "t3a_published"),
    ("t3a → t3b (first event wait)    ", "t3a_published", "t3b_first_wake"),
    ("t3b → t4  (drainPending MLS)    ", "t3b_first_wake", "t4_first_drain"),
    ("TOTAL t0 → t4 (in-app → synced) ", "t0_launch", "t4_first_drain"),
]
def fmt(x): return "    n/a" if x is None else f"{x:8.0f}"

print()
print("="*74)
print(f"  Sonar iOS DEVICE cold-start + Marmot sync — {len(runs)} run(s), real account")
print("="*74)
for i, r in enumerate(runs, 1):
    g = r.get("t1_local_paint",(0,""))[1]; t4 = r.get("t4_first_drain",(0,""))[1]
    print(f"  run {i}: {g or '?'}  t4 {t4 or '(no t4)'}")
print("-"*74)
print("  phase".ljust(36) + "     min      med      max   (ms)")
print("-"*74)
for label, a, b in PHASES:
    vals = [d(r,a,b) for r in runs]; vals = [v for v in vals if v is not None]
    if vals:
        print(f"  {label}".ljust(36) + f"  {fmt(min(vals))} {fmt(statistics.median(vals))} {fmt(max(vals))}")
    else:
        print(f"  {label}".ljust(36) + "       n/a      n/a      n/a")
print("="*74)
PY
