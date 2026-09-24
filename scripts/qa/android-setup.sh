#!/usr/bin/env bash
# android-setup.sh — boot a DEDICATED QA emulator, install the Debug build IN
# PLACE, and start a logcat capture. Prints the serial on stdout.
#
#   scripts/qa/android-setup.sh [--avd Sonar_QA_API_36] [--port 5580]
#                               [--no-install] [--fresh]
#
# --fresh clears app data first (onboarding / permission-timing scenarios).
# It is refused on anything that is not an emulator.
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
QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa}"
AVD="Sonar_QA_API_36"; PORT=5580; INSTALL=1; FRESH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --avd) AVD="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --no-install) INSTALL=0; shift ;;
    --fresh) FRESH=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
SERIAL="emulator-$PORT"
mkdir -p "$QA_HOME"

EMULATOR="${ANDROID_HOME:-$HOME/Library/Android/sdk}/emulator/emulator"
if ! adb devices | grep -q "^$SERIAL[[:space:]]*device"; then
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
adb -s "$SERIAL" logcat -c
nohup adb -s "$SERIAL" logcat -v time > "$LOG" 2>&1 &
echo ">> logcat → $LOG (pid $!)" >&2
adb -s "$SERIAL" shell am start -n chat.bitchat.sonar/.MainActivity >/dev/null
echo "$SERIAL"
