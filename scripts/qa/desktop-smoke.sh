#!/usr/bin/env bash
# desktop-smoke.sh — scripted hardware smoke of the desktop Bluetooth mesh
# against a real phone, for the QA-128/129/134 legs the simulated interop test
# cannot reach (a controller that refuses to advertise, BlueZ quirks, MTU
# negotiation, a link that really drops).
#
#   QA_ANDROID_SERIAL=<serial> scripts/qa/desktop-smoke.sh [--only QA-128]
#
# It asserts on BOTH sides. The phone's half is its own delivery receipt, minted
# after it decrypts (and, over 480 bytes, reassembles) the DM, not a log string:
# a one-sided pass is what let "the desktop says it sent" hide a phone that got
# nothing (finding D2 on #612).
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
# How long the phone's radio stays off in QA-129 — long enough to be a real
# outage the phone must recover from, short enough to leave the rest of the
# budget for the re-handshake.
DROP_SECS="${QA_DROP_SECS:-30}"
RUN="$(date +%m%d%H%M%S)"
RESULTS="$QA_HOME/desktop-smoke-$RUN.json"
mkdir -p "$QA_HOME"
declare -a ROWS=()
FAILED=0


# Gradle 8.12 refuses a JDK newer than 23 and reports only its version string
# ("* What went wrong: 25.0.2"), which reads as the driver simply not running.
# A shell whose JAVA_HOME points at a current JDK — sdkman's default here — hits
# this on every scenario, so pick a supported one rather than fail opaquely.
pick_jdk() {
  local major
  if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
    major="$("$JAVA_HOME/bin/java" -version 2>&1 | sed -n '1s/.*version "\([0-9]*\).*/\1/p')"
    [[ "$major" == 17 || "$major" == 21 ]] && return 0
  fi
  local c
  for c in /usr/lib/jvm/java-21-openjdk-* /usr/lib/jvm/java-17-openjdk-*; do
    [[ -x "$c/bin/java" ]] || continue
    export JAVA_HOME="$c"
    echo "jdk: $c (JAVA_HOME was ${major:+JDK $major}${major:+, }unsupported by gradle 8.12)"
    return 0
  done
  echo "no JDK 17 or 21 found; gradle 8.12 rejects newer ones. Set JAVA_HOME." >&2
  exit 2
}

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

# Where the driver writes its QA: lines while it runs.
qa_out() { echo "$QA_HOME/desktop-driver-$1-$RUN.qa"; }

# Runs the driver and prints its QA: lines. Never fails the run itself.
drive() { # scenario budget_secs -> stdout: key=value lines
  # Declared separately: a single `local a=$1 b=..$a..` is evaluated in one pass
  # under `set -u`, so the third assignment read $scenario before it was set and
  # aborted the driver. Both scenarios then "failed" for want of a log file, and
  # QA-129 reported a stale session that had never been tested.
  local scenario="$1"
  local budget="$2"
  local log="$QA_HOME/desktop-driver-$scenario-$RUN.log"
  local out
  out="$(qa_out "$scenario")"
  : > "$out"
  ( cd "$ROOT/apps/sonar" && SONAR_QA_HARDWARE=1 SONAR_QA_SCENARIO="$scenario" \
      SONAR_QA_BUDGET_SECS="$budget" SONAR_QA_OUT="$out" SONAR_BLE_DEBUG=1 \
      ./gradlew --no-daemon --quiet :composeApp:jvmTest \
        --tests 'chat.bitchat.sonar.DesktopMeshHardwareDriver' --rerun-tasks ) \
    > "$log" 2>&1
  # Read the driver's own file, not gradle's console: gradle captures a test's
  # stdout into its JUnit XML report, so the console carries no QA: lines and
  # every scenario read as unrun.
  cat "$out"
}

val() { sed -n "s/^$2=//p" <<< "$1" | tail -1; }

