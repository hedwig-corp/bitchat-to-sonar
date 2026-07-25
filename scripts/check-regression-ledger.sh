#!/usr/bin/env bash
# Assert every test cited in docs/REGRESSIONS.md exists, is a real test, and is enabled.
#
# The ledger's value is the link from an invariant to the test that pins it, and
# that link is what rots first: a test gets renamed and the entry quietly becomes
# a lie. This checks the part a machine can check.
#
# It is deliberately strict about FALSE PASSES: a checker that silently passes is
# worse than no checker. So a citation resolves only if:
#   - the declaration lives in a known test location (not production source),
#   - it is annotated as a test (@Test / #[test] / #[tokio::test]),
#   - it is not commented out and not disabled (@Ignore / #[ignore]),
#   - for Class.method, the method is inside that class's body (not merely in the
#     same file), searching every file that declares the class rather than the
#     first one found.
#
# It cannot tell whether a test is still *meaningful*, or whether it pins the real
# call site rather than a helper. Those stay review questions — see the Unguarded
# section of the ledger.
#
# Citation grammar (from "Guarded by:" / "Also guarded by:" lines):
#   `ClassName.methodName`   Kotlin / Swift test in a test source set
#   `file.rs::fn_name`       Rust #[test] / #[tokio::test] (these live in-tree
#                            under #[cfg(test)], so they are matched by file)
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

LEDGER="docs/REGRESSIONS.md"

# Test locations only. Production source sets are deliberately excluded: if
# `apps/sonar/.../commonMain` or the iOS app were searched, deleting a real test
# would still pass whenever production code happened to declare the same symbol.
KOTLIN_SWIFT_TEST_ROOTS=(
  "apps/sonar/composeApp/src/commonTest"
  "apps/sonar/composeApp/src/jvmTest"
  "apps/sonar/composeApp/src/androidUnitTest"
  "ios/bitchatTests"
)
# Rust unit tests live beside production code under #[cfg(test)], so the root is
# the crate; the #[test] annotation requirement is what keeps this honest.
RUST_ROOT="core"

if [[ ! -f "$LEDGER" ]]; then
  echo "check-regression-ledger: $LEDGER not found" >&2
  exit 1
fi

# Only "Guarded by:" lines count, so backticked prose elsewhere is not read as a
# citation. Fenced blocks are stripped so the entry-format example is skipped.
refs=$(awk '/^```/ { fenced = !fenced; next } !fenced' "$LEDGER" \
  | grep -E '^\*\*(Also g|G)uarded by:\*\*' \
  | grep -oE '`[A-Za-z_][A-Za-z0-9_/.]*(\.[A-Za-z_][A-Za-z0-9_]*|::[A-Za-z_][A-Za-z0-9_]*)`' \
  | tr -d '`' \
  | sort -u)

if [[ -z "$refs" ]]; then
  echo "check-regression-ledger: no 'Guarded by:' references found in $LEDGER" >&2
  echo "Every entry must cite a test that fails without the fix." >&2
  exit 1
fi

existing_roots=()
for root in "${KOTLIN_SWIFT_TEST_ROOTS[@]}"; do
  [[ -d "$root" ]] && existing_roots+=("$root")
