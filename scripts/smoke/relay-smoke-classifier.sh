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

# Write sender<TAB>receiver<TAB>sent<TAB>received rows using only POSIX awk.
# sent_tsv contains sender, receiver, sequence, timestamp, payload; recv_all_tsv
# contains payload, receive timestamp.
build_pair_delivery_matrix() {
  local sent_tsv="$1" recv_all_tsv="$2" matrix_tsv="$3"
  : > "$matrix_tsv"
  [[ -s "$sent_tsv" ]] || return 0

  awk -F'\t' '
    NR == FNR {
      pair = $1 SUBSEP $2
      sent[pair]++
      payload_pair[$5] = pair
      next
    }
    {
      pair = payload_pair[$1]
      if (pair != "") recv[pair]++
    }
    END {
      for (pair in sent) {
        split(pair, fields, SUBSEP)
        printf "%s\t%s\t%s\t%s\n", fields[1], fields[2], sent[pair], (recv[pair] ? recv[pair] : 0)
      }
    }
  ' "$sent_tsv" "$recv_all_tsv" > "$matrix_tsv"
}

pair_delivery_json() {
  local matrix_tsv="$1"
  awk -F'\t' 'BEGIN { printf "[" }
    { printf "%s{\"sender\":%s,\"receiver\":%s,\"sent\":%s,\"received\":%s}", (NR > 1 ? "," : ""), $1, $2, $3, $4 }
    END { print "]" }
  ' "$matrix_tsv"
}
