#!/usr/bin/env bash

# Classify one target/control relay-smoke result. Arguments:
#   target_status control_status target_sent target_received control_sent control_received
#
# A partially working control proves that the shared Sonar/Marmot receive path
# can deliver messages, so a target with zero delivery is a target-relay issue
# even when the control misses a strict threshold. Comparable ambiguous partial
# failures remain inconclusive instead of being asserted as a Sonar regression.
classify_relay_smoke() {
  local target_status="$1" control_status="$2"
  local target_sent="$3" target_received="$4"
  local control_sent="$5" control_received="$6"

  if [[ "$target_status" == "pass" ]]; then
    printf 'pass'
  elif [[ "$control_status" == "skipped" ]]; then
    printf 'target_fail'
  elif [[ "$control_status" == "pass" ]]; then
    printf 'relay_issue'
  elif (( target_received == 0 && control_received > 0 )); then
    printf 'relay_issue'
  elif (( target_sent > 0 && control_sent > 0 && target_received == 0 && control_received == 0 )); then
    printf 'regression'
  else
    printf 'inconclusive'
  fi
}
