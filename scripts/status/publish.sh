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

# Always rebuild from the checkout, so a `git pull` on the scheduler host takes
# effect on the next run. Building only when the binary is missing silently
# reuses a stale one: probe changes land in git, every publish still looks
# healthy, and the document never actually changes. Cargo is a fast no-op when
# the tree is unchanged. Set SONAR_STATUS_BIN to opt out and manage the binary
# yourself (e.g. a host without a Rust toolchain).
if [[ -n "${SONAR_STATUS_BIN:-}" ]]; then
  if [[ ! -x "$BIN" ]]; then
    echo "error: SONAR_STATUS_BIN=$BIN is not executable" >&2
    exit 1
  fi
else
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

# Optional chat probe: set SONAR_STATUS_CHAT_PROBE=1 and
# SONAR_STATUS_PROBE_NSEC or SONAR_STATUS_PROBE_NSEC_FILE (dedicated identity).
if [[ "${SONAR_STATUS_CHAT_PROBE:-}" == "1" || "${SONAR_STATUS_CHAT_PROBE:-}" == "true" ]]; then
  args+=(--chat-probe)
fi
if [[ -n "${SONAR_STATUS_PROBE_NSEC_FILE:-}" ]]; then
  args+=(--probe-nsec-file "$SONAR_STATUS_PROBE_NSEC_FILE")
fi

if [[ "${SONAR_STATUS_STICKER_PROBE:-}" == "1" || "${SONAR_STATUS_STICKER_PROBE:-}" == "true" ]]; then
  args+=(--sticker-probe)
fi
if [[ "${SONAR_STATUS_MEDIA_PROBE:-}" == "1" || "${SONAR_STATUS_MEDIA_PROBE:-}" == "true" ]]; then
  args+=(--media-probe)
fi
# Optional: SONAR_STATUS_BLOSSOM_SERVER / SONAR_STATUS_BLOSSOM_COMPARE are
# forwarded via clap env attrs on the binary (no extra flags needed here).

if [[ -n "${SONAR_STATUS_GROUPS_RESULT:-}" ]]; then
  args+=(--groups-result "$SONAR_STATUS_GROUPS_RESULT")
fi
if [[ "${SONAR_STATUS_PAYMENTS_COMING_SOON:-}" == "1" ]]; then
  args+=(--payments-coming-soon)
fi

if [[ "${1:-}" == "--dry-run" ]]; then
  args+=(--dry-run)
fi

exec "$BIN" "${args[@]}"
