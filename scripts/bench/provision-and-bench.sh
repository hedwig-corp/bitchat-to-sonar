#!/usr/bin/env bash
#
# provision-and-bench.sh — Faithful "existing account, cold process" benchmark.
#
# Stands up a REAL Marmot conversation so the cold-start runs exercise the
# actual relay re-sync path (not an empty subscription):
#
#   1. Generate two identities with sonar-cli: A (the simulator's identity) and
#      B (a headless counterparty).
#   2. Launch the sim app with SONAR_BENCH_NSEC=<nsecA> so it adopts identity A
#      and publishes its Marmot KeyPackage.
#   3. From B, send a 1:1 DM to npubA. DMs (member_count<=2) AUTO-JOIN on the
#      recipient (core: marmot.rs process_incoming), so the sim's local DB gains
#      a real group with no UI interaction.
#   4. Before each cold-start run, B sends a fresh message so the relay has new
#      events for the sim to replay on launch (woke=1 = real re-sync).
#   5. Delegate the measured loop to cold-start-bench.sh.
#
# Requires: a Debug Sonar.app (scripts/bench/build-sim.sh) and a release
# sonar-cli (cargo build -p sonar-cli --release). Uses the live public relays,
# so it needs network. All identities/data are throwaway.
#
# Usage:
#   scripts/bench/provision-and-bench.sh --app /path/Sonar.app [--runs N] \
#       [--device NAME|UDID] [--cli /path/sonar-cli] [--msgs-per-run K]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUNDLE_ID="sh.hedwig.sonar"
APP_PATH=""
DEVICE=""
RUNS=5
MSGS_PER_RUN=1
CLI="$REPO_ROOT/core/target/release/sonar-cli"
WORK="/tmp/sonar-bench"
# Keep this list in sync with MarmotService.defaultRelayUrls (Swift).
RELAYS=( wss://relay.damus.io wss://nos.lol wss://relay.primal.net wss://relay.kaleidoswap.com wss://nostr.relay.hedwig.sh )

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_PATH="$2"; shift 2;;
    --device) DEVICE="$2"; shift 2;;
    --runs) RUNS="$2"; shift 2;;
    --cli) CLI="$2"; shift 2;;
    --msgs-per-run) MSGS_PER_RUN="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

log() { echo ">> $*" >&2; }
[[ -x "$CLI" ]] || { echo "ERROR: sonar-cli not found at $CLI" >&2; exit 1; }
[[ -d "$APP_PATH" ]] || { echo "ERROR: --app .app bundle required" >&2; exit 1; }

relay_args=(); for r in "${RELAYS[@]}"; do relay_args+=(--relay "$r"); done
HOME_A="$WORK/agentA"; HOME_B="$WORK/agentB"
mkdir -p "$WORK"

# --- 1. identities -----------------------------------------------------------
# Wipe any prior agent homes: `init --force` rewrites config.json (new db key)
# but leaves the old encrypted marmot DB → "Wrong encryption key" on next use.
log "generating identity A (simulator) + B (counterparty)…"
rm -rf "$HOME_A" "$HOME_B"
"$CLI" --home "$HOME_A" "${relay_args[@]}" init --force >/dev/null
"$CLI" --home "$HOME_B" "${relay_args[@]}" init --force >/dev/null
NSEC_A="$(python3 -c "import json;print(json.load(open('$HOME_A/config.json'))['nsec'])")"
NPUB_A="$("$CLI" --home "$HOME_A" identity | python3 -c "import sys,json;print(json.load(sys.stdin)['npub'])")"
NPUB_B="$("$CLI" --home "$HOME_B" identity | python3 -c "import sys,json;print(json.load(sys.stdin)['npub'])")"
log "npubA=$NPUB_A"
log "npubB=$NPUB_B"
# Publish B's KeyPackage too (harmless; lets A reply if extended later).
"$CLI" --home "$HOME_B" "${relay_args[@]}" publish >/dev/null 2>&1 || true

# --- 2. resolve + boot device, install app -----------------------------------
resolve_device() {
  if [[ -n "$DEVICE" ]]; then
    if [[ "$DEVICE" =~ ^[0-9A-Fa-f-]{36}$ ]]; then echo "$DEVICE"; return; fi
    xcrun simctl list devices available | grep -F "$DEVICE" | grep -oE '[0-9A-Fa-f-]{36}' | head -1; return
  fi
  local b; b="$(xcrun simctl list devices booted | grep -oE '[0-9A-Fa-f-]{36}' | head -1 || true)"
  [[ -n "$b" ]] && { echo "$b"; return; }
  xcrun simctl list devices available | grep -E 'iPhone' | grep -oE '[0-9A-Fa-f-]{36}' | tail -1
}
UDID="$(resolve_device)"; [[ -n "$UDID" ]] || { echo "no device" >&2; exit 1; }
log "device: $UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" || true
log "clean install (wipe any prior identity/onboarding state)…"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP_PATH"

