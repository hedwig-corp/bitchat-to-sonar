#!/usr/bin/env bash
# Publish the current Android alpha to Zapstore (https://zapstore.dev).
#
# Prerequisites:
#   - zsp on PATH  (go install github.com/zapstore/zsp@latest)
#   - SIGN_WITH    nsec1… | bunker://… | browser
#   - Android release signing keystore + passwords (see below)
#   - gh auth      optional; used as GITHUB_TOKEN to avoid API rate limits
#
# Keystore (any of):
#   SONAR_KEYSTORE / SONAR_KEYSTORE_PASSWORD / SONAR_KEY_ALIAS / SONAR_KEY_PASSWORD
#   or apps/sonar/local.properties:
#     sonar.keystore=...
#     sonar.keystore.password=...
#     sonar.key.alias=...
#     sonar.key.password=...
#
# Usage:
#   scripts/zapstore-publish.sh              # phone APK from GitHub release
#   scripts/zapstore-publish.sh --local      # build + sign local phone APK, then publish
#   scripts/zapstore-publish.sh --check      # dry-run fetch only
#
# All alpha tags are GitHub pre-releases → always passes --pre-release.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIG="${ZAPSTORE_CONFIG:-$REPO_ROOT/zapstore.yaml}"
DIST_DIR="$REPO_ROOT/dist"
SIGNED_APK="$DIST_DIR/sonar-android-signed.apk"
APKSIGNER="${APKSIGNER:-}"

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

need zsp

# --- load signing props from local.properties if env unset --------------------
lp="$REPO_ROOT/apps/sonar/local.properties"
prop() {
  local key="$1"
  [[ -f "$lp" ]] || return 0
  # shellcheck disable=SC2002
  grep -E "^${key}=" "$lp" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

SONAR_KEYSTORE="${SONAR_KEYSTORE:-$(prop sonar.keystore)}"
SONAR_KEYSTORE_PASSWORD="${SONAR_KEYSTORE_PASSWORD:-$(prop sonar.keystore.password)}"
SONAR_KEY_ALIAS="${SONAR_KEY_ALIAS:-$(prop sonar.key.alias)}"
SONAR_KEY_PASSWORD="${SONAR_KEY_PASSWORD:-$(prop sonar.key.password)}"

# Default keystore path if present on this machine (never committed)
if [[ -z "$SONAR_KEYSTORE" && -f "$HOME/upload-keystore.jks" ]]; then
  SONAR_KEYSTORE="$HOME/upload-keystore.jks"
fi
if [[ -z "$SONAR_KEY_ALIAS" ]]; then
  SONAR_KEY_ALIAS="upload"
fi

find_apksigner() {
  if [[ -n "$APKSIGNER" && -x "$APKSIGNER" ]]; then
    echo "$APKSIGNER"
    return
  fi
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  local found
  found="$(ls -1 "$sdk"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n "$found" ]] || die "apksigner not found; set ANDROID_HOME or APKSIGNER"
  echo "$found"
}

sign_apk() {
  local in_apk="$1"
  local out_apk="$2"
  [[ -f "$in_apk" ]] || die "APK not found: $in_apk"
  [[ -n "$SONAR_KEYSTORE" && -f "$SONAR_KEYSTORE" ]] || \
    die "signing keystore missing. Set SONAR_KEYSTORE or sonar.keystore in local.properties"
  [[ -n "$SONAR_KEYSTORE_PASSWORD" && -n "$SONAR_KEY_PASSWORD" ]] || \
    die "set SONAR_KEYSTORE_PASSWORD and SONAR_KEY_PASSWORD (or local.properties equivalents)"

  local apksigner
  apksigner="$(find_apksigner)"
  mkdir -p "$(dirname "$out_apk")"
  echo "→ signing $in_apk → $out_apk (alias=$SONAR_KEY_ALIAS)"
  "$apksigner" sign \
    --ks "$SONAR_KEYSTORE" \
    --ks-pass "pass:$SONAR_KEYSTORE_PASSWORD" \
    --ks-key-alias "$SONAR_KEY_ALIAS" \
    --key-pass "pass:$SONAR_KEY_PASSWORD" \
    --v1-signing-enabled true \
    --v2-signing-enabled true \
    --v3-signing-enabled true \
    --out "$out_apk" \
    "$in_apk"
  "$apksigner" verify --verbose "$out_apk" | tail -5
}

MODE="github"
for arg in "$@"; do
  case "$arg" in
    --local) MODE="local" ;;
    --check) MODE="check" ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *) die "unknown arg: $arg" ;;
  esac
done

# GitHub token for rate limits / private assets
if [[ -z "${GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
  export GITHUB_TOKEN
fi

export GITHUB_TOKEN="${GITHUB_TOKEN:-}"

case "$MODE" in
  check)
    echo "→ zsp publish --check --pre-release $CONFIG"
    zsp publish --check --pre-release "$CONFIG"
    ;;
  local)
    [[ -n "${SIGN_WITH:-}" ]] || die "set SIGN_WITH (nsec1…, bunker://…, or browser)"
    echo "→ building phone release APK"
    (
      cd "$REPO_ROOT/apps/sonar"
      ./gradlew :composeApp:assembleRelease --no-daemon
    )
    UNSIGNED="$REPO_ROOT/apps/sonar/composeApp/build/outputs/apk/release/composeApp-release-unsigned.apk"
    # Gradle may emit app-release.apk when signing is configured
    if [[ ! -f "$UNSIGNED" ]]; then
      UNSIGNED="$(ls "$REPO_ROOT"/apps/sonar/composeApp/build/outputs/apk/release/*.apk 2>/dev/null | head -1 || true)"
    fi
    [[ -f "$UNSIGNED" ]] || die "no release APK produced"
    sign_apk "$UNSIGNED" "$SIGNED_APK"
    echo "→ publishing local signed APK to Zapstore"
    zsp publish --pre-release --quiet \
      -r https://github.com/hedwig-corp/bitchat-to-sonar \
      "$SIGNED_APK"
    ;;
  github)
    [[ -n "${SIGN_WITH:-}" ]] || die "set SIGN_WITH (nsec1…, bunker://…, or browser)"
    # Prefer publishing a freshly signed local phone APK if present; else GitHub.
    if [[ -f "$SIGNED_APK" ]]; then
      echo "→ publishing existing $SIGNED_APK"
      zsp publish --pre-release --quiet \
        -r https://github.com/hedwig-corp/bitchat-to-sonar \
        "$SIGNED_APK"
    else
      echo "→ publishing from GitHub release (must be v2+ signed APK)"
      echo "  tip: if the release asset is unsigned, run with --local first"
      zsp publish --pre-release --quiet "$CONFIG"
    fi
    ;;
esac

echo "✅ Zapstore step finished"
