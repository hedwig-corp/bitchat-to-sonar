#!/usr/bin/env bash
# Build, independently sign, and publish Sonar Darkmatter to its Zapstore entry.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${ZAPSTORE_CONFIG:-$REPO_ROOT/zapstore-darkmatter.yaml}"
DIST_DIR="$REPO_ROOT/dist"
SIGNED_APK="$DIST_DIR/sonar-darkmatter-0.1.0-darkmatter.1-android.apk"
APKSIGNER="${APKSIGNER:-}"

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

MODE="github"
for arg in "$@"; do
  case "$arg" in
    --local) MODE="local" ;;
    --check) MODE="check" ;;
    -h|--help)
      echo "usage: $0 [--local|--check]"
      exit 0
      ;;
    *) die "unknown argument: $arg" ;;
  esac
done

need zsp

local_properties="$REPO_ROOT/apps/sonar/local.properties"
property() {
  local key="$1"
  [[ -f "$local_properties" ]] || return 0
  local property_key property_value result=""
  while IFS='=' read -r property_key property_value; do
    [[ "$property_key" == "$key" ]] && result="$property_value"
  done < "$local_properties"
  printf '%s' "$result"
}

DARKMATTER_KEYSTORE="${DARKMATTER_KEYSTORE:-$(property darkmatter.keystore)}"
DARKMATTER_KEYSTORE_PASSWORD="${DARKMATTER_KEYSTORE_PASSWORD:-$(property darkmatter.keystore.password)}"
DARKMATTER_KEY_ALIAS="${DARKMATTER_KEY_ALIAS:-$(property darkmatter.key.alias)}"
DARKMATTER_KEY_PASSWORD="${DARKMATTER_KEY_PASSWORD:-$(property darkmatter.key.password)}"

find_apksigner() {
  if [[ -n "$APKSIGNER" && -x "$APKSIGNER" ]]; then
    echo "$APKSIGNER"
    return
  fi
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  local found
  found="$(find "$sdk/build-tools" -mindepth 2 -maxdepth 2 -name apksigner -type f 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n "$found" ]] || die "apksigner not found; set ANDROID_HOME or APKSIGNER"
  echo "$found"
}

sign_apk() {
  local input="$1"
  local output="$2"
  [[ -f "$input" ]] || die "APK not found: $input"
  [[ -n "$DARKMATTER_KEYSTORE" && -f "$DARKMATTER_KEYSTORE" ]] || {
    die "set DARKMATTER_KEYSTORE to the separate Darkmatter signing keystore"
  }
  [[ -n "$DARKMATTER_KEYSTORE_PASSWORD" && -n "$DARKMATTER_KEY_ALIAS" && -n "$DARKMATTER_KEY_PASSWORD" ]] || {
    die "set all DARKMATTER_KEYSTORE_PASSWORD / DARKMATTER_KEY_ALIAS / DARKMATTER_KEY_PASSWORD values"
  }

  local signer
  signer="$(find_apksigner)"
  export DARKMATTER_KEYSTORE_PASSWORD DARKMATTER_KEY_PASSWORD
  mkdir -p "$(dirname "$output")"
  "$signer" sign \
    --ks "$DARKMATTER_KEYSTORE" \
    --ks-pass env:DARKMATTER_KEYSTORE_PASSWORD \
    --ks-key-alias "$DARKMATTER_KEY_ALIAS" \
    --key-pass env:DARKMATTER_KEY_PASSWORD \
    --v1-signing-enabled true \
    --v2-signing-enabled true \
    --v3-signing-enabled true \
    --out "$output" \
    "$input"
  "$signer" verify --verbose "$output"
}

if [[ -z "${GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
  export GITHUB_TOKEN
fi

case "$MODE" in
  check)
    zsp publish --check --pre-release "$CONFIG"
    ;;
  local)
    [[ -n "${SIGN_WITH:-}" ]] || die "set SIGN_WITH (nsec1…, bunker://…, or browser)"
    (
      cd "$REPO_ROOT/apps/sonar"
      ./gradlew :darkmatterApp:assembleRelease --no-daemon
    )
    apk="$(find "$REPO_ROOT/apps/sonar/darkmatterApp/build/outputs/apk/release" -maxdepth 1 -name '*.apk' -type f | head -1 || true)"
    [[ -n "$apk" ]] || die "Darkmatter release APK was not produced"
    sign_apk "$apk" "$SIGNED_APK"
    zsp publish --pre-release --quiet \
      -r https://github.com/hedwig-corp/bitchat-to-sonar \
      "$SIGNED_APK"
    ;;
  github)
    [[ -n "${SIGN_WITH:-}" ]] || die "set SIGN_WITH (nsec1…, bunker://…, or browser)"
    if [[ -f "$SIGNED_APK" ]]; then
      zsp publish --pre-release --quiet \
        -r https://github.com/hedwig-corp/bitchat-to-sonar \
        "$SIGNED_APK"
    else
      zsp publish --pre-release --quiet "$CONFIG"
    fi
    ;;
esac
