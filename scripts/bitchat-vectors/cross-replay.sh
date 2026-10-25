#!/usr/bin/env bash
# Cross-replay: hold the four bitchat implementations to each other's bytes.
#
#   ios         stock bitchat iOS        (BitFoundation + app codecs, upstream HEAD)
#   android     stock bitchat-android    (app unit-test harness, upstream HEAD)
#   sonar-ios   Sonar iOS                (ios/bitchat's own codec files, this checkout)
#   sonar-rust  Sonar Android            (core/bitchat-protocol, this checkout)
#
# regenerate.sh shows each reference client still produces its own committed
# vectors. This runs every observer over BOTH reference files (cross.py ops)
# and checks, with cross.py compare:
#
#   ios -> ios, android -> android     self-replay, must agree completely
#   every other source -> observer     each mismatch explained in
#                                      core/bitchat-protocol/vectors/cross/ledger.json,
#                                      and every ledger entry must still occur
#   sonar-rust -> sonar-ios            the two Sonar platforms held to each other
#                                      on every op (--expect-from)
#
#   scripts/bitchat-vectors/cross-replay.sh                        # all four
#   scripts/bitchat-vectors/cross-replay.sh --only ios             # one observer
#   scripts/bitchat-vectors/cross-replay.sh --only sonar-ios,sonar-rust   # no upstream clone
#   scripts/bitchat-vectors/cross-replay.sh --ios-repo https://github.com/<fork>/bitchat --ios-rev <branch>
#
# exit 0 everything agrees or is explained; 1 an unexplained or stale result;
# 2 an observer failed to run.
#
# Needs: git, python3; Swift toolchain (macOS) for ios; JDK 17 + Android SDK
# for android. Both upstream builds resolve dependencies online.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GEN="$ROOT/core/bitchat-protocol/vectors/generators"
VEC="$ROOT/core/bitchat-protocol/vectors"
CROSS="$VEC/cross"
# shellcheck source=scripts/bitchat-vectors/lib.sh
. "$ROOT/scripts/bitchat-vectors/lib.sh"
IOS_REPO="https://github.com/permissionlesstech/bitchat"
ANDROID_REPO="https://github.com/permissionlesstech/bitchat-android"
IOS_REV="HEAD"; ANDROID_REV="HEAD"; ONLY=""
OUT="${SONAR_CROSS_WORK:-$(mktemp -d)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --ios-repo) IOS_REPO="$2"; shift 2 ;;
    --ios-rev) IOS_REV="$2"; shift 2 ;;
    --android-repo) ANDROID_REPO="$2"; shift 2 ;;
    --android-rev) ANDROID_REV="$2"; shift 2 ;;
    --work) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
OBSERVERS="ios android sonar-ios sonar-rust"
wants() { [[ -z "$ONLY" || ",$ONLY," == *",$1,"* ]]; }
for o in $OBSERVERS; do mkdir -p "$OUT/results-$o"; done
echo "work dir: $OUT"

for p in ios android; do
  python3 "$ROOT/scripts/bitchat-vectors/cross.py" ops "$VEC/bitchat-$p.json" "$OUT/ops-$p.json"
done
OPS="$OUT/ops-ios.json:$OUT/ops-android.json"

observe_ios() {
  local dir="$OUT/bitchat-ios" rev
  rev="$(clone_at "$IOS_REPO" "$dir" "$IOS_REV")"
  echo "ios observer: $IOS_REPO at $rev"
  local tests="$dir/localPackages/BitFoundation/Tests/BitFoundationTests"
  cp "$CROSS/SonarCrossObserver.swift" "$tests/"
  install_ios_app_codecs "$dir" "$tests"
  ( cd "$dir/localPackages/BitFoundation" \
    && SONAR_CROSS_OPS="$OPS" SONAR_CROSS_OUT_DIR="$OUT/results-ios" \
       swift test --filter SonarCrossObserver 2>&1 | grep -E "CROSS|error:|passed|failed" | tail -8 )
  [[ -s "$OUT/results-ios/results-ios.json" && -s "$OUT/results-ios/results-android.json" ]] \
    || { echo "ios observer produced no results" >&2; return 2; }
}

