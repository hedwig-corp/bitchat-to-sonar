#!/usr/bin/env bash
# android-mdk-upgrade.sh — app-level MDK v1 (0.8) -> v2 upgrade on a
# DEDICATED Android emulator (QA-190…196, QA-210…212). Prints PASS/FAIL per
# scenario; exit status = failures.
#
# The upgrade cannot be faked with one build: the app must build history on
# the v1 build, then be replaced IN PLACE (`adb install -r`, never uninstall)
# by the v2 build. Peers do the same with two sonar-cli builds.
#
#   QA_SERIAL=emulator-5594 V1_APK=<main's Debug APK> V2_APK=<this tree's> \
#   MDK08_CLI=<main's sonar-cli> scripts/qa/android-mdk-upgrade.sh
#
# Env:
#   QA_SERIAL     a disposable emulator you created for this run (required).
#                 The script runs `pm clear` on it so the v1 install starts
#                 fresh: never point it at a phone (it refuses non-emulators).
#   V1_APK        main's Debug APK (MDK 0.8). Build it from a second checkout:
#                   git worktree add --detach <dir> <pre-bump commit>
#                   (cd <dir>/apps/sonar && ./gradlew :composeApp:assembleDebug)
#                 It needs apps/sonar/composeApp/google-services.json: without
#                 it the 0.8 app crashes in push registration once onboarded.
#   V2_APK        this tree's Debug APK (default: its assembleDebug output)
#   MDK08_CLI     main's sonar-cli (MDK 0.8); SONAR_CLI the v2 one
#   SEED_N        messages the first peer sends on v1 (default 85: past the
#                 80-row first-paint window, so the deferred remainder runs)
#
# Peers and app use the default public relays, so this needs network.
set -uo pipefail
# Pipelines test with `grep -c … >/dev/null`, not `grep -q`: under pipefail a
# `grep -q` that stops reading early SIGPIPEs the producer and turns a match
# into a failure.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa-$(basename "$ROOT")}"
: "${QA_SERIAL:?QA_SERIAL must name a disposable emulator}"
: "${V1_APK:?V1_APK must be the MDK 0.8 Debug APK from main}"
: "${MDK08_CLI:?MDK08_CLI must be the MDK 0.8 sonar-cli from main}"
V2_APK="${V2_APK:-$ROOT/apps/sonar/composeApp/build/outputs/apk/debug/composeApp-debug.apk}"
export SONAR_CLI="${SONAR_CLI:-$ROOT/core/target/release/sonar-cli}"
export MDK08_CLI QA_SERIAL
SEED_N="${SEED_N:-85}"
UI="$ROOT/scripts/qa/android-ui.sh"
M="$ROOT/scripts/qa/mdk-upgrade.sh"
PKG=chat.bitchat.sonar
RUN=$(date +%s)
FAILS=0
pass() { echo "PASS $1 $2"; }
fail() { echo "FAIL $1 $2"; FAILS=$((FAILS + 1)); }
adbs() { adb -s "$QA_SERIAL" "$@"; }

[[ "$QA_SERIAL" == emulator-* ]] || { echo "refusing: $QA_SERIAL is not an emulator" >&2; exit 2; }
[[ -s "$V1_APK" && -s "$V2_APK" && -x "$MDK08_CLI" && -x "$SONAR_CLI" ]] \
  || { echo "missing V1_APK / V2_APK / MDK08_CLI / SONAR_CLI" >&2; exit 2; }

