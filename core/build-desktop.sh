#!/bin/bash
#
# Build sonar-ffi for the DESKTOP host (JVM / Compose Desktop) and assemble the
# JNA-loadable dynamic library + UniFFI Kotlin bindings.
#
# This is the desktop twin of build-android.sh / build-ios.sh. The Compose
# Multiplatform desktop target (jvm) reuses the SAME UniFFI Kotlin bindings as
# Android — they are pure Kotlin/JNA and platform-agnostic — but loads a host
# dynamic library (.dylib on macOS, .so on Linux, .dll on Windows) instead of a
# per-ABI Android .so.
#
# Outputs (straight into the CMP app's jvmMain source set):
#   apps/sonar/composeApp/src/jvmMain/resources/<jna-os-prefix>/libsonar_ffi.<ext>
#       the host dynamic library, laid out where JNA finds it on the classpath
#       (e.g. darwin-aarch64/libsonar_ffi.dylib, linux-x86-64/libsonar_ffi.so)
#   apps/sonar/composeApp/src/jvmMain/kotlin/uniffi/sonar_ffi/sonar_ffi.kt
#       UniFFI Kotlin bindings (uniffi 0.31) — same generator as Android
#
# The consuming Gradle module depends on net.java.dev.jna:jna (plain jar; the
# @aar variant is Android-only).
#
# Usage: core/build-desktop.sh
# Prereqs: a host Rust toolchain (the build uses the default host target).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

CRATE="sonar-ffi"

# --- SQLCipher / crypto backend ---------------------------------------------
# sonar-core links mdk-sqlite-storage → rusqlite's bundled-sqlcipher. On an
# Apple host, libsqlite3-sys compiles SQLCipher against CommonCrypto when no
# OpenSSL is advertised via env (same path the macOS slice in build-ios.sh
# takes). On Linux it falls back to the system/vendored OpenSSL. UNSET any
# OpenSSL discovery vars so the host build picks the native crypto backend.
unset OPENSSL_DIR OPENSSL_LIB_DIR OPENSSL_INCLUDE_DIR OPENSSL_NO_VENDOR \
      OPENSSL_STATIC LIBSQLITE3_SYS_USE_PKG_CONFIG 2>/dev/null || true

HOST_TARGET="$(rustc -vV | sed -n 's/^host: //p')"
echo "Host target: $HOST_TARGET"

# Map the host OS/arch to (1) the dynamic-library extension and (2) the JNA
# resource prefix JNA uses when extracting a bundled native lib from the
# classpath (com.sun.jna.Platform.RESOURCE_PREFIX).
UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"
case "$UNAME_M" in
  arm64|aarch64) JNA_ARCH="aarch64" ;;
  x86_64|amd64)  JNA_ARCH="x86-64" ;;
  *) echo "error: unsupported arch $UNAME_M" >&2; exit 1 ;;
esac
case "$UNAME_S" in
  Darwin)
    LIB="libsonar_ffi.dylib"
    JNA_PREFIX="darwin-$JNA_ARCH"
    # JNA also accepts the un-suffixed `darwin` folder; emit both for safety.
    JNA_PREFIX_ALT="darwin"
    ;;
  Linux)
    LIB="libsonar_ffi.so"
    JNA_PREFIX="linux-$JNA_ARCH"
    JNA_PREFIX_ALT=""
    ;;
  MINGW*|MSYS*|CYGWIN*)
    LIB="sonar_ffi.dll"
    JNA_PREFIX="win32-$JNA_ARCH"
    JNA_PREFIX_ALT=""
    ;;
  *) echo "error: unsupported OS $UNAME_S" >&2; exit 1 ;;
esac

OUT="${OUT:-$REPO_ROOT/apps/sonar/composeApp/src/jvmMain}"
RES_DIR="$OUT/resources"
KOTLIN_DIR="$OUT/kotlin"

# Only wipe the generated artifacts (KOTLIN_DIR holds hand-written actuals too).
rm -rf "$RES_DIR/$JNA_PREFIX" "$KOTLIN_DIR/uniffi"
[[ -n "$JNA_PREFIX_ALT" ]] && rm -rf "$RES_DIR/$JNA_PREFIX_ALT"
mkdir -p "$RES_DIR/$JNA_PREFIX" "$KOTLIN_DIR"

# --- Build the host cdylib ---------------------------------------------------
echo "Building $CRATE (cdylib) for $HOST_TARGET..."
cargo build -p "$CRATE" --lib --release

BUILT="$SCRIPT_DIR/target/release/$LIB"
[[ -f "$BUILT" ]] || { echo "error: expected $BUILT" >&2; exit 1; }
cp "$BUILT" "$RES_DIR/$JNA_PREFIX/$LIB"
if [[ -n "$JNA_PREFIX_ALT" ]]; then
  mkdir -p "$RES_DIR/$JNA_PREFIX_ALT"
  cp "$BUILT" "$RES_DIR/$JNA_PREFIX_ALT/$LIB"
fi

# --- Generate the Kotlin bindings (library mode, reads metadata from the lib) -
echo "Generating Kotlin bindings..."
cargo run -p "$CRATE" --features cli --bin uniffi-bindgen -- generate \
  --library "$BUILT" \
  --language kotlin --out-dir "$KOTLIN_DIR"

echo ""
echo "Done. Outputs under $OUT:"
find "$RES_DIR" -name "$LIB" -exec ls -lh {} \; | awk '{print "  " $NF " (" $5 ")"}'
find "$KOTLIN_DIR/uniffi" -name "*.kt" | sed 's/^/  /'
