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
# Marker capture (first that works):
#   1. idevicesyslog -m SONAR_BENCH  (USB / libimobiledevice)
#   2. CoreDevice pull of the app LogFileSink
#      (Library/Application Support/sonar-marmot/logs/ios/sonar-ios.log)
#      — works over Wi-Fi when USB syslog is unavailable.
#
# Marker timestamps are read from the BitLogger `[HH:MM:SS.mmm]` prefix embedded
# in each line (device-local, ms precision) — robust to host/device clock skew.
#
# Env: UDID (hardware udid), BUNDLE, RUNS, TIMEOUT (per-run wait for t4), OUT,
#      CAPTURE=auto|syslog|applog
set -euo pipefail

UDID="${UDID:-00008120-00011DE63453C01E}"
BUNDLE="${BUNDLE:-sh.hedwig.sonar}"
RUNS="${RUNS:-5}"
TIMEOUT="${TIMEOUT:-120}"
OUT="${OUT:-/tmp/sonar-bench/device}"
CAPTURE="${CAPTURE:-auto}"
APP_LOG_REL='Library/Application Support/sonar-marmot/logs/ios/sonar-ios.log'
mkdir -p "$OUT"
LOG="$OUT/markers.log"
: > "$LOG"

pull_app_log() {
  local dest="$1"
  local partial="${dest}.partial"
  rm -f "$partial"
  if xcrun devicectl device copy from \
    --device "$UDID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" \
    --source "$APP_LOG_REL" \
    --destination "$partial" >/dev/null 2>&1; then
    mv -f "$partial" "$dest"
    return 0
  fi
  rm -f "$partial"
  return 1
}

count_t4() {
  local file="$1"
  grep -c "t4_first_drain" "$file" 2>/dev/null || true
}

# Decide capture mode.
if [[ "$CAPTURE" == "auto" ]]; then
  if command -v idevicesyslog >/dev/null && idevice_id -l 2>/dev/null | grep -qx "$UDID"; then
    CAPTURE=syslog
  else
    CAPTURE=applog
  fi
fi

if [[ "$CAPTURE" != "syslog" && "$CAPTURE" != "applog" ]]; then
  echo "CAPTURE must be auto|syslog|applog (got: $CAPTURE)" >&2
  exit 1
fi

SP=""
cleanup() {
  [[ -n "$SP" ]] && kill "$SP" 2>/dev/null || true
}
trap cleanup EXIT

if [[ "$CAPTURE" == "syslog" ]]; then
  command -v idevicesyslog >/dev/null || {
    echo "idevicesyslog not found (brew install libimobiledevice), or use CAPTURE=applog" >&2
    exit 1
  }
  echo ">> streaming device syslog (filtered to SONAR_BENCH)…" >&2
  idevicesyslog -u "$UDID" -m "SONAR_BENCH" -o "$LOG" >/dev/null 2>&1 &
  SP=$!
  sleep 2
else
  echo ">> capturing SONAR_BENCH via CoreDevice app log pull (Wi-Fi-safe)…" >&2
  TMP_APP="$OUT/sonar-ios.log"
  pull_app_log "$TMP_APP" || : > "$TMP_APP"
  before_total=$(count_t4 "$TMP_APP"); before_total=${before_total:-0}
fi

for ((i=1; i<=RUNS; i++)); do
  echo ">> run $i/$RUNS: cold launch (--terminate-existing)…" >&2
  if [[ "$CAPTURE" == "syslog" ]]; then
    before=$(count_t4 "$LOG"); before=${before:-0}
  else
    before=$before_total
  fi
  xcrun devicectl device process launch --terminate-existing --device "$UDID" "$BUNDLE" >/dev/null 2>&1 || \
    echo "   launch error (continuing)" >&2
  waited=0
  now=$before
  while (( waited < TIMEOUT )); do
    if [[ "$CAPTURE" == "syslog" ]]; then
      now=$(count_t4 "$LOG"); now=${now:-0}
    else
      if pull_app_log "$TMP_APP"; then
        now=$(count_t4 "$TMP_APP"); now=${now:-0}
      fi
    fi
    if (( now > before )); then
      break
    fi
    sleep 2; waited=$((waited+2))
  done
  if (( now > before )); then
    echo "   t4 after ${waited}s" >&2
    before_total=$now
  else
    echo "   TIMEOUT (${TIMEOUT}s)" >&2
  fi
  sleep 4
done

