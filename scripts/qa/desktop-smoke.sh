#!/usr/bin/env bash
# desktop-smoke.sh — scripted hardware smoke of the desktop Bluetooth mesh
# against a real phone, for the QA-128/129/134 legs the simulated interop test
# cannot reach (a controller that refuses to advertise, BlueZ quirks, MTU
# negotiation, a link that really drops).
#
#   QA_ANDROID_SERIAL=<serial> scripts/qa/desktop-smoke.sh [--only QA-128]
#
# It asserts on BOTH sides: the desktop driver's `QA:` lines and the phone's
# logcat. A one-sided pass is what let "the desktop says it linked" hide a phone
# that had already dropped its half (finding D2 on #612).
#
# Preconditions: an ONBOARDED Sonar on a connected Android phone with Bluetooth
# on and the app in the foreground, a Linux desktop with a working BLE adapter,
# and JAVA_HOME on a JDK 17 or 21. Nothing is installed, wiped or uninstalled on
# the phone: QA-129 toggles its Bluetooth and turns it back on.
#
# Exit status = number of failed scenarios.
# Results: human summary on stdout + $QA_HOME/desktop-smoke-<run>.json.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERIAL="${QA_ANDROID_SERIAL:?set QA_ANDROID_SERIAL (adb devices) — the phone to link against}"
export QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa-$(basename "$ROOT")}"
ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
RUN="$(date +%m%d%H%M%S)"
RESULTS="$QA_HOME/desktop-smoke-$RUN.json"
mkdir -p "$QA_HOME"
declare -a ROWS=()
FAILED=0

# The bridge writes here when SONAR_BLE_DEBUG is set; it is the only view of
# what the radio actually did.
BLE_LOG="${XDG_STATE_HOME:-$HOME/.local/state}/sonar/sonar-ble.log"

record() { # id status detail
  local id="$1" st="$2" detail="${3:-}"
  ROWS+=("$id|$st|$detail")
  printf '%-8s %-4s %s\n' "$id" "$st" "$detail"
  [[ "$st" == FAIL ]] && FAILED=$((FAILED + 1))
  return 0
}
want() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }
adbsh() { adb -s "$SERIAL" shell "$@" 2>/dev/null; }

phone_ready() { # the phone must be able to advertise, or nothing can be dialed
  [[ "$(adbsh settings get global bluetooth_on | tr -d '\r')" == "1" ]] || return 1
  adbsh pidof chat.bitchat.sonar >/dev/null || return 1
  return 0
}

foreground_app() {
  adbsh am start -n chat.bitchat.sonar/.MainActivity >/dev/null
  sleep 3
}

# Runs the driver and prints its QA: lines. Never fails the run itself.
drive() { # scenario budget_secs -> stdout: key=value lines
  local scenario="$1" budget="$2" log="$QA_HOME/desktop-driver-$scenario-$RUN.log"
  ( cd "$ROOT/apps/sonar" && SONAR_QA_HARDWARE=1 SONAR_QA_SCENARIO="$scenario" \
      SONAR_QA_BUDGET_SECS="$budget" SONAR_BLE_DEBUG=1 \
      ./gradlew --no-daemon --quiet :composeApp:jvmTest \
        --tests 'chat.bitchat.sonar.DesktopMeshHardwareDriver' --rerun-tasks ) \
    > "$log" 2>&1
  sed -n 's/^ *QA: //p' "$log"
}

val() { sed -n "s/^$2=//p" <<< "$1" | tail -1; }