# A driver that never ran must not be reported as a behavioural failure. Without
# this, a bug in THIS script made QA-129 announce "stale session survives: D2" —
# a finding about code that was never exercised. ERROR means the harness broke.
ran() { [[ "$(val "$1" done)" == true ]]; }
harness_error() { # id
  local why
  why="$(sed -n '/What went wrong/{n;s/^[* ]*//p;}' "$QA_HOME"/desktop-driver-*-"$RUN".log 2>/dev/null | head -1)"
  record "$1" ERROR "the driver did not run${why:+ (${why})}; see $QA_HOME/desktop-driver-*-$RUN.log"
}

qa128() { # a desktop that dials a phone links and carries DMs both ways
  phone_ready || { record QA-128 SKIP "phone not ready (Bluetooth off or Sonar not running)"; return; }
  foreground_app
  local o; o="$(drive link 150)"
  ran "$o" || { harness_error QA-128; return; }
  local linked dm receipt peer secs
  linked="$(val "$o" noiseEstablished)"; dm="$(val "$o" dmSent)"
  receipt="$(val "$o" dmReceipt)"; peer="$(val "$o" peerName)"
  secs="$(val "$o" noiseEstablishedAfterSecs)"
  if [[ "$linked" == true && "$dm" == true && "$receipt" == true ]]; then
    record QA-128 PASS "linked to '${peer:-?}' in ${secs:-?}s; phone returned a delivery receipt for the DM"
  elif [[ "$linked" == true && "$dm" == true ]]; then
    # The desktop wrote the DM and the phone never acked it: exactly the
    # one-sided claim (finding D2) this scenario exists to catch.
    record QA-128 FAIL "DM written but the phone never returned a receipt (one-sided send)"
  elif [[ "$linked" == true ]]; then
    record QA-128 FAIL "linked but the DM was refused locally (dmSent=$dm)"
  elif [[ -z "$(val "$o" peerFp)" ]]; then
    record QA-128 FAIL "no mesh peer discovered in 150 s (phone advertising? in range?)"
  else
    record QA-128 FAIL "peer seen but no Noise session in 150 s (handshake stalled)"
  fi
}

qa129() { # a dropped link is re-handshaken, not left half-dead
  phone_ready || { record QA-129 SKIP "phone not ready"; return; }
  foreground_app
  local out mark; out="$(qa_out drop)"; mark="$out.toggled"
  rm -f "$out" "$mark"; : > "$out"
  # Pull the phone's radio only once the desktop really has a link, then restore
  # it. Two earlier shapes both toggled outside the driver's watch: a fixed
  # `sleep 45` fired during gradle's startup, and a 140-iteration ceiling expired
  # 17 s before the link came up, because `--no-daemon --rerun-tasks` spends
  # 60-155 s before the test body runs. So wait on the driver's own lines with no
  # budget of our own: it always writes `done=true` from its finally block, which
  # is what ends this loop when no link ever appears.
  ( while :; do
      grep -q '^noiseEstablished=true' "$out" 2>/dev/null && break
      grep -q '^done=true' "$out" 2>/dev/null && exit 0
      sleep 1
    done
    sleep 4
    adbsh cmd bluetooth_manager disable >/dev/null
    echo "off" >> "$mark"; sleep "$DROP_SECS"
    adbsh cmd bluetooth_manager enable >/dev/null
    echo "on" >> "$mark" ) &
  local toggler=$!
  # The driver waits for the marker's `on` line before it tries to send again, so
  # a receipt cannot be mistaken for one that crossed before the outage.
  export SONAR_QA_RESUME="$mark"
  local o; o="$(drive drop 300)"
  unset SONAR_QA_RESUME
  ran "$o" || { harness_error QA-129; wait "$toggler" 2>/dev/null; adbsh cmd bluetooth_manager enable >/dev/null; return; }
  wait "$toggler" 2>/dev/null
  # Leave the phone as we found it, whatever happened above.
  adbsh cmd bluetooth_manager enable >/dev/null
  local linked dropped relinked tries
  linked="$(val "$o" noiseEstablished)"; dropped="$(val "$o" linkDropped)"
  relinked="$(val "$o" relinked)"; tries="$(val "$o" dmsSentAfterDrop)"
  # The verdict is recovery, not the intermediate state. `linkDropped` is only
  # observable on a link the desktop dialed: on the GATT server path bluster
  # stubs the disconnect, so MeshLink keeps the session until the phone's fresh
  # m1 resets it. Both shapes must end with DMs flowing again, which is the part
  # the user can feel, so that is what decides it — and it is asserted with the
  # phone's own receipt, not a desktop-side claim.
  if [[ "$linked" != true ]]; then
    record QA-129 FAIL "never linked, so the drop was never exercised (phone in range?)"
  elif ! grep -qx on "$mark" 2>/dev/null; then
    record QA-129 ERROR "the radio was never toggled; nothing was tested (see $mark)"
  elif [[ "$relinked" == true ]]; then
    record QA-129 PASS "DM acked again after a ${DROP_SECS}s outage (${tries:-?} send(s) to recover; desktop saw the drop: ${dropped:-no})"
  elif [[ "$(val "$o" radioBack)" != true ]]; then
    record QA-129 ERROR "the driver never saw the radio come back; budget too short?"
  else
    record QA-129 FAIL "no DM got through after the radio returned (stale session survives: D2)"
  fi
}

