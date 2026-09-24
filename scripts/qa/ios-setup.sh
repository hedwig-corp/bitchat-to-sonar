#!/usr/bin/env bash
# ios-setup.sh — create/boot a DEDICATED QA simulator, build the app SIGNED
# (Debug, arm64), install it and start a unified-log capture. Prints the UDID.
#
#   scripts/qa/ios-setup.sh [--name "Sonar QA iPhone"] [--no-build] [--fresh]
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
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa}"
NAME="Sonar QA iPhone"; BUILD=1; FRESH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --fresh) FRESH=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$QA_HOME"
BUNDLE=sh.hedwig.sonar

if [[ ! -d "$ROOT/ios/localPackages/SonarCore/Frameworks/sonarffi.xcframework" ]]; then
  echo "sonarffi.xcframework missing — run core/build-ios.sh (or copy it from a worktree whose" >&2
  echo "'git rev-parse HEAD:core' matches this one)." >&2
  exit 1
fi

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
nohup xcrun simctl spawn "$UDID" log stream --level info \
  --predicate 'subsystem == "chat.bitchat"' > "$LOG" 2>&1 &
echo ">> unified log → $LOG (pid $!)" >&2
xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
echo "$UDID"
