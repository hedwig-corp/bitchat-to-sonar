#!/usr/bin/env bash
# ios-setup.sh — create/boot a DEDICATED QA simulator, build the app SIGNED
# (Debug, arm64), install it and start a unified-log capture. Prints the UDID.
#
#   scripts/qa/ios-setup.sh [--name "Sonar QA iPhone"] [--no-build] [--fresh]
#                           [--build-core | --trust-core] [--allow-missing-config]
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
# the pass silently tests old core code. The script records the core tree it
# was built from (`git rev-parse HEAD:core`) in Frameworks/.sonar-core-tree and
# refuses a mismatch: --build-core runs core/build-ios.sh and writes the stamp;
# --trust-core accepts the current framework (you checked it yourself).
#
# Preflight (presence only — values are never printed): BREEZ_API_KEY in
# ios/Configs/Local.xcconfig and ios/bitchat/GoogleService-Info.plist. Debug
# builds succeed without them, but wallet flows / offline-payment pushes are
# silently off. Refused unless --allow-missing-config, which records the gap
# in $QA_HOME/config-gaps.txt for the QA report.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa}"
NAME="Sonar QA iPhone"; BUILD=1; FRESH=0; CORE=check; ALLOW_MISSING=0
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
grep -Eq '^[[:space:]]*BREEZ_API_KEY[[:space:]]*=[[:space:]]*[^[:space:]]' \
  "$ROOT/ios/Configs/Local.xcconfig" 2>/dev/null ||
  missing+=("BREEZ_API_KEY in ios/Configs/Local.xcconfig: wallet flows off")
[[ -f "$ROOT/ios/bitchat/GoogleService-Info.plist" ]] ||
  missing+=("ios/bitchat/GoogleService-Info.plist: no FCM, no offline-payment pushes")
if (( ${#missing[@]} )); then
  printf 'missing local config:\n' >&2; printf '  - %s\n' "${missing[@]}" >&2
  if (( ! ALLOW_MISSING )); then
    echo "refusing to build a QA app that silently lacks them; copy them from the primary" >&2
    echo "checkout, or pass --allow-missing-config and report wallet/push scenarios as not run." >&2
    exit 1
  fi
  for gap in "${missing[@]}"; do            # idempotent across setup reruns
    grep -qxF "ios: $gap" "$QA_HOME/config-gaps.txt" 2>/dev/null ||
      echo "ios: $gap" >> "$QA_HOME/config-gaps.txt"
  done
fi

FRAMEWORKS="$ROOT/ios/localPackages/SonarCore/Frameworks"
STAMP="$FRAMEWORKS/.sonar-core-tree"
CORE_TREE="$(git -C "$ROOT" rev-parse HEAD:core)"
if [[ -n "$(git -C "$ROOT" status --porcelain -- core)" ]]; then
  CORE_TREE="$CORE_TREE+dirty"     # uncommitted core edits never match a stamp
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
  if ! xcodebuild build -project "$ROOT/ios/bitchat.xcodeproj" -scheme "bitchat (iOS)" \
      -configuration Debug -destination "id=$UDID" -derivedDataPath "$QA_HOME/DerivedData" \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 -allowProvisioningUpdates \
      > "$QA_HOME/ios-build.log" 2>&1; then
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