launch() { adbs shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1; }
home_rows() { "$UI" dump 2>/dev/null | sed -n '/MESSAGES/,$p'; }
grant_prompts() {
  local i d
  for i in 1 2 3 4 5 6; do
    d="$("$UI" dump 2>/dev/null)"
    if grep -q "While using the app" <<<"$d"; then "$UI" tapx "While using the app" >/dev/null
    elif grep -qE $'\tAllow\t|\tAllow$' <<<"$d"; then "$UI" tapx "Allow" >/dev/null
    else return 0; fi
    sleep 2
  done
}
# The soft keyboard stays up after a send. Swipes that start on it glide-type
# into the composer ("GT GT GT…") instead of scrolling the transcript, and it
# hides the newest rows, so close it whenever it is shown.
hide_ime() { [[ "$("$UI" ime 2>/dev/null)" == shown ]] && { adbs shell input keyevent 4; sleep 1; }; return 0; }
send_in_open_chat() {
  "$UI" tapedit >/dev/null; sleep 1; "$UI" type "$1"; "$UI" tapx "Send" >/dev/null; sleep 1; hide_ime
}
scroll_until() { # scroll_until <up|down> <text>
  local i dy1=700 dy2=1900
  [[ "$1" == down ]] && { dy1=1900; dy2=500; }
  hide_ime
  for i in $(seq 1 40); do
    "$UI" dump 2>/dev/null | grep -c "$2" >/dev/null && return 0
    adbs shell input swipe 540 "$dy1" 540 "$dy2" 400; sleep 1
  done
  return 1
}
open_row() { "$UI" tapx "$1" >/dev/null; sleep 4; }
back_home() { "$UI" tapx "Back" >/dev/null 2>&1; sleep 2; "$UI" dump | grep -c "Start a chat" >/dev/null || { adbs shell input keyevent 4; sleep 2; }; }

# --- v1 install -------------------------------------------------------------
adbs shell settings put secure stylus_handwriting_enabled 0
adbs shell pm clear "$PKG" >/dev/null 2>&1 || true
adbs install -r "$V1_APK" | grep -c Success >/dev/null || { echo "v1 install failed — stop, do not uninstall" >&2; exit 2; }
launch; sleep 8
"$UI" tapx "Get started" >/dev/null; sleep 2; "$UI" tapx "Surprise me" >/dev/null; sleep 1
"$UI" tapx "Continue" >/dev/null; sleep 3; "$UI" gone "Generating" 40 >/dev/null
"$UI" tapx "Start chatting" >/dev/null; sleep 5; grant_prompts
"$UI" wait "Start a chat" 30 >/dev/null || { echo "v1 onboarding did not reach the chat list" >&2; exit 2; }

rm -rf "$QA_HOME/peers/up-p-$RUN" "$QA_HOME/peers/up-q-$RUN"
P="$("$M" peer "up-p-$RUN" 08 2>/dev/null | tail -1)"
Q="$("$M" peer "up-q-$RUN" 08 2>/dev/null | tail -1)"
"$UI" tapx "Search" >/dev/null; sleep 1; "$UI" tapedit >/dev/null; "$UI" type "$P"
"$UI" wait "Start secure chat" 15 >/dev/null && "$UI" tapx "Start secure chat" -1 >/dev/null
"$UI" wait "Say hi to" 20 >/dev/null
# Typed texts are dictionary words plus the run number: Gboard autocorrect
# learned "v1" from the baseline and rewrote a later "v2" to it.
send_in_open_chat "hello $RUN"
got="$("$M" expect "up-p-$RUN" "hello $RUN" 120 2>/dev/null)"
[[ -n "$got" ]] || { echo "v1 baseline: the peer never received the app's message" >&2; exit 2; }
APP="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["sender"])' "$got")"
TARGET="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$got")"
# A dropped publish here would only show up later as a QA-191 failure, so the
# reaction retries like the sends below and the baseline stops if it never lands.
reacted=0
for t in 1 2 3 4; do
  "$MDK08_CLI" --home "$QA_HOME/peers/up-p-$RUN" react --to "$APP" --target "$TARGET" --emoji "👍" \
    2>/dev/null | grep -c '"type":"reacted"' >/dev/null && { reacted=1; break; }
  sleep $((t * 3))
