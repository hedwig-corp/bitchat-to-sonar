#!/usr/bin/env bash
# scripts/smoke/relay-smoke.sh
#
# Daily Sonar/Marmot relay smoke test (brainstorm "Approach A").
#
# Provisions a seeded set of ephemeral identities, exchanges encrypted Sonar/Marmot
# DMs over a TARGET relay (default: wss://nostr.relay.hedwig.sh) AND a CONTROL relay
# set (default: the Sonar bootstrap relays), measures delivery/loss/latency/errors
# for each, and classifies the outcome:
#
#   - relay_issue   target fails, control passes  -> problem is the TARGET relay
#   - regression    target fails, control fails   -> Sonar/Marmot regression
#   - target_fail   target fails, control skipped -> cannot classify further
#   - pass          target passes                 -> healthy
#
# A failure optionally:
#   - DMs a report to a Sonar npub (needs SONAR_SMOKE_REPORTER_NSEC)
#   - opens a GitHub issue (needs GITHUB_TOKEN / gh auth + OPEN_ISSUES=1)
#
# The receiver must be subscribed before the sender fires (NIP-17 gift-wrap events
# are delivered live); the harness starts each receiver's listener, then sends.
#
# Written for bash 3.2 (macOS default) as well as bash 4+: no associative arrays.
#
# Usage:
#   scripts/smoke/relay-smoke.sh                     # full run, defaults
#   SEED=42 scripts/smoke/relay-smoke.sh             # reproducible topology
#   SKIP_REPORT=1 scripts/smoke/relay-smoke.sh       # no DM (local testing)
#   SKIP_CONTROL=1 scripts/smoke/relay-smoke.sh      # target relay only
#   RELAY_SMOKE_DEBUG=1 ...                          # keep work dir, dump raw recv
#   IDENTITIES=3 MESSAGES_PER_PAIR=1 scripts/smoke/relay-smoke.sh
#
# Requires the sonar-cli binary. Set SONAR_CLI to an absolute path to override
# auto-detection. See docs/RELAY-SMOKE.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$ROOT/scripts/smoke"

# ---- config precedence: env > config file > built-in default ----
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/relay-smoke.config.json}"
cfg() { [[ -f "$CONFIG_FILE" ]] && jq -r "$1 // empty" "$CONFIG_FILE" 2>/dev/null || true; }

TARGET_RELAY="${TARGET_RELAY:-$(cfg '.target_relay')}"
TARGET_RELAY="${TARGET_RELAY:-wss://nostr.relay.hedwig.sh}"

CTRL_DEFAULT="wss://relay.damus.io wss://nos.lol wss://relay.primal.net"
CONTROL_RELAYS="${CONTROL_RELAYS:-$(cfg '.control_relays // [] | join(" ")')}"
CONTROL_RELAYS="${CONTROL_RELAYS:-$CTRL_DEFAULT}"
SKIP_CONTROL="${SKIP_CONTROL:-$(cfg '.skip_control // 0')}"

IDENTITIES="${IDENTITIES:-$(cfg '.identities')}"
IDENTITIES="${IDENTITIES:-5}"
FANOUT="${FANOUT:-$(cfg '.fanout')}"
FANOUT="${FANOUT:-2}"
MESSAGES_PER_PAIR="${MESSAGES_PER_PAIR:-$(cfg '.messages_per_pair')}"
MESSAGES_PER_PAIR="${MESSAGES_PER_PAIR:-2}"
CONNECT_DELAY_SECS="${CONNECT_DELAY_SECS:-3}"
RECEIVE_TIMEOUT_SECS="${RECEIVE_TIMEOUT_SECS:-$(cfg '.receive_timeout_secs')}"
RECEIVE_TIMEOUT_SECS="${RECEIVE_TIMEOUT_SECS:-20}"
RECEIVE_POLL_SECS="${RECEIVE_POLL_SECS:-2}"
SEND_GAP_SECS="${SEND_GAP_SECS:-1}"
MAX_RETRIES="${MAX_RETRIES:-2}"
SEED="${SEED:-}"

# thresholds (env > config)
MAX_LOSS_PCT="${MAX_LOSS_PCT:-$(cfg '.thresholds.max_loss_pct')}"
MAX_LOSS_PCT="${MAX_LOSS_PCT:-0}"
MAX_P95_LATENCY_MS="${MAX_P95_LATENCY_MS:-$(cfg '.thresholds.max_p95_latency_ms')}"
MAX_P95_LATENCY_MS="${MAX_P95_LATENCY_MS:-5000}"
MAX_ERRORS="${MAX_ERRORS:-$(cfg '.thresholds.max_errors')}"
MAX_ERRORS="${MAX_ERRORS:-0}"
# tolerate a single transient drop so a one-off blip does not flip the run to fail
MAX_LOST="${MAX_LOST:-$(cfg '.thresholds.max_lost')}"
MAX_LOST="${MAX_LOST:-1}"

