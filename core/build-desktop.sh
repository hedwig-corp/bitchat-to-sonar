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

# --- Build the BLE radio bridge (sonar-ble: native CoreBluetooth/BlueZ over a C
#     ABI, loaded by JNA) and drop its dynamic library next to the core's. It's a
#     SEPARATE cargo workspace (its BLE deps stay out of sonar-ffi / CI). ---------
BLE_LIB="$(echo "$LIB" | sed 's/sonar_ffi/sonar_ble/')"  # libsonar_ble.<ext>
echo "Building sonar-ble (BLE radio bridge)..."
( cd "$SCRIPT_DIR/sonar-ble" && cargo build --release --lib )
BLE_BUILT="$SCRIPT_DIR/sonar-ble/target/release/$BLE_LIB"
if [[ -f "$BLE_BUILT" ]]; then
  cp "$BLE_BUILT" "$RES_DIR/$JNA_PREFIX/$BLE_LIB"
  [[ -n "$JNA_PREFIX_ALT" ]] && cp "$BLE_BUILT" "$RES_DIR/$JNA_PREFIX_ALT/$BLE_LIB"
else
  echo "warning: $BLE_BUILT not found — desktop BLE will be unavailable" >&2
fi

# --- Fetch the Breez SDK Liquid native lib (on-device ⚡PAY wallet) -------------
# The KMP `jvm` variant (technology.breez.liquid:breez-sdk-liquid-kmp) is a
# UniFFI/JNA binding that loads libbreez_sdk_liquid_bindings off the classpath but
# does NOT bundle it. Breez ships the prebuilt host libs in the Go bindings repo;
# we pull the one matching our exact KMP version (kept in sync with libs.versions
# .toml) so the desktop wallet reconstructs the SAME wallet as Android/iOS.
BREEZ_VER="$(sed -n 's/^breez-sdk-liquid *= *"\([^"]*\)".*/\1/p' "$REPO_ROOT/apps/sonar/gradle/libs.versions.toml" | head -1)"
case "$UNAME_S" in
  Darwin) BREEZ_GOARCH="$([[ $JNA_ARCH == aarch64 ]] && echo darwin-aarch64 || echo darwin-amd64)"; BREEZ_LIB="libbreez_sdk_liquid_bindings.dylib" ;;
  Linux)  BREEZ_GOARCH="$([[ $JNA_ARCH == aarch64 ]] && echo linux-aarch64 || echo linux-amd64)";  BREEZ_LIB="libbreez_sdk_liquid_bindings.so" ;;
  *)      BREEZ_GOARCH="windows-amd64"; BREEZ_LIB="breez_sdk_liquid_bindings.dll" ;;
esac

# Pinned SHA256 of the Breez native lib per "<version>|<goarch>". This is a
# fund-path native library fetched from a Git TAG (mutable — a tag can be
# force-moved), so we verify integrity and refuse to ship a mismatch. Update these
# when bumping breez-sdk-liquid in libs.versions.toml:
#   curl -fsSL <url> | shasum -a 256
breez_sha256() {
  case "$1|$2" in
    "0.11.13|darwin-aarch64") echo "164d0bd874a9f9e20d6950335274cb6d66dd4c180f5e3a17e80f56a0613919e0" ;;
    "0.11.13|darwin-amd64")   echo "9573f1541fb3e2f10932a1593a5d7ae2cc5fcd984d311db09b4f3034a92fbeb6" ;;
    "0.11.13|linux-aarch64")  echo "38ffe3af352277bd6b9ef4f07e740d53133936a0c629060e9f5b76d22c58f54f" ;;
    "0.11.13|linux-amd64")    echo "656d228c168da625745d18ecd545c1ebee76db9e78ebd6b09937c3cc17eebc2c" ;;
    "0.11.13|windows-amd64")  echo "718a8305a03dfbc71fedd18c2566933f1b4dd1d25f92a1032c9d3c9ca2435c40" ;;
    *) echo "" ;;
  esac
}
sha256_of() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }

if [[ -n "$BREEZ_VER" ]]; then
  BREEZ_URL="https://raw.githubusercontent.com/breez/breez-sdk-liquid-go/v$BREEZ_VER/breez_sdk_liquid/lib/$BREEZ_GOARCH/$BREEZ_LIB"
  BREEZ_DEST="$RES_DIR/$JNA_PREFIX/$BREEZ_LIB"
  echo "Fetching Breez SDK Liquid native lib v$BREEZ_VER ($BREEZ_GOARCH)..."
  if curl -fsSL -o "$BREEZ_DEST" "$BREEZ_URL"; then
    WANT_SHA="$(breez_sha256 "$BREEZ_VER" "$BREEZ_GOARCH")"
    GOT_SHA="$(sha256_of "$BREEZ_DEST")"
    if [[ -z "$WANT_SHA" ]]; then
      echo "warning: no pinned SHA256 for breez $BREEZ_VER/$BREEZ_GOARCH — integrity NOT verified." >&2
      echo "         Add it to breez_sha256() in build-desktop.sh after bumping the version." >&2
    elif [[ "$WANT_SHA" != "$GOT_SHA" ]]; then
      rm -f "$BREEZ_DEST"
      echo "error: Breez native lib checksum mismatch ($BREEZ_GOARCH) — refusing to ship an" >&2
      echo "       unverified fund-path library." >&2
      echo "       expected $WANT_SHA" >&2
      echo "       got      $GOT_SHA" >&2
      exit 1
    else
      echo "Breez native lib SHA256 verified ($BREEZ_GOARCH)."
    fi
    [[ -f "$BREEZ_DEST" && -n "$JNA_PREFIX_ALT" ]] && cp "$BREEZ_DEST" "$RES_DIR/$JNA_PREFIX_ALT/$BREEZ_LIB"
  else
    echo "warning: could not fetch $BREEZ_URL — desktop ⚡PAY wallet will be unavailable" >&2
  fi
else
  echo "warning: breez-sdk-liquid version not found in libs.versions.toml — skipping wallet lib" >&2
fi

echo ""
echo "Done. Outputs under $OUT:"
find "$RES_DIR" \( -name "$LIB" -o -name "$BLE_LIB" \) -exec ls -lh {} \; | awk '{print "  " $NF " (" $5 ")"}'
find "$KOTLIN_DIR/uniffi" -name "*.kt" | sed 's/^/  /'
