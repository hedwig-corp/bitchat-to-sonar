#!/usr/bin/env bash
# Package the Linux desktop app into release-ready artifacts.
#
# Produces, in dist/, named to match the Android release assets:
#   sonar-<version>-linux-amd64.deb
#   sonar-<version>-linux-amd64.tar.gz
#
# Deliberately a local script rather than a CI job: this project is self-funded
# and a jpackage build is expensive, so artifacts are built on a maintainer's
# machine and folded into the existing release process, the same way
# zapstore-publish.sh handles Android.
#
# Prerequisites:
#   - JDK 17 and the repo's Gradle wrapper (apps/sonar/gradlew)
#   - dpkg-deb, fakeroot   (Debian/Ubuntu: apt install dpkg fakeroot)
#   - a Rust toolchain     (the Gradle build compiles the desktop core + BLE bridge)
#   - libdbus-1-dev, pkg-config for the BlueZ backend
#   - xvfb, optional, only so the smoke run works on a headless machine
#   - gh auth, optional, only for --upload
#
# Usage:
#   scripts/package-linux-desktop.sh                 # build + verify + stage in dist/
#   scripts/package-linux-desktop.sh --no-smoke      # skip launching the packaged app
#   scripts/package-linux-desktop.sh --check         # verify tooling and the dep patch only
#   scripts/package-linux-desktop.sh --upload v0.1-alpha.13.3
#
# --upload attaches the staged artifacts to an EXISTING release. Alpha tags are
# pre-releases; this never creates or promotes a release, it only uploads.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DIST_DIR="$REPO_ROOT/dist"
DEB_DIR="$REPO_ROOT/apps/sonar/composeApp/build/compose/binaries/main/deb"
APP_DIR="$REPO_ROOT/apps/sonar/composeApp/build/compose/binaries/main/app"
SMOKE=1
MODE=build
TAG=""

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
step() { echo "→ $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-smoke) SMOKE=0; shift ;;
    --check) MODE=check; shift ;;
    --upload) MODE=upload; TAG="${2:-}"; [[ -n "$TAG" ]] || die "--upload needs a release tag"; shift 2 ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

need dpkg-deb
need fakeroot

# The control-file patch is the fiddliest part of this, so its fixtures run
# first: a broken patch should stop the build, not surface in a shipped package.
step "verifying the control-file patch against fixture packages"
"$REPO_ROOT/scripts/test-deb-runtime-deps.sh"

if [[ "$MODE" == check ]]; then
  echo "check passed: tooling present and the dependency patch behaves"
  exit 0
fi

step "building the .deb and the portable distributable"
( cd "$REPO_ROOT/apps/sonar" && ./gradlew --no-daemon :composeApp:packageDeb :composeApp:createDistributable )

# Exactly one, or the wrong artifact ships. Belt and braces rather than a known
# hazard: packageDeb clears this directory today (checked, a planted
# sonar_0.1~alpha.12.9_amd64.deb was gone after a build), so this only bites if
# that changes or the task is skipped. It costs nothing and turns "shipped the
# wrong version" into a stop.
mapfile -t DEBS < <(find "$DEB_DIR" -name 'sonar_*.deb')
[[ ${#DEBS[@]} -eq 1 ]] || die "expected exactly one .deb in $DEB_DIR, found ${#DEBS[@]}: ${DEBS[*]:-none}. Remove stale builds and retry."
DEB="${DEBS[0]}"

step "adding the runtime dependencies jpackage cannot derive"
"$REPO_ROOT/scripts/deb-add-runtime-deps.sh" "$DEB"

if [[ "$SMOKE" == 1 ]]; then
  # jpackage will happily emit a well-formed .deb whose payload is missing a
  # native library or whose launcher is wrong, and no unit test sees either.
  step "smoke-running the packaged app"
  SMOKE_ROOT="$(mktemp -d)"
  trap 'rm -rf "$SMOKE_ROOT"' EXIT
  dpkg-deb -x "$DEB" "$SMOKE_ROOT"
  BIN="$SMOKE_ROOT/opt/sonar/bin/Sonar"
  [[ -x "$BIN" ]] || die "launcher missing from the package"
  LOG="$SMOKE_ROOT/smoke.log"
  if [[ -n "${DISPLAY:-}" ]]; then
    "$BIN" > "$LOG" 2>&1 &
  elif command -v xvfb-run >/dev/null 2>&1; then
    xvfb-run -a "$BIN" > "$LOG" 2>&1 &
  else
    die "no DISPLAY and no xvfb-run; install xvfb or pass --no-smoke"
  fi
  PID=$!
  # Long enough to clear JVM start, native core load and first paint.
  sleep 40
  kill -0 "$PID" 2>/dev/null || { echo "--- smoke log ---"; cat "$LOG"; die "the packaged app exited during startup"; }
  kill "$PID" 2>/dev/null || true
  # Matches UNCAUGHT failures, not the substring "Exception": skiko logs
  # "RenderException: Cannot create Linux GL context" when there is no GPU, then
  # falls back to software rendering and carries on. A check that cannot tell a
  # recovered fallback from a fatal gets ignored within a week.
  if grep -qE 'Exception in thread|UnsatisfiedLinkError|FATAL|Could not find or load main class' "$LOG"; then
    echo "--- smoke log ---"; cat "$LOG"
    die "the packaged app logged a fatal during startup"
  fi
  echo "  packaged app survived startup with a clean log"
  # Coverage stops at onboarding: SonarDesktopRoot gates boot() on the onboarded
  # flag, so this exercises the launcher, the JVM image and the native core load,
  # not relay connect, the encrypted DB, or DesktopSecrets.
fi

step "staging release artifacts"
# Three transforms on the version, each for a reason:
#   strip a trailing -<n>   jpackage appends a Debian REVISION on some JDK builds
#                           (one machine produced 0.1~alpha.13.3, a GitHub runner
#                           0.1~alpha.13.3-1). It is packaging metadata, not the
#                           upstream version, and leaving it in breaks the naming
#                           convention and any tag comparison.
#   ~ becomes -             the Debian pre-release marker is not in the git tag.
RAW_VERSION="$(dpkg-deb -f "$DEB" Version)"
VERSION="$(printf '%s' "$RAW_VERSION" | sed -E 's/-[0-9]+$//' | tr '~' '-')"
mkdir -p "$DIST_DIR"
cp "$DEB" "$DIST_DIR/sonar-${VERSION}-linux-amd64.deb"
tar -C "$APP_DIR" -czf "$DIST_DIR/sonar-${VERSION}-linux-amd64.tar.gz" Sonar

echo
echo "deb Version=$RAW_VERSION → asset version=$VERSION"
ls -lh "$DIST_DIR"/sonar-"${VERSION}"-linux-amd64.* | awk '{print "  "$9"  "$5}'

if [[ "$MODE" == upload ]]; then
  need gh
  # The version is a literal in build.gradle.kts, not derived from the tag, so a
  # release cut without bumping it would otherwise attach the previous version's
  # artifacts under the new tag.
  [[ "${TAG#v}" == "$VERSION" ]] || die "tag $TAG does not match built version $VERSION; bump SONAR_VERSION_NAME in apps/sonar/composeApp/build.gradle.kts"
  step "attaching to release $TAG"
  gh release upload "$TAG" \
    "$DIST_DIR/sonar-${VERSION}-linux-amd64.deb" \
    "$DIST_DIR/sonar-${VERSION}-linux-amd64.tar.gz" --clobber
else
  echo
  echo "to attach these to an existing release:"
  echo "  scripts/package-linux-desktop.sh --upload v${VERSION}"
fi
