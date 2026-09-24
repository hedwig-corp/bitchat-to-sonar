#!/usr/bin/env bash
# ios-setup.sh — create/boot a DEDICATED QA simulator, build the app SIGNED
# (Debug, arm64), install it and start a unified-log capture. Prints the UDID.
#
#   scripts/qa/ios-setup.sh [--name "<simulator name>"] [--no-build] [--fresh]
#                           [--build-core | --trust-core] [--allow-missing-config]
#
# The default simulator is "Sonar QA <worktree name>": one per worktree, so
# two agents on the same Mac never install into (or --fresh-erase) the same
# device.
#
# Why signed, not scripts/bench/build-sim.sh: the unsigned bench build has no
# App Group entitlement, so the Marmot store cannot open and real onboarding /
# messaging cannot be tested. A signed simulator build carries the simulated
# entitlements (App Group + keychain) and behaves like the real app.
#
# Always target the simulator by UDID — never `booted`. Other agents on the
# same Mac share CoreSimulator; one ran `simctl uninstall booted` mid-QA and
# wiped the app under test. Use a SECOND dedicated simulator for
# `xcodebuild test` (tests clone and reboot their destination).
#
# --fresh erases this QA simulator's app (simulators are disposable; real
# devices are never touched by this script).
#
# Rust core freshness: sonarffi.xcframework is gitignored, so a worktree can
# carry one built from an OLDER core. An ABI-compatible build links fine and
# the pass silently tests old core code. The script records the core it was
# built from in Frameworks/.sonar-core-tree — `git rev-parse HEAD:core`, plus a
# hash of the uncommitted core diff and untracked core files when the tree is
# dirty, so each new edit needs a new build — and refuses a mismatch:
# --build-core runs core/build-ios.sh and writes the stamp; --trust-core
# accepts the current framework (you checked it yourself).
#
# Preflight (presence only — values are never printed): BREEZ_API_KEY in
# ios/Configs/Local.xcconfig or the environment (then handed to xcodebuild via
# a 0600 temp xcconfig, never argv) and ios/bitchat/GoogleService-Info.plist. Debug
# builds succeed without them, but wallet flows / offline-payment pushes are
# silently off. Refused unless --allow-missing-config, which records the gap
# in $QA_HOME/config-gaps.txt for the QA report.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa-$(basename "$ROOT")}"   # per worktree
NAME="Sonar QA $(basename "$ROOT")"; BUILD=1; FRESH=0; CORE=check; ALLOW_MISSING=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --fresh) FRESH=1; shift ;;
    --build-core) CORE=build; shift ;;
    --trust-core) CORE=trust; shift ;;
    --allow-missing-config) ALLOW_MISSING=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$QA_HOME"
BUNDLE=sh.hedwig.sonar

missing=()
KEY_XCCONFIG=""
if ! grep -Eq '^[[:space:]]*BREEZ_API_KEY[[:space:]]*=[[:space:]]*[^[:space:]]' \
    "$ROOT/ios/Configs/Local.xcconfig" 2>/dev/null; then
  if [[ -n "${BREEZ_API_KEY:-}" ]]; then
    # Release.xcconfig sets the key to empty, so an env var alone never
    # reaches the build: pass it as an -xcconfig override from a private
    # temp file (not argv, where `ps` would show it).
    KEY_XCCONFIG="$(mktemp "${TMPDIR:-/tmp}/sonar-qa-breez.XXXXXX")"
    chmod 600 "$KEY_XCCONFIG"
    trap 'rm -f "$KEY_XCCONFIG"' EXIT
    printf 'BREEZ_API_KEY = %s\n' "$BREEZ_API_KEY" > "$KEY_XCCONFIG"
  else
    missing+=("BREEZ_API_KEY (ios/Configs/Local.xcconfig or env): wallet flows off")
  fi
fi
[[ -f "$ROOT/ios/bitchat/GoogleService-Info.plist" ]] ||
  missing+=("ios/bitchat/GoogleService-Info.plist: no FCM, no offline-payment pushes")
# config-gaps.txt reflects THIS run: drop the platform's old entries first, so
# a gap fixed since the last setup is not still reported as "not run".
if [[ -f "$QA_HOME/config-gaps.txt" ]]; then
  grep -v '^ios: ' "$QA_HOME/config-gaps.txt" > "$QA_HOME/config-gaps.txt.tmp" || true
  mv "$QA_HOME/config-gaps.txt.tmp" "$QA_HOME/config-gaps.txt"