# reporting
REPORT_NPUB="${REPORT_NPUB:-$(cfg '.report.npub')}"
REPORT_NPUB="${REPORT_NPUB:-npub10srglj0rdsmtehwlflxptwz74c955c2y7jrhdmjm5gr6gycpsp5sg3fm3c}"
SKIP_REPORT="${SKIP_REPORT:-0}"
REPORTER_NSEC="${SONAR_SMOKE_REPORTER_NSEC:-}"
REPORTER_NSEC_FILE="${SONAR_SMOKE_REPORTER_NSEC_FILE:-}"
OPEN_ISSUES="${OPEN_ISSUES:-0}"
GITHUB_REPO="${GITHUB_REPO:-}"

# misc
SONAR_CLI="${SONAR_CLI:-$ROOT/core/target/release/sonar-cli}"
DEBUG="${RELAY_SMOKE_DEBUG:-0}"

if [[ ! -x "$SONAR_CLI" ]]; then
  echo "sonar-cli not found at $SONAR_CLI." >&2
  echo "Build it:  cargo build -p sonar-cli --release  (from $ROOT/core)" >&2
  echo "Or set:    SONAR_CLI=/path/to/sonar-cli" >&2
  exit 2
fi

# ---- portable wall-clock millis ----
if [[ "$(date +%s%N 2>/dev/null)" =~ ^[0-9]{13,}$ ]]; then
  now_ms() { local t; t=$(date +%s%N); echo "${t:0:13}"; }
else
  now_ms() { python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null \
              || awk 'BEGIN{srand();print srand()*1000}'; }
fi

# ---- run state ----
RUN_TAG="smoke:$(date +%Y%m%d%H%M%S):${SEED:-rnd}"
RUN_ID="$(printf '%s' "$RUN_TAG" | tr -dc 'A-Za-z0-9:' | tr -d '\n')"
SEED_NUM="${SEED:-$(date +%s)}"
WORK="$(mktemp -d /tmp/relay-smoke.XXXXXX)"
METRICS_JSON="${METRICS_JSON:-$WORK/metrics.json}"
[[ "$DEBUG" == "1" ]] && trap 'echo "[relay-smoke] DEBUG work dir kept: $WORK" >&2' EXIT \
                    || trap 'rm -rf "$WORK"' EXIT

log() { printf '[relay-smoke] %s\n' "$*" >&2; }

# Build --relay args for a space-separated relay string into the global RELAY_ARGS.
set_relay_args() {
  RELAY_ARGS=()
  local r
  for r in $1; do RELAY_ARGS+=(--relay "$r"); done
}

# Run a sonar-cli command with bounded retries. Echoes stdout on success.
# On final failure, returns non-zero and leaves the last stderr in $WORK/.clierr.
cli() {
  local attempt=0 out rc
  while :; do
    attempt=$((attempt + 1))
    if out=$("$@" 2>"$WORK/.clierr"); then echo "$out"; return 0; fi
    rc=$?
    if (( attempt >= MAX_RETRIES )); then return "$rc"; fi
    sleep 1
  done
}

# ---- enhanced diagnostics helpers ----

# topology: list of directed edges (sender_idx, receiver_idx, sender_npub, receiver_npub)
topology_tsv() {
  local label="$1"
  local graph="$WORK/graph.tsv"
  local out="$WORK/topology-$label.tsv"
  : > "$out"
  [[ -f "$graph" ]] || return 0
  while IFS=$'\t' read -r a b; do
    printf '%s\t%s\t%s\t%s\n' "$a" "$b" "${NPUBS[$a]:-unknown}" "${NPUBS[$b]:-unknown}" >> "$out"
  done < "$graph"
  printf '%s' "$out"
}

