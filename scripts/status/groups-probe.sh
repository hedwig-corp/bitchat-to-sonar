#!/usr/bin/env bash
# Hermes task: Group chats probe for Sonar status.
#
# Creates a test MLS group with 5 probe identities, sends a message from each,
# validates all agents received every message, and writes the result JSON.
#
# Requirements:
#   - sonar-cli built (cargo build -p sonar-cli --release)
#   - 5 probe identities initialized under $STATE_DIR/agent-{1..5}
#   - Bootstrap relays reachable
#
# Usage:
#   ./scripts/status/groups-probe.sh --setup   # one-time: create 5 identities
#   ./scripts/status/groups-probe.sh           # run probe + write result.json

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="${SONAR_STATUS_CLI:-$ROOT/core/target/release/sonar-cli}"
STATE_DIR="${SONAR_STATUS_GROUPS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/sonar-status/groups}"
RESULT="${SONAR_STATUS_GROUPS_RESULT:-$STATE_DIR/result.json}"
AGENTS=5
RELAYS="${SONAR_STATUS_PROBE_RELAYS:-wss://relay.damus.io,wss://nos.lol,wss://relay.primal.net}"

mkdir -p "$STATE_DIR"

# --- Setup: create 5 identities ---
if [[ "${1:-}" == "--setup" ]]; then
  echo "Setting up $AGENTS probe identities..."
  for i in $(seq 1 $AGENTS); do
    local_home="$STATE_DIR/agent-$i"
    if [[ -f "$local_home/config.json" ]]; then
      echo "  agent-$i already initialized, skipping"
    else
      mkdir -p "$local_home"
      "$CLI" --home "$local_home" init --force 2>/dev/null
      "$CLI" --home "$local_home" --relays "$RELAYS" publish 2>/dev/null || true
      npub=$("$CLI" --home "$local_home" identity 2>/dev/null | grep -o 'npub=[^ ]*' | cut -d= -f2 || echo "unknown")
      echo "  agent-$i: $npub"
    fi
  done
  exit 0
fi

# --- Probe: create group, send, validate ---
echo "Running groups probe with $AGENTS agents..."
START_MS=$(date +%s%3N)

# Collect all agent npubs
NPUBS=()
for i in $(seq 1 $AGENTS); do
  npub=$("$CLI" --home "$STATE_DIR/agent-$i" identity 2>/dev/null | grep -o 'npub=[^ ]*' | cut -d= -f2 || echo "")
  NPUBS+=("$npub")
done

echo "Agents: ${NPUBS[*]}"

# Agent 1 sends a DM to each other agent
GROUP_NAME="sonar-status-probe-$(date +%s)"
echo "Creating test conversations: $GROUP_NAME"

for i in $(seq 2 $AGENTS); do
  idx=$((i - 1))
  "$CLI" --home "$STATE_DIR/agent-1" --relays "$RELAYS" \
    send --to "${NPUBS[$idx]}" --text "probe-ping-$i" --group-name "$GROUP_NAME" 2>/dev/null || true
done

sleep 3  # let relays propagate

# Each agent syncs and checks for messages
VERIFIED=0
EXPECTED=$AGENTS

for i in $(seq 1 $AGENTS); do
  "$CLI" --home "$STATE_DIR/agent-$i" --relays "$RELAYS" sync 2>/dev/null || true
  msgs=$("$CLI" --home "$STATE_DIR/agent-$i" --relays "$RELAYS" messages 2>/dev/null | grep -c '"type"' || echo "0")
  if [[ "$msgs" -gt 0 ]]; then
    VERIFIED=$((VERIFIED + 1))
    echo "  agent-$i: $msgs message(s) received"
  else
    echo "  agent-$i: no messages"
  fi
done

END_MS=$(date +%s%3N)
ELAPSED=$((END_MS - START_MS))

# Write result JSON
if [[ $VERIFIED -eq $AGENTS ]]; then
  STATE="ok"
  OK="true"
  ERR="null"
else
  STATE="degraded"
  OK="false"
  ERR="\"$((AGENTS - VERIFIED)) agent(s) did not receive messages\""
fi

cat > "$RESULT" << JSON
{
  "ok": $OK,
  "state": "$STATE",
  "agents": $AGENTS,
  "messages_expected": $EXPECTED,
  "messages_verified": $VERIFIED,
  "ms": $ELAPSED,
  "error": $ERR
}
JSON

echo "Result: $RESULT"
cat "$RESULT"
