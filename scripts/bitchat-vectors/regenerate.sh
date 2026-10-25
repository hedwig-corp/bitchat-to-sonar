#!/usr/bin/env bash
# Regenerate the bitchat wire-format vectors by running OUR generators inside
# the UPSTREAM reference codebases, then diff against the committed vectors.
#
# This is the executable form of "always compatible with upstream": the
# committed vectors are what bitchat iOS and bitchat-android produced at the
# pinned revisions; this script produces them again at any revision (HEAD by
# default) and reports every case whose bytes moved, appeared or vanished.
#
#   scripts/bitchat-vectors/regenerate.sh                 # both, HEAD, diff only
#   scripts/bitchat-vectors/regenerate.sh --only ios      # one platform
#   scripts/bitchat-vectors/regenerate.sh --ios-rev 30c58eee --android-rev dfc67dad
#   scripts/bitchat-vectors/regenerate.sh --write         # overwrite the committed files
#
# exit 0 identical; 1 differences (or --write applied); 2 a generator failed.
#
# Needs: git, python3; Swift toolchain (macOS) for ios; JDK 17 + Android SDK
# (ANDROID_HOME, or a local.properties to copy) for android. Both upstream
# builds run online (SwiftPM / Gradle dependency resolution).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GEN="$ROOT/core/bitchat-protocol/vectors/generators"
VEC="$ROOT/core/bitchat-protocol/vectors"
# shellcheck source=scripts/bitchat-vectors/lib.sh
. "$ROOT/scripts/bitchat-vectors/lib.sh"
IOS_REPO="https://github.com/permissionlesstech/bitchat"
ANDROID_REPO="https://github.com/permissionlesstech/bitchat-android"
IOS_REV="HEAD"; ANDROID_REV="HEAD"; ONLY=""; WRITE=0
OUT="${SONAR_VECTOR_WORK:-$(mktemp -d)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --ios-rev) IOS_REV="$2"; shift 2 ;;
    --android-rev) ANDROID_REV="$2"; shift 2 ;;
    --write) WRITE=1; shift ;;
    --work) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT"
echo "work dir: $OUT"

gen_ios() {
  local dir="$OUT/bitchat-ios" rev
  rev="$(clone_at "$IOS_REPO" "$dir" "$IOS_REV")"
  echo "ios: upstream at $rev"
  local tests="$dir/localPackages/BitFoundation/Tests/BitFoundationTests"
  cp "$GEN/bitchat-ios-swift/SonarVectorDump.swift" "$tests/"
  install_ios_app_codecs "$dir" "$tests"
  ( cd "$dir/localPackages/BitFoundation" \
    && SONAR_VECTOR_OUT="$OUT/raw-ios.json" swift test --filter SonarVectorDump 2>&1 | tail -5 )
  [[ -s "$OUT/raw-ios.json" ]] || { echo "ios: generator produced no file" >&2; return 2; }
  python3 "$ROOT/scripts/bitchat-vectors/normalize.py" "$OUT/raw-ios.json" "$OUT/bitchat-ios.json"
}

gen_android() {
  local dir="$OUT/bitchat-android" rev
  rev="$(clone_at "$ANDROID_REPO" "$dir" "$ANDROID_REV")"
  echo "android: upstream at $rev"
  mkdir -p "$dir/app/src/test/java/com/bitchat/android/protocol"
  cp "$GEN/bitchat-android-kotlin/SonarVectorDumpTest.kt" "$dir/app/src/test/java/com/bitchat/android/protocol/"
  if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
    for lp in "$ROOT/apps/sonar/local.properties" "$HOME/github/work/bitchat-android/local.properties"; do
      [[ -f "$lp" ]] && { grep '^sdk.dir=' "$lp" > "$dir/local.properties" || true; break; }
    done
  fi
  ( cd "$dir" && SONAR_VECTOR_OUT="$OUT/raw-android.json" \
      ./gradlew --no-daemon -q :app:testDebugUnitTest \
        --tests 'com.bitchat.android.protocol.SonarVectorDumpTest' 2>&1 | tail -15 )
  [[ -s "$OUT/raw-android.json" ]] || { echo "android: generator produced no file" >&2; return 2; }
  python3 "$ROOT/scripts/bitchat-vectors/normalize.py" "$OUT/raw-android.json" "$OUT/bitchat-android.json"
}

status=0
for p in ios android; do
  [[ -n "$ONLY" && "$ONLY" != "$p" ]] && continue
  echo "== $p"
  if ! "gen_$p"; then echo "$p: generator failed" >&2; exit 2; fi
  if [[ $WRITE -eq 1 ]]; then
    cp "$OUT/bitchat-$p.json" "$VEC/bitchat-$p.json"
    echo "$p: wrote $VEC/bitchat-$p.json"
    status=1
  else
    python3 "$ROOT/scripts/bitchat-vectors/diff.py" "$VEC/bitchat-$p.json" "$OUT/bitchat-$p.json" || status=1
  fi
done
if [[ $status -ne 0 && $WRITE -eq 0 ]]; then
  cat <<'MSG'

The upstream codec no longer produces the committed bytes. Replay the fresh
file with `cargo test -p bitchat-protocol --test vectors` after copying it over
(or re-run with --write), update the revision pins in SPEC.md and
scripts/check-bitchat-upstream-drift.sh, and record the wire change in SPEC.md.
MSG
fi
exit $status
