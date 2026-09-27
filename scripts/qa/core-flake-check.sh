#!/usr/bin/env bash
# core-flake-check.sh — rerun a crate's unit tests many times to catch flakes a
# single CI run misses: tests that share process-wide state and only fail when
# another test interleaves with them (QA-125).
#
#   scripts/qa/core-flake-check.sh [--runs N] [--package CRATE] [FILTER]
#
# Defaults: 20 rounds of `sonar-core`'s whole lib suite. Each round runs it three
# ways: default threads, --test-threads 64 (widens interleavings, which is what
# surfaced the account-backup flake) and --test-threads 1 (order-only bugs).
# Prints each failing test once per failed run; exit status is the number of
# failed runs (capped at 255), so 0 means stable.
set -euo pipefail

RUNS=20
PACKAGE=sonar-core
FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2 ;;
    --package) PACKAGE="$2"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) FILTER="$1"; shift ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT/core"
if ! build="$(cargo test -q -p "$PACKAGE" --lib --no-run 2>&1)"; then echo "$build"; exit 255; fi

failed=0
total=0
for mode in default 64 1; do
  threads=()
  [[ "$mode" != default ]] && threads=(--test-threads "$mode")
  mode_failed=0
  for ((i = 1; i <= RUNS; i++)); do
    total=$((total + 1))
    if ! out="$(cargo test -q -p "$PACKAGE" --lib "$FILTER" -- ${threads[@]+"${threads[@]}"} 2>&1)"; then
      failed=$((failed + 1))
      mode_failed=$((mode_failed + 1))
      grep -E -- "--- FAILED|^test .* FAILED" <<<"$out" | sed "s/^/  [$mode #$i] /" || true
    fi
  done
  echo "threads=$mode: $((RUNS - mode_failed))/$RUNS runs passed"
done
echo "core-flake-check: $PACKAGE ${FILTER:-(all)} — $failed of $total runs failed"
exit $((failed > 255 ? 255 : failed))