fi
if (( ${#missing[@]} )); then
  printf 'missing local config:\n' >&2; printf '  - %s\n' "${missing[@]}" >&2
  if (( ! ALLOW_MISSING )); then
    echo "refusing to build a QA app that silently lacks them; copy them from the primary" >&2
    echo "checkout, or pass --allow-missing-config and report wallet/push scenarios as not run." >&2
    exit 1
  fi
  for gap in "${missing[@]}"; do echo "ios: $gap" >> "$QA_HOME/config-gaps.txt"; done
fi

FRAMEWORKS="$ROOT/ios/localPackages/SonarCore/Frameworks"
STAMP="$FRAMEWORKS/.sonar-core-tree"
CORE_TREE="$(git -C "$ROOT" rev-parse HEAD:core)"
if [[ -n "$(git -C "$ROOT" status --porcelain -- core)" ]]; then
  # Hash the actual uncommitted content (tracked diff + untracked files), so a
  # second edit after a build no longer matches the first build's stamp.
  dirty_hash="$(
    cd "$ROOT" && {
      git diff HEAD --binary -- core
      git ls-files --others --exclude-standard -z -- core | xargs -0 shasum 2>/dev/null
    } | shasum | cut -c1-16
  )"
  CORE_TREE="$CORE_TREE+dirty-$dirty_hash"
fi
case "$CORE" in
  build)
    echo ">> building the Rust core for iOS (core/build-ios.sh)" >&2
    "$ROOT/core/build-ios.sh" >&2
    echo "$CORE_TREE" > "$STAMP" ;;
  trust)
    [[ -d "$FRAMEWORKS/sonarffi.xcframework" ]] || { echo "no sonarffi.xcframework to trust" >&2; exit 1; } ;;
  check)
    if [[ ! -d "$FRAMEWORKS/sonarffi.xcframework" ]]; then
      echo "sonarffi.xcframework missing — rerun with --build-core" >&2; exit 1
    fi
    if [[ "$(cat "$STAMP" 2>/dev/null)" != "$CORE_TREE" ]]; then
      echo "sonarffi.xcframework was not built from this core (stamp '$(cat "$STAMP" 2>/dev/null || echo none)'," >&2
      echo "need '$CORE_TREE'): rerun with --build-core, or --trust-core if you verified it." >&2
      exit 1
    fi ;;
esac

UDID="$(xcrun simctl list devices available | sed -nE "s/^[[:space:]]+$NAME \(([0-9A-F-]+)\).*/\1/p" | head -1)"
if [[ -z "$UDID" ]]; then
  TYPE="$(xcrun simctl list devicetypes | grep -E '^iPhone [0-9]+ Pro \(' | sort -t' ' -k2,2n \
    | tail -1 | sed -nE 's/^iPhone [0-9]+ Pro \((.*)\)$/\1/p')"
  RUNTIME="$(xcrun simctl list runtimes available | sed -nE 's/^iOS .* - (com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+)$/\1/p' | tail -1)"
  echo ">> creating simulator '$NAME' ($TYPE, $RUNTIME)" >&2
  UDID="$(xcrun simctl create "$NAME" "$TYPE" "$RUNTIME")"
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null

APP="$QA_HOME/DerivedData/Build/Products/Debug-iphonesimulator/Sonar.app"
if (( BUILD )); then
  echo ">> building signed Debug for $UDID" >&2
  set -o pipefail
  key_args=()
  [[ -n "$KEY_XCCONFIG" ]] && key_args=(-xcconfig "$KEY_XCCONFIG")
  if ! xcodebuild build -project "$ROOT/ios/bitchat.xcodeproj" -scheme "bitchat (iOS)" \
      -configuration Debug -destination "id=$UDID" -derivedDataPath "$QA_HOME/DerivedData" \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 -allowProvisioningUpdates \
      ${key_args[@]+"${key_args[@]}"} > "$QA_HOME/ios-build.log" 2>&1; then
    grep -E "error:" "$QA_HOME/ios-build.log" | head -20 >&2
    echo "BUILD FAILED — full log: $QA_HOME/ios-build.log" >&2
    exit 1
  fi
fi
[[ -d "$APP" ]] || { echo "no app at $APP (build first)" >&2; exit 1; }

if (( FRESH )); then
  echo ">> erasing the app on QA simulator $UDID" >&2
  xcrun simctl uninstall "$UDID" "$BUNDLE" || true
fi
xcrun simctl install "$UDID" "$APP"

LOG="$QA_HOME/ios-log-$UDID.txt"
PIDFILE="$QA_HOME/ios-log-$UDID.pid"
# One capture per simulator: a rerun must not add a second writer to the file.
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
fi
# chat.bitchat = BitLogger/SecureLogger (incl. SONAR_BENCH markers);
# sh.hedwig.sonar = push registration/handling and the Breez wallet logger.
nohup xcrun simctl spawn "$UDID" log stream --level info \
  --predicate 'subsystem == "chat.bitchat" OR subsystem == "sh.hedwig.sonar"' > "$LOG" 2>&1 &
echo $! > "$PIDFILE"
echo ">> unified log → $LOG (pid $!)" >&2
xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
echo "$UDID"