observe_android() {
  local dir="$OUT/bitchat-android" rev
  rev="$(clone_at "$ANDROID_REPO" "$dir" "$ANDROID_REV")"
  echo "android observer: $ANDROID_REPO at $rev"
  mkdir -p "$dir/app/src/test/java/com/bitchat/android/protocol"
  cp "$CROSS/SonarCrossObserverTest.kt" "$dir/app/src/test/java/com/bitchat/android/protocol/"
  if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
    for lp in "$ROOT/apps/sonar/local.properties" "$HOME/github/work/bitchat-android/local.properties"; do
      [[ -f "$lp" ]] && { grep '^sdk.dir=' "$lp" > "$dir/local.properties" || true; break; }
    done
  fi
  # --rerun: the ops files are not Gradle task inputs.
  ( cd "$dir" && SONAR_CROSS_OPS="$OPS" SONAR_CROSS_OUT_DIR="$OUT/results-android" \
      ./gradlew --no-daemon -q :app:testDebugUnitTest --rerun \
        --tests 'com.bitchat.android.protocol.SonarCrossObserverTest' 2>&1 | tail -15 )
  [[ -s "$OUT/results-android/results-ios.json" && -s "$OUT/results-android/results-android.json" ]] \
    || { echo "android observer produced no results" >&2; return 2; }
}

observe_sonar_ios() {
  echo "sonar-ios observer: ios/bitchat at $(git -C "$ROOT" rev-parse --short HEAD)"
  "$ROOT/scripts/bitchat-vectors/sonar-ios-codec.sh" "$OUT/sonar-ios-codec" "$CROSS/SonarCrossObserver.swift"
  ( cd "$OUT/sonar-ios-codec" \
    && SONAR_CROSS_OPS="$OPS" SONAR_CROSS_OUT_DIR="$OUT/results-sonar-ios" \
       swift test --filter SonarCrossObserver 2>&1 | grep -E "CROSS|error:|passed|failed" | tail -8 )
  [[ -s "$OUT/results-sonar-ios/results-ios.json" && -s "$OUT/results-sonar-ios/results-android.json" ]] \
    || { echo "sonar-ios observer produced no results" >&2; return 2; }
}

observe_sonar_rust() {
  echo "sonar-rust observer: core/bitchat-protocol at $(git -C "$ROOT" rev-parse --short HEAD)"
  ( cd "$ROOT/core" && cargo run -q -p bitchat-protocol --example cross_observer -- \
      "$OUT/results-sonar-rust" "$OUT/ops-ios.json" "$OUT/ops-android.json" )
  [[ -s "$OUT/results-sonar-rust/results-ios.json" && -s "$OUT/results-sonar-rust/results-android.json" ]] \
    || { echo "sonar-rust observer produced no results" >&2; return 2; }
}

status=0
for p in $OBSERVERS; do
  wants "$p" || continue
  echo "== observer $p"
  if ! "observe_${p//-/_}"; then echo "$p: observer failed" >&2; exit 2; fi
  for src in ios android; do
    python3 "$ROOT/scripts/bitchat-vectors/cross.py" compare \
      --ops "$OUT/ops-$src.json" --results "$OUT/results-$p/results-$src.json" \
      --source "$src" --target "$p" --ledger "$CROSS/ledger.json" \
      --report "$OUT/report-$src-to-$p.json" || status=1
  done
done
if wants sonar-ios && wants sonar-rust; then
  echo "== Sonar iOS held to Sonar Android"
  for src in ios android; do
    python3 "$ROOT/scripts/bitchat-vectors/cross.py" compare \
      --ops "$OUT/ops-$src.json" --results "$OUT/results-sonar-ios/results-$src.json" \
      --expect-from "$OUT/results-sonar-rust/results-$src.json" \
      --source sonar-rust --target sonar-ios --ledger "$CROSS/ledger.json" \
      --report "$OUT/report-sonar-rust-to-sonar-ios-$src.json" || status=1
  done
fi
if [[ $status -ne 0 ]]; then
  cat <<'MSG'

A reference client disagrees with the other in a way the ledger does not
explain, or a ledger entry no longer reproduces. Decide which side is right
(SPEC.md is the arbiter), then either record the divergence in
core/bitchat-protocol/vectors/cross/ledger.json with its consequence on the
wire, or remove the stale entry and the SPEC.md note it backs.
MSG
fi
exit $status
