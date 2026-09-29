#!/usr/bin/env bash
# Summarize Sonar's on-device logs for one launch or session on a physical
# iPhone: the relay-facing cost of a start (publishes, relay rate limits, ack
# latency), the local-time share fan-out, MDK re-processing, and index health.
#
# This is the before/after instrument for the alpha.15 slow-launch fixes
# (docs/PERFORMANCE.md, "Device log summary"). It reads the app's own log
# files out of the app container — no root, works on a TestFlight build, and
# removes nothing from the device. Every metric is a line the app already
# writes; nothing here changes app behavior.
#
# Usage:
#   scripts/bench/device-log-summary.sh --device <udid> --since <ISO-8601 UTC prefix> [--out <dir>]
#
#   --device   hardware UDID or CoreDevice id (`xcrun devicectl list devices`)
#   --since    only lines at or after this UTC timestamp prefix, e.g.
#              2026-09-29T00:11 (stamp `date -u +%Y-%m-%dT%H:%M:%S` before
#              you launch, and pass that)
#   --out      where to keep the pulled logs (default: a temp dir, printed)
#
# The log files rotate at 2 MB; the summary reads the current file and its
# first rotation, which covers hours on a busy account.
set -uo pipefail

DEVICE=""
SINCE=""
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$DEVICE" && -n "$SINCE" ]] || { echo "usage: $0 --device <udid> --since <ISO-8601 UTC prefix> [--out <dir>]" >&2; exit 2; }
if [[ -z "$OUT" ]]; then
  OUT="$(mktemp -d -t sonar-device-logs)"
fi
mkdir -p "$OUT"

xcrun devicectl device copy from --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier sh.hedwig.sonar \
  --source "Library/Application Support/sonar-marmot/logs" --destination "$OUT" >/dev/null 2>&1 \
  || { echo "log copy failed (device reachable? app installed as a Debug/TestFlight build?)" >&2; exit 1; }

CORE="$OUT/core.log"
IOS="$OUT/ios.log"
cat "$OUT"/core/sonar-core.log.1 "$OUT"/core/sonar-core.log 2>/dev/null | awk -v s="$SINCE" '$0 >= s' > "$CORE"
cat "$OUT"/ios/sonar-ios.log.1 "$OUT"/ios/sonar-ios.log 2>/dev/null | awk -v s="$SINCE" '$0 >= s' > "$IOS"

per_minute() { # $1 = fixed string
  grep -F -- "$1" "$CORE" | cut -c1-16 | uniq -c | awk '{printf "    %s  %s\n", $2, $1}'
}
count() { grep -cF -- "$1" "$CORE" | tr -d ' '; }
quantiles() { # stdin: numbers
  sort -n | awk '{a[NR]=$1} END{ if (NR==0) {print "n=0"; exit} printf "n=%d p50=%s p90=%s max=%s\n", NR, a[int(NR*0.5)+1], a[int(NR*0.9)+1], a[NR]}'
}

echo "window: $SINCE .. $(tail -1 "$CORE" | cut -c1-19)   core lines: $(wc -l < "$CORE" | tr -d ' ')   logs: $OUT"
echo
echo "== connects"
grep -E "conversation index open failed|relays added|relay quorum reached|subscribe_marmot done" "$CORE" | cut -c12-23,28-140 | sed 's/^/    /'
echo "    index open failures: $(count 'conversation index open failed')"
echo
echo "== local-time share"
grep -E "timezone share pass|timezone share trickle|timezone share group cap" "$CORE" | cut -c12-23,28-160 | sed 's/^/    /'
echo
pubs_total=$(count send_publish_start)
pubs_unique=$(grep -F send_publish_start "$CORE" | grep -o 'message_id=[0-9a-f]*' | sort -u | wc -l | tr -d ' ')
echo "== publishes: $pubs_total starts for $pubs_unique unique rows (per minute below)"
per_minute send_publish_start
echo
echo "== relay rate-limit notices: $(count 'rate limited')   subscriptions rejected: $(count 'subscription rejected')"
per_minute "rate limited"
echo
echo "== first relay ack latency (ms): $(grep -o 'rtt_ms=[0-9]*' "$CORE" | cut -d= -f2 | quantiles)"
echo
failed_total=$(count 'preserving rollback retry')
failed_unique=$(grep -F 'preserving rollback retry' "$CORE" | grep -o 'event_id=[0-9a-f]*' | sort -u | wc -l | tr -d ' ')
retired=$(count 'retiring it')
echo "== MDK failed events: $failed_total ($failed_unique unique)   retired after the pass budget: $retired"
per_minute 'preserving rollback retry'
echo
echo "== iOS lifecycle"
grep -E "became-active|entered-background|Suspend close|store closed" "$IOS" | cut -c12-23,40-120 | sed 's/^/    /' | tail -12
echo
echo "summary: publishes=$pubs_total unique=$pubs_unique rate_limited=$(count 'rate limited') acks=$(grep -o 'rtt_ms=[0-9]*' "$CORE" | cut -d= -f2 | quantiles) mdk_failed=$failed_total retired=$retired index_failures=$(count 'conversation index open failed')"