done
(( reacted )) || { echo "v1 baseline: the peer's 👍 never published" >&2; exit 2; }
# Per-message retries: `mdk-upgrade.sh seed` stops at the first dropped send,
# and restarting it re-sends the messages that did land.
seed_v1() { # seed_v1 <peer> <n> <prefix>
  local i t
  for i in $(seq 1 "$2"); do
    for t in 1 2 3 4 5; do
      "$MDK08_CLI" --home "$QA_HOME/peers/$1" send --to "$APP" --text "$3 $i/$2" \
        --push-settle-secs 0 2>/dev/null | grep -c '"type"' >/dev/null && break
      sleep $((t * 3))
    done
  done
}
seed_v1 "up-q-$RUN" 2 "q v1 $RUN"
peer_send() { # peer_send <peer> <text> on the peer's current CLI, retried
  local t
  for t in 1 2 3 4; do
    "$M" send "$1" "$APP" "$2" 2>/dev/null | grep -c '"type":"sent"' >/dev/null && return 0
    sleep $((t * 5))
  done
  return 1
}
seed_v1 "up-p-$RUN" "$SEED_N" "p v1 $RUN"
"$UI" wait "p v1 $RUN $SEED_N/$SEED_N" 120 >/dev/null || { echo "v1 baseline: history never painted" >&2; exit 2; }
back_home
# Both chats must exist on v1, or QA-190/QA-194 would test a chat that never was.
"$UI" wait "q v1 $RUN 2/2" 180 >/dev/null || { echo "v1 baseline: the second peer's chat never painted" >&2; exit 2; }
back_home

# --- upgrade in place -------------------------------------------------------
adbs install -r "$V2_APK" | grep -c Success >/dev/null || { echo "v2 install failed — stop, do not uninstall" >&2; exit 2; }
t0=$SECONDS; mark="$(adbs shell 'date "+%m-%d %H:%M:%S.000"' | tr -d '\r')"; launch
"$UI" wait "MESSAGES" 60 >/dev/null; painted=$((SECONDS - t0))
mlock="$(adbs logcat -d -T "$mark" 2>/dev/null | grep -c 'sqlcipher_mlock')"
[[ "$mlock" -lt 1000 ]] && pass QA-211 "first v2 launch: $mlock failed-mlock log lines" \
  || fail QA-211 "first v2 launch flooded logcat with $mlock failed-mlock lines"
"$UI" shot "mdk-upgrade-$RUN-home" >/dev/null 2>&1
sleep 4
if home_rows | grep -c "p v1 $RUN $SEED_N/$SEED_N" >/dev/null && home_rows | grep -c "q v1 $RUN 2/2" >/dev/null; then
  pass QA-190 "upgrade kept both v1 chats (Messages painted ${painted}s after launch, dump-polled)"
else
  fail QA-190 "v1 chats missing after the upgrade"
fi
n="$(home_rows | grep -c $'\tNote to Self\t')"
[[ "$n" == 1 ]] && pass QA-210 "one Note to Self row after the upgrade" || fail QA-210 "$n Note to Self rows"
bak="$(adbs shell "run-as $PKG ls -R files" 2>/dev/null | grep -c 'mdk08.bak')"
[[ "$bak" -ge 1 ]] && pass QA-195 "v1 store quarantined as *.mdk08.bak" || fail QA-195 "no *.mdk08.bak"

# Rows are opened by their preview: a CLI peer's title is its profile name
# once kind-0 loads, and both peers may share it.
open_row "p v1 $RUN $SEED_N/$SEED_N"
if ! scroll_until up "p v1 $RUN 1/$SEED_N"; then
  oldest="$("$UI" dump | grep -oE "p v1 $RUN [0-9]+/$SEED_N" | sort -t' ' -k4 -n | head -1)"
  sleep 60  # the idle tick also drains the v1 remainder: did it arrive late?
  if scroll_until up "p v1 $RUN 1/$SEED_N"; then
    fail QA-191 "the oldest v1 row paged in only after a 60 s idle wait (stuck at '$oldest')"
  else
    fail QA-191 "the oldest v1 row never paged in (stuck at '$oldest')"
  fi
elif ! scroll_until up "hello $RUN"; then
  fail QA-191 "the app's first v1 message never paged in"
elif ! "$UI" dump | grep -c "👍" >/dev/null; then
  "$UI" shot "mdk-upgrade-$RUN-qa191" >/dev/null 2>&1
  fail QA-191 "the v1 👍 chip is missing on the app's first message"
