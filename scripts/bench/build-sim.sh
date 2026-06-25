#!/usr/bin/env bash
#
# build-sim.sh — Build the Sonar iOS app (Debug) for the iOS Simulator and
# print the path to the produced .app bundle.
#
# Debug is REQUIRED: the SONAR_BENCH cold-start markers are emitted through
# SecureLogger, which only logs with `%{public}@` privacy (i.e. readable in the
# unified log) in DEBUG builds. A Release build would render them as <private>.
#
# Signing is intentionally DISABLED. CLI builds of this app sign ad-hoc with
# empty entitlements (the bundle id `sh.hedwig.sonar` belongs to the Hedwig team
# and a local personal team can't provision it), so Keychain returns
# errSecMissingEntitlement (-34018) regardless. The benchmark provisioning path
# (SONAR_BENCH_NSEC) is therefore Keychain-INDEPENDENT: it adopts the env
# identity directly and derives the encrypted-DB key from it. So the unsigned
# build — which launches reliably on the simulator — is exactly what we want.
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

echo ">> Building \"$SCHEME\" (Debug, iphonesimulator, arm64, unsigned) → $DERIVED_DATA" >&2
# arm64 ONLY: the Arti (libarti_bitchat.a) and sonarffi simulator slices are
# arm64-only (Apple Silicon). 'generic/platform=iOS Simulator' would also try
# the x86_64 slice and fail to link. Pin to arm64.
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  EXCLUDED_ARCHS=x86_64 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  >&2

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Sonar.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: build succeeded but $APP_PATH not found." >&2
  exit 1
fi
# Print ONLY the app path on stdout so callers can capture it.
echo "$APP_PATH"
