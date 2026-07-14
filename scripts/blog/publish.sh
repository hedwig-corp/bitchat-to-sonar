#!/usr/bin/env bash
# Publish Sonar blog posts (docs/blog/<slug>/README.md) as NIP-23 (kind 30023)
# long-form events to public relays. The website reads them back at runtime
# (web/src/lib/blog-nostr.js) with the static list as fallback.
#
# Signer (never commit). Resolved from, in order:
#   SONAR_BLOG_BUNKER / SONAR_BLOG_BUNKER_FILE  (NIP-46 bunker:// URL — signer
#                                                app must be online to answer)
#   SONAR_BLOG_NSEC / SONAR_BLOG_NSEC_FILE       (raw nsec/hex key)
# The signer's pubkey MUST equal BLOG_PUBKEY_HEX in web/src/lib/blog-data.js,
# otherwise the site filters the posts out.
#
# Config is loaded from scripts/blog/.env (gitignored) if present, so the signer
# does not have to be re-exported every run. Override the path with SONAR_BLOG_ENV.
# See scripts/blog/.env.example for the template.
#
# Usage:
#   scripts/blog/publish.sh [--dry-run] [slug ...]
#     no slug   → every docs/blog/*/README.md
#     slug      → docs/blog/<slug>/README.md
#     --dry-run → build + sign + print the event(s), do not publish
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BLOG_DIR="$ROOT/docs/blog"

# Load local config (signer, overrides) if present. The file uses conditional
# `: "${VAR:=…}"` assignment, so a value already exported in the environment
# wins — `SONAR_BLOG_BUNKER=… publish.sh` still overrides the file for a one-off.
ENV_FILE="${SONAR_BLOG_ENV:-$ROOT/scripts/blog/.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# Keep this list in sync with BLOG_FEED_RELAYS in web/src/lib/blog-data.js.
RELAYS=(
  wss://relay.damus.io
  wss://nos.lol
  wss://relay.primal.net
  wss://nostr.relay.hedwig.sh
)

command -v nak >/dev/null 2>&1 || { echo "error: nak not found (go install github.com/fiatjaf/nak@latest)" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "error: node not found" >&2; exit 1; }

DRY_RUN=0
SLUGS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) SLUGS+=("$arg") ;;
  esac
done

# Resolve the signer. A bunker:// URL takes precedence over a raw key. nak
# accepts either via --sec.
SIGNER="${SONAR_BLOG_BUNKER:-}"
if [[ -z "$SIGNER" && -n "${SONAR_BLOG_BUNKER_FILE:-}" ]]; then
  SIGNER="$(tr -d '[:space:]' < "${SONAR_BLOG_BUNKER_FILE}")"
fi
if [[ -z "$SIGNER" ]]; then
  SIGNER="${SONAR_BLOG_NSEC:-}"
  if [[ -z "$SIGNER" && -n "${SONAR_BLOG_NSEC_FILE:-}" ]]; then
    SIGNER="$(tr -d '[:space:]' < "${SONAR_BLOG_NSEC_FILE}")"
  fi
fi
if [[ "$DRY_RUN" -eq 0 && -z "$SIGNER" ]]; then
  echo "error: set SONAR_BLOG_BUNKER(_FILE) or SONAR_BLOG_NSEC(_FILE) to publish (or pass --dry-run)" >&2
  exit 1
fi

# Build the list of README paths.
READMES=()
if [[ "${#SLUGS[@]}" -gt 0 ]]; then
  for slug in "${SLUGS[@]}"; do
    f="$BLOG_DIR/$slug/README.md"
    [[ -f "$f" ]] || { echo "error: no post at $f" >&2; exit 1; }
    READMES+=("$f")
  done
else
  while IFS= read -r f; do READMES+=("$f"); done < <(find "$BLOG_DIR" -mindepth 2 -maxdepth 2 -name README.md | sort)
fi

[[ "${#READMES[@]}" -gt 0 ]] || { echo "no posts found under $BLOG_DIR" >&2; exit 1; }

TMP_BODY="$(mktemp)"
trap 'rm -f "$TMP_BODY"' EXIT

for readme in "${READMES[@]}"; do
  slug="$(basename "$(dirname "$readme")")"
  event_json="$(node "$ROOT/scripts/blog/build-event.mjs" "$readme" "$TMP_BODY")"

  nak_args=(event -c "@$TMP_BODY")
  [[ -n "$SIGNER" ]] && nak_args+=(--sec "$SIGNER")

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "── dry-run: $slug ──" >&2
    printf '%s' "$event_json" | nak "${nak_args[@]}"
    echo
  else
    echo "── publishing: $slug ──" >&2
    printf '%s' "$event_json" | nak "${nak_args[@]}" "${RELAYS[@]}"
    echo
  fi
done
