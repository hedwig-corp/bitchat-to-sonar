#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke/relay-smoke-classifier.sh
source "$ROOT/scripts/smoke/relay-smoke-classifier.sh"

assert_classification() {
  local expected="$1"
  shift
  local actual
  actual="$(classify_relay_smoke "$@")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'expected %s, got %s for: %s\n' "$expected" "$actual" "$*" >&2
    exit 1
  fi
}

assert_classification pass         pass fail 20 20 20 0
assert_classification relay_issue  fail pass 20 0 20 20
assert_classification target_fail  fail skipped 20 0 0 0
assert_classification relay_issue  fail fail 20 0 20 15
assert_classification regression   fail fail 20 0 20 0
assert_classification inconclusive fail fail 20 12 20 15

printf 'relay-smoke classifier tests passed\n'
