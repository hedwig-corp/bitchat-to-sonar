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

# Every rule sources its file list from `git ls-files` and short-circuits on an
# empty list, so run outside a checkout this would print OK and exit 0 — a
# guard whose whole thesis is "a degraded path must not succeed quietly" must
# not do that itself.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "check-rng-hygiene: not inside a git work tree — cannot enumerate sources" >&2
  exit 2
}
if [ -z "$(git ls-files '*.swift' '*.rs' '*.kt')" ]; then
  echo "check-rng-hygiene: no tracked Swift/Rust/Kotlin sources found — refusing to report OK" >&2
  exit 2
fi

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
# whole-comment lines (prose about a rule must not trip the rule) and opt-outs.
#
# The comment pattern is ANCHORED to the start of the grep prefix
# (`path:lineno:`). Unanchored, it matches a `:` followed by `//` anywhere in
# the line — which `https://` in a trailing comment satisfies, silently
# exempting the code. ~200 tracked source files already carry a `://` line, so
# that is an accident waiting, not a contrived bypass.
scan() { # $1 = newline-separated files, $2 = ERE
  [ -z "$1" ] && return 0
  printf '%s\n' "$1" | tr '\n' '\0' | xargs -0 -r grep -nHE "$2" 2>/dev/null \
    | grep -vE '^[^:]*:[0-9]+:[[:space:]]*(///|//|\*|/\*|#)' \
    | grep -vF "$OPT_OUT" \
    || true
}

# ---------------------------------------------------------------- Swift ----
# The check must be tied to the CALL, not to the line. A window search lets an
# unchecked call inherit a checked call's guard from above; a line-wide
# substring allowlist reopens the same hole from the side:
#
#     _ = a.withUnsafeMutableBytes { SecRandomCopyBytes(..) }; if s == errSecSuccess { }
#
# So: cut the line at the call, keep only the statement it starts (up to `;`),
# and require errSecSuccess inside THAT span.
swift_bad=$(
  scan "$(list_sources '*.swift')" 'SecRandomCopyBytes' \
    | grep -vF "$SWIFT_HELPER:" \
    | awk -F: '
      {
        prefix = $1 ":" $2
        text = substr($0, length(prefix) + 2)
        # Judge every call on the line, not just the first.
        rest = text; bad = 0
        while (match(rest, /SecRandomCopyBytes/)) {
          stmt = substr(rest, RSTART)
          sub(/;.*$/, "", stmt)          # this call statement only
          if (stmt !~ /errSecSuccess/) bad = 1
          rest = substr(rest, RSTART + 18)
        }
        if (bad) print prefix ":" text
      }' \
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
# (`let _ =`, `let _res =`, `.ok()`, a `match` that drops both arms) leaves the
# buffer zeroed and is flagged.
#
# Routed through list_sources so test trees really are excluded, as the header
# and CLAUDE.md both claim — deterministic fixtures are legitimate there.
rust_files=$(list_sources '*.rs' | grep -vE '(^|/)(vendor|target)/' || true)
rust_bad=$(
  [ -z "$rust_files" ] || printf '%s\n' "$rust_files" | tr '\n' '\0' | xargs -0 -r awk '
    # Blank out string literals before looking for terminators: `format!("x: {e}")`
    # carries a brace that would otherwise cut the statement short of its `?`.
    function strip(s,   t) { t = s; gsub(/"[^"]*"/, "\"\"", t); return t }
    # `where`/`wfile` are captured where the statement STARTED. A statement left
    # open at EOF is flushed on the next file'\''s first line, so using FILENAME
    # here would blame the wrong file.
    function judge(raw, where, wfile,   t) {
      t = strip(raw)
      sub(/[;{].*$/, "", t)                    # statement ends at the first ; or {
      # `.ok()` and a dropped-Err match are swallows no matter what else the
      # span picked up, so they can never be rescued by a stray ? downstream.
      if (t ~ /\.ok\(\)/ || t ~ /Err\(_\)/) {
        printf "%s:%d:%s\n", wfile, where, t
        return
      }
      if (t !~ /\?/ && t !~ /\.expect\(/ && t !~ /\.unwrap\(/)
        printf "%s:%d:%s\n", wfile, where, t
    }
    # Match both the 0.2 `getrandom::getrandom(..)` and the 0.3+ `getrandom::fill(..)`
    # entry points. Pinning only the former means a dep bump silently disarms
    # the whole Rust half. Never a type position (`getrandom::Error`) — those
    # have no open paren after the name.
    function callAt(s) { return match(s, /getrandom(::(getrandom|fill))?[[:space:]]*\(/) }
    FNR==1 { if (instmt) judge(buf, start, startfile); instmt=0; buf=""; start=0; startfile="" }
    {
      if (instmt) {                            # continuation of a wrapped call
        buf = buf " " $0
        if (strip(buf) ~ /[;{]/) { judge(buf, start, startfile); instmt=0 }
        else next
        # fall through: the same line may open another call
      }
      line=$0
      sub(/^[[:space:]]*/, "", line)
      if (line ~ /^(\/\/|\*|#)/) next
      if (line ~ /^use /) next
      if (index($0, "rng-hygiene: ok")) next
      # Judge EVERY call on the line: a handled call must not cover for an
      # unhandled one after it.
      rest = $0
      while (callAt(rest)) {
        seg = substr(rest, RSTART)
        rest = substr(rest, RSTART + RLENGTH)
        if (strip(seg) ~ /[;{]/) { judge(seg, FNR, FILENAME) }
        else { buf = seg; start = FNR; startfile = FILENAME; instmt = 1 }
      }
    }
    END { if (instmt) judge(buf, start, startfile) }      # unterminated at EOF still counts
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
#
# ThreadLocalRandom/SplittableRandom are named explicitly: `[^a-zA-Z]Random\(`
# cannot match them (a letter sits immediately before `Random`), and they are
# the two JDK RNGs someone reaches for first once kotlin.random is banned.
#
# No `grep -v secureRandom` allowlist: a line-wide substring exemption is the
# same hole as the Swift one, e.g.
#     if (s) secureRandomHex(1).length else (0..15).random()
# The seam's own files are excluded by PATH instead, which cannot be spoofed
# from inside an unrelated line.
kotlin_bad=$(
  scan "$(list_sources '*.kt')" '\.random\(\)|kotlin\.random|java\.util\.Random|Math\.random|ThreadLocalRandom|SplittableRandom|[^a-zA-Z]Random\(|Random\.next' \
    | grep -vE '^[^:]*/SecureRandom(\.android|\.jvm)?\.kt:' \
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