if [[ "$CAPTURE" == "syslog" ]]; then
  kill "$SP" 2>/dev/null || true; wait "$SP" 2>/dev/null || true
  SP=""
else
  pull_app_log "$TMP_APP" || true
  # Extract only the new marker lines from this session when possible.
  if [[ -f "$TMP_APP" ]]; then
    # Keep the full pulled log for aggregation — aggregator splits on t0/t1.
    cp "$TMP_APP" "$LOG"
    # Also keep a markers-only slice for readability.
    grep "SONAR_BENCH" "$TMP_APP" > "$OUT/markers-only.log" || true
  fi
fi

LOG="$LOG" RUNS_EXPECTED="$RUNS" python3 - <<'PY'
import os, re, statistics
log = os.environ["LOG"]
expected = int(os.environ.get("RUNS_EXPECTED", "5"))

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

# Prefer t0_launch run splits; fall back to t1 when t0 was logged before the
# file sink was configured (older builds).
split_key = "t0_launch" if any(mk == "t0_launch" for _, mk, _ in events) else "t1_local_paint"
runs, cur = [], None
for ms, mk, ann in events:
    if mk == split_key:
        if cur: runs.append(cur)
        cur = {}
    if cur is None: continue
    if mk not in cur: cur[mk] = (ms, ann)
if cur: runs.append(cur)

# Keep complete runs that reached t4; take the last N for this session.
runs = [r for r in runs if "t4_first_drain" in r]
if len(runs) > expected:
    runs = runs[-expected:]

def d(r, a, b):
    if a in r and b in r:
        v = r[b][0] - r[a][0]
        # Only treat a LARGE negative as a real midnight wrap; small negatives
        # are just async marker ordering (t1/t2 fire within a few ms).
        if v < -43200000: v += 86400000
        return v
    return None

# Post-background-publish: startPolling runs before KeyPackage/profile work, so
# t3a is off the sync critical path (and often lands after t4). Prefer t3→t4 /
# t2→t4 for the pain-point comparison; keep t3→t3a as an off-path note.
PHASES = [
    ("t0 → t1   (open DB, local paint)", "t0_launch", "t1_local_paint"),
    ("t1 → t2   (pre-relay window)    ", "t1_local_paint", "t2_relay_connect_begin"),
    ("t2 → t3   (relay quorum connect)", "t2_relay_connect_begin", "t3_relay_connected"),
    ("t3 → t3b  (first event wait)    ", "t3_relay_connected", "t3b_first_wake"),
    ("t3b → t4  (drainPending MLS)    ", "t3b_first_wake", "t4_first_drain"),
    ("t3 → t4   (post-connect sync)   ", "t3_relay_connected", "t4_first_drain"),
    ("t2 → t4   (relay path)          ", "t2_relay_connect_begin", "t4_first_drain"),
    ("TOTAL t1 → t4 (paint → synced)  ", "t1_local_paint", "t4_first_drain"),
    ("TOTAL t0 → t4 (in-app → synced) ", "t0_launch", "t4_first_drain"),
    ("t3 → t3a  (publish dispatch)    ", "t3_relay_connected", "t3a_published"),
    # Publish latency itself, now CONCURRENT with the drain (#265): a large
    # value here is no longer a cold-start regression on its own — judge the
    # drain by t3b → t4.
    ("t3 → t3a-done (publish latency) ", "t3_relay_connected", "t3a_publish_done"),
]
def fmt(x): return "    n/a" if x is None else f"{x:8.0f}"

print()
print("="*74)
print(f"  Sonar iOS DEVICE cold-start + Marmot sync — {len(runs)} run(s), real account")
print(f"  split on {split_key}")
print("="*74)
for i, r in enumerate(runs, 1):
    g = r.get("t1_local_paint",(0,""))[1]; t4 = r.get("t4_first_drain",(0,""))[1]
    print(f"  run {i}: {g or '?'}  t4 {t4 or '(no t4)'}")
print("-"*74)
print("  phase".ljust(42) + "     min      med      max   (ms)")
print("-"*74)
for label, a, b in PHASES:
    vals = [d(r,a,b) for r in runs]; vals = [v for v in vals if v is not None]
    if vals:
        print(f"  {label}".ljust(42) + f"  {fmt(min(vals))} {fmt(statistics.median(vals))} {fmt(max(vals))}")
    else:
        print(f"  {label}".ljust(42) + "       n/a      n/a      n/a")
print("="*74)
PY
