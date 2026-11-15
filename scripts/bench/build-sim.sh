#!/usr/bin/env bash
#
# build-sim.sh — Build the Sonar iOS app (Debug) for the iOS Simulator and
# print the path to the produced .app bundle.
#
# Debug is REQUIRED: the SONAR_BENCH cold-start markers are emitted through
# SecureLogger, which only logs with `%{public}@` privacy (i.e. readable in the
# unified log) in DEBUG builds. A Release build would render them as <private>.
#
# Signed for the simulator, the way scripts/qa/ios-setup.sh builds. Since #362
# the Marmot store lives only in the App Group container, and the app refuses
# to open it without one. An unsigned build has no App Group, so every bench
# run stopped at "Marmot local open failed: App Group group.sh.hedwig.sonar
# unavailable" before t1_local_paint and the KeyPackage was never published. A
# simulator build needs no device provisioning; if Xcode still refuses to sign,
# put your own DEVELOPMENT_TEAM in the gitignored ios/Configs/Local.xcconfig
# (see .agents/skills/qa-run/SKILL.md). The build fails here, not 8 DM retries
# later, if the App Group did not make it into the simulated entitlements.
#
# The benchmark path stays Keychain-INDEPENDENT (SONAR_BENCH_NSEC): it adopts
# the env identity and derives the encrypted-DB key from it, so a keychain
# entry an earlier launch left behind does not change which store opens.
#
# Same flags as ios-setup.sh, except the destination: this build is not tied to
# one simulator, so it targets 'generic/platform=iOS Simulator' (pinned to
# arm64 below). As there, BREEZ_API_KEY from the environment is handed to
# xcodebuild through a 0600 temp xcconfig (never argv) when
# ios/Configs/Local.xcconfig has none. The bench does not need the wallet, so
# a missing key is not an error.
#
# DerivedData defaults to a per-worktree directory OUTSIDE /tmp: macOS purges
# old /tmp and $TMPDIR files nightly, which deletes pieces of unpacked SwiftPM
# binary artifacts (see ios-setup.sh), and a DerivedData shared by two
# checkouts produced a binary mixing both trees' object files.
#
# Prereq: run `core/build-ios.sh` first so SonarCore/Frameworks/sonarffi.xcframework
# (incl. the ios-arm64-simulator slice) exists.
#
# Usage: scripts/bench/build-sim.sh [--derived-data DIR | DIR]
# stdout carries ONLY the .app path; build output goes to stderr.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/sonar-bench-$(basename "$REPO_ROOT")"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --derived-data) DERIVED_DATA="$2"; shift 2;;
    -*) echo "unknown arg: $1" >&2; exit 2;;
    *) DERIVED_DATA="$1"; shift;;   # positional form, kept for old callers
  esac
done
SCHEME="bitchat (iOS)"
PROJECT="$REPO_ROOT/ios/bitchat.xcodeproj"
APP_GROUP="group.sh.hedwig.sonar"

if [[ ! -d "$REPO_ROOT/ios/localPackages/SonarCore/Frameworks/sonarffi.xcframework" ]]; then
  echo "ERROR: sonarffi.xcframework missing — run core/build-ios.sh first." >&2
  exit 1
fi

key_args=()
if ! grep -Eq '^[[:space:]]*BREEZ_API_KEY[[:space:]]*=[[:space:]]*[^[:space:]]' \
    "$REPO_ROOT/ios/Configs/Local.xcconfig" 2>/dev/null && [[ -n "${BREEZ_API_KEY:-}" ]]; then
  KEY_XCCONFIG="$(mktemp "${TMPDIR:-/tmp}/sonar-bench-breez.XXXXXX")"
  chmod 600 "$KEY_XCCONFIG"
  trap 'rm -f "$KEY_XCCONFIG"' EXIT
  printf 'BREEZ_API_KEY = %s\n' "$BREEZ_API_KEY" > "$KEY_XCCONFIG"
  key_args=(-xcconfig "$KEY_XCCONFIG")
fi

echo ">> Building \"$SCHEME\" (Debug, iphonesimulator, arm64, signed) → $DERIVED_DATA" >&2
# arm64 ONLY: the Arti (libarti_bitchat.a) and sonarffi simulator slices are
# arm64-only (Apple Silicon). 'generic/platform=iOS Simulator' would also try
# the x86_64 slice and fail to link. Pin to arm64.
xcodebuild -skipPackagePluginValidation build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  EXCLUDED_ARCHS=x86_64 \
  ${key_args[@]+"${key_args[@]}"} \
  >&2

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Sonar.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: build succeeded but $APP_PATH not found." >&2
  exit 1
fi

# A simulator app's entitlements are not in its code signature (codesign -d
# shows ad-hoc, none): the simulator reads the __TEXT,__entitlements section
# of the main executable. No App Group there = the store will not open.
# otool dumps that section as 32-bit little-endian words; reassemble the bytes
# and parse the plist.
has_app_group() {
  xcrun otool -s __TEXT __entitlements "$1" 2>/dev/null | python3 -c '
import plistlib, string, sys
raw = bytearray()
for line in sys.stdin:
    parts = line.split()
    if len(parts) < 2 or not all(c in string.hexdigits for c in parts[0]):
        continue  # the "<path>:" and "Contents of ..." header lines
    for word in parts[1:]:
        raw += bytes.fromhex(word)[::-1]
try:
    ents = plistlib.loads(bytes(raw).rstrip(b"\0"))
except Exception:
    sys.exit(1)  # no section (unsigned build) or not a plist
sys.exit(0 if sys.argv[1] in ents.get("com.apple.security.application-groups", []) else 1)
' "$2"
}
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Info.plist")"
if ! has_app_group "$APP_PATH/$EXE" "$APP_GROUP"; then
  echo "ERROR: $APP_PATH has no $APP_GROUP in its simulated entitlements;" >&2
  echo "   the Marmot store cannot open. Was the build signed? (CODE_SIGNING_ALLOWED=NO" >&2
  echo "   in the environment or an xcconfig would cause this.)" >&2
  exit 1
fi
# Print ONLY the app path on stdout so callers can capture it.
echo "$APP_PATH"
