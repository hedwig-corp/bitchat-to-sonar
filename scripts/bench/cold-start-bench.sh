#!/usr/bin/env bash
#
# cold-start-bench.sh — Benchmark Sonar's iOS cold-start + Nostr/Marmot relay
# sync on the iOS Simulator.
#
# It repeatedly cold-starts the app (terminate the process, relaunch — it never
# erases the container, so the provisioned identity + Marmot groups persist) and
# reads SONAR_BENCH markers from the unified log to time each startup phase:
#
#   t0_launch            app process entered BitchatApp.init()   (in-process T0)
#   t1_local_paint       local groups hydrated from encrypted DB (first paint)
#   t2_relay_connect     relay attach begins
#   t3_relay_connected   relays quorum-connected
#   t4_first_drain       first relay event burst applied to local storage
#                        (initial Marmot sync produced data; woke=1 = had events)
#
# Headline number: launch -> t4 (cold start until the relay sync delivered the
# first batch of group state into local storage).
#
# REQUIRES a Debug build (markers are %{public}@ only in DEBUG) AND that the
# target identity already has Marmot groups on the relays — see PROVISIONING in
# scripts/bench/README.md. A fresh/empty identity has nothing to re-sync.
#
# Usage:
#   scripts/bench/cold-start-bench.sh --app /path/to/Sonar.app [opts]
#   scripts/bench/cold-start-bench.sh --no-install [opts]   # app already installed
#
# Options:
#   --app PATH        .app bundle to (re)install once before the runs
#   --no-install      skip install (use the already-installed, provisioned app)
#   --device NAME|UDID  simulator to use (default: a booted one, else newest iPhone)
#   --runs N          number of cold-start iterations (default 5)
#   --timeout SECS    per-run wait for t4 before giving up (default 60)
#   --bundle ID       app bundle id (default sh.hedwig.sonar)
#   --out DIR         output dir for raw logs (default /tmp/sonar-bench/runs)
set -euo pipefail

BUNDLE_ID="sh.hedwig.sonar"
RUNS=5
TIMEOUT=60
APP_PATH=""
DO_INSTALL=1
DEVICE=""
OUT_DIR="/tmp/sonar-bench/runs"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_PATH="$2"; shift 2;;
    --no-install) DO_INSTALL=0; shift;;
    --device) DEVICE="$2"; shift 2;;
    --runs) RUNS="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --bundle) BUNDLE_ID="$2"; shift 2;;
    --out) OUT_DIR="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

log() { echo ">> $*" >&2; }

# --- resolve simulator UDID -------------------------------------------------
resolve_device() {
  if [[ -n "$DEVICE" ]]; then
    # Accept a UDID directly, else resolve by name.
    if xcrun simctl list devices | grep -q "$DEVICE"; then
      if [[ "$DEVICE" =~ ^[0-9A-Fa-f-]{36}$ ]]; then echo "$DEVICE"; return; fi
      xcrun simctl list devices available | grep -F "$DEVICE" | grep -oE '[0-9A-Fa-f-]{36}' | head -1
      return
    fi
    echo "ERROR: device '$DEVICE' not found" >&2; exit 1
  fi
  # Prefer an already-booted device.
  local booted
  booted="$(xcrun simctl list devices booted | grep -oE '[0-9A-Fa-f-]{36}' | head -1 || true)"
  if [[ -n "$booted" ]]; then echo "$booted"; return; fi
  # Else newest available iPhone.
  xcrun simctl list devices available \
    | grep -E 'iPhone' | grep -oE '[0-9A-Fa-f-]{36}' | tail -1
}

UDID="$(resolve_device)"
[[ -n "$UDID" ]] || { echo "ERROR: no simulator device resolved" >&2; exit 1; }
log "device: $UDID"

# --- boot --------------------------------------------------------------------
state="$(xcrun simctl list devices | grep -F "$UDID" | grep -oE '\((Booted|Shutdown)\)' | tr -d '()' || true)"
if [[ "$state" != "Booted" ]]; then
  log "booting simulator…"
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
fi

# --- install (once) ----------------------------------------------------------
if [[ "$DO_INSTALL" == "1" ]]; then
  [[ -n "$APP_PATH" ]] || { echo "ERROR: --app required unless --no-install" >&2; exit 1; }
  [[ -d "$APP_PATH" ]] || { echo "ERROR: app not found: $APP_PATH" >&2; exit 1; }
  log "installing $APP_PATH (provisioned data preserved across runs)"
  xcrun simctl install "$UDID" "$APP_PATH"
fi

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/run_*.ndjson "$OUT_DIR"/run_*.launch 2>/dev/null || true

