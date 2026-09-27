#!/usr/bin/env bash
# android-release-window-focus.sh — before connected tests on a CI emulator,
# close any system dialog that holds window focus, and fail loudly if one
# still does.
#
#   android-release-window-focus.sh            # uses $ANDROID_SERIAL or the one device
#
# Why: android-emulator-runner presses the menu key (keyevent 82) as soon as
# sys.boot_completed flips. On a slow boot System UI is not dispatching input
# yet, the key times out after 5 s, and System UI's "not responding" dialog
# keeps window focus for the rest of the job. Espresso's pressBack() waits for
# the app window to have focus, so every SystemBackAndroidTest case then fails
# with RootViewWithoutFocusException while the tests that never need focus
# pass. In the 38 "Compose tests" runs up to 2026-09-27, all 8 red ones had
# that unlock take more than 5.6 s and every unlock under 5.4 s was green.
#
# Run it after the build and before connectedDebugAndroidTest, so a dialog
# raised at boot has had time to appear. ACTION_CLOSE_SYSTEM_DIALOGS closes
# the ANR dialog (AppNotRespondingDialog force-closes the hung process), the
# crash dialog, the shade and the power menu; System UI then restarts, so the
# keyguard is dismissed again after it.
set -uo pipefail

focus() {
  adb shell dumpsys window 2>/dev/null | grep -m1 'mCurrentFocus=' | sed 's/^ *//' | tr -d '\r'
}

held_by_system() {
  case "$1" in
    ""|*"mCurrentFocus=null"*) return 0 ;;
    *"Not Responding"*|*"Error Dialog"*|*NotificationShade*|*Keyguard*) return 0 ;;
    *) return 1 ;;
  esac
}

current="$(focus)"
echo "window focus before tests: ${current:-<none>}"
for _ in 1 2 3 4 5 6; do
  held_by_system "$current" || { echo "window focus ready: $current"; exit 0; }
  adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1
  adb shell wm dismiss-keyguard >/dev/null 2>&1
  sleep 10
  current="$(focus)"
  echo "window focus after dismissing: ${current:-<none>}"
done
echo "a system window still holds focus: ${current:-<none>}; Espresso pressBack cannot run" >&2
exit 1
