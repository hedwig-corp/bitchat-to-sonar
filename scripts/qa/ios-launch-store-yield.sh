#!/usr/bin/env bash
# ios-launch-store-yield.sh — QA-187, iOS leg: a cold launch must not wait for
# a notification-extension wake that holds the Marmot store lock.
#
#   QA_UDID=<uuid> SONAR_BENCH_NSEC=nsec1… scripts/qa/ios-launch-store-yield.sh [--budget-ms 3000]
#
# `simctl push` presents a notification on the simulator but never runs the
# extension, so the real NSE cannot be driven here. Instead a stand-in process
# (ios-nse-standin/nse_standin.swift) takes the SAME App Group flock the NSE
# takes and behaves like either extension:
#   yield     the fixed NSE: release the moment the app posts
#             MarmotStoreLock.hostWantsStoreNotification
#   stubborn  the old NSE: hold 13 s (5 s relay quorum + 8 s drain), ignore it
# The REAL app is cold-launched each time and t0_launch → t1_local_paint is read
# from its SONAR_BENCH markers (Debug build, unified log).
#
# PASS: no-holder and yield launches paint within the budget AND the stubborn
# launch is slow (≥ 10 s). The stubborn control proves the lock really sits on
# the first-paint path in this build; if it is fast, nothing was measured and
# the script FAILs as inconclusive instead of passing.
#
# Preconditions: scripts/qa/ios-setup.sh installed a SIGNED Debug build on
# QA_UDID (an unsigned build has no App Group, so there is no lock to contend
# for), and SONAR_BENCH_NSEC is a throwaway identity (`sonar-cli init`). The
# DEBUG bench hook skips onboarding with it. Exit status = 0 pass, 1 fail.
#
# Trap: ios-setup.sh's own launch (no bench identity) raises the system
# "Would Like to Send You Notifications" alert. It survives terminate and
# relaunch, keeps the app from ever becoming active, and so no t1_local_paint
# is logged ("no t0/t1 markers"). Reboot the simulator first
# (`xcrun simctl shutdown $QA_UDID; xcrun simctl boot $QA_UDID`); launches
# with SONAR_BENCH_NSEC never ask.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UDID="${QA_UDID:?set QA_UDID (scripts/qa/ios-setup.sh prints it)}"
NSEC="${SONAR_BENCH_NSEC:?set SONAR_BENCH_NSEC to a throwaway nsec (sonar-cli init)}"
BUDGET=3000
while [[ $# -gt 0 ]]; do
  case "$1" in
    --budget-ms) BUDGET="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
BUNDLE=sh.hedwig.sonar
GROUP=group.sh.hedwig.sonar
QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa-$(basename "$ROOT")}"
WORK="$QA_HOME/store-yield"; mkdir -p "$WORK"
HELPER="$WORK/nse_standin"

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -swift-version 5 -sdk "$SDK" -target arm64-apple-ios17.0-simulator \
  -o "$HELPER" "$ROOT/scripts/qa/ios-nse-standin/nse_standin.swift" || { echo "FAIL helper build"; exit 1; }

launch_env=(env SIMCTL_CHILD_SONAR_BENCH_NSEC="$NSEC")

# cold_paint_ms — terminate, cold-launch, print t0_launch→t1_local_paint in ms.
cold_paint_ms() {
  local log="$WORK/bench-$1.ndjson" i
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  : > "$log"
  xcrun simctl spawn "$UDID" log stream --level debug --style ndjson --color none \
    --predicate 'eventMessage CONTAINS "SONAR_BENCH"' > "$log" 2>/dev/null &
  local stream=$!
  sleep 2
  "${launch_env[@]}" xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
  for i in $(seq 1 40); do
    grep -q 't1_local_paint' "$log" && break
    sleep 1
  done
  kill "$stream" >/dev/null 2>&1; wait "$stream" 2>/dev/null
  python3 - "$log" <<'PY'
import json, sys
from datetime import datetime
ts = {}
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except ValueError: continue
    m = e.get("eventMessage", "")
    for k in ("t0_launch", "t1_local_paint"):
        if k in m and k not in ts:
            ts[k] = datetime.strptime(e["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
if len(ts) == 2: print(int((ts["t1_local_paint"] - ts["t0_launch"]) * 1000))
else: print("")
PY
}

# Warm-up: the first launch creates the App Group store directory.
cold_paint_ms warmup >/dev/null
GROUP_DIR="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" "$GROUP" 2>/dev/null)"
LOCK="$GROUP_DIR/sonar-marmot/marmot.store.lock"
[[ -n "$GROUP_DIR" && -d "$GROUP_DIR/sonar-marmot" ]] || { echo "FAIL inconclusive: no App Group store (unsigned build?)"; exit 1; }
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
sleep 2

run_mode() { # none | yield | stubborn
  local mode="$1" holder="" out="$WORK/standin-$1.txt"
  : > "$out"
  if [[ "$mode" != none ]]; then
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    sleep 1
    xcrun simctl spawn "$UDID" "$HELPER" "$LOCK" "$mode" > "$out" 2>&1 &
    holder=$!
    for _ in $(seq 1 20); do grep -q 'holding store lock' "$out" && break; sleep 0.25; done
    grep -q 'holding store lock' "$out" || { echo "FAIL inconclusive: stand-in could not take the lock: $(cat "$out")"; exit 1; }
  fi
  printf -v "MS_$mode" '%s' "$(cold_paint_ms "$mode")"
  [[ -n "$holder" ]] && wait "$holder" 2>/dev/null
  local v="MS_$mode"
  echo "  $mode: t0→t1=${!v:-?}ms $(tr '\n' ' ' < "$out")"
}

echo "Sonar iOS store-yield check (QA-187) on $UDID, budget ${BUDGET}ms"
run_mode none
run_mode yield
run_mode stubborn

fail=0
for m in none yield stubborn; do v="MS_$m"; [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "FAIL inconclusive: no t0/t1 markers for $m (Release build?)"; exit 1; }; done
if (( MS_stubborn < 10000 )); then
  echo "FAIL inconclusive: the 13 s holder only delayed paint to ${MS_stubborn}ms, so the lock is not on this build's paint path"
  exit 1
fi
grep -q 'host-wants notification received' "$WORK/standin-yield.txt" || { echo "FAIL the app never asked the holder to yield"; fail=1; }
(( MS_none <= BUDGET )) || { echo "FAIL no-holder launch ${MS_none}ms over budget"; fail=1; }
(( MS_yield <= BUDGET )) || { echo "FAIL yielding-holder launch ${MS_yield}ms over budget"; fail=1; }
(( fail == 0 )) && echo "PASS QA-187 (iOS): paint ${MS_none}ms alone, ${MS_yield}ms with a yielding holder, ${MS_stubborn}ms with the old holder"
exit "$fail"