# --- run loop ----------------------------------------------------------------
for ((i=1; i<=RUNS; i++)); do
  log "----- run $i/$RUNS -----"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 1

  ndjson="$OUT_DIR/run_$i.ndjson"
  : > "$ndjson"
  # Start the log stream BEFORE launch so t0 is captured. --level debug so
  # SecureLogger.info markers are not filtered out.
  xcrun simctl spawn "$UDID" log stream \
      --level debug --style ndjson --color none \
      --predicate 'eventMessage CONTAINS "SONAR_BENCH"' \
      > "$ndjson" 2>/dev/null &
  stream_pid=$!
  sleep 2  # let the stream attach

  python3 -c 'import time;print(repr(time.time()))' > "$OUT_DIR/run_$i.launch"
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

  # Wait until t4 marker shows or timeout.
  waited=0
  while (( waited < TIMEOUT )); do
    if grep -q 't4_first_drain' "$ndjson" 2>/dev/null; then break; fi
    sleep 1; waited=$((waited+1))
  done
  kill "$stream_pid" >/dev/null 2>&1 || true
  wait "$stream_pid" 2>/dev/null || true
  if grep -q 't4_first_drain' "$ndjson"; then
    log "run $i: t4 reached after ${waited}s"
  else
    log "run $i: TIMEOUT (no t4 within ${TIMEOUT}s)"
  fi
done

# --- aggregate ---------------------------------------------------------------
OUT_DIR="$OUT_DIR" RUNS="$RUNS" python3 - <<'PY'
import json, os, glob, statistics, re
from datetime import datetime

out_dir = os.environ["OUT_DIR"]
runs = int(os.environ["RUNS"])

def parse_ts(s):
    # "2026-06-24 14:30:01.123456+0200"
    return datetime.strptime(s, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()

MARKERS = ["t0_launch","t1_local_paint","t2_relay_connect_begin","t3_relay_connected","t4_first_drain"]
LABEL = {
    "t0_launch":"t0 launch",
    "t1_local_paint":"t1 local paint",
    "t2_relay_connect_begin":"t2 relay connect begin",
    "t3_relay_connected":"t3 relay connected",
    "t4_first_drain":"t4 first drain (synced)",
}

rows = []   # per-run dict of marker -> epoch (first occurrence)
for i in range(1, runs+1):
    f = os.path.join(out_dir, f"run_{i}.ndjson")
    if not os.path.exists(f): continue
    launch_f = os.path.join(out_dir, f"run_{i}.launch")
    launch_epoch = None
    if os.path.exists(launch_f):
        try: launch_epoch = float(open(launch_f).read().strip())
        except Exception: pass
    times = {}
    drain_meta = ""
    for line in open(f):
        line=line.strip()
        if not line: continue
        try: obj=json.loads(line)
        except Exception: continue
        msg = obj.get("eventMessage","")
        ts  = obj.get("timestamp","")
        for m in MARKERS:
            if m in msg and m not in times:
                try: times[m]=parse_ts(ts)
                except Exception: pass
                if m=="t4_first_drain":
                    mm=re.search(r'woke=(\d+) notif=(\d+)', msg)
                    if mm: drain_meta=f"woke={mm.group(1)} notif={mm.group(2)}"
    times["_launch"]=launch_epoch
    times["_drain_meta"]=drain_meta
    rows.append((i,times))

def fmt(ms):
    return "   n/a" if ms is None else f"{ms:7.0f}"

# Phase deltas we report, each (label, from_key, to_key). "launch" is the wall
# time of simctl launch (process spawn ~). t0 is the first in-process marker.
PHASES = [
    ("launch → t0   (process+SwiftUI init)", "_launch", "t0_launch"),
    ("t0 → t1       (open DB, local paint) ", "t0_launch", "t1_local_paint"),
    ("t1 → t2       (pre-relay delay)      ", "t1_local_paint", "t2_relay_connect_begin"),
    ("t2 → t3       (relay quorum connect) ", "t2_relay_connect_begin", "t3_relay_connected"),
    ("t3 → t4       (initial sync drain)   ", "t3_relay_connected", "t4_first_drain"),
    ("TOTAL launch → t4 (cold→synced)     ", "_launch", "t4_first_drain"),
    ("TOTAL t0 → t4     (in-app→synced)   ", "t0_launch", "t4_first_drain"),
]

print()
print("="*78)
print(f"  Sonar iOS cold-start + Marmot sync benchmark — {len(rows)} run(s)")
print("="*78)

# Per-run t4 metadata
for i,t in rows:
    meta=t.get("_drain_meta") or "(no t4)"
    print(f"  run {i}: t4 {meta}")
print("-"*78)
hdr = "  phase".ljust(40) + "  min     med     max   (ms)"
print(hdr)
print("-"*78)
for label, a, b in PHASES:
    vals=[]
    for _,t in rows:
        ta=t.get(a); tb=t.get(b)
        if ta is not None and tb is not None:
            vals.append((tb-ta)*1000.0)
    if vals:
        mn=min(vals); md=statistics.median(vals); mx=max(vals)
        print(f"  {label}".ljust(40) + f"  {fmt(mn)} {fmt(md)} {fmt(mx)}")
    else:
        print(f"  {label}".ljust(40) + "      n/a     n/a     n/a")
print("="*78)
print("  Notes:")
print("  - 'synced' (t4) = first relay event burst applied to the local DB.")
print("    woke=1 means the relay replayed stored group events (the real")
print("    re-sync path); woke=0/notif=0 means nothing new to sync this run.")
print("  - Deep backfill of large group histories may continue past t4.")
print("="*78)
PY
