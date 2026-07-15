#!/usr/bin/env bash
# Build the official MarmotKit Android bindings from the immutable MDK v0.9.4
# release commit. This is a separate build island from Sonar's legacy core.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MDK_REPOSITORY="https://github.com/marmot-protocol/mdk.git"
MDK_TAG="v0.9.4"
MDK_REVISION="e391adc133a9b60e420da7a0446f014a180ac8d2"
MDK_CACHE="${DARKMATTER_MDK_CACHE:-$SCRIPT_DIR/target/darkmatter-mdk-$MDK_REVISION}"
OUTPUT="${DARKMATTER_MDK_OUTPUT:-$REPO_ROOT/apps/sonar/darkmatterApp/build/generated/mdk-v0.9.4}"
ANDROID_ABIS="${ANDROID_ABIS:-arm64-v8a armeabi-v7a}"

die() { echo "error: $*" >&2; exit 1; }

if [[ ! -d "$MDK_CACHE/.git" ]]; then
  [[ ! -e "$MDK_CACHE" ]] || die "MDK cache exists but is not a git checkout: $MDK_CACHE"
  mkdir -p "$(dirname "$MDK_CACHE")"
  echo "Cloning MDK $MDK_TAG..."
  git clone --branch "$MDK_TAG" --depth 1 "$MDK_REPOSITORY" "$MDK_CACHE"
fi

actual_revision="$(git -C "$MDK_CACHE" rev-parse HEAD)"
[[ "$actual_revision" == "$MDK_REVISION" ]] || {
  die "MDK cache is $actual_revision; expected immutable $MDK_TAG commit $MDK_REVISION"
}
actual_remote="$(git -C "$MDK_CACHE" remote get-url origin)"
[[ "$actual_remote" == "$MDK_REPOSITORY" ]] || {
  die "MDK cache origin is $actual_remote; expected $MDK_REPOSITORY"
}
git -C "$MDK_CACHE" diff --quiet || die "MDK cache has modified tracked files"
git -C "$MDK_CACHE" diff --cached --quiet || die "MDK cache has staged changes"

[[ -n "$OUTPUT" && "$OUTPUT" != "/" ]] || die "refusing unsafe output path: $OUTPUT"

if ! rustup toolchain list | grep -q '^1\.90\.0-'; then
  rustup toolchain install 1.90.0 --profile minimal
fi

case " $ANDROID_ABIS " in
  *" arm64-v8a "*) rustup target add --toolchain 1.90.0 aarch64-linux-android >/dev/null ;;
esac
case " $ANDROID_ABIS " in
  *" armeabi-v7a "*) rustup target add --toolchain 1.90.0 armv7-linux-androideabi >/dev/null ;;
esac
case " $ANDROID_ABIS " in
  *" x86 "*) rustup target add --toolchain 1.90.0 i686-linux-android >/dev/null ;;
esac
case " $ANDROID_ABIS " in
  *" x86_64 "*) rustup target add --toolchain 1.90.0 x86_64-linux-android >/dev/null ;;
esac

export ANDROID_ABIS
export CARGO_TARGET_DIR="${DARKMATTER_CARGO_TARGET_DIR:-$SCRIPT_DIR/target/darkmatter-mdk-v0.9.4}"

"$MDK_CACHE/crates/marmot-uniffi/kotlin-bindings.sh"

UPSTREAM_OUTPUT="$MDK_CACHE/crates/marmot-uniffi/output/android"
[[ -f "$UPSTREAM_OUTPUT/kotlin/dev/ipf/marmotkit/marmot_uniffi.kt" ]] || {
  die "upstream MarmotKit Kotlin binding was not produced"
}

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/kotlin" "$OUTPUT/jniLibs"
cp -R "$UPSTREAM_OUTPUT/kotlin/." "$OUTPUT/kotlin/"
cp -R "$UPSTREAM_OUTPUT/jniLibs/." "$OUTPUT/jniLibs/"
printf '%s\n%s\n' "$MDK_TAG" "$MDK_REVISION" > "$OUTPUT/.mdk-version"

echo "Built Sonar Darkmatter bindings from $MDK_TAG ($MDK_REVISION)."
echo "Output: $OUTPUT"
