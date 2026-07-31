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
#               nonce or seed. Every call must check errSecSuccess on its own
#               line; the one blessed helper is exempt.
#   2. Rust   — an unhandled getrandom error leaves the array zeroed for the
#               same reason. The statement must propagate (?) or panic loudly.
#   3. Kotlin — kotlin.random.Random is a clock-seeded XorWow, not a CSPRNG.
#               Compose/shared production code must go through
#               secureRandomBytes()/secureRandomHex() (see SecureRandom.kt).
#
# Deliberate non-crypto randomness (UI jitter, backoff, sampling) is allowed
# with an inline opt-out on the same line or the line above:
#
#     val delay = (0..100).random()   // rng-hygiene: ok — animation jitter
#
# Scope: TRACKED files only (git ls-files), so gitignored build output and SPM
# checkouts under ios/build/DerivedData never trip it. Rust skips vendored and
# generated trees. Test sources are excluded — fixtures are deterministic on
# purpose.
#
# Run from the repo root. Exits non-zero with the offending lines.

set -uo pipefail
cd "$(dirname "$0")/.."

status=0
fail() { printf '\n\033[31mFAIL\033[0m %s\n' "$1"; status=1; }

OPT_OUT='rng-hygiene: ok'
# The blessed Swift helper: the only place allowed to call SecRandomCopyBytes
# without errSecSuccess on the same line (it checks on the next line).
SWIFT_HELPER='ios/bitchat/Utils/SecureRandom.swift'

# Tracked sources, minus test trees. A file list, not a directory walk, so
# nothing gitignored can reach any rule.
list_sources() { # $1 = glob
  git ls-files "$1" \
    | grep -vE '(^|/)(bitchatTests|TestUtilities|commonTest|jvmTest|androidUnitTest|androidInstrumentedTest|tests?)/' \
    || true
}

# Emit "file:line:text" for lines matching $2 in the given files, dropping
# comment lines (prose about a rule must not trip the rule) and opt-outs.
scan() { # $1 = newline-separated files, $2 = ERE
  [ -z "$1" ] && return 0
  printf '%s\n' "$1" | tr '\n' '\0' | xargs -0 -r grep -nHE "$2" 2>/dev/null \
    | grep -vE ':[[:space:]]*(///|//|\*|/\*|#)' \
    | grep -vF "$OPT_OUT" \
    || true
}

# ---------------------------------------------------------------- Swift ----
# Require errSecSuccess on the SAME line as the call. A window search lets an
# unchecked call inherit the guard of a checked call above it.
swift_bad=$(
  scan "$(list_sources '*.swift')" 'SecRandomCopyBytes' \
    | grep -v 'errSecSuccess' \
    | grep -vF "$SWIFT_HELPER:" \
    || true
)
if [ -n "$swift_bad" ]; then
  fail "SecRandomCopyBytes without an errSecSuccess check on the same line (a failure here yields an all-zeros buffer):"
  printf '%s\n' "$swift_bad" | sed 's/^/  /'
  echo "  → use SecureRandom.bytes(_:) / SecureRandom.optionalBytes(_:) from $SWIFT_HELPER"
fi

# ----------------------------------------------------------------- Rust ----
# Statement-scoped: a call may wrap onto the next line (`getrandom(..)` then
# `.map_err(..)?;`), so collect through the terminating `;` before judging.
# Handled == propagates with ? or panics with expect/unwrap. Everything else
# (`let _ =`, `let _res =`, `.ok()`, a bare `is_err()` test) leaves the buffer
# zeroed and is flagged.
rust_files=$(git ls-files '*.rs' | grep -vE '(^|/)(vendor|target)/' || true)
rust_bad=$(
  [ -z "$rust_files" ] || printf '%s\n' "$rust_files" | tr '\n' '\0' | xargs -0 -r awk '
    function judge(text, where,   t) {
      t = text
      sub(/;.*$/, "", t)                       # statement ends at the first ;
      if (t !~ /\?/ && t !~ /\.expect\(/ && t !~ /\.unwrap\(/)
        printf "%s:%d:%s\n", FILENAME, where, t
    }
    FNR==1 { instmt=0; buf=""; start=0 }
    {
      if (instmt) {                            # continuation of a wrapped call
        buf = buf " " $0
        if (index(buf, ";")) { judge(buf, start); instmt=0 }
        next
      }
      line=$0
      sub(/^[[:space:]]*/, "", line)
      if (line ~ /^(\/\/|\*|#)/) next
      if (line ~ /^use /) next
      if (index($0, "rng-hygiene: ok")) next
      # Only real calls: `getrandom(` — never a type position like
      # `getrandom::Error`, which has no open paren after the name.
      if (match($0, /getrandom[[:space:]]*\(/) == 0) next
      buf = substr($0, RSTART)                 # from the call to end of line
      if (index(buf, ";")) { judge(buf, FNR) } else { instmt=1; start=FNR }
    }
  ' || true
)
if [ -n "$rust_bad" ]; then
  fail "getrandom error not handled (leaves the buffer zeroed):"
  printf '%s\n' "$rust_bad" | sed 's/^/  /'
  echo "  → propagate with ? / map_err(..)?, or .expect(\"OS RNG available\")"
fi

# --------------------------------------------------------------- Kotlin ----
# Denylist the RNG *token*, not the receiver shape. Matching only
# `"0123456789abcdef".random()` is bypassed by hoisting the alphabet into a
# val — which is the deleted code, one refactor away.
kotlin_bad=$(
  scan "$(list_sources '*.kt')" '\.random\(\)|kotlin\.random|java\.util\.Random|Math\.random|[^a-zA-Z]Random\(|Random\.next' \
    | grep -v 'secureRandom' \
    || true
)
if [ -n "$kotlin_bad" ]; then
  fail "non-cryptographic randomness in shared/Compose production code:"
  printf '%s\n' "$kotlin_bad" | sed 's/^/  /'
  echo "  → use secureRandomBytes()/secureRandomHex() from SecureRandom.kt,"
  echo "    or mark a deliberate non-crypto use: // $OPT_OUT — <reason>"
fi

if [ "$status" -eq 0 ]; then
  echo "RNG hygiene: OK (Swift SecRandomCopyBytes checked, getrandom errors handled, Kotlin uses the CSPRNG seam)"
fi
exit "$status"
