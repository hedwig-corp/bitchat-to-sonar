#!/usr/bin/env bash
# large-account.sh — run the iOS app on a ~400-group account in the QA
# simulator and fail on main-thread stalls or a starved sync queue.
#
#   scripts/qa/large-account.sh [--peers 400] [--reply 40] [--dup 20] [--groups 5]
#                               [--rounds 3] [--away 45] [--settle 20]
#                               [--port 7447] [--keep-relay]
#                               [-- <ios-setup.sh args, e.g. --trust-core>]
#
# Why: every QA and bench account had a handful of groups, and four bugs that
# only show at ~400 groups shipped through them (R-054 catch-up order, R-055
# main-thread O(groups²) walks, R-056 relay lookups and push-token DMs starving
# the gap sync). This reproduces that account shape without touching public
# relays and gates on the lines that exposed those bugs.
#
# Steps:
#  1. `seed_large_account` (core/sonar-core/examples) starts a local relay on
#     --port, seeds the account (1:1 chats with --peers peers, --reply of them
#     answering, a second 1:1 group with --dup of them, --groups team groups),
#     writes the encrypted store, then keeps the relay serving.
#  2. scripts/qa/ios-setup.sh builds/installs the signed Debug app on this
#     worktree's QA simulator (extra args after `--` go to it).
#  3. The store replaces the app's (App Group `sonar-marmot/`), per-chat
#     local-time overrides are written the way a toggle stores them (group ids
#     AND the peer's npub, the alias key behind R-055), one chat is muted (so
#     every row's mute lookup runs, R-057), and the app launches
#     with the DEBUG bench hooks: SONAR_BENCH_NSEC (identity + DB key),
#     SONAR_BENCH_RELAYS (the local relay), SONAR_BENCH_APNS_TOKEN (so the
#     push-token share path runs).
#  4. --rounds background/foreground cycles (Settings to the front for --away
#     seconds, then back), then scripts/qa/stall-gate.sh over the app's own
#     log: any main-thread stall, a work-queue wait over 2 s, a gap recovery
#     over 15 s or missing fails the run.
#
# Simulator only, and the simulator is disposable (its Sonar store is
# replaced). Never point this at a physical device. Android is not covered
# yet: its DB key lives in the Keystore, so a seeded store cannot be dropped
# in (tracked gap in docs/QA-SCENARIOS.md, QA-160).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa-$(basename "$ROOT")}"
BUNDLE=sh.hedwig.sonar
PEERS=400; REPLY=40; DUP=20; TEAMS=5; ROUNDS=3; AWAY=45; SETTLE=20; PORT=7447; KEEP=0
SETUP_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --peers) PEERS="$2"; shift 2 ;;
    --reply) REPLY="$2"; shift 2 ;;
    --dup) DUP="$2"; shift 2 ;;
    --groups) TEAMS="$2"; shift 2 ;;
    --rounds) ROUNDS="$2"; shift 2 ;;
    --away) AWAY="$2"; shift 2 ;;
    --settle) SETTLE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --keep-relay) KEEP=1; shift ;;
    --) shift; SETUP_ARGS=("$@"); break ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

FIX="$QA_HOME/large-account"
rm -rf "$FIX"; mkdir -p "$FIX"
echo ">> fixture dir $FIX" >&2

# 1. Seed (and keep the relay up for the app).
(cd "$ROOT/core" && cargo build -q --release -p sonar-core --example seed_large_account)
SEEDER="$ROOT/core/target/release/examples/seed_large_account"
FIXTURE_DIR="$FIX/store" FIXTURE_PEERS="$PEERS" FIXTURE_REPLY_PEERS="$REPLY" \
  FIXTURE_DUP_PEERS="$DUP" FIXTURE_GROUPS="$TEAMS" FIXTURE_RELAY_PORT="$PORT" \
  "$SEEDER" > "$FIX/seed.out" 2> "$FIX/seed.log" &
SEED_PID=$!
cleanup() { (( KEEP )) || kill "$SEED_PID" 2>/dev/null || true; }
trap cleanup EXIT
for _ in $(seq 1 600); do
  grep -q '^READY ' "$FIX/seed.out" 2>/dev/null && break
  kill -0 "$SEED_PID" 2>/dev/null || { echo "seeder died:" >&2; tail -20 "$FIX/seed.log" >&2; exit 1; }
  sleep 1
done
grep -q '^READY ' "$FIX/seed.out" || { echo "seeder never finished (see $FIX/seed.log)" >&2; exit 1; }
grep '^\[seed\] done' "$FIX/seed.log" >&2 || true
MANIFEST="$FIX/store/fixture.json"
NSEC="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nsec"])' "$MANIFEST")"
RELAY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["relay"])' "$MANIFEST")"

