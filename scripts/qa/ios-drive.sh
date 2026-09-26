#!/usr/bin/env bash
# ios-drive.sh — headless iOS UI driver for agent QA passes (no Simulator
# panel needed). Runs one XCUITest that executes a step script against the
# installed Sonar app on the QA simulator, by UDID.
#
#   QA_UDID=<udid> scripts/qa/ios-drive.sh [--nsec-file <sonar-cli config.json>] [--rebuild] \
#       <name> "<step;step;…>"
#
# Steps (see ios-driver/QADriverUITests/QADriver.swift for the full list):
#   launch · activate · tap:<label> · tapc:<substring> · tapid:<id> · tapxy:<x>,<y>
#   longpress:<substring> · longpressxy:<x>,<y> · type:<text> · expect:<substring>[@secs] · absent:<…>
#   count:<substring>[=n] · shot:<name> · tree:<name> · sbtap:<SpringBoard button>
# e.g. "launch;tapc:Sonar agent DM;longpress:hello;shot:menu;tap:👍;expect:👍"
#
# Output: $QA_HOME/idrive/<name>/ — steps.log, <shot>.png, <tree>.txt (the
# accessibility tree: read labels there, never guess coordinates off a PNG).
# Exit status: 0 when every step passed.
#
# `launch` starts the app with SONAR_BENCH_NSEC (DEBUG builds skip onboarding)
# taken from --nsec-file, a throwaway `sonar-cli init` config — never a real
# account. The value is handed over in the environment and never printed.
# `activate` attaches to the running app without relaunching it.
#
# The driver lives in its own generated project ($QA_HOME/ios-driver); the
# app's Xcode project is not touched. First run builds it (~1 min).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa-$(basename "$ROOT")}"
UDID="${QA_UDID:?set QA_UDID (see scripts/qa/ios-setup.sh)}"
NSEC_FILE=""; REBUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nsec-file) NSEC_FILE="$2"; shift 2 ;;
    --rebuild) REBUILD=1; shift ;;
    -*) echo "unknown arg: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
NAME="${1:?name}"; STEPS="${2:?steps}"
BUILD="$QA_HOME/ios-driver"
OUT="$QA_HOME/idrive/$NAME"

if (( REBUILD )) || [[ ! -d "$BUILD/dd/Build/Products" ]]; then
  ruby "$ROOT/scripts/qa/ios-driver/gen.rb" "$BUILD"
  set -o pipefail
  xcodebuild build-for-testing -project "$BUILD/QADriver.xcodeproj" -scheme QADriver \
    -destination "id=$UDID" -derivedDataPath "$BUILD/dd" > "$BUILD/build.log" 2>&1 ||
    { echo "driver build failed: $BUILD/build.log" >&2; exit 1; }
fi

NSEC=""
if [[ -n "$NSEC_FILE" ]]; then
  NSEC="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nsec"])' "$NSEC_FILE")"
fi
rm -rf "$OUT"; mkdir -p "$OUT"
rc=0
TEST_RUNNER_QA_STEPS="$STEPS" TEST_RUNNER_QA_OUT="$OUT" TEST_RUNNER_QA_NSEC="$NSEC" \
  xcodebuild test-without-building -project "$BUILD/QADriver.xcodeproj" -scheme QADriver \
  -destination "id=$UDID" -derivedDataPath "$BUILD/dd" \
  -only-testing:QADriverUITests/QADriver/testDrive > "$OUT/xcodebuild.log" 2>&1 || rc=$?
cat "$OUT/steps.log" 2>/dev/null; echo
grep -E "error: .*failed - " "$OUT/xcodebuild.log" | sed 's/.*failed - /FAIL: /' || true
echo "ios-drive: $NAME rc=$rc → $OUT"
exit "$rc"