qa134() { # a long DM crosses in both directions
  phone_ready || { record QA-134 SKIP "phone not ready"; return; }
  foreground_app
  local o; o="$(drive longdm 150)"
  ran "$o" || { harness_error QA-134; return; }
  local sent chars receipt
  sent="$(val "$o" dmSent)"; chars="$(val "$o" dmChars)"; receipt="$(val "$o" dmReceipt)"
  # Over 480 bytes the engine must split the packet into 0x20 fragments, and only
  # the phone's receipt proves it put them back together: an oversized single
  # GATT write is dropped silently while the desktop-side write still returns
  # true. There is no local marker to count — fragmenting happens in MeshLink,
  # which does not log it, and sonar-ble.log records the peripheral/scan side
  # only. An earlier version grepped it for '0x20' and reported 0 fragments for a
  # DM the phone had plainly reassembled.
  if [[ "${chars:-0}" -le 480 ]]; then
    record QA-134 ERROR "the driver sent only ${chars:-0} chars, below the fragment threshold"
  elif [[ "$sent" == true && "$receipt" == true ]]; then
    record QA-134 PASS "${chars}-char DM fragmented, reassembled and acked by the phone"
  elif [[ "$sent" == true ]]; then
    record QA-134 FAIL "${chars}-char DM written but never acked: fragments lost in flight"
  else
    record QA-134 FAIL "the ${chars}-char DM was refused locally"
  fi
}

echo "Sonar desktop mesh smoke — run $RUN against phone $SERIAL"
pick_jdk
echo "adapter: $(bluetoothctl show 2>/dev/null | sed -n 's/^\s*Powered: /powered=/p' | head -1)"
if ! command -v adb >/dev/null; then echo "adb not found" >&2; exit 2; fi
SCENARIOS=(qa128 qa129 qa134)

# A mistyped --only would otherwise run nothing and exit 0, which reads as a
# green pass of the leg you meant to check.
if [[ -n "$ONLY" ]]; then
  known=0
  for s in "${SCENARIOS[@]}"; do [[ "QA-${s#qa}" == "$ONLY" ]] && known=1; done
  if [[ "$known" == 0 ]]; then
    echo "unknown scenario: $ONLY (have: ${SCENARIOS[*]/#qa/QA-})" >&2
    exit 2
  fi
fi

for s in "${SCENARIOS[@]}"; do
  id="QA-${s#qa}"
  want "$id" || continue
  "$s"
done

if [[ "${#ROWS[@]}" -eq 0 ]]; then
  echo "no scenario ran" >&2
  exit 2
fi

python3 - "$RESULTS" "$RUN" "$SERIAL" "${ROWS[@]}" <<'PY'
import json, sys
path, run, serial, rows = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
out = {"run": run, "phone": serial, "scenarios": [
    dict(zip(("id", "status", "detail"), r.split("|", 2))) for r in rows]}
json.dump(out, open(path, "w"), indent=2)
PY
echo "results: $RESULTS — $FAILED failed"
exit "$FAILED"