else
  pass QA-191 "older v1 history pages in, with the v1 👍 chip"
fi
scroll_until down "p v1 $RUN $SEED_N/$SEED_N" >/dev/null
send_in_open_chat "waiting $RUN"; sleep 20
"$UI" dump | grep -c "Waiting for them to update" >/dev/null \
  && pass QA-193 "peer still on v1: 'Waiting for them to update Sonar'" \
  || fail QA-193 "no waiting banner while the peer is on v1"

"$M" upgrade-peer "up-p-$RUN" >/dev/null 2>&1
# Its v2 KeyPackage must reach the public relays first. A send that fails
# before core accepts it stays an in-memory "Couldn't send · Retry" echo
# (#613, by design), so sending at once would test relay propagation.
sleep 15
# QA-213: send from older history; the view must follow the reader's message
# with no manual scroll (Signal).
for i in $(seq 1 8); do adbs shell input swipe 540 700 540 1900 300; sleep 1; done
send_in_open_chat "resumed $RUN"
sleep 2
"$UI" dump | grep -c "resumed $RUN" >/dev/null \
  && pass QA-213 "a send from older history scrolls into view" \
  || fail QA-213 "the send from older history stayed off-screen"
if "$M" expect "up-p-$RUN" "resumed $RUN" 180 >/dev/null 2>&1; then
  pass QA-192 "after the peer updated, the app's send reached it on v2"
else
  fail QA-192 "the updated peer never received the app's v2 send"
fi
peer_send "up-p-$RUN" "p v2 reply $RUN"
if scroll_until down "p v2 reply $RUN"; then
  pass QA-192b "the peer's v2 reply lands in the same chat as the v1 history (QA-212)"
else
  "$UI" shot "mdk-upgrade-$RUN-qa192b" >/dev/null 2>&1
  back_home
  home_has="$(home_rows | grep -c "p v2 reply $RUN")"
  open_row "p v2 reply $RUN"
  reopen_has="$(scroll_until down "p v2 reply $RUN" && echo yes || echo no)"
  fail QA-192b "the v2 reply did not paint in the open chat (QA-212; home row has it: $home_has, after reopen: $reopen_has)"
fi
back_home
sleep 3
new_rows="$(home_rows | grep -c "p v2 reply $RUN")"
old_rows="$(home_rows | grep -c "p v1 $RUN $SEED_N/$SEED_N")"
[[ "$new_rows" == 1 && "$old_rows" == 0 ]] && pass QA-192c "one chat row for the peer (no leftover v1 row)" \
  || fail QA-192c "rows: v2 preview=$new_rows, leftover v1 preview=$old_rows"

"$M" upgrade-peer "up-q-$RUN" >/dev/null 2>&1
sleep 15  # the peer's v2 KeyPackage must reach the relays first
peer_send "up-q-$RUN" "q v2 first $RUN"
if "$UI" wait "q v2 first $RUN" 180 >/dev/null; then
  open_row "q v2 first $RUN"
  if "$UI" dump | grep -c "q v1 $RUN 2/2" >/dev/null && "$UI" dump | grep -c "q v2 first $RUN" >/dev/null; then
    pass QA-194 "a peer that updates and writes first folds onto its v1 chat"
  else
    fail QA-194 "the peer's v2 welcome did not fold onto its v1 chat"
  fi
  back_home
else
  fail QA-194 "the updated peer's first v2 message never showed"
fi

adbs shell am force-stop "$PKG"; sleep 2; launch
if "$UI" wait "MESSAGES" 60 >/dev/null && sleep 3 && home_rows | grep -c "p v2 reply $RUN" >/dev/null \
   && home_rows | grep -c "q v2 first $RUN" >/dev/null \
   && [[ "$(home_rows | grep -c $'\tNote to Self\t')" == 1 ]]; then
  pass QA-190b "cold restart after the upgrade keeps every chat, one Note to Self"
else
  fail QA-190b "cold restart lost a chat or duplicated Note to Self"
fi
echo "failures: $FAILS"
exit "$FAILS"
