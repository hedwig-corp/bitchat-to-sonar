#!/usr/bin/env bash
# peers.sh — headless White Noise/Marmot counterparties for agent QA passes.
#
# Each peer is a `sonar-cli` home under $QA_HOME/peers/<name>. Peers are
# throwaway identities: create fresh ones per run so welcomes, first-message
# and pending-chat paths are exercised every time.
#
#   peers.sh new <name>                       init + publish KeyPackage → npub
#   peers.sh npub <name>                      print the peer's npub
#   peers.sh send <name> <to-npub> <text>     encrypted text DM
#   peers.sh send-image <name> <to-npub> <file> [blossom-url]
#   peers.sh listen <name> [secs]             JSON lines of inbound messages
#                                             (streams; runs the full window)
#   peers.sh expect <name> <substring> [secs] print the first inbound message JSON
#                                             containing <substring> and exit 0 the
#                                             moment it arrives; exit 1 on timeout
#   peers.sh id-of <name> <substring>         id of the newest message (either side)
#                                             whose text contains <substring>
#   peers.sh id-of-media <name>               id of the newest media message the
#                                             peer sent
#   peers.sh react <name> <to-npub> <target-id> <emoji>
#                                             encrypted NIP-25 kind-7 on a message in
#                                             the 1:1 chat with <to-npub>; waits for
#                                             the relay ack
#   peers.sh expect-reaction <name> <emoji> [secs] [target-id] [count]
#                                             print the first tally update (either a
#                                             `reactions` line or an inbound message
#                                             carrying chips) that shows <emoji>
#                                             (on <target-id>, with at least <count>
#                                             reactors when given); exit 1 on timeout
#
# Env: QA_HOME (default $TMPDIR/sonar-qa-<worktree>), SONAR_CLI (default core/target/release/sonar-cli).
#
# Known limits (see .agents/skills/qa-pass/reference.md):
# - Only 1:1 welcomes auto-join. Multi-member group invites stay pending in the
#   CLI, so group delivery cannot be verified with these peers.
# - The default Blossom server (push.sonar.hedwig.sh) took ~36 s per upload on
#   2026-09-23; send-image defaults to https://nostr.download so media scenarios
#   measure the app, not that server. Pass the URL explicitly to test the default.
# - `listen` publishes a KeyPackage at startup; the first listen after the app
#   starts a chat can take 10-20 s while the welcome is processed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa-$(basename "$ROOT")}"
CLI="${SONAR_CLI:-$ROOT/core/target/release/sonar-cli}"
PEERS="$QA_HOME/peers"
mkdir -p "$PEERS"

if [[ ! -x "$CLI" ]]; then
  echo ">> building sonar-cli (cargo build -p sonar-cli --release)" >&2
  (cd "$ROOT/core" && cargo build -q -p sonar-cli --release)
fi

home() { echo "$PEERS/${1:?peer name}"; }

# sonar-cli logs relay chatter (auth-required warnings, …) on stderr; drop it
# so an agent reading the output sees only the JSON result lines.
cli() { "$CLI" "$@" 2>/dev/null; }

json_field() {
  python3 -c 'import json,sys
for line in sys.stdin:
    try: print(json.loads(line)[sys.argv[1]]); break
    except (ValueError, KeyError): pass' "$1"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  new)
    name="${1:?new <name>}"
    [[ -e "$(home "$name")" ]] && { echo "peer '$name' exists: $(home "$name")" >&2; exit 1; }
    npub="$(cli --home "$(home "$name")" init | json_field npub)"
    [[ "$npub" == npub1* ]] || { echo "init failed for '$name'" >&2; exit 1; }
    cli --home "$(home "$name")" publish >/dev/null
    echo "$npub" > "$(home "$name")/npub"
    echo "$npub" ;;
  npub)
    cat "$(home "${1:?npub <name>}")/npub" ;;
  send)
    name="${1:?send <name> <to> <text>}"; to="${2:?to npub}"; shift 2
    cli --home "$(home "$name")" send --to "$to" --text "$*" | grep '"type"' ;;
  send-image)
    name="${1:?send-image <name> <to> <file>}"; to="${2:?to npub}"; file="${3:?file}"
    blossom="${4:-https://nostr.download}"
    cli --home "$(home "$name")" send --to "$to" --file "$file" --kind image --blossom "$blossom" \
      | grep '"type"' ;;
  listen)
    name="${1:?listen <name> [secs]}"; secs="${2:-30}"
    cli --home "$(home "$name")" listen --timeout-secs "$secs" --poll-secs 5 \
      | grep --line-buffered '"type":"message"' || true ;;
  expect)
    # A shell pipeline (listen | grep | grep -q) block-buffers the first grep
    # and keeps `sonar-cli listen` running to its timeout, so every match cost
    # the full window. Match line by line and stop the listener on the hit.
    name="${1:?expect <name> <substring> [secs]}"; needle="${2:?substring}"; secs="${3:-60}"
    python3 - "$CLI" "$(home "$name")" "$needle" "$secs" "$name" <<'EXPECT_PY'
