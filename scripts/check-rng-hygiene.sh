#!/usr/bin/env bash
# Fail if production code can silently fall back to predictable randomness.
#
# Motivated by the COLDCARD firmware disclosure (Block, 2026-07):
# https://engineering.block.xyz/blog/predictable-rng-fallback-and-32-bit-reseed-in-coldcard-firmware
# A guard that checked only whether a macro was *defined* — not whether it was
# *enabled* — silently bound wallet seed generation to a non-cryptographic
# fallback PRNG. Nothing crashed, nothing logged, and the firmware shipped that
# way for years. The lesson is not "use a CSPRNG"; every codebase already
# intends to. The lesson is that a degraded RNG path must not be able to
# succeed quietly, and that only a mechanical check keeps it that way.
#
# The three rules below are the shapes that bug takes in this repo:
#
#   1. Swift  — SecRandomCopyBytes returns an OSStatus and leaves the buffer
#               untouched on failure. Callers here start from a zero-filled
#               buffer, so discarding the status yields an all-zeros "random"
#               nonce or seed. Every call must check errSecSuccess.
#   2. Rust   — `let _ = getrandom(..)` leaves the array zeroed for the same
#               reason. Propagate the error or panic; never ignore it.
#   3. Kotlin — kotlin.random.Random is a clock-seeded XorWow, not a CSPRNG.
#               Compose production code must go through secureRandomBytes()/
#               secureRandomHex() (see SecureRandom.kt), matching iOS's UUID().
#
# Run from the repo root. Exits non-zero with the offending lines.

set -uo pipefail
cd "$(dirname "$0")/.."

status=0
fail() { printf '\n\033[31mFAIL\033[0m %s\n' "$1"; status=1; }

# ---------------------------------------------------------------- Swift ----
# Production Swift only: test code may build deterministic fixtures on purpose.
# Comment lines are stripped first so prose about the rule (including this
# script's own reference doc in SecureRandom.swift) does not trip the rule.
swift_hits=$(
  grep -rn --include='*.swift' 'SecRandomCopyBytes' ios/ \
    | grep -v '/bitchatTests/' \
    | grep -v '/TestUtilities/' \
    | grep -vE ':[[:space:]]*(///|//|\*|/\*)' \
    || true
)

swift_bad=""
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  file=${hit%%:*}
  rest=${hit#*:}
  line=${rest%%:*}
  # The status check may sit on the same line (`guard SecRandom... == errSec`)
  # or just below it (`let status = ...` / `guard status == errSecSuccess`).
  from=$(( line > 2 ? line - 2 : 1 ))
  to=$(( line + 3 ))
  if ! sed -n "${from},${to}p" "$file" | grep -q 'errSecSuccess'; then
    swift_bad+="  $hit"$'\n'
  fi
done <<< "$swift_hits"

if [ -n "$swift_bad" ]; then
  fail "SecRandomCopyBytes without an errSecSuccess check (a failure here yields an all-zeros buffer):"
  printf '%s' "$swift_bad"
  echo "  → use SecureRandom.bytes(_:) / SecureRandom.optionalBytes(_:) from ios/bitchat/Utils/SecureRandom.swift"
fi

# ----------------------------------------------------------------- Rust ----
rust_bad=$(
  grep -rn --include='*.rs' -E '(let[[:space:]]+_|^[[:space:]]*_)[[:space:]]*=[[:space:]]*getrandom' core/ \
    | grep -v '/target/' \
    | grep -v '/vendor/' \
    || true
)
if [ -n "$rust_bad" ]; then
  fail "discarded getrandom error (leaves the buffer zeroed):"
  printf '%s\n' "$rust_bad" | sed 's/^/  /'
  echo "  → propagate with ? or .expect(\"OS RNG available\")"
fi

# --------------------------------------------------------------- Kotlin ----
# Strip comment lines first so prose about the rule does not trip the rule.
kotlin_bad=$(
  grep -rn --include='*.kt' -E 'kotlin\.random\.Random|Random\.next|"[0-9a-fA-F]+"\.random\(\)|\)\.random\(\)' \
    apps/sonar/composeApp/src/commonMain \
    apps/sonar/composeApp/src/androidMain \
    apps/sonar/composeApp/src/jvmMain 2>/dev/null \
    | grep -vE ':[[:space:]]*(\*|//|/\*)' \
    || true
)
if [ -n "$kotlin_bad" ]; then
  fail "non-cryptographic kotlin.random in Compose production code:"
  printf '%s\n' "$kotlin_bad" | sed 's/^/  /'
  echo "  → use secureRandomBytes()/secureRandomHex() from SecureRandom.kt"
fi

if [ "$status" -eq 0 ]; then
  echo "RNG hygiene: OK (Swift SecRandomCopyBytes checked, getrandom errors handled, Compose uses the CSPRNG seam)"
fi
exit "$status"
