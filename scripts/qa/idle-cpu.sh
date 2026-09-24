#!/usr/bin/env bash
# idle-cpu.sh — average CPU of the running Sonar app over a window, for the
# "idle churn" check of a QA pass. Leave the app on the chat list, untouched.
#
#   idle-cpu.sh android <serial> [secs] [--max PCT]
#   idle-cpu.sh ios <simulator-udid> [secs] [--max PCT]
#
# Prints "cpu_pct=<n> window=<secs>s" and exits 1 when --max is exceeded.
# Baseline 2026-09-23: Android emulator 0.67 % on the chat list (60 s window).
# A jump to several percent at idle usually means a poll loop, a relay
# reconnect storm or recomposition churn — see docs/PERFORMANCE.md.
set -euo pipefail

platform="${1:?android|ios}"; target="${2:?serial or udid}"; secs="${3:-60}"
max=""
if [[ "${4:-}" == "--max" ]]; then max="${5:?--max PCT}"; fi

case "$platform" in
  android)
    pid="$(adb -s "$target" shell pidof chat.bitchat.sonar | tr -d '\r')"
    [[ -n "$pid" ]] || { echo "Sonar is not running on $target" >&2; exit 2; }
    ticks() { adb -s "$target" shell cat "/proc/$pid/stat" | awk '{print $14 + $15}'; }
    hz="$(adb -s "$target" shell getconf CLK_TCK 2>/dev/null | tr -d '\r')"; hz="${hz:-100}"
    t1="$(ticks)"; sleep "$secs"; t2="$(ticks)"
    pct="$(python3 -c "print(round(($t2 - $t1) / $hz / $secs * 100, 2))")" ;;
  ios)
    # Simulator apps are host processes: read their CPU time with ps.
    pid="$(xcrun simctl spawn "$target" launchctl list | awk '/sh\.hedwig\.sonar/ && $1 ~ /^[0-9]+$/ {print $1; exit}')"
    [[ -n "$pid" ]] || { echo "Sonar is not running on simulator $target" >&2; exit 2; }
    cpu_secs() {
      ps -o time= -p "$pid" | python3 -c '
import sys
t = sys.stdin.read().strip()
parts = [float(x) for x in t.replace("-", ":").split(":")]
s = 0.0
for p in parts: s = s * 60 + p
print(s)'
    }
    c1="$(cpu_secs)"; sleep "$secs"; c2="$(cpu_secs)"
    pct="$(python3 -c "print(round(($c2 - $c1) / $secs * 100, 2))")" ;;
  *) echo "platform must be android or ios" >&2; exit 2 ;;
esac

echo "cpu_pct=$pct window=${secs}s"
if [[ -n "$max" ]] && python3 -c "import sys; sys.exit(0 if $pct > $max else 1)"; then
  echo "FAIL: idle CPU $pct% > $max%" >&2
  exit 1
fi
