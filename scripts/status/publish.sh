#!/usr/bin/env bash
# Probe Sonar systems and publish kind 30078 status to public relays.
# Secrets: SONAR_STATUS_NSEC or SONAR_STATUS_NSEC_FILE (never commit).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${SONAR_STATUS_BIN:-$ROOT/core/target/release/sonar-status}"
STATE_DIR="${SONAR_STATUS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/sonar-status}"
NSEC_FILE="${SONAR_STATUS_NSEC_FILE:-}"
PREV="$STATE_DIR/previous.json"
OUT="$STATE_DIR/last.json"

mkdir -p "$STATE_DIR"

if [[ ! -x "$BIN" ]]; then
  echo "building sonar-status…"
  cargo build -p sonar-status --release --manifest-path "$ROOT/core/Cargo.toml"
  BIN="$ROOT/core/target/release/sonar-status"
fi

args=(publish --out "$OUT")
if [[ -n "$NSEC_FILE" ]]; then
  args+=(--nsec-file "$NSEC_FILE")
elif [[ -z "${SONAR_STATUS_NSEC:-}" ]]; then
  echo "error: set SONAR_STATUS_NSEC or SONAR_STATUS_NSEC_FILE" >&2
  exit 1
fi

if [[ -f "$OUT" ]]; then
  cp "$OUT" "$PREV"
  args+=(--previous "$PREV")
fi

# Optional: SONAR_STATUS_HTTP="https://a/health https://b/health"
if [[ -n "${SONAR_STATUS_HTTP:-}" ]]; then
  # shellcheck disable=SC2206
  for u in $SONAR_STATUS_HTTP; do
    args+=(--http "$u")
  done
fi

if [[ "${1:-}" == "--dry-run" ]]; then
  args+=(--dry-run)
fi

exec "$BIN" "${args[@]}"
