#!/usr/bin/env bash
# stall-gate.sh — fail a QA run on main-thread stalls or a starved sync queue,
# read from the app's own diagnostics log (sonar-ios.log).
#
#   scripts/qa/stall-gate.sh <sonar-ios.log> [--since <ISO-8601 UTC>]
#                            [--max-stall-ms 250] [--max-section-ms 250]
#                            [--max-wait-ms 2000]
#                            [--min-gap-recoveries N] [--max-gap-ms 15000]
#
# What it reads:
#   main thread stalled ms=N sections=[...]           SNMainThreadStallProbe
#   main-thread section slow name=X ms=N               SNMainThreadStallProbe.measure
#   marmot workQueue op=X waited_ms=N ran_ms=M         MarmotService.run (>1 s)
#   foreground refresh: gap recovery finished at N ms  refreshAfterForeground
# The first two ship since 1.15.3; the last two come with R-056 (#657), so a
# build without them fails --min-gap-recoveries rather than passing blind.
#
# Fails (exit 1) when any probe stall reaches --max-stall-ms, when any one
# instrumented main-thread section runs --max-section-ms or longer (250 ms is
# the hang threshold Xcode Organizer uses), when any work-queue op waited
# longer than --max-wait-ms, when fewer than --min-gap-recoveries foreground
# gap recoveries finished, or when one took longer than --max-gap-ms.
#
# Both main-thread checks are needed. The probe pings every 500 ms and only
# notices a ping still pending at the next tick, so it reports stalls of
# about 500 ms and up wherever they happen; a 360 ms block it never sees.
# The section lines time the instrumented sites exactly at any length.
#
# Prints a summary either way: the worst stalls with the sections they named,
# the slowest sections, the worst waits per op, and every gap-recovery time.
# R-054 / R-055 / R-056 were all visible in exactly these lines on a
# 400-group account and invisible on small ones.
set -euo pipefail

LOG="${1:?usage: stall-gate.sh <sonar-ios.log> [--since ISO] [--max-stall-ms N] [--max-section-ms N] [--max-wait-ms N] [--min-gap-recoveries N] [--max-gap-ms N]}"
shift
SINCE=""; MAX_STALL=250; MAX_SECTION=250; MAX_WAIT=2000; MIN_GAP=0; MAX_GAP=15000
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --max-stall-ms) MAX_STALL="$2"; shift 2 ;;
    --max-section-ms) MAX_SECTION="$2"; shift 2 ;;
    --max-wait-ms) MAX_WAIT="$2"; shift 2 ;;
    --min-gap-recoveries) MIN_GAP="$2"; shift 2 ;;
    --max-gap-ms) MAX_GAP="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -f "$LOG" ]] || { echo "no log at $LOG" >&2; exit 2; }

python3 - "$LOG" "$SINCE" "$MAX_STALL" "$MAX_SECTION" "$MAX_WAIT" "$MIN_GAP" "$MAX_GAP" <<'PY'
import re, sys
from collections import defaultdict

log, since = sys.argv[1], sys.argv[2]
max_stall, max_section, max_wait, min_gap, max_gap = map(int, sys.argv[3:8])
stall_re = re.compile(r"main thread stalled ms=(\d+) sections=(\[.*?\])")
section_re = re.compile(r"main-thread section slow name=(\S+) ms=(\d+)")
wait_re = re.compile(r"marmot workQueue op=(\S+) waited_ms=(\d+) ran_ms=(\d+)")
gap_re = re.compile(r"foreground refresh: gap recovery finished at (\d+) ms")

stalls, sections, waits, gaps = [], defaultdict(list), defaultdict(list), []
with open(log, errors="replace") as fh:
    for line in fh:
        ts = line.split(" ", 1)[0]
        if since and ts < since:
            continue
        if m := stall_re.search(line):
            stalls.append((int(m.group(1)), m.group(2), ts))
        elif m := section_re.search(line):
            sections[m.group(1)].append(int(m.group(2)))
        elif m := wait_re.search(line):
            waits[m.group(1)].append((int(m.group(2)), int(m.group(3)), ts))
        elif m := gap_re.search(line):
            gaps.append((int(m.group(1)), ts))

failures = []
bad_stalls = [s for s in stalls if s[0] >= max_stall]
if bad_stalls:
    failures.append(f"{len(bad_stalls)} main-thread stall(s) >= {max_stall} ms")
bad_sections = [ms for v in sections.values() for ms in v if ms >= max_section]
if bad_sections:
    failures.append(f"{len(bad_sections)} main-thread section(s) >= {max_section} ms")
bad_waits = [(op, w) for op, ws in waits.items() for w in ws if w[0] > max_wait]
if bad_waits:
    failures.append(f"{len(bad_waits)} work-queue wait(s) > {max_wait} ms")
slow_gaps = [g for g in gaps if g[0] > max_gap]
if slow_gaps:
    failures.append(f"{len(slow_gaps)} gap recover(y/ies) slower than {max_gap} ms")
if len(gaps) < min_gap:
    failures.append(f"{len(gaps)} gap recoveries finished, expected >= {min_gap}")

print(f"stall-gate: {log}" + (f" since {since}" if since else ""))
print(f"  main-thread stalls: {len(stalls)}")
for ms, sections, ts in sorted(stalls, reverse=True)[:5]:
    print(f"    {ms:>6} ms  {sections}  {ts}")
print(f"  slow main-thread sections (> 48 ms): {sum(len(v) for v in sections.values())}")
for name, v in sorted(sections.items(), key=lambda kv: -max(kv[1])):
    print(f"    {name}: n={len(v)} worst={max(v)} ms total={sum(v)} ms")
print(f"  work-queue ops over 1 s: {sum(len(v) for v in waits.values())}")
for op, ws in sorted(waits.items(), key=lambda kv: -max(w[0] for w in kv[1])):
    worst = max(ws)
    print(f"    {op}: n={len(ws)} worst waited={worst[0]} ms ran={worst[1]} ms")
print(f"  gap recoveries finished: {len(gaps)}" + (f" ({', '.join(str(g[0]) + ' ms' for g in gaps)})" if gaps else ""))
if failures:
    print("FAIL: " + "; ".join(failures))
    sys.exit(1)
print("PASS")
PY
