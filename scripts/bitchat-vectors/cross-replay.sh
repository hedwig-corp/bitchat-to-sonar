#!/usr/bin/env bash
# Cross-replay: run stock bitchat iOS's codec on bitchat-android's bytes and
# stock bitchat-android's codec on bitchat iOS's bytes.
#
# regenerate.sh shows each reference client still produces its own committed
# vectors; this shows whether the two reference clients agree with EACH OTHER.
# Both vector files are turned into neutral operations (cross.py ops), each
# observer runs both files through its real codec (so every platform also
# replays its own file, which must match exactly and proves the harness), and
# cross.py compare checks the four directions:
#
#   ios -> ios, android -> android   self-replay, must agree completely
#   android -> ios, ios -> android   every mismatch must be explained in
#                                    core/bitchat-protocol/vectors/cross/ledger.json,
#                                    and every ledger entry must still occur
#
#   scripts/bitchat-vectors/cross-replay.sh                 # both upstreams at HEAD
#   scripts/bitchat-vectors/cross-replay.sh --only ios      # iOS observer only
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
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT/results-ios" "$OUT/results-android"
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

status=0
for p in ios android; do
  [[ -n "$ONLY" && "$ONLY" != "$p" ]] && continue
  echo "== observer $p"
  if ! "observe_$p"; then echo "$p: observer failed" >&2; exit 2; fi
  for src in ios android; do
    python3 "$ROOT/scripts/bitchat-vectors/cross.py" compare \
      --ops "$OUT/ops-$src.json" --results "$OUT/results-$p/results-$src.json" \
      --source "$src" --target "$p" --ledger "$CROSS/ledger.json" \
      --report "$OUT/report-$src-to-$p.json" || status=1
  done
done
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
