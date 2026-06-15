#!/bin/bash
#
# Build sonar-ffi for iOS/macOS and assemble the SonarCore Swift package bits.
#
# Outputs:
#   ios/localPackages/SonarCore/Frameworks/sonarffi.xcframework
#       static libsonar_ffi.a per slice (ios-arm64, ios-arm64-simulator,
#       macos-arm64), each with Headers/{sonar_ffiFFI.h, module.modulemap}
#   ios/localPackages/SonarCore/Sources/SonarFFI.swift
#       UniFFI-generated Swift bindings (uniffi 0.31, proc-macro mode,
#       library-mode bindgen run against the host (macOS) staticlib)
#
# Usage: core/build-ios.sh
# Prereqs: rustup targets aarch64-apple-ios, aarch64-apple-ios-sim,
#          aarch64-apple-darwin (auto-installed below), Xcode CLT.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

# --- SQLCipher / CommonCrypto (persistent storage) ---------------------------
# sonar-core links mdk-sqlite-storage, which pulls rusqlite's (hardcoded)
# `bundled-sqlcipher` feature. On Apple host→Apple target builds the
# libsqlite3-sys build.rs compiles SQLCipher against Apple CommonCrypto
# (-DSQLCIPHER_CRYPTO_CC, links the Security + CoreFoundation frameworks) IFF no
# OpenSSL is advertised via env. So we UNSET the OpenSSL discovery vars to force
# the CommonCrypto path and avoid the OpenSSL iOS cross-compile entirely.
# (The frameworks come through as `cargo:rustc-link-lib=framework=...` in the
# static lib; the Swift consumer links them automatically via the xcframework.)
unset OPENSSL_DIR OPENSSL_LIB_DIR OPENSSL_INCLUDE_DIR OPENSSL_NO_VENDOR \
      OPENSSL_STATIC LIBSQLITE3_SYS_USE_PKG_CONFIG 2>/dev/null || true

CRATE="sonar-ffi"
LIB_NAME="libsonar_ffi.a"
FFI_MODULE="sonar_ffiFFI" # uniffi: <crate_name>FFI
PKG_DIR="$REPO_ROOT/ios/localPackages/SonarCore"
XCFRAMEWORK="$PKG_DIR/Frameworks/sonarffi.xcframework"
GEN_DIR="$SCRIPT_DIR/target/uniffi-swift"

# NOTE: macOS ships as a universal (arm64+x86_64) slice because
# `generic/platform=macOS` builds both arches (the Arti xcframework is
# arm64-only and already fails that x86_64 link; don't make it worse).
TARGETS=(
    "aarch64-apple-ios"     # iOS device
    "aarch64-apple-ios-sim" # iOS simulator (Apple Silicon)
    "aarch64-apple-darwin"  # macOS (Apple Silicon)
    "x86_64-apple-darwin"   # macOS (Intel; lipo'd with the arm64 build)
)

GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[build-ios]${NC} $1"; }

# --- prerequisites -----------------------------------------------------------
for target in "${TARGETS[@]}"; do
    if ! rustup target list --installed | grep -q "^$target$"; then
        log "Installing rust target $target"
        rustup target add "$target"
    fi
done

# --- build the staticlib for every slice -------------------------------------
# NOTE: --lib only; the uniffi-bindgen helper bin (feature "cli") must never be
# cross-compiled. Size opts (opt-level=z, thin LTO) live in [profile.release]
# in core/Cargo.toml — NOT in RUSTFLAGS, where `-C lto` clashes with cargo's
# `-C embed-bitcode=no`. No `-C strip=symbols` anywhere: bindgen library mode
# reads uniffi metadata symbols from the .a; we `strip -x` (local syms only)
# afterwards.
for target in "${TARGETS[@]}"; do
    case "$target" in
        *-apple-ios*)    export IPHONEOS_DEPLOYMENT_TARGET="16.0" ;;
        *-apple-darwin*) export MACOSX_DEPLOYMENT_TARGET="13.0" ;;
    esac
    log "cargo build --release --target $target"
    cargo build --release --target "$target" -p "$CRATE" --lib
done

# --- generate Swift bindings (library mode, against the host slice) ----------
rm -rf "$GEN_DIR"
log "Generating Swift bindings (uniffi-bindgen library mode)"
cargo run -q -p "$CRATE" --features cli --bin uniffi-bindgen -- \
    generate --library "$SCRIPT_DIR/target/aarch64-apple-darwin/release/$LIB_NAME" \
    --language swift --out-dir "$GEN_DIR"

# --- assemble headers per slice ----------------------------------------------
# xcodebuild requires a separate -headers dir per -library; the modulemap must
# be named module.modulemap inside the xcframework Headers for SPM to find it.
HEADERS_DIR="$GEN_DIR/Headers"
rm -rf "$HEADERS_DIR"; mkdir -p "$HEADERS_DIR"
cp "$GEN_DIR/$FFI_MODULE.h" "$HEADERS_DIR/"
cp "$GEN_DIR/$FFI_MODULE.modulemap" "$HEADERS_DIR/module.modulemap"

# --- create xcframework -------------------------------------------------------
rm -rf "$XCFRAMEWORK"
mkdir -p "$PKG_DIR/Frameworks"

# Universal macOS lib (xcodebuild rejects two separate macos libraries).
MACOS_UNIVERSAL_DIR="$SCRIPT_DIR/target/universal-macos/release"
mkdir -p "$MACOS_UNIVERSAL_DIR"
lipo -create \
    "$SCRIPT_DIR/target/aarch64-apple-darwin/release/$LIB_NAME" \
    "$SCRIPT_DIR/target/x86_64-apple-darwin/release/$LIB_NAME" \
    -output "$MACOS_UNIVERSAL_DIR/$LIB_NAME"

ARGS=()
for lib in \
    "$SCRIPT_DIR/target/aarch64-apple-ios/release/$LIB_NAME" \
    "$SCRIPT_DIR/target/aarch64-apple-ios-sim/release/$LIB_NAME" \
    "$MACOS_UNIVERSAL_DIR/$LIB_NAME"; do
    strip -x "$lib" 2>/dev/null || true
    ARGS+=(-library "$lib" -headers "$HEADERS_DIR")
done
log "xcodebuild -create-xcframework"
xcodebuild -create-xcframework "${ARGS[@]}" -output "$XCFRAMEWORK"

# --- install generated Swift into the package ---------------------------------
mkdir -p "$PKG_DIR/Sources"
cp "$GEN_DIR/sonar_ffi.swift" "$PKG_DIR/Sources/SonarFFI.swift"

log "Done."
log "  $XCFRAMEWORK ($(du -sh "$XCFRAMEWORK" | cut -f1))"
log "  $PKG_DIR/Sources/SonarFFI.swift"