# 2. App on this worktree's QA simulator.
UDID="$("$ROOT/scripts/qa/ios-setup.sh" ${SETUP_ARGS[@]+"${SETUP_ARGS[@]}"})"
echo ">> simulator $UDID" >&2
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
# One bench launch so the App Group store directory exists for this identity.
SIMCTL_CHILD_SONAR_BENCH_NSEC="$NSEC" SIMCTL_CHILD_SONAR_BENCH_RELAYS="$RELAY" \
  xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
sleep 8
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
sleep 2

# 3. Drop in the seeded store and the local-time overrides.
GROUP_DIR="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" group.sh.hedwig.sonar)/sonar-marmot"
mkdir -p "$GROUP_DIR"
rm -f "$GROUP_DIR"/marmot.sqlite*
cp "$FIX"/store/marmot.sqlite* "$GROUP_DIR"/
python3 - "$MANIFEST" > "$FIX/overrides.args" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
args = []
# The duplicate-peer chats, stored the way toggleShareLocalTime(forChatId:)
# stores them: every group id of the chat, bare and prefixed, plus the peer's
# npub. The npub is the alias key that kept R-055's walk quadratic.
for g in m["groups"]:
    if g["kind"] != "dup":
        continue
    for key in (g["mls_group_id"], "marmot:" + g["mls_group_id"], g["peer_npub"]):
        args += [key, "-bool", "YES"]
print("\n".join(args))
PY
OVERRIDES=()
while IFS= read -r line; do [[ -n "$line" ]] && OVERRIDES+=("$line"); done < "$FIX/overrides.args"
# By path, not by bundle id: `defaults write sh.hedwig.sonar` from simctl
# spawn lands in the simulator's global preferences, which the app never
# reads. Going through `defaults` (not editing the plist) keeps cfprefsd's
# cache coherent.
PREFS="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)/Library/Preferences/$BUNDLE"
# One muted chat, stored the way SonarChatMuteStore stores it (JSON
# [key: Date], Date as seconds since 2001; distantFuture = until turned back
# on). With nothing muted, isChatMuted returns early and the per-row mute
# lookups behind R-057 never run.
MUTE_HEX="$(python3 - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
first = next(g for g in m["groups"] if g["kind"] == "dm")
print(json.dumps({"marmot:" + first["mls_group_id"]: 63113904000.0}).encode().hex())
PY
)"
xcrun simctl spawn "$UDID" defaults write "$PREFS" sonar.chat.mutes.v1 -data "$MUTE_HEX"
if (( ${#OVERRIDES[@]} )); then
  xcrun simctl spawn "$UDID" defaults write "$PREFS" sonar.privacy.shareLocalTimeByChat \
    -dict-add "${OVERRIDES[@]}"
  N_SET="$(xcrun simctl spawn "$UDID" defaults read "$PREFS" sonar.privacy.shareLocalTimeByChat \
    | grep -c ' = 1;' || true)"
  (( N_SET * 3 >= ${#OVERRIDES[@]} )) \
    || { echo "local-time overrides did not reach the app container ($N_SET set)" >&2; exit 1; }
fi
echo ">> local-time overrides: $(( ${#OVERRIDES[@]} / 3 )) keys in the app's defaults; 1 chat muted" >&2

# 4. Measured run: launch, then background/foreground rounds.
START="$(date -u +%Y-%m-%dT%H:%M:%S)"
TOKEN="$(openssl rand -hex 32)"
SIMCTL_CHILD_SONAR_BENCH_NSEC="$NSEC" SIMCTL_CHILD_SONAR_BENCH_RELAYS="$RELAY" \
  SIMCTL_CHILD_SONAR_BENCH_APNS_TOKEN="$TOKEN" \
  xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
sleep "$SETTLE"
for round in $(seq 1 "$ROUNDS"); do
  echo ">> round $round/$ROUNDS: away ${AWAY}s" >&2
  xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null
  sleep "$AWAY"
  xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
  sleep "$SETTLE"
done

LOGS="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)/Library/Application Support/sonar-marmot/logs"
cp "$LOGS/ios/sonar-ios.log" "$FIX/sonar-ios.log"
cp "$LOGS/core/sonar-core.log" "$FIX/sonar-core.log" 2>/dev/null || true
# Relay round trips the account made (one EOSE per answered REQ), the
# fan-out R-056 measured: per-member lookups and push-token DMs show here
# long before they show as a stall. Reported, not gated.
REQS="$(awk -v s="$START" '$1 >= s' "$FIX/sonar-core.log" 2>/dev/null | grep -c 'relay EOSE' || true)"
echo ">> relay REQs answered since launch: ${REQS:-0} (launch + $ROUNDS foregrounds)" >&2
"$ROOT/scripts/qa/stall-gate.sh" "$FIX/sonar-ios.log" --since "$START" --min-gap-recoveries "$ROUNDS"