qa128() { # a desktop that dials a phone links and carries DMs both ways
  phone_ready || { record QA-128 SKIP "phone not ready (Bluetooth off or Sonar not running)"; return; }
  foreground_app
  adb -s "$SERIAL" logcat -c
  local o; o="$(drive link 150)"
  local linked dm peer
  linked="$(val "$o" noiseEstablished)"; dm="$(val "$o" dmSent)"; peer="$(val "$o" peerName)"
  # The phone's own view, so a desktop-side claim cannot pass alone.
  local phone_est phone_rx
  phone_est="$(adb -s "$SERIAL" logcat -d 2>/dev/null | grep -c 'Noise link ESTABLISHED')"
  phone_rx="$(adb -s "$SERIAL" logcat -d 2>/dev/null | grep -c 'central subscribed')"
  if [[ "$linked" == true && "$dm" == true && "${phone_est:-0}" -gt 0 ]]; then
    record QA-128 PASS "linked to '${peer:-?}', DM accepted, phone logged ESTABLISHED (${phone_rx} subscribe burst(s))"
  elif [[ "$linked" == true && "${phone_est:-0}" -eq 0 ]]; then
    record QA-128 FAIL "desktop says linked but the phone never logged ESTABLISHED (one-sided session)"
  elif [[ -z "$(val "$o" peerFp)" ]]; then
    record QA-128 FAIL "no mesh peer discovered in 150 s (phone advertising? in range?)"
  else
    record QA-128 FAIL "linked=$linked dmSent=$dm phoneEstablished=${phone_est:-0}"
  fi
}

qa129() { # a dropped link is re-handshaken, not left half-dead
  phone_ready || { record QA-129 SKIP "phone not ready"; return; }
  foreground_app
  # Drop the phone's radio mid-run, then restore it. The driver watches for
  # hasMeshLink going false and then true again.
  ( sleep 45; adbsh cmd bluetooth_manager disable >/dev/null; sleep 20
    adbsh cmd bluetooth_manager enable >/dev/null ) &
  local toggler=$!
  local o; o="$(drive drop 210)"
  wait "$toggler" 2>/dev/null
  # Leave the phone as we found it.
  adbsh cmd bluetooth_manager enable >/dev/null
  local dropped relinked
  dropped="$(val "$o" linkDropped)"; relinked="$(val "$o" relinked)"
  if [[ "$dropped" == true && "$relinked" == true ]]; then
    record QA-129 PASS "session reset on the drop and re-established after the radio came back"
  elif [[ "$dropped" != true ]]; then
    record QA-129 FAIL "the desktop never noticed the link drop (stale session survives: D2)"
  else
    record QA-129 FAIL "dropped but never re-linked within the budget"
  fi
}

qa134() { # a long DM crosses in both directions
  phone_ready || { record QA-134 SKIP "phone not ready"; return; }
  foreground_app
  local o; o="$(drive longdm 150)"
  local sent chars
  sent="$(val "$o" dmSent)"; chars="$(val "$o" dmChars)"
  # Over 480 bytes the engine must fragment (0x20); a single oversized GATT
  # write is silently dropped by the phone.
  local frag
  frag="$(grep -c 'mesh_fragment\|0x20' "$BLE_LOG" 2>/dev/null || echo 0)"
  if [[ "$sent" == true && "${chars:-0}" -gt 480 ]]; then
    record QA-134 PASS "${chars}-char DM accepted over the link (fragment markers in log: $frag)"
  else
    record QA-134 FAIL "sent=$sent chars=${chars:-0} (needs >480 to exercise 0x20)"
  fi
}

echo "Sonar desktop mesh smoke — run $RUN against phone $SERIAL"
echo "adapter: $(bluetoothctl show 2>/dev/null | sed -n 's/^\s*Powered: /powered=/p' | head -1)"
if ! command -v adb >/dev/null; then echo "adb not found" >&2; exit 2; fi
for s in qa128 qa129 qa134; do
  id="QA-${s#qa}"
  want "$id" || continue
  "$s"
done

python3 - "$RESULTS" "$RUN" "$SERIAL" "${ROWS[@]}" <<'PY'
import json, sys
path, run, serial, rows = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
out = {"run": run, "phone": serial, "scenarios": [
    dict(zip(("id", "status", "detail"), r.split("|", 2))) for r in rows]}
json.dump(out, open(path, "w"), indent=2)
PY
echo "results: $RESULTS — $FAILED failed"
exit "$FAILED"
