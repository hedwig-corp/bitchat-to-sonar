#!/usr/bin/env bash
# Assert every test cited in docs/REGRESSIONS.md still exists.
#
# The ledger's value is the link from an invariant to the test that pins it. That
# link is what rots first: tests get renamed, and the entry silently becomes a
# lie. This checks the one part a machine can check. Whether the test is still
# *meaningful* is a review question.
#
# Ledger lines look like:
#   **Guarded by:** `TranscriptDisplayPolicyTest.outOfWindowCanonicalRowFulfillsEchoAndIsAdmitted`
#   **Also guarded by:** `ATest.one`, `BTest.two`
#
# For each `Class.method`, require a test source declaring that class AND a
# function of that name.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

LEDGER="docs/REGRESSIONS.md"
TEST_ROOTS=("apps/sonar/composeApp/src" "ios/bitchatTests" "ios/bitchat")

if [[ ! -f "$LEDGER" ]]; then
  echo "check-regression-ledger: $LEDGER not found" >&2
  exit 1
fi

# Collect `Class.method` refs from "Guarded by:" / "Also guarded by:" lines only,
# so prose backticks elsewhere are not treated as test references. Fenced blocks
# are stripped first so the entry-format example is not read as a real citation.
refs=$(awk '/^```/ { fenced = !fenced; next } !fenced' "$LEDGER" \
  | grep -E '^\*\*(Also g|G)uarded by:\*\*' \
  | grep -oE '`[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*`' \
  | tr -d '`' \
  | sort -u)

if [[ -z "$refs" ]]; then
  echo "check-regression-ledger: no 'Guarded by:' references found in $LEDGER" >&2
  echo "Every entry must cite a test that fails without the fix." >&2
  exit 1
fi

existing_roots=()
for root in "${TEST_ROOTS[@]}"; do
  [[ -d "$root" ]] && existing_roots+=("$root")
done

if [[ ${#existing_roots[@]} -eq 0 ]]; then
  echo "check-regression-ledger: no test roots found; run from the repo root" >&2
  exit 1
fi

missing=0
checked=0

while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  checked=$((checked + 1))
  class="${ref%%.*}"
  method="${ref##*.}"

  # The file declaring the class (Kotlin `class Foo`, Swift `class Foo` / extension).
  file=$(grep -rlE "(class|struct|extension)[[:space:]]+${class}\b" \
    --include="*.kt" --include="*.swift" "${existing_roots[@]}" 2>/dev/null | head -1)

  if [[ -z "$file" ]]; then
    echo "MISSING CLASS  $ref  (no test source declares '$class')"
    missing=$((missing + 1))
    continue
  fi

  # Kotlin declares `fun name(`, Swift declares `func name(`.
  if ! grep -qE "\b(fun|func)[[:space:]]+${method}[[:space:]]*\(" "$file" 2>/dev/null; then
    echo "MISSING TEST   $ref  ('$method' not found in $file)"
    missing=$((missing + 1))
    continue
  fi
done <<< "$refs"

if [[ $missing -gt 0 ]]; then
  cat >&2 <<EOF

check-regression-ledger: $missing of $checked reference(s) are stale.

docs/REGRESSIONS.md cites tests that no longer exist. Either restore the test or
update the entry. If an invariant genuinely lost its test, move it to the
"Unguarded" section rather than deleting it — that section is the backlog.
EOF
  exit 1
fi

echo "check-regression-ledger: $checked regression test reference(s) OK"
