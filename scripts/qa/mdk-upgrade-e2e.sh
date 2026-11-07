#!/usr/bin/env bash
# mdk-upgrade-e2e.sh — headless, real-store check of the MDK v1 -> v2 chat
# migration (QA-208). Two sonar-cli peers build history on MDK 0.8 ("v1",
# main before the bump), then the v2 CLI opens the SAME homes, which migrates
# the real MDK 0.8 SQLCipher stores, and the peers keep talking on v2.
#
# Asserts: each v1 store is quarantined (*.mdk08.bak) and its decrypted chat
# rows and kind-7 reactions move into sealed sidecars; no plaintext lands on
# disk; the first v2 send creates ONE v2 DM both peers join; each side's v1
# history (with its reaction chip) pages inside that v2 chat; replies flow both
# ways; neither side lists a second chat.
#
# Everything runs on a local relay (the large-account seeder serves it), so no
# public relay is touched.
#
#   V1_CLI=<main's sonar-cli> scripts/qa/mdk-upgrade-e2e.sh
#
# Build V1_CLI from a checkout of the last MDK 0.8 main, e.g.:
#   git worktree add --detach <dir> <pre-bump commit>
#   CARGO_TARGET_DIR=<dir>/target cargo build -p sonar-cli --manifest-path <dir>/core/Cargo.toml
# and this tree's: cargo build -p sonar-cli -p sonar-core --example seed_large_account
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
V1="${V1_CLI:?set V1_CLI to an MDK 0.8 sonar-cli (see header)}"
V2="${V2_CLI:-$ROOT/core/target/debug/sonar-cli}"
SEED="${SEED_BIN:-$ROOT/core/target/debug/examples/seed_large_account}"
PORT="${RELAY_PORT:-7471}"
RELAY=ws://127.0.0.1:$PORT
R="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa-$(basename "$ROOT")}/mdk-upgrade-e2e"
rm -rf "$R"; mkdir -p "$R"
pass=0; fail=0
ok() { echo "PASS $*"; pass=$((pass+1)); }
ko() { echo "FAIL $*"; fail=$((fail+1)); }

# Local relay (the seeder serves it; a 1-chat seed is harmless).
FIXTURE_DIR=$R/relayfix FIXTURE_PEERS=1 FIXTURE_REPLY_PEERS=0 FIXTURE_DUP_PEERS=0 \
  FIXTURE_GROUPS=0 FIXTURE_RELAY_PORT=$PORT FIXTURE_SERVE=1 "$SEED" >"$R/relay.log" 2>&1 &
RELAY_PID=$!
trap 'kill $RELAY_PID 2>/dev/null' EXIT
for _ in $(seq 1 120); do grep -q READY "$R/relay.log" && break; sleep 1; done
grep -q READY "$R/relay.log" || { echo "relay did not start"; cat "$R/relay.log"; exit 1; }

