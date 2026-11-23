#!/usr/bin/env bash
# _bench-sim.sh — print the UDID of this worktree's DEDICATED bench simulator,
# "Sonar Bench <worktree name>", creating and booting it if needed.
#
#   UDID="$(scripts/bench/_bench-sim.sh)"
#
# The bench scripts use it when no --device is given. They used to fall back
# to "a booted simulator", and provision-and-bench.sh uninstalls Sonar and
# clears its App Group container on that device. Other agents on the same Mac
# share CoreSimulator, so that default could wipe another session's app under
# test. One simulator per worktree keeps two benchmarks (or a benchmark and a
# QA pass, which uses "Sonar QA <worktree name>") off each other's devices.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAME="${SONAR_BENCH_SIM_NAME:-Sonar Bench $(basename "$ROOT")}"

UDID="$(xcrun simctl list devices available | sed -nE "s/^[[:space:]]+$NAME \(([0-9A-F-]+)\).*/\1/p" | head -1)"
if [[ -z "$UDID" ]]; then
  read -r TYPE RUNTIME < <("$ROOT/scripts/qa/ios-sim-type.sh")
  echo ">> creating bench simulator '$NAME' ($TYPE, $RUNTIME)" >&2
  UDID="$(xcrun simctl create "$NAME" "$TYPE" "$RUNTIME")"
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null
echo "$UDID"