# per-pair delivery matrix: sender_idx receiver_idx sent received
pair_delivery_matrix() {
  local label="$1"
  local sent_tsv="$WORK/sent-$label.tsv"
  local recv_all="$WORK/recv-all-$label.tsv"
  local matrix="$WORK/matrix-$label.tsv"
  : > "$matrix"
  [[ -f "$sent_tsv" ]] || { printf '%s' "$matrix"; return 0; }
  awk -F'\t' '
  NR==FNR { sent[$1"\t"$2]++; next }
  {
    payload=$1
    # payload format: RUN_ID:b<receiver>:a<sender>:s<seq>
    if (match(payload, ":b([0-9]+):a([0-9]+):s", m)) {
      recv[m[2]"\t"m[1]]++
    }
  }
  END {
    for (pair in sent) {
      printf "%s\t%s\n", pair, (recv[pair] ? recv[pair] : 0)
    }
  }
  ' "$sent_tsv" "$recv_all" 2>/dev/null >> "$matrix" || true
  printf '%s' "$matrix"
}

# infer a root cause from send/listener/recv artifacts
infer_root_cause() {
  local label="$1"
  local sent_tsv="$WORK/sent-$label.tsv"
  local recv_all="$WORK/recv-all-$label.tsv"
  local errlog="$WORK/errors-$label.txt"
  local send_err="$WORK/send-$label.err"
  local raw_count=0 sent_count=0 recv_count=0 err_count=0 send_err_lines=0
  raw_count=$(find "$WORK" -maxdepth 1 -name "raw-$label-b*.jsonl" -print0 2>/dev/null | xargs -0 -r wc -l | awk '{s+=$1} END {print s+0}')
  sent_count=$(wc -l < "$sent_tsv" 2>/dev/null | tr -d ' ' || echo 0)
  recv_count=$(wc -l < "$recv_all" 2>/dev/null | tr -d ' ' || echo 0)
  err_count=$(wc -l < "$errlog" 2>/dev/null | tr -d ' ' || echo 0)
  send_err_lines=$(wc -l < "$send_err" 2>/dev/null | tr -d ' ' || echo 0)

  if (( err_count > 0 || send_err_lines > 0 )) && (( sent_count == 0 )); then
    printf 'send_failed: sonar-cli send or provision failed before any message was accepted'
    return 0
  fi
  if (( sent_count == 0 )); then
    printf 'no_send_attempts: graph produced zero send attempts (check identities/fanout)'
    return 0
  fi
  if (( raw_count == 0 )); then
    printf 'listener_zero_events: send succeeded (%d messages) but listeners received zero raw events; likely relay did not store/propagate NIP-17 gift-wraps' "$sent_count"
    return 0
  fi
  if (( recv_count == 0 )); then
    printf 'decrypt_failure: listeners saw %d raw events but none decrypted to expected payload; KeyPackage may be missing or MLS group setup failed' "$raw_count"
    return 0
  fi
  if (( recv_count < sent_count )); then
    printf 'partial_delivery: listeners decrypted %d/%d messages; relay dropped some events or listener timing missed them' "$recv_count" "$sent_count"
    return 0
  fi
  printf 'healthy'
}

# collect listener stderr snippets (last N non-empty lines) per receiver
listener_error_digest() {
  local label="$1" limit="${2:-20}"
  local combined=""
  local f
  for f in "$WORK"/recv-$label-b*.err; do
    [[ -f "$f" && -s "$f" ]] || continue
    local b
    b=$(basename "$f" | sed -E "s/recv-$label-b([0-9]+)\.err/\1/")
    local lines
    lines=$(grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -n "$limit" | sed 's/$/\n/' | tr '\n' ';' | sed 's/;$/\n/')
    [[ -n "$lines" ]] && combined="${combined}receiver_$b: $lines; "
  done
  printf '%s' "$combined" | sed 's/; $//'
}

# collect send stderr digest (first N lines)
send_error_digest() {
  local label="$1" limit="${2:-20}"
  local f="$WORK/send-$label.err"
  [[ -f "$f" && -s "$f" ]] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | head -n "$limit" | tr '\n' ';' | sed 's/;$/\n/'
}

# latency stats: read ms-per-line on stdin, print "min median p95 max" (ms)
latency_stats() {
  awk '{ a[NR]=$1 }
  END {
    if (NR == 0) { print "0 0 0 0"; exit }
    for (i = 1; i <= NR; i++) v[i] = a[i]
    n = NR
    for (i = 1; i < n; i++) for (j = i + 1; j <= n; j++) if (v[j] < v[i]) { t = v[i]; v[i] = v[j]; v[j] = t }
    min = v[1]; max = v[n]
    med = (n % 2) ? v[int(n / 2) + 1] : int((v[n / 2] + v[n / 2 + 1]) / 2)
    pi = int(0.95 * n); if (pi < 1) pi = 1; if (pi > n) pi = n
    printf "%d %d %d %d\n", min, med, v[pi], max
  }
}

