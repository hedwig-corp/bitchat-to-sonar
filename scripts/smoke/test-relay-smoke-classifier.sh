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

work="$(mktemp -d /tmp/relay-smoke-classifier.XXXXXX)"
trap 'rm -rf "$work"' EXIT
sent="$work/sent.tsv"
received="$work/received.tsv"
matrix="$work/matrix.tsv"

printf '0\t1\t1\t1000\trun:b1:a0:s1\n1\t0\t1\t1001\trun:b0:a1:s1\n' > "$sent"
printf 'run:b1:a0:s1\t1100\n' > "$received"
build_pair_delivery_matrix "$sent" "$received" "$matrix"

expected=$'0\t1\t1\t1\n1\t0\t1\t0'
actual="$(sort "$matrix")"
if [[ "$actual" != "$expected" ]]; then
  printf 'unexpected delivery matrix:\n%s\n' "$actual" >&2
  exit 1
fi

pair_delivery_json "$matrix" | jq -e '
  length == 2 and
  any(.sender == 0 and .receiver == 1 and .sent == 1 and .received == 1) and
  any(.sender == 1 and .receiver == 0 and .sent == 1 and .received == 0)
' >/dev/null

: > "$sent"
build_pair_delivery_matrix "$sent" "$received" "$matrix"
if [[ "$(pair_delivery_json "$matrix")" != "[]" ]]; then
  printf 'empty delivery matrix did not encode as []\n' >&2
  exit 1
fi

printf 'relay-smoke classifier tests passed\n'
