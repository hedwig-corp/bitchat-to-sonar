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
#   peers.sh share-tz <name> <to-npub> <zone> share an IANA zone privately (encrypted
#                                             in MLS) with the existing 1:1 chat
#   peers.sh expect-tz <name> <from-npub> [zone] [secs]
#                                             exit 0 once <from> has shared a zone
#                                             (== <zone> when given); prints it
#   peers.sh tz <name>                        print every zone peers shared (JSON)
#   peers.sh share-tz-group <name> <group-hex> <zone>
#                                             share a zone with a multi-member group
#   peers.sh accept <name>                    accept every pending group invite
#   peers.sh groups <name>                    print the peer's groups + members
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
  share-tz)
    name="${1:?share-tz <name> <to> <zone>}"; to="${2:?to npub}"; zone="${3:?IANA zone}"
    cli --home "$(home "$name")" timezone share --to "$to" --zone "$zone" | grep '"type"' ;;
  expect-tz)
    name="${1:?expect-tz <name> <from> [zone] [secs]}"; from="${2:?from npub}"
    zone="${3:-}"; secs="${4:-60}"
    args=(timezone show --from "$from" --wait-secs "$secs")
    [[ -n "$zone" ]] && args+=(--zone "$zone")
    cli --home "$(home "$name")" "${args[@]}" | grep '"type"' ;;
  tz)
    cli --home "$(home "${1:?tz <name>}")" timezone show | grep '"type"' || true ;;
  share-tz-group)
    name="${1:?share-tz-group <name> <group-hex> <zone>}"; group="${2:?group hex}"; zone="${3:?IANA zone}"
    cli --home "$(home "$name")" timezone share --group "$group" --zone "$zone" | grep '"type"' ;;
  accept)
    cli --home "$(home "${1:?accept <name>}")" accept | grep '"type"' ;;
  groups)
    cli --home "$(home "${1:?groups <name>}")" groups | grep '"type"' ;;
  *)
    sed -n '2,36p' "$0"; exit 2 ;;
esac
