#!/usr/bin/env bash
# android-setup.sh — boot a DEDICATED QA emulator, install the Debug build IN
# PLACE, and start a logcat capture. Prints the serial on stdout.
#
#   scripts/qa/android-setup.sh [--avd Sonar_QA_API_36] [--port 5580]
#                               [--no-install] [--fresh] [--allow-missing-config]
#                               [--take-over]
#
# --fresh clears app data first (onboarding / permission-timing scenarios).
# It is refused on anything that is not an emulator.
#
# Preflight (presence only — values are never printed): the Breez key
# (`breez.apiKey` in apps/sonar/local.properties or env BREEZ_API_KEY) and
# apps/sonar/composeApp/google-services.json. Without them the Debug build
# still installs, but wallet flows / offline-payment pushes are silently off
# and any QA result about them is meaningless. Setup refuses unless you pass
# --allow-missing-config, which records the gap in $QA_HOME/config-gaps.txt
# for the QA report. Copy the files from the primary checkout; never commit them.
#
# Ownership: the worktree that sets up a running emulator owns it for that
# boot (~/.sonar-qa/owners/<serial> = worktree path + the emulator's boot id).
# Another worktree is refused while the same boot runs — two agents on one
# emulator would install over (or --fresh-clear) each other's app. Create a
# second AVD and pass --avd/--port, or --take-over when the owner is gone.
# A relaunched emulator has a new boot id, so a stale claim never blocks it.
#
# Rules (CLAUDE.md "Never Uninstall Device Apps"): this script never
# uninstalls, and only targets an emulator it booted by serial. Physical
# devices are out of scope for agent QA — the account key lives there.
# If `installDebug` fails, STOP and report; do not uninstall to "fix" it.
#
# Create the AVD once (any recent arm64 image works):
#   sdkmanager "system-images;android-36;google_apis_playstore;arm64-v8a"
#   avdmanager create avd -n Sonar_QA_API_36 -d pixel_7 \
#     -k "system-images;android-36;google_apis_playstore;arm64-v8a"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa-$(basename "$ROOT")}"   # per worktree
AVD="Sonar_QA_API_36"; PORT=5580; INSTALL=1; FRESH=0; ALLOW_MISSING=0; TAKE_OVER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --avd) AVD="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --no-install) INSTALL=0; shift ;;
    --fresh) FRESH=1; shift ;;
    --allow-missing-config) ALLOW_MISSING=1; shift ;;
    --take-over) TAKE_OVER=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
SERIAL="emulator-$PORT"
mkdir -p "$QA_HOME"

missing=()
props="$ROOT/apps/sonar/local.properties"
if [[ -z "${BREEZ_API_KEY:-}" ]] &&
   ! grep -Eq '^[[:space:]]*breez\.apiKey[[:space:]]*=[[:space:]]*[^[:space:]]' "$props" 2>/dev/null; then
  missing+=("Breez key (breez.apiKey in apps/sonar/local.properties or env BREEZ_API_KEY): wallet flows off")
fi
[[ -f "$ROOT/apps/sonar/composeApp/google-services.json" ]] ||
  missing+=("apps/sonar/composeApp/google-services.json: no FCM, no offline-payment pushes")
# config-gaps.txt reflects THIS run: drop the platform's old entries first, so
# a gap fixed since the last setup is not still reported as "not run".
if [[ -f "$QA_HOME/config-gaps.txt" ]]; then
  grep -v '^android: ' "$QA_HOME/config-gaps.txt" > "$QA_HOME/config-gaps.txt.tmp" || true
  mv "$QA_HOME/config-gaps.txt.tmp" "$QA_HOME/config-gaps.txt"