import json, subprocess, sys, time
cli, home, needle, secs, name = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
start = time.monotonic()
proc = subprocess.Popen(
    [cli, "--home", home, "listen", "--timeout-secs", str(secs), "--poll-secs", "5"],
    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
try:
    for line in proc.stdout:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("type") == "message" and needle in msg.get("content", ""):
            print(line.strip())
            print(f"expect ok: '{needle}' reached {name} after "
                  f"{time.monotonic() - start:.0f}s", file=sys.stderr)
            sys.exit(0)
finally:
    proc.kill()
print(f"expect TIMEOUT: '{needle}' never reached {name} ({secs}s)", file=sys.stderr)
sys.exit(1)
EXPECT_PY
    ;;
  id-of)
    name="${1:?id-of <name> <substring>}"; needle="${2:?substring}"
    cli --home "$(home "$name")" messages | python3 -c '
import json, sys
needle, best = sys.argv[1], None
for line in sys.stdin:
    try: m = json.loads(line)
    except ValueError: continue
    if m.get("type") == "message" and needle in m.get("content", ""):
        if best is None or m["created_at_secs"] >= best["created_at_secs"]: best = m
if best is None: sys.exit("no message contains " + repr(needle))
print(best["id"])' "$needle" ;;
  id-of-media)
    name="${1:?id-of-media <name>}"
    cli --home "$(home "$name")" messages | python3 -c '
import json, sys
best = None
for line in sys.stdin:
    try: m = json.loads(line)
    except ValueError: continue
    if m.get("type") == "message" and m.get("mine") and m.get("media"):
        if best is None or m["created_at_secs"] >= best["created_at_secs"]: best = m
if best is None: sys.exit("no media message sent by this peer")
print(best["id"])' ;;
  react)
    name="${1:?react <name> <to> <target-id> <emoji>}"; to="${2:?to npub}"
    target="${3:?target id}"; emoji="${4:?emoji}"
    cli --home "$(home "$name")" react --to "$to" --target "$target" --emoji "$emoji" \
      | grep '"type"' ;;
  expect-reaction)
    name="${1:?expect-reaction <name> <emoji> [secs] [target-id] [count]}"; emoji="${2:?emoji}"
    secs="${3:-60}"; target="${4:-}"; count="${5:-1}"
    python3 - "$CLI" "$(home "$name")" "$emoji" "$secs" "$target" "$count" "$name" <<'EXPECT_PY'
import json, subprocess, sys, time
cli, home, emoji, secs, target, count, name = sys.argv[1:8]
secs, count = int(secs), int(count)
start = time.monotonic()
proc = subprocess.Popen(
    [cli, "--home", home, "listen", "--timeout-secs", str(secs), "--poll-secs", "5"],
    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
try:
    for line in proc.stdout:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "reactions":
            tallies, tid = ev.get("tallies", []), ev.get("target_id", "")
        elif ev.get("type") == "message":
            tallies, tid = ev.get("reactions", []), ev.get("id", "")
        else:
            continue
        if target and tid != target:
            continue
        if any(t.get("emoji") == emoji and t.get("count", 0) >= count for t in tallies):
            print(line.strip())
            print(f"expect-reaction ok: {emoji} reached {name} after "
                  f"{time.monotonic() - start:.0f}s", file=sys.stderr)
            sys.exit(0)
finally:
    proc.kill()
print(f"expect-reaction TIMEOUT: {emoji} never reached {name} ({secs}s)", file=sys.stderr)
sys.exit(1)
EXPECT_PY
    ;;
  *)
    sed -n '2,39p' "$0"; exit 2 ;;
esac
