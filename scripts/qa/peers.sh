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
#   peers.sh expect <name> <substring> [secs] exit 0 once a message containing
#                                             <substring> arrives, else 1
#
# Env: QA_HOME (default $TMPDIR/sonar-qa), SONAR_CLI (default core/target/release/sonar-cli).
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
QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa}"
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
      | grep '"type":"message"' || true ;;
  expect)
    name="${1:?expect <name> <substring> [secs]}"; needle="${2:?substring}"; secs="${3:-60}"
    start=$SECONDS
    if cli --home "$(home "$name")" listen --timeout-secs "$secs" --poll-secs 5 \
        | grep '"type":"message"' | grep -F -q -- "$needle"; then
      echo "expect ok: '$needle' reached $name after $((SECONDS - start))s"
    else
      echo "expect TIMEOUT: '$needle' never reached $name (${secs}s)" >&2; exit 1
    fi ;;
  *)
    sed -n '2,25p' "$0"; exit 2 ;;
esac
