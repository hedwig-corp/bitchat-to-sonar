#!/bin/bash
#
# Build sonar-ffi for Android and assemble the JNI libs + Kotlin bindings.
#
# Mirror of build-ios.sh for the Android side of issue #6 (1:1 Android app).
#
# Outputs (straight into the CMP app's androidMain source set):
#   apps/sonar/composeApp/src/androidMain/jniLibs/<abi>/libsonar_ffi.so
#       for arm64-v8a, armeabi-v7a, x86_64
#   apps/sonar/composeApp/src/androidMain/kotlin/uniffi/sonar_ffi/sonar_ffi.kt
#       UniFFI Kotlin bindings (uniffi 0.31)
#
# The generated Kotlin uses JNA — the consuming Gradle module must depend on
#   net.java.dev.jna:jna:<ver>@aar
#
# Usage: ANDROID_NDK_HOME=/path/to/ndk core/build-android.sh
# Prereqs: cargo-ndk, rustup targets aarch64/armv7/x86_64-linux-android
#          (auto-added below), an Android NDK (ANDROID_NDK_HOME or auto-detect).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

# --- NDK discovery -----------------------------------------------------------
if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
  if [[ -d "$SDK/ndk" ]]; then
    # Pick the highest installed NDK version.
    ANDROID_NDK_HOME="$SDK/ndk/$(ls "$SDK/ndk" | sort -V | tail -1)"
  fi
fi
[[ -n "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_NDK_HOME" ]] || {
  echo "error: set ANDROID_NDK_HOME to an installed Android NDK" >&2; exit 1
}
export ANDROID_NDK_HOME
echo "Using NDK: $ANDROID_NDK_HOME"

CRATE="sonar-ffi"
LIB="libsonar_ffi.so"

# P2P voice calls (iroh + cpal/opus via oboe) are ON by default so the shipped
# app can place real calls. oboe links the SHARED libc++ runtime, so we ship
# libc++_shared.so alongside each .so (below). Override with SONAR_FEATURES=""
# for a lean messaging-only build.
SONAR_FEATURES="${SONAR_FEATURES-calls-audio}"
FEATURE_ARGS=()
[[ -n "$SONAR_FEATURES" ]] && FEATURE_ARGS=(--features "$SONAR_FEATURES")
# Write straight into the CMP app's androidMain (the canonical consumer), the
# way build-ios.sh assembles ios/localPackages/SonarCore. Override OUT to retarget.
OUT="${OUT:-$REPO_ROOT/apps/sonar/composeApp/src/androidMain}"
JNILIBS="$OUT/jniLibs"
KOTLIN_DIR="$OUT/kotlin"

# ABI -> rust target (cargo-ndk maps these; listed for the rustup add).
RUST_TARGETS=(aarch64-linux-android armv7-linux-androideabi x86_64-linux-android)
for t in "${RUST_TARGETS[@]}"; do rustup target add "$t" >/dev/null 2>&1 || true; done

# SQLCipher on Android needs OpenSSL (no CommonCrypto). sonar-core enables
# libsqlite3-sys `bundled-sqlcipher-vendored-openssl` for target_os=android, so
# OpenSSL is compiled from source by openssl-src using cargo-ndk's toolchain.
# Make sure no host OpenSSL env leaks in and confuses the cross build.
unset OPENSSL_DIR OPENSSL_LIB_DIR OPENSSL_INCLUDE_DIR OPENSSL_NO_VENDOR \
      OPENSSL_STATIC LIBSQLITE3_SYS_USE_PKG_CONFIG 2>/dev/null || true

# Only wipe the generated artifacts — KOTLIN_DIR is the androidMain source root
# and also holds hand-written Kotlin (MainActivity, actuals), so scope the
# delete to the generated uniffi package.
rm -rf "$JNILIBS" "$KOTLIN_DIR/uniffi"
mkdir -p "$JNILIBS" "$KOTLIN_DIR"

# --- Build the 3 ABIs (cargo-ndk copies each .so into jniLibs/<abi>/) ---------
echo "Building $CRATE for arm64-v8a, armeabi-v7a, x86_64 ${SONAR_FEATURES:+($SONAR_FEATURES)}..."
cargo ndk -o "$JNILIBS" \
  -t arm64-v8a -t armeabi-v7a -t x86_64 \
  build -p "$CRATE" --lib --release ${FEATURE_ARGS[@]+"${FEATURE_ARGS[@]}"}

# --- Ship libc++_shared.so (oboe links the shared C++ runtime) ----------------
# Only needed for the calls-audio build (cpal→oboe). The NDK prebuilt sysroot
# holds one per target triple; copy it next to each abi's libsonar_ffi.so.
if [[ "$SONAR_FEATURES" == *calls-audio* ]]; then
  NDK_HOST="$(ls "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" 2>/dev/null | head -1)"
  SYSROOT_LIB="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST/sysroot/usr/lib"
  copy_libcxx() { # <abi> <triple>
    local src="$SYSROOT_LIB/$2/libc++_shared.so"
    if [[ -f "$src" ]]; then
      cp "$src" "$JNILIBS/$1/" && echo "  shipped libc++_shared.so for $1"
    else
      echo "warn: libc++_shared.so not found for $1 at $src" >&2
    fi
  }
  copy_libcxx arm64-v8a   aarch64-linux-android
  copy_libcxx armeabi-v7a arm-linux-androideabi
  copy_libcxx x86_64      x86_64-linux-android
fi

# --- Generate the Kotlin bindings (library mode, reads metadata from a .so) ---
echo "Generating Kotlin bindings..."
cargo run -p "$CRATE" --features cli --bin uniffi-bindgen -- generate \
  --library "$JNILIBS/arm64-v8a/$LIB" \
  --language kotlin --out-dir "$KOTLIN_DIR"

echo ""
echo "Done. Outputs under $OUT:"
find "$JNILIBS" -name "$LIB" -exec ls -lh {} \; | awk '{print "  " $NF " (" $5 ")"}'
find "$KOTLIN_DIR" -name "*.kt" | sed 's/^/  /'
echo ""
echo "Consume from an Android module: copy jniLibs/ into src/main/jniLibs/,"
echo "the kotlin/ sources into src/main/kotlin/, and add the JNA dependency:"
echo "  implementation(\"net.java.dev.jna:jna:5.14.0@aar\")"