# Provision N ephemeral identities on the current RELAY_ARGS.
# Fills global indexed arrays HOMES[] and NPUBS[] (indexed 0..N-1).
provision() {
  local plabel="${1:-run}"
  HOMES=(); NPUBS=()
  local i home npub out
  for ((i = 0; i < IDENTITIES; i++)); do
    home="$WORK/agent-$plabel-$i"; mkdir -p "$home"
    if ! cli "$SONAR_CLI" --home "$home" "${RELAY_ARGS[@]}" init >/dev/null; then
      log "init failed for $plabel agent-$i: $(cat "$WORK/.clierr")"; return 1
    fi
    if ! cli "$SONAR_CLI" --home "$home" "${RELAY_ARGS[@]}" publish >/dev/null; then
      log "publish failed for $plabel agent-$i: $(cat "$WORK/.clierr")"; return 1
    fi
    if ! out=$(cli "$SONAR_CLI" --home "$home" "${RELAY_ARGS[@]}" identity); then
      log "identity failed for $plabel agent-$i: $(cat "$WORK/.clierr")"; return 1
    fi
    npub=$(printf '%s' "$out" | jq -r '.npub // empty')
    if [[ -z "$npub" ]]; then log "empty npub for $plabel agent-$i"; return 1; fi
    HOMES[i]="$home"; NPUBS[i]="$npub"
  done
  log "provisioned $IDENTITIES identities ($plabel)"
}

# Build the seeded directed graph (each identity sends to up to FANOUT others).
build_graph() {
  GRAPH_FILE="$WORK/graph.tsv"
  awk -v n="$IDENTITIES" -v fanout="$FANOUT" -v seed="$SEED_NUM" '
  BEGIN {
    srand(seed)
    for (a = 0; a < n; a++) {
      cnt = 0; seen = ""
      while (cnt < fanout && cnt < n - 1) {
        b = int(rand() * n)
        if (b == a) continue
        if (index(seen, ":" b ":") > 0) continue
        seen = seen ":" b ":"
        print a "\t" b
        cnt++
      }
    }
  }' > "$GRAPH_FILE"
}