cli() { local bin=$1 home=$2; shift 2; "$bin" --home "$R/$home" --relay "$RELAY" "$@" 2>>"$R/$home.err"; }
npub_of() { python3 -c 'import json,sys
for l in sys.stdin:
    try: print(json.loads(l)["npub"]); break
    except Exception: pass'; }

ALICE=$(cli $V1 alice init | npub_of); BOB=$(cli $V1 bob init | npub_of)
cli $V1 alice publish >/dev/null; cli $V1 bob publish >/dev/null
echo "alice=$ALICE bob=$BOB"

# --- v1 history ---------------------------------------------------------------
for i in 1 2 3; do cli $V1 bob send --to "$ALICE" --text "v1 hello $i" >/dev/null; done
cli $V1 alice messages > "$R/alice-v1-msgs.jsonl"
grep -c '"v1 hello' "$R/alice-v1-msgs.jsonl" | grep -q 3 && ok "v1: alice has bob's 3 messages" || ko "v1: alice history ($(wc -l <"$R/alice-v1-msgs.jsonl") rows)"
cli $V1 alice send --to "$BOB" --text "v1 reply from alice" >/dev/null
TARGET=$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    m=json.loads(l)
    if m.get("content")=="v1 hello 1": print(m["id"]); break' "$R/alice-v1-msgs.jsonl")
cli $V1 alice react --to "$BOB" --target "$TARGET" --emoji "👍" >/dev/null && ok "v1: alice reacted 👍 to 'v1 hello 1' ($TARGET)" || ko "v1 react"
cli $V1 bob messages > "$R/bob-v1-msgs.jsonl"
grep -q '"v1 reply from alice"' "$R/bob-v1-msgs.jsonl" && ok "v1: bob has alice's reply" || ko "v1: bob history"

# --- upgrade alice in place (first v2 open migrates the real MDK 0.8 store) ----
ls "$R/alice" > "$R/alice-files-before.txt"
cli $V2 alice publish > "$R/alice-upgrade.out"
ls "$R/alice" > "$R/alice-files-after.txt"
find "$R/alice" -name '*.mdk08.bak' | grep -q . && ok "upgrade: alice v1 store quarantined as *.mdk08.bak" || ko "upgrade: no bak ($(cat "$R/alice-files-after.txt" | tr '\n' ' '))"
find "$R/alice" -name '*.sonar-transcript.json' | grep -q . && ok "upgrade: alice v1 transcript moved into the sealed sidecar" || ko "upgrade: no transcript sidecar"
find "$R/alice" -name '*.sonar-reactions.json' | grep -q . && ok "upgrade: reaction index present" || ko "upgrade: no reaction index"
grep -rq "v1 hello" "$R/alice" 2>/dev/null && ko "privacy: plaintext found on disk" || ok "privacy: no v1 plaintext readable on disk"

# Bob upgrades too.
cli $V2 bob publish > "$R/bob-upgrade.out"
find "$R/bob" -name '*.mdk08.bak' | grep -q . && ok "upgrade: bob migrated" || ko "upgrade: bob not migrated"

# --- first v2 send: alice creates the v2 DM, v1 history moves into it --------
cli $V2 alice send --to "$BOB" --text "v2 after upgrade" > "$R/alice-v2-send.out"
grep -q '"type"' "$R/alice-v2-send.out" && ok "v2: alice sent on the new v2 DM" || ko "v2 send ($(cat "$R/alice-v2-send.out"))"
cli $V2 alice groups > "$R/alice-v2-groups.jsonl"
LIVE=$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    m=json.loads(l)
    if m.get("type")=="group" or "members" in m: print(m["id"]); break' "$R/alice-v2-groups.jsonl")
echo "alice v2 group: $LIVE"
cli $V2 alice messages --group "$LIVE" > "$R/alice-v2-msgs.jsonl"
cat "$R/alice-v2-msgs.jsonl" | python3 -c 'import json,sys
for l in sys.stdin:
    try: m=json.loads(l); print("   ", m.get("content"), "| reactions:", m.get("reactions"))
    except Exception: pass'
n=$(grep -c '"v1 hello' "$R/alice-v2-msgs.jsonl")
[[ "$n" == 3 ]] && ok "fold: alice's v2 chat holds the 3 decrypted v1 messages" || ko "fold: v2 chat has $n v1 rows"
grep -q '"v1 reply from alice"' "$R/alice-v2-msgs.jsonl" && ok "fold: alice's own v1 reply moved too" || ko "fold: own v1 reply missing"
grep -q '"v2 after upgrade"' "$R/alice-v2-msgs.jsonl" && ok "fold: new v2 message in the same chat" || ko "fold: v2 message missing"
python3 - "$R/alice-v2-msgs.jsonl" <<'PY' && ok "fold: v1 👍 still on 'v1 hello 1' inside the v2 chat" || ko "fold: v1 reaction lost"
import json,sys
for l in open(sys.argv[1]):
    m=json.loads(l)
    if m.get("content")=="v1 hello 1":
        r=m.get("reactions") or []
        sys.exit(0 if any(x.get("emoji")=="👍" for x in r) else 1)
sys.exit(1)
PY

# --- bob: the v2 welcome folds his v1 chat; he sees history + the new message --
# One-shot verbs can exit before the live welcome lands; listen like peers.sh.
cli $V2 bob listen --timeout-secs 12 --poll-secs 3 > "$R/bob-v2-listen.jsonl"
cli $V2 bob messages > "$R/bob-v2-msgs.jsonl"
grep -q '"v2 after upgrade"' "$R/bob-v2-msgs.jsonl" && ok "bob: received the v2 message (welcome auto-joined)" || ko "bob: v2 message not received"
nb=$(grep -c '"v1 hello' "$R/bob-v2-msgs.jsonl")
[[ "$nb" == 3 ]] && ok "bob: his v1 history moved into the same v2 chat" || ko "bob: v2 chat has $nb v1 rows"

# --- reply both ways on v2 ------------------------------------------------------
cli $V2 bob send --to "$ALICE" --text "v2 reply from bob" >/dev/null
cli $V2 alice listen --timeout-secs 8 --poll-secs 3 >/dev/null
cli $V2 alice messages --group "$LIVE" > "$R/alice-v2-msgs2.jsonl"
grep -q '"v2 reply from bob"' "$R/alice-v2-msgs2.jsonl" && ok "v2: bob's reply lands in alice's same chat" || ko "v2: bob reply not in alice's chat"
na=$(cli $V2 alice groups | grep -c '"id"')
[[ "$na" == 1 ]] && ok "v2: alice has exactly one chat with bob" || ko "v2: alice lists $na chats"
nb2=$(cli $V2 bob groups | grep -c '"id"')
[[ "$nb2" == 1 ]] && ok "v2: bob has exactly one chat with alice" || ko "v2: bob lists $nb2 chats"

echo "RESULT pass=$pass fail=$fail"
(( fail == 0 ))
