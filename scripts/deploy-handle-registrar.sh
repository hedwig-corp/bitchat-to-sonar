#!/usr/bin/env bash
# Deploy the Sonar handle registrar (services/handle-registrar).
#
# Usage:
#   scripts/deploy-handle-registrar.sh            # typecheck + tests + deploy
#   scripts/deploy-handle-registrar.sh --check    # everything except the real deploy
#   scripts/deploy-handle-registrar.sh --dry-run  # alias for --check
#
# Secrets (CF_DNS_TOKEN, optional REGISTER_SECRET) are managed with
# `wrangler secret put` and are never read or printed here.

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --check|--dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_DIR="$REPO_ROOT/services/handle-registrar"
cd "$SERVICE_DIR"

echo "==> Installing dependencies"
npm ci 2>/dev/null || npm install

echo "==> Typechecking"
npx tsc --noEmit

echo "==> Running tests"
npx vitest run

# Refuse to ship a config that would silently break DNS writes: the ZONE_ID
# placeholder means every offer registration would 502.
if grep -q 'FILL_ME' wrangler.jsonc; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "warning: ZONE_ID placeholder still present in wrangler.jsonc (fine for --check, blocks real deploy)" >&2
  else
    echo "error: ZONE_ID in wrangler.jsonc is still the FILL_ME placeholder." >&2
    echo "       Fill it with the Cloudflare zone id for sonarprivacy.xyz, then re-run." >&2
    exit 1
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "==> Dry run: validating bundle without deploying"
  npx wrangler deploy --dry-run
  echo "==> Dry run OK (nothing deployed)"
  exit 0
fi

echo "==> Deploying"
npx wrangler deploy

cat <<'EOF'
==> Deployed.
Reminders (one-time setup, if not done yet):
  - npx wrangler secret put CF_DNS_TOKEN        (Zone.DNS:Edit token)
  - npx wrangler secret put REGISTER_SECRET     (optional pilot gate)
  - Enable DNSSEC on the sonarprivacy.xyz zone  (required by BIP-353 clients)
EOF