# --- 3. seed identity A on the sim + publish its KeyPackage -------------------
# simctl launch passes env vars prefixed with SIMCTL_CHILD_ to the app.
log "launching sim as identity A to publish KeyPackage…"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_SONAR_BENCH_NSEC="$NSEC_A" xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

# Poll the unified log until the sim reports relay-connected (KeyPackage publish
# follows immediately after). --info because SecureLogger markers are info level.
log "waiting for sim relay-connect (t3)…"
for _ in $(seq 1 40); do
  if xcrun simctl spawn "$UDID" log show --last 2m --info --debug --style compact \
       --predicate 'eventMessage CONTAINS "SONAR_BENCH t3_relay_connected"' 2>/dev/null \
       | grep -q t3_relay_connected; then
    log "  relay connected."
    break
  fi
  sleep 2
done
sleep 6  # let publishKeyPackage land on the relays

# --- 4. provisioning DM (auto-joins on the sim) ------------------------------
# Retry: B needs A's KeyPackage on the relays; tolerate relay propagation lag.
log "sending provisioning DM B→A (retry until KeyPackage found)…"
sent=0
for attempt in $(seq 1 8); do
  if "$CLI" --home "$HOME_B" "${relay_args[@]}" send --to "$NPUB_A" \
        --text "sonar-bench provisioning $(date +%H:%M:%S)" --group-name "sonar-bench" >/dev/null 2>"$WORK/send.err"; then
    sent=1; log "  provisioning DM sent (attempt $attempt)."; break
  fi
  log "  attempt $attempt failed: $(tail -1 "$WORK/send.err"); retrying in 8s…"
  sleep 8
done
[[ "$sent" == "1" ]] || { echo "ERROR: could not deliver provisioning DM (A's KeyPackage never found)" >&2; exit 1; }
log "waiting 20s for the sim to auto-join + drain the welcome…"
sleep 20
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

# --- 5. fresh messages + measured cold-start loop ----------------------------
# Pre-seed one round of fresh messages so the FIRST run already has events to
# replay. cold-start-bench.sh then drives terminate→relaunch and parses markers.
# We inject MSGS_PER_RUN messages, terminate, run ONE measured cold start, repeat.
export SIMCTL_CHILD_SONAR_BENCH_NSEC="$NSEC_A"
OUT_DIR="$WORK/runs"; mkdir -p "$OUT_DIR"; rm -f "$OUT_DIR"/run_*.ndjson "$OUT_DIR"/run_*.launch 2>/dev/null || true

for ((i=1; i<=RUNS; i++)); do
  log "===== measured run $i/$RUNS ====="
  for ((m=1; m<=MSGS_PER_RUN; m++)); do
    "$CLI" --home "$HOME_B" "${relay_args[@]}" send --to "$NPUB_A" \
        --text "bench run $i msg $m $(date +%H:%M:%S.%N)" --group-name "sonar-bench" >/dev/null || true
  done
  sleep 3  # let the relay store the events
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 1
  ndjson="$OUT_DIR/run_$i.ndjson"; : > "$ndjson"
  xcrun simctl spawn "$UDID" log stream --level debug --style ndjson --color none \
      --predicate 'eventMessage CONTAINS "SONAR_BENCH"' > "$ndjson" 2>/dev/null &
  stream_pid=$!
  sleep 2
  python3 -c 'import time;print(repr(time.time()))' > "$OUT_DIR/run_$i.launch"
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
  waited=0
  while (( waited < 60 )); do
    grep -q 't4_first_drain' "$ndjson" 2>/dev/null && break
    sleep 1; waited=$((waited+1))
  done
  kill "$stream_pid" >/dev/null 2>&1 || true; wait "$stream_pid" 2>/dev/null || true
  log "run $i done (waited ${waited}s)"
done

# --- 6. aggregate (reuse the same parser as cold-start-bench.sh) -------------
OUT_DIR="$OUT_DIR" RUNS="$RUNS" python3 "$REPO_ROOT/scripts/bench/_aggregate.py"