done
if [[ ${#existing_roots[@]} -eq 0 ]]; then
  echo "check-regression-ledger: no test roots found; run from the repo root" >&2
  exit 1
fi

# Is `method` declared as an enabled test inside `class`'s body in `file`?
# Scopes to the class body so an unrelated method elsewhere in the same file
# cannot satisfy the citation.
check_class_method() {
  local file="$1" class="$2" method="$3"
  awk -v class="$class" -v method="$method" '
    # Track the enclosing top-level declaration. Swift methods may live in an
    # `extension Foo`, so extensions count as part of the class body.
    # Each modifier is followed by whitespace; grouping the separator INSIDE the
    # repeated alternation is what lets `final class Foo` match. Without it the
    # regex demanded `final` be immediately adjacent to `class`, so every
    # `final class ...: XCTestCase` suite silently failed to resolve.
    /^[[:space:]]*((public|internal|private|final|open|@[A-Za-z]+)[[:space:]]+)*(class|struct|extension)[[:space:]]+[A-Za-z_]/ {
      inclass = ($0 ~ ("(class|struct|extension)[[:space:]]+" class "([[:space:]]*[:{<]|[[:space:]]*$)"))
    }
    {
      # Remember recent annotations, ignoring comments and blank lines.
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^(\/\/|\/\*|\*)/ || line == "") { next }
      if (line ~ /@Ignore|#\[ignore\]/) { disabled = 1 }
      if (line ~ /@Test|#\[test\]|#\[tokio::test\]/) { annotated = 1; disabled = 0; next }

      if (inclass && line ~ ("^(public |internal |private |suspend |inline |override )*(fun|func)[[:space:]]+" method "[[:space:]]*\\(")) {
        # XCTest discovers by the `test` prefix, not by an annotation, so a
        # `func testFoo()` in a Swift suite IS an enabled test. Scoped to `func`
        # so a Kotlin `fun testFoo()` still requires its @Test.
        xctest = (line ~ /(^|[[:space:]])func[[:space:]]/ && method ~ /^test/)
        if ((annotated || xctest) && !disabled) { found = 1; exit }
        if (!annotated && !xctest) { unannotated = 1 }
        if (disabled) { was_disabled = 1 }
      }
      # An annotation only applies to the next declaration.
      if (line ~ /^(public |internal |private |suspend |inline |override |async )*(fun|func|fn)[[:space:]]/) { annotated = 0; disabled = 0 }
    }
    END {
      if (found) { print "ok"; exit }
      if (was_disabled) { print "disabled"; exit }
      if (unannotated) { print "unannotated"; exit }
      print "absent"
    }
  ' "$file"
}

# Is `fn` an enabled #[test]/#[tokio::test] in this Rust file?
check_rust_fn() {
  local file="$1" fn="$2"
  # Verdict is printed only from END: awk's `exit` still runs END, so printing
  # from the main body would emit the verdict twice.
  awk -v fn="$fn" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^(\/\/|\/\*|\*)/ || line == "") { next }
      if (line ~ /#\[ignore\]/) { disabled = 1 }
      if (line ~ /#\[(tokio::)?test\]/) { annotated = 1; disabled = 0; next }
      if (line ~ ("^(pub )?(async )?fn[[:space:]]+" fn "[[:space:]]*\\(")) {
        if (annotated && !disabled) { found = 1; exit }
        if (disabled) { was_disabled = 1; exit }
        unannotated = 1; exit
      }
      if (line ~ /^(pub )?(async )?fn[[:space:]]/) { annotated = 0; disabled = 0 }
    }
    END {
      if (found) { print "ok" }
      else if (was_disabled) { print "disabled" }
      else if (unannotated) { print "unannotated" }
      else { print "absent" }
    }
  ' "$file"
}

missing=0
checked=0

while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  checked=$((checked + 1))

  # Rust citation: file.rs::fn_name
  if [[ "$ref" == *".rs::"* ]]; then
    rust_file="${ref%%::*}"
    rust_fn="${ref##*::}"
    if [[ ! -d "$RUST_ROOT" ]]; then
      echo "MISSING ROOT   $ref  (no '$RUST_ROOT' directory)"
      missing=$((missing + 1)); continue
    fi
    candidates=$(find "$RUST_ROOT" -name "$(basename "$rust_file")" -not -path "*/target/*" 2>/dev/null)
    if [[ -z "$candidates" ]]; then
      echo "MISSING FILE   $ref  (no '$rust_file' under $RUST_ROOT/)"
      missing=$((missing + 1)); continue
    fi
    verdict="absent"
    while IFS= read -r cand; do
      [[ -z "$cand" ]] && continue
      r=$(check_rust_fn "$cand" "$rust_fn")
      [[ "$r" == "ok" ]] && { verdict="ok"; break; }
      [[ "$r" != "absent" ]] && verdict="$r"
    done <<< "$candidates"
    case "$verdict" in
      ok) ;;
      disabled)    echo "DISABLED TEST  $ref  (#[ignore] — it guards nothing)"; missing=$((missing + 1)) ;;
      unannotated) echo "NOT A TEST     $ref  (no #[test]/#[tokio::test] on '$rust_fn')"; missing=$((missing + 1)) ;;
      *)           echo "MISSING TEST   $ref  ('$rust_fn' not found in $rust_file)"; missing=$((missing + 1)) ;;
    esac
    continue
  fi

  # Kotlin/Swift citation: Class.method
  class="${ref%%.*}"
  method="${ref##*.}"

  # Every file declaring the class, not just the first: duplicate class names or
  # Swift extensions would otherwise cause an arbitrary, wrong verdict.
  files=$(grep -rlE "(class|struct|extension)[[:space:]]+${class}\b" \
    --include="*.kt" --include="*.swift" "${existing_roots[@]}" 2>/dev/null)

  if [[ -z "$files" ]]; then
    echo "MISSING CLASS  $ref  (no test source declares '$class'; production code does not count)"
    missing=$((missing + 1)); continue
  fi

  verdict="absent"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    r=$(check_class_method "$f" "$class" "$method")
    [[ "$r" == "ok" ]] && { verdict="ok"; break; }
    [[ "$r" != "absent" ]] && verdict="$r"
  done <<< "$files"

  case "$verdict" in
    ok) ;;
    disabled)    echo "DISABLED TEST  $ref  (@Ignore — it guards nothing)"; missing=$((missing + 1)) ;;
    unannotated) echo "NOT A TEST     $ref  ('$method' exists but has no @Test annotation)"; missing=$((missing + 1)) ;;
    *)           echo "MISSING TEST   $ref  ('$method' not found in $class's body)"; missing=$((missing + 1)) ;;
  esac
done <<< "$refs"

if [[ $missing -gt 0 ]]; then
  cat >&2 <<EOF

check-regression-ledger: $missing of $checked citation(s) do not resolve to an enabled test.

docs/REGRESSIONS.md cites tests that no longer exist, are not tests, or are
disabled. Either restore the test or update the entry. If an invariant genuinely
lost its guard, move it to the "Unguarded" section rather than deleting it —
that section is the backlog.
EOF
  exit 1
fi

echo "check-regression-ledger: $checked regression test citation(s) OK"
