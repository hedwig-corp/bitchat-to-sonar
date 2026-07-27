#!/bin/bash
#
# Verify every Android native library has 16 KB-aligned LOAD segments.
#
# GrapheneOS and Android 15+ devices can run a 16 KB-page kernel; a .so whose
# ELF LOAD segments are only 4 KB-aligned fails at dlopen with a hard abort.
# core/build-android.sh links libsonar_ffi.so with max-page-size=16384; this
# script is the independent check (also covers copied prebuilts such as
# libc++_shared.so and any AAR-shipped JNI that ends up in the APK).
#
# Usage:
#   scripts/check-so-alignment.sh                    # scan the default jniLibs
#   scripts/check-so-alignment.sh path/to/dir-or.apk # scan a dir of .so or an APK
#
# Exit codes: 0 = all aligned, 1 = at least one under-aligned .so, 2 = usage.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-$REPO_ROOT/apps/sonar/composeApp/src/androidMain/jniLibs}"
MIN_ALIGN=$((0x4000))

# Find a readelf: prefer llvm-readelf from the NDK, fall back to PATH.
find_readelf() {
  if command -v llvm-readelf >/dev/null 2>&1; then echo "llvm-readelf"; return; fi
  local sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
  local ndk="${ANDROID_NDK_HOME:-}"
  if [[ -z "$ndk" && -d "$sdk/ndk" ]]; then
    ndk="$sdk/ndk/$(ls "$sdk/ndk" | sort -V | tail -1)"
  fi
  if [[ -n "$ndk" ]]; then
    local host_dir
    host_dir="$(ls "$ndk/toolchains/llvm/prebuilt" 2>/dev/null | head -1)"
    local cand="$ndk/toolchains/llvm/prebuilt/$host_dir/bin/llvm-readelf"
    [[ -x "$cand" ]] && { echo "$cand"; return; }
  fi
  if command -v readelf >/dev/null 2>&1; then echo "readelf"; return; fi
  echo ""
}

READELF="$(find_readelf)"
[[ -n "$READELF" ]] || {
  echo "error: no llvm-readelf/readelf found (install an Android NDK or LLVM)" >&2
  exit 2
}

# Collect .so files: from a directory tree, or extracted from an APK.
WORKDIR=""
cleanup() { if [[ -n "$WORKDIR" ]]; then rm -rf "$WORKDIR"; fi; }
trap cleanup EXIT

declare -a SO_FILES=()
if [[ -d "$TARGET" ]]; then
  while IFS= read -r f; do SO_FILES+=("$f"); done < <(find "$TARGET" -name '*.so' | sort)
elif [[ -f "$TARGET" && "$TARGET" == *.apk ]]; then
  WORKDIR="$(mktemp -d)"
  unzip -q "$TARGET" 'lib/*' -d "$WORKDIR" || true
  while IFS= read -r f; do SO_FILES+=("$f"); done < <(find "$WORKDIR" -name '*.so' | sort)
else
  echo "usage: $0 [jniLibs-dir | app.apk]" >&2
  exit 2
fi

[[ ${#SO_FILES[@]} -gt 0 ]] || { echo "error: no .so files found under $TARGET" >&2; exit 2; }

fail=0
for so in "${SO_FILES[@]}"; do
  # Minimum LOAD-segment alignment; readelf prints it in the last column
  # (hex like 0x4000 or decimal). Hex→dec in bash arithmetic — BSD awk (macOS)
  # has no strtonum. Take the smallest across segments.
  min=""
  while IFS= read -r a; do
    v=$(( a ))   # bash arithmetic accepts both 0x-hex and decimal
    if [[ -z "$min" || $v -lt $min ]]; then min=$v; fi
  done < <("$READELF" -lW "$so" | awk '$1 == "LOAD" { print $NF }')
  min="${min:-0}"
  # Only 64-bit ABIs can run under a 16 KB-page kernel; armeabi-v7a (32-bit)
  # never does, so its 4 KB alignment is expected — report, don't fail.
  enforced=1
  case "$so" in
    */armeabi-v7a/*) enforced=0 ;;
  esac
  if (( min >= MIN_ALIGN )); then
    printf '  ok    %-8s %s\n' "$(printf '0x%x' "$min")" "${so#$REPO_ROOT/}"
  elif (( enforced )); then
    printf '  FAIL  %-8s %s\n' "$(printf '0x%x' "$min")" "${so#$REPO_ROOT/}"
    fail=1
  else
    printf '  note  %-8s %s (32-bit ABI, not enforced)\n' "$(printf '0x%x' "$min")" "${so#$REPO_ROOT/}"
  fi
done

if (( fail )); then
  echo ""
  echo "error: .so files above have LOAD alignment < 0x4000 and will crash on" >&2
  echo "16 KB-page devices (GrapheneOS / Android 15+). Rebuild with NDK r27+" >&2
  echo "via core/build-android.sh (it sets -Wl,-z,max-page-size=16384)." >&2
  exit 1
fi
echo "All ${#SO_FILES[@]} native libraries are 16 KB-aligned."