fi
if (( ${#missing[@]} )); then
  printf 'missing local config:\n' >&2; printf '  - %s\n' "${missing[@]}" >&2
  if (( ! ALLOW_MISSING )); then
    echo "refusing to set up a QA build that silently lacks them; copy them from the primary" >&2
    echo "checkout, or pass --allow-missing-config and report wallet/push scenarios as not run." >&2
    exit 1
  fi
  for gap in "${missing[@]}"; do echo "android: $gap" >> "$QA_HOME/config-gaps.txt"; done
fi

EMULATOR="${ANDROID_HOME:-$HOME/Library/Android/sdk}/emulator/emulator"
if ! adb devices | grep -q "^${SERIAL}[[:space:]]*device"; then
  [[ -x "$EMULATOR" ]] || { echo "emulator binary not found (set ANDROID_HOME)" >&2; exit 1; }
  echo ">> booting $AVD on $SERIAL" >&2
  nohup "$EMULATOR" -avd "$AVD" -port "$PORT" -no-boot-anim -no-snapshot-save \
    > "$QA_HOME/emulator-$PORT.log" 2>&1 &
  adb -s "$SERIAL" wait-for-device
  until [[ "$(adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; do
    sleep 2
  done
fi

if [[ "$(adb -s "$SERIAL" shell getprop ro.kernel.qemu 2>/dev/null | tr -d '\r')" != 1 ]] &&
   [[ "$(adb -s "$SERIAL" shell getprop ro.boot.qemu 2>/dev/null | tr -d '\r')" != 1 ]]; then
  echo "refusing: $SERIAL is not an emulator" >&2; exit 1
fi
# The port may already belong to ANOTHER agent's emulator on this shared Mac;
# installing over it — or `--fresh`-clearing it — would erase that agent's
# state. Only touch the AVD we were asked for.
running_avd="$(adb -s "$SERIAL" emu avd name 2>/dev/null | head -1 | tr -d '\r')"
if [[ "$running_avd" != "$AVD" ]]; then
  echo "refusing: $SERIAL runs AVD '${running_avd:-unknown}', not '$AVD' — pick a free --port" >&2
  exit 1
fi
OWNERS="$HOME/.sonar-qa/owners"; mkdir -p "$OWNERS"
boot_id="$(adb -s "$SERIAL" shell cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r')"
owner=""; owner_boot=""
if [[ -f "$OWNERS/$SERIAL" ]]; then
  { read -r owner; read -r owner_boot; } < "$OWNERS/$SERIAL" || true
fi
if [[ -n "$owner" && "$owner" != "$ROOT" && "$owner_boot" == "$boot_id" && "$TAKE_OVER" != 1 ]]; then
  echo "refusing: $SERIAL is in use by another worktree ($owner). Create a second AVD and" >&2
  echo "pass --avd/--port, or --take-over if that agent is gone." >&2
  exit 1
fi
printf '%s\n%s\n' "$ROOT" "$boot_id" > "$OWNERS/$SERIAL"

if (( INSTALL )); then
  echo ">> installDebug on $SERIAL (in place)" >&2
  (cd "$ROOT/apps/sonar" && ANDROID_SERIAL="$SERIAL" ./gradlew -q :composeApp:installDebug) >&2
fi

if (( FRESH )); then
  echo ">> clearing app data + revoking runtime permissions on $SERIAL" >&2
  adb -s "$SERIAL" shell pm clear chat.bitchat.sonar >/dev/null
  for p in BLUETOOTH_SCAN BLUETOOTH_ADVERTISE BLUETOOTH_CONNECT ACCESS_FINE_LOCATION \
           ACCESS_COARSE_LOCATION RECORD_AUDIO POST_NOTIFICATIONS; do
    adb -s "$SERIAL" shell pm revoke chat.bitchat.sonar "android.permission.$p" 2>/dev/null || true
  done
fi

LOG="$QA_HOME/logcat-$SERIAL.txt"
PIDFILE="$QA_HOME/logcat-$SERIAL.pid"
# One capture per serial: a second writer truncating the same file would
# interleave and overwrite the log across setup reruns.
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
fi
adb -s "$SERIAL" logcat -c
nohup adb -s "$SERIAL" logcat -v time > "$LOG" 2>&1 &
echo $! > "$PIDFILE"
echo ">> logcat → $LOG (pid $!)" >&2
adb -s "$SERIAL" shell am start -n chat.bitchat.sonar/.MainActivity >/dev/null
echo "$SERIAL"