# Run the seeded exchange against the current RELAY_ARGS. Emits a metrics JSON
# object for `label` on stdout. Uses indexed arrays only (bash 3.2 safe).
run_exchange() {
  LABEL="$1"
  local sent_tsv="$WORK/sent-$LABEL.tsv"
  local errors=0
  local errlog="$WORK/errors-$LABEL.txt"; : > "$errlog"

  local b sender seq payload t0 out home_b recvf rawf liserr lis_pid
  for ((b = 0; b < IDENTITIES; b++)); do
    # senders targeting b (from the seeded graph) -> space-separated indices
    local senders
    senders=$(awk -F'\t' -v b="$b" '$2 == b {printf "%s ", $1}' "$GRAPH_FILE")
    [[ -z "$senders" || "$senders" == " " ]] && continue
    home_b="${HOMES[$b]}"
    recvf="$WORK/recv-$LABEL-b$b.tsv"; rawf="$WORK/raw-$LABEL-b$b.jsonl"
    liserr="$WORK/recv-$LABEL-b$b.err"; : > "$recvf"; : > "$rawf"
    # receiver listener FIRST (gift-wrap events arrive live)
    (
      "$SONAR_CLI" --home "$home_b" "${RELAY_ARGS[@]}" \
        listen --timeout-secs "$RECEIVE_TIMEOUT_SECS" --poll-secs "$RECEIVE_POLL_SECS" --no-publish 2>>"$liserr" \
        | tee "$rawf" \
        | while IFS= read -r line; do [[ -n "$line" ]] && printf '%s\t%s\n' "$(now_ms)" "$line"; done > "$recvf"
    ) &
    lis_pid=$!
    sleep "$CONNECT_DELAY_SECS"

    for sender in $senders; do
      for ((seq = 1; seq <= MESSAGES_PER_PAIR; seq++)); do
        payload="$RUN_ID:b$b:a$sender:s$seq"
        t0=$(now_ms)
        if out=$(cli "$SONAR_CLI" --home "${HOMES[$sender]}" "${RELAY_ARGS[@]}" \
                   send --to "${NPUBS[$b]}" --text "$payload" 2>>"$WORK/send-$LABEL.err"); then
          printf '%s\t%s\t%s\t%s\t%s\n' "$sender" "$b" "$seq" "$t0" "$payload" >> "$sent_tsv"
        else
          errors=$((errors + 1))
          printf '[send-fail] a%s->b%s s%s: %s\n' "$sender" "$b" "$seq" "$(cat "$WORK/.clierr")" >> "$errlog"
        fi
        sleep "$SEND_GAP_SECS"
      done
    done
    wait "$lis_pid" 2>/dev/null || true
  done

  if [[ "$DEBUG" == "1" ]]; then
    log "DEBUG raw recv ($LABEL):" >&2
    for rf in "$WORK"/raw-$LABEL-b*.jsonl; do [[ -f "$rf" ]] && { echo "--- $rf ($(wc -l < "$rf" | tr -d ' ') lines) ---"; cat "$rf"; } >&2; done
    log "DEBUG sent_tsv ($LABEL):" >&2; cat "$sent_tsv" >&2 2>/dev/null || true
    log "DEBUG listen errs ($LABEL):" >&2; cat "$WORK"/recv-$LABEL-b*.err 2>/dev/null >&2 || true
  fi

  # combined received: payload<TAB>emit_ms across all receivers for this label
  local recv_all="$WORK/recv-all-$LABEL.tsv"; : > "$recv_all"
  local rf rline rem rcontent
  for rf in "$WORK"/recv-$LABEL-b*.tsv; do
    [[ -f "$rf" ]] || continue
    while IFS=$'\t' read -r rem rline; do
      [[ -z "$rline" ]] && continue
      rcontent=$(printf '%s' "$rline" | jq -r '.content // empty' 2>/dev/null)
      [[ -n "$rcontent" ]] && printf '%s\t%s\n' "$rcontent" "$rem" >> "$recv_all"
    done < "$rf"
  done

  local sent received=0 lost latfile emit
  sent=$(wc -l < "$sent_tsv" 2>/dev/null | tr -d ' ' || echo 0)
  [[ -z "$sent" ]] && sent=0
  latfile="$WORK/latency-$LABEL.txt"; : > "$latfile"
  if (( sent > 0 )); then
    while IFS=$'\t' read -r sa sb ssq st0 spayload; do
      emit=$(awk -F'\t' -v p="$spayload" '$1 == p {print $2}' "$recv_all" | sort -n | head -1)
      if [[ -n "$emit" ]]; then
        received=$((received + 1))
        awk -v e="$emit" -v t="$st0" 'BEGIN{ d=e-t; if(d<0)d=0; print d }' >> "$latfile"
      fi
    done < "$sent_tsv"
  fi

  lost=$((sent - received))
  local loss_pct=0
  (( sent > 0 )) && loss_pct=$(awk -v r="$received" -v s="$sent" 'BEGIN{ printf "%.1f", (s-r)*100.0/s }')

  local lat_min lat_med lat_p95 lat_max
  read -r lat_min lat_med lat_p95 lat_max <<< "$(latency_stats < "$latfile")"

  local topology_tsv_file matrix_tsv_file root_cause send_err listener_err
  topology_tsv_file="$(topology_tsv "$LABEL")"
  matrix_tsv_file="$(pair_delivery_matrix "$LABEL")"
  root_cause="$(infer_root_cause "$LABEL")"
  send_err="$(send_error_digest "$LABEL")"
  listener_err="$(listener_error_digest "$LABEL")"

  # pair delivery matrix as JSON array of {sender,receiver,sent,received}
  local pair_json
  pair_json=$(awk -F'\t' '
    { printf "%s{\"sender\":%s,\"receiver\":%s,\"sent\":%s,\"received\":%s}", (NR>1?",":""), $1, $2, $3, $4 }
    END { if (NR==0) print ""; else print "" }
  ' "$matrix_tsv_file")

  # topology as JSON array of {sender,receiver,sender_npub,receiver_npub}
  local topo_json
  topo_json=$(awk -F'\t' '
    { printf "%s{\"sender\":%s,\"receiver\":%s,\"sender_npub\":\"%s\",\"receiver_npub\":\"%s\"}", (NR>1?",":""), $1, $2, $3, $4 }
    END { if (NR==0) print ""; else print "" }
  ' "$topology_tsv_file")

  local _filter
  _filter='{"name":$name,"sent":$sent,"received":$received,"lost":$lost,"loss_pct":$loss_pct,"latency_ms":{"min":$lat_min,"median":$lat_med,"p95":$lat_p95,"max":$lat_max},"errors":$errors,"root_cause":$root_cause,"diagnostics":{"send_errors":$send_err,"listener_errors":$listener_err},"topology":[$topo_json],"pair_delivery":[$pair_json]}'
  jq -n \
    --arg name "$LABEL" \
    --argjson sent "$sent" --argjson received "$received" --argjson lost "$lost" \
    --argjson loss_pct "$loss_pct" \
    --argjson lat_min "$lat_min" --argjson lat_med "$lat_med" \
    --argjson lat_p95 "$lat_p95" --argjson lat_max "$lat_max" \
    --argjson errors "$errors" \
    --arg root_cause "$root_cause" \
    --arg send_err "$send_err" \
    --arg listener_err "$listener_err" \
    --arg topo_json "$topo_json" \
    --arg pair_json "$pair_json" \
    "$_filter"
}

# pass/fail for a single relay-set given thresholds. Gates on absolute lost-message
# count (MAX_LOST) so a single transient drop does not flip a healthy relay-set to
# fail; p95 latency and CLI errors still gate directly.
set_status() {
  local loss_pct="$1" p95="$2" errors="$3" lost="${4:-0}"
  awk -v p="$p95" -v e="$errors" -v lo="$lost" \
      -v mp="$MAX_P95_LATENCY_MS" -v me="$MAX_ERRORS" -v mlo="$MAX_LOST" \
  'BEGIN{ if(lo+0>mlo+0 || p+0>mp+0 || e+0>me+0) print "fail"; else print "pass" }'
}

# ---- main ----
main() {
  local started_at ended_at
  started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  log "run=$RUN_ID seed=$SEED_NUM identities=$IDENTITIES fanout=$FANOUT msgs=$MESSAGES_PER_PAIR"

  local target_metrics control_metrics='null'
  local target_status control_status="skipped"

  # target relay
  set_relay_args "$TARGET_RELAY"
  log "TARGET relay: $TARGET_RELAY"
  provision "target"
  build_graph
  target_metrics=$(run_exchange "target")
  local t_loss t_p95 t_err t_lost
  t_loss=$(printf '%s' "$target_metrics" | jq -r '.loss_pct')
  t_lost=$(printf '%s' "$target_metrics" | jq -r '.lost')
  t_p95=$(printf '%s' "$target_metrics" | jq -r '.latency_ms.p95')
  t_err=$(printf '%s' "$target_metrics" | jq -r '.errors')
  target_status=$(set_status "$t_loss" "$t_p95" "$t_err" "$t_lost")
  log "target: $target_status (loss=${t_loss}% lost=${t_lost} p95=${t_p95}ms errors=${t_err})"

  # control relay set (unless skipped)
  if [[ "$SKIP_CONTROL" != "1" ]]; then
    set_relay_args "$CONTROL_RELAYS"
    log "CONTROL relays: $CONTROL_RELAYS"
    provision "control"
    build_graph   # same seed -> same topology
    control_metrics=$(run_exchange "control")
    local c_loss c_p95 c_err c_lost
    c_loss=$(printf '%s' "$control_metrics" | jq -r '.loss_pct')
    c_lost=$(printf '%s' "$control_metrics" | jq -r '.lost')
    c_p95=$(printf '%s' "$control_metrics" | jq -r '.latency_ms.p95')
    c_err=$(printf '%s' "$control_metrics" | jq -r '.errors')
    control_status=$(set_status "$c_loss" "$c_p95" "$c_err" "$c_lost")
    log "control: $control_status (loss=${c_loss}% lost=${c_lost} p95=${c_p95}ms errors=${c_err})"
  fi

  # classify
  local overall root_cause_target root_cause_control
  root_cause_target=$(printf '%s' "$target_metrics" | jq -r '.root_cause // "unknown"')
  root_cause_control=$(printf '%s' "$control_metrics" | jq -r '.root_cause // "unknown"')
  if [[ "$target_status" == "pass" ]]; then
    overall="pass"
  elif [[ "$control_status" == "pass" ]]; then
    overall="relay_issue"        # target fails, control healthy -> the relay
  elif [[ "$control_status" == "skipped" ]]; then
    overall="target_fail"        # no control run -> cannot classify further
  else
    overall="regression"         # target and control both fail -> Sonar-side
  fi
  log "overall: $overall"

  ended_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n \
    --arg run_id "$RUN_ID" --argjson seed "$SEED_NUM" \
    --arg started_at "$started_at" --arg ended_at "$ended_at" \
    --arg target_relay "$TARGET_RELAY" --arg control_relays "$CONTROL_RELAYS" \
    --argjson identities "$IDENTITIES" --argjson fanout "$FANOUT" \
    --argjson messages_per_pair "$MESSAGES_PER_PAIR" \
    --argjson receive_timeout_secs "$RECEIVE_TIMEOUT_SECS" \
    --arg max_loss_pct "$MAX_LOSS_PCT" --arg max_p95_latency_ms "$MAX_P95_LATENCY_MS" \
    --argjson max_errors "$MAX_ERRORS" --argjson max_lost "$MAX_LOST" \
    --arg target_status "$target_status" --arg control_status "$control_status" \
    --arg overall "$overall" --arg report_npub "$REPORT_NPUB" \
    --arg root_cause_target "$root_cause_target" \
    --arg root_cause_control "$root_cause_control" \
    --argjson target "$target_metrics" --argjson control "$control_metrics" \
    '{run_id:$run_id, seed:$seed, started_at:$started_at, ended_at:$ended_at,
      config:{target_relay:$target_relay, control_relays:($control_relays|split(" ")),
              identities:$identities, fanout:$fanout, messages_per_pair:$messages_per_pair,
              receive_timeout_secs:$receive_timeout_secs},
      thresholds:{max_loss_pct:($max_loss_pct|tonumber), max_p95_latency_ms:($max_p95_latency_ms|tonumber), max_errors:$max_errors, max_lost:$max_lost},
      target_status:$target_status, control_status:$control_status, overall:$overall,
      root_causes:{target:$root_cause_target, control:$root_cause_control},
      target:$target, control:$control, report_npub:$report_npub}' \
    > "$METRICS_JSON"

  cat "$METRICS_JSON"

  report_if_needed "$overall"
  issue_if_needed "$overall"

  [[ "$overall" == "pass" ]]
}

# DM a one-line report to REPORT_NPUB using the reporter identity (if provisioned).
report_if_needed() {
  local overall="$1"
  if [[ "$SKIP_REPORT" == "1" ]]; then log "SKIP_REPORT=1 -> no DM"; return 0; fi
  if [[ -z "$REPORTER_NSEC" && -z "$REPORTER_NSEC_FILE" ]]; then
    log "no reporter nsec -> skipping DM report (set SONAR_SMOKE_REPORTER_NSEC)"; return 0
  fi
  local rhome="$WORK/reporter"; mkdir -p "$rhome"
  set_relay_args "$TARGET_RELAY $CONTROL_RELAYS"
  if [[ -n "$REPORTER_NSEC_FILE" ]]; then
    cli "$SONAR_CLI" --home "$rhome" "${RELAY_ARGS[@]}" init --nsec-file "$REPORTER_NSEC_FILE" >/dev/null \
      || { log "reporter init failed: $(cat "$WORK/.clierr")"; return 0; }
  else
    cli "$SONAR_CLI" --home "$rhome" "${RELAY_ARGS[@]}" init --nsec-env SONAR_SMOKE_REPORTER_NSEC >/dev/null \
      || { log "reporter init failed: $(cat "$WORK/.clierr")"; return 0; }
  fi
  cli "$SONAR_CLI" --home "$rhome" "${RELAY_ARGS[@]}" publish >/dev/null || true
  local summary
  summary=$(printf '%s' "$METRICS_JSON" | jq -r '
    "[relay-smoke] " + .overall +
    " | target " + .target.name + " " + .target_status +
    " loss=" + (.target.loss_pct|tostring) + "%" +
    " (" + (.target.lost|tostring) + "/" + (.target.sent|tostring) + ")" +
    " p95=" + (.target.latency_ms.p95|tostring) + "ms errors=" + (.target.errors|tostring) +
    " cause=" + (.root_causes.target // "unknown") +
    " | control " + .control_status +
    " loss=" + (.control.loss_pct|tostring) + "%" +
    " cause=" + (.root_causes.control // "unknown") +
    " | seed=" + (.seed|tostring) +
    " | topology=" + (.config.identities|tostring) + "x" + (.config.fanout|tostring) + "x" + (.config.messages_per_pair|tostring)'
    "$METRICS_JSON")
  if cli "$SONAR_CLI" --home "$rhome" "${RELAY_ARGS[@]}" send --to "$REPORT_NPUB" --text "$summary" >/dev/null; then
    log "report DM sent to $REPORT_NPUB"
  else
    log "report DM failed: $(cat "$WORK/.clierr") (recipient KeyPackage may be missing on the relay)"
  fi
}

# Open a GitHub issue on failure (relay_issue / regression / target_fail).
issue_if_needed() {
  local overall="$1"
  [[ "$OPEN_ISSUES" == "1" ]] || { log "OPEN_ISSUES!=1 -> no issue"; return 0; }
  [[ "$overall" == "pass" ]] && { log "pass -> no issue"; return 0; }
  command -v gh >/dev/null 2>&1 || { log "gh not found -> cannot open issue"; return 0; }

  local kind="$overall"
  # stable title (no date) so repeated failures dedupe onto ONE open issue per kind
  local title="[relay-smoke] $kind on $TARGET_RELAY"
  local body
  body=$(jq -r --arg relay "$TARGET_RELAY" --arg ctrl "$CONTROL_RELAYS" --arg ts "$(date -u +'%F %H:%M UTC')" '
    "**Update " + $ts + "**.\n\n" +
    "Daily relay smoke test classified this run as **" + .overall + "**.\n\n" +
    "**Target relay** `" + $relay + "` — status: " + .target_status + "\n" +
    "- loss: " + (.target.loss_pct|tostring) + "% (lost " + (.target.lost|tostring) + "/" + (.target.sent|tostring) + ")\n" +
    "- latency p95: " + (.target.latency_ms.p95|tostring) + "ms\n" +
    "- CLI errors: " + (.target.errors|tostring) + "\n" +
    "- root cause: " + (.root_causes.target // "unknown") + "\n" +
    "- send stderr: `" + ((.target.diagnostics.send_errors // "none")|tostring) + "`\n" +
    "- listener stderr: `" + ((.target.diagnostics.listener_errors // "none")|tostring) + "`\n\n" +
    "**Control relay set** `" + $ctrl + "` — status: " + .control_status + "\n" +
    "- loss: " + (.control.loss_pct|tostring) + "% (lost " + (.control.lost|tostring) + "/" + (.control.sent|tostring) + ")\n" +
    "- latency p95: " + (.control.latency_ms.p95|tostring) + "ms\n" +
    "- root cause: " + (.root_causes.control // "unknown") + "\n\n" +
    "**Topology**\n" +
    "- identities: " + (.config.identities|tostring) + ", fanout: " + (.config.fanout|tostring) + ", messages per pair: " + (.config.messages_per_pair|tostring) + "\n" +
    "- expected edges: identities × fanout × messages = " + ((.config.identities * .config.fanout * .config.messages_per_pair)|tostring) + "\n" +
    "- receive timeout: " + (.config.receive_timeout_secs|tostring) + "s\n\n" +
    "**Classification**\n" +
    "- `relay_issue` = target fails, control passes (problem is the target relay)\n" +
    "- `regression` = target and control both fail (Sonar/Marmot regression)\n" +
    "- `target_fail` = target fails, control was skipped\n\n" +
    "**Reproduce locally**\n" +
    "```\nSEED=" + (.seed|tostring) + " SKIP_REPORT=1 RELAY_SMOKE_DEBUG=1 scripts/smoke/relay-smoke.sh\n```\n\n" +
    "Full metrics JSON:\n```json\n" + (.|tostring) + "\n```"' "$METRICS_JSON")

  local repo_args=()
  [[ -n "$GITHUB_REPO" ]] && repo_args=(--repo "$GITHUB_REPO")
  # dedupe: comment on an existing OPEN issue with this title instead of opening a
  # new one each run; only create on the first failure of a streak
  local existing
  existing=$(gh issue list "${repo_args[@]}" --state open --search "$title in:title" --limit 1 \
              --json number --jq '.[0].number // empty' 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    if gh issue comment "$existing" "${repo_args[@]}" --body "$body" \
         >/tmp/relay-smoke-issue.txt 2>/tmp/relay-smoke-issue.err; then
      log "commented on existing issue #$existing: $(cat /tmp/relay-smoke-issue.txt)"
    else
      log "gh issue comment failed: $(cat /tmp/relay-smoke-issue.err)"
    fi
    return 0
  fi
  # first failure of the streak: create (labels may not exist yet; fall back to without)
  if gh issue create "${repo_args[@]}" --title "$title" --body "$body" \
       --label "smoke,relay,$kind" >/tmp/relay-smoke-issue.txt 2>/tmp/relay-smoke-issue.err; then
    log "issue opened: $(cat /tmp/relay-smoke-issue.txt)"
  elif gh issue create "${repo_args[@]}" --title "$title" --body "$body" \
       >/tmp/relay-smoke-issue.txt 2>/tmp/relay-smoke-issue.err; then
    log "issue opened (no labels): $(cat /tmp/relay-smoke-issue.txt)"
  else
    log "gh issue create failed: $(cat /tmp/relay-smoke-issue.err)"
  fi
}

main "$@"
