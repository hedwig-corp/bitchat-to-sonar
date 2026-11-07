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
# (see .agents/skills/qa-run/SKILL.md).
#
# The benchmark path stays Keychain-INDEPENDENT (SONAR_BENCH_NSEC): it adopts
# the env identity and derives the encrypted-DB key from it, so a keychain
# entry an earlier launch left behind does not change which store opens.
#
# Prereq: run `core/build-ios.sh` first so SonarCore/Frameworks/sonarffi.xcframework
# (incl. the ios-arm64-simulator slice) exists.
#
# Usage: scripts/bench/build-sim.sh [derived-data-dir]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DERIVED_DATA="${1:-/tmp/sonar-bench/DerivedData}"
SCHEME="bitchat (iOS)"
PROJECT="$REPO_ROOT/ios/bitchat.xcodeproj"

if [[ ! -d "$REPO_ROOT/ios/localPackages/SonarCore/Frameworks/sonarffi.xcframework" ]]; then
  echo "ERROR: sonarffi.xcframework missing — run core/build-ios.sh first." >&2
  exit 1
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
  >&2

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Sonar.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: build succeeded but $APP_PATH not found." >&2
  exit 1
fi
# Print ONLY the app path on stdout so callers can capture it.
echo "$APP_PATH"
