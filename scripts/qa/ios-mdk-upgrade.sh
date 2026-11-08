#!/usr/bin/env bash
# ios-mdk-upgrade.sh — app-level MDK v1 (0.8) -> v2 upgrade on a DEDICATED iOS
# simulator (QA-190, 191, 193, 192, 212, 194, 195, 210). Prints PASS/FAIL per
# scenario; exit status = failures. The iOS twin of android-mdk-upgrade.sh.
#
#   QA_UDID=<udid> V1_APP=<main's Sonar.app> MDK08_CLI=<main's sonar-cli> \
#     scripts/qa/ios-mdk-upgrade.sh
#
# Env:
#   QA_UDID     a simulator made for QA (ios-setup.sh names them "Sonar QA …").
#               The script ERASES it first: `simctl uninstall` keeps the
#               simulator keychain and the App Group store, so a new bench
#               identity could not open the old store. It refuses any simulator
#               whose name does not start with "Sonar QA".
#   V1_APP      main's signed Debug app (MDK 0.8). Build it from a second
#               checkout with scripts/qa/ios-setup.sh there; the app is in that
#               checkout's QA DerivedData (…/DerivedData/sonar-qa-<dir>/…).
#   V2_APP      this tree's signed Debug app (default: this worktree's
#               ios-setup.sh DerivedData)
#   MDK08_CLI   main's sonar-cli (MDK 0.8); SONAR_CLI the v2 one
#   SEED_N      messages the first peer sends on v1 (default 85: past the
#               80-row first-paint window, so QA-191 pages into the remainder
#               the migration leaves in *.mdk08.bak)
#
# The app runs on a throwaway `sonar-cli init` identity handed over as
# SONAR_BENCH_NSEC (DEBUG builds only), so no real account is involved. Peers
# and app use the default public relays, so this needs network.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa-$(basename "$ROOT")}"
export QA_UDID="${QA_UDID:?set QA_UDID to a dedicated QA simulator}"
V1_APP="${V1_APP:?set V1_APP to the signed Debug Sonar.app built from main}"
V2_APP="${V2_APP:-$HOME/Library/Developer/Xcode/DerivedData/sonar-qa-$(basename "$ROOT")/Build/Products/Debug-iphonesimulator/Sonar.app}"
export MDK08_CLI="${MDK08_CLI:?set MDK08_CLI to the sonar-cli built from main}"
SONAR_CLI="${SONAR_CLI:-$ROOT/core/target/release/sonar-cli}"
SEED_N="${SEED_N:-85}"
M="$ROOT/scripts/qa/mdk-upgrade.sh"
DRIVE="$ROOT/scripts/qa/ios-drive.sh"
BUNDLE=sh.hedwig.sonar
RUN="$(date +%s)"
FAILS=0

pass() { echo "PASS $1 $2"; }
fail() { echo "FAIL $1 $2"; FAILS=$((FAILS + 1)); }
drive() { "$DRIVE" --nsec-file "$APP_HOME/config.json" "iup-$RUN-$1" "$2" >/dev/null 2>&1; }
tree() { cat "$QA_HOME/idrive/iup-$RUN-$1/$2.txt" 2>/dev/null; }
# Home rows only: one row exposes its preview twice (the row button and its
# text), so count the row buttons.
rows() { tree "$1" "$2" | grep -E "^ *Button," | grep -oE "label: '[^']*'" ; }
# Under pipefail a `grep -q` that stops reading early SIGPIPEs the producer and
# turns a match into a failure: capture first, then test.
has() { grep -c -- "$1" >/dev/null <<<"$2"; }
peer_send() { # peer_send <peer> <text>: retried, a dropped publish is not a test result
  local t out
  for t in 1 2 3 4; do
    out="$("$M" send "$1" "$APP" "$2" 2>/dev/null)"
    has '"type":"sent"' "$out" && return 0
    sleep $((t * 5))
  done
  echo "peer $1 could not send '$2'" >&2; return 1
}
# Typing right after the tap can land before the composer has focus, and the
# first keyboard use on a just-erased simulator swallows the text: type a
# throwaway character and delete it before the real text.
BS=$'\b'
type_send() { echo "activate;tapid:sonar-message-composer;wait:2;type:x;wait:1;type:$BS;wait:1;type:$1;wait:1;tap:Send"; }

name="$(xcrun simctl list devices | sed -nE "s/^[[:space:]]+(.*) \($QA_UDID\).*/\1/p" | head -1)"
[[ "$name" == "Sonar QA"* ]] || { echo "refusing: $QA_UDID ('$name') is not a 'Sonar QA' simulator" >&2; exit 2; }
for a in "$V1_APP" "$V2_APP"; do [[ -d "$a" ]] || { echo "no app at $a" >&2; exit 2; }; done

# --- fresh v1 install with history ------------------------------------------
xcrun simctl shutdown "$QA_UDID" >/dev/null 2>&1
xcrun simctl erase "$QA_UDID" || { echo "could not erase $QA_UDID" >&2; exit 2; }
xcrun simctl boot "$QA_UDID"; xcrun simctl bootstatus "$QA_UDID" -b >/dev/null
xcrun simctl install "$QA_UDID" "$V1_APP" || { echo "v1 install failed" >&2; exit 2; }
# A just-erased simulator spends its first minute building caches, and the
# first launch of a fresh install kept the app's main thread busy past
# XCUITest's 30 s snapshot limit. Warm both up before driving (the app stays
# on onboarding: without SONAR_BENCH_NSEC it creates no identity).
sleep 30
xcrun simctl launch "$QA_UDID" "$BUNDLE" >/dev/null 2>&1; sleep 25
xcrun simctl terminate "$QA_UDID" "$BUNDLE" >/dev/null 2>&1; sleep 2
APP_HOME="$QA_HOME/ios-up-$RUN"
"$SONAR_CLI" --home "$APP_HOME" init >/dev/null 2>&1
APP="$("$SONAR_CLI" --home "$APP_HOME" identity 2>/dev/null \
  | python3 -c 'import json,sys; print(json.loads([l for l in sys.stdin if l.startswith("{")][-1])["npub"])')"
[[ -n "$APP" ]] || { echo "could not create the app identity" >&2; exit 2; }
drive v1-launch "launch;sbtap:Allow;expect:MESSAGES@90" \
  || { echo "v1 app did not reach Messages" >&2; exit 2; }
sleep 10  # the v1 KeyPackage must reach the relays before peers can invite

P="ip-p-$RUN"; Q="ip-q-$RUN"
"$M" peer "$P" 08 >/dev/null 2>&1; "$M" peer "$Q" 08 >/dev/null 2>&1
seed() { # seed <peer> <n> <prefix>: per-message retries for public-relay hiccups
  local i t out
  for i in $(seq 1 "$2"); do
    for t in 1 2 3 4 5; do
      out="$("$MDK08_CLI" --home "$QA_HOME/peers/$1" send --to "$APP" --text "$3 $i/$2" \
        --push-settle-secs 0 2>/dev/null)"
      has '"type"' "$out" && break
      [[ $t == 5 ]] && return 1
      sleep $((t * 3))
    done
  done
}
seed "$P" "$SEED_N" "p v1 $RUN" || { echo "v1 baseline: seeding $P failed" >&2; exit 2; }
seed "$Q" 1 "q v1 $RUN" || { echo "v1 baseline: seeding $Q failed" >&2; exit 2; }
TARGET="$("$M" id-of "$P" "p v1 $RUN 1/$SEED_N" 2>/dev/null)"
reacted=0
for t in 1 2 3 4; do
  out="$("$M" react "$P" "$APP" "$TARGET" "👍" 2>/dev/null)"
  has '"type":"reacted"' "$out" && { reacted=1; break; }
  sleep $((t * 3))
done
(( reacted )) || { echo "v1 baseline: the peer's 👍 never published" >&2; exit 2; }
drive v1-seeded "activate;expect:p v1 $RUN $SEED_N/$SEED_N@180;expect:q v1 $RUN 1/1@180" \
  || { echo "v1 baseline: history never reached the app" >&2; exit 2; }

# --- upgrade in place -------------------------------------------------------
xcrun simctl terminate "$QA_UDID" "$BUNDLE" >/dev/null 2>&1
xcrun simctl install "$QA_UDID" "$V2_APP" || { echo "v2 install failed — stop, do not uninstall" >&2; exit 2; }
mark="$(date '+%Y-%m-%d %H:%M:%S')"
if drive v2-launch "launch;expect:MESSAGES@90;expect:p v1 $RUN $SEED_N/$SEED_N@60;expect:q v1 $RUN 1/1@30;tree:home"; then
  paint="$(xcrun simctl spawn "$QA_UDID" log show --info --start "$mark" --style compact \
    --predicate 'subsystem == "chat.bitchat" AND eventMessage CONTAINS "SONAR_BENCH t"' 2>/dev/null \
    | python3 -c '
import re, sys
t = {}
for line in sys.stdin:
    m = re.match(r"\S+ (\d+):(\d+):(\d+\.\d+).*SONAR_BENCH (t\w+)", line)
    if m and m.group(4) not in t:
        t[m.group(4)] = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
if "t0_launch" in t and "t1b_home_appear" in t:
    print("%.2fs" % (t["t1b_home_appear"] - t["t0_launch"]))
else:
    print("n/a")')"
  pass QA-190 "upgrade kept both v1 chats (launch→home ${paint})"
else
  fail QA-190 "v1 chats missing after the upgrade"
fi
n="$(rows v2-launch home | grep -c "^label: 'Note to Self, ")"
[[ "$n" == 1 ]] && pass QA-210 "one Note to Self row after the upgrade" || fail QA-210 "$n Note to Self rows"
store="$("$M" store "$QA_UDID" 2>/dev/null)"
has 'mdk08.bak' "$store" \
  && pass QA-195 "v1 store quarantined as *.mdk08.bak" || fail QA-195 "no *.mdk08.bak in the App Group"

swipes="$(printf 'swipedown;%.0s' $(seq 1 30))"
drive open-p "activate;tapc:p v1 $RUN $SEED_N/$SEED_N;expect:p v1 $RUN $SEED_N/$SEED_N@20;${swipes}expect:p v1 $RUN 1/$SEED_N@20;expect:👍@15" \
  && pass QA-191 "the v1 history and its 👍 chip are in the chat" \
  || fail QA-191 "v1 history or the v1 👍 chip missing"
# No expect on the typed text: a send that cannot reach a v1 peer drops its
# echo by design; the banner is the signal.
drive wait-v1 "$(type_send "waiting $RUN");expect:Waiting for them to update@40" \
  && pass QA-193 "peer still on v1: 'Waiting for them to update Sonar'" \
  || fail QA-193 "no waiting banner while the peer is on v1"

"$M" upgrade-peer "$P" >/dev/null 2>&1
sleep 15  # the peer's v2 KeyPackage must reach the relays (see android-mdk-upgrade.sh)
# QA-213: send from older history; the view must follow the reader's message
# with no manual scroll (Signal). The view is back near message 1 first.
up="$(printf 'swipedown;%.0s' $(seq 1 15))"
drive send-v2 "activate;${up}$(type_send "resumed $RUN" | sed 's/^activate;//');expect:resumed $RUN@20" \
  && pass QA-213 "a send from older history scrolls into view" \
  || fail QA-213 "the send from older history stayed off-screen"
if "$M" expect "$P" "resumed $RUN" 180 >/dev/null 2>&1; then
  pass QA-192 "after the peer updated, the app's send reached it on v2"
else
  fail QA-192 "the updated peer never received the app's v2 send"
fi
peer_send "$P" "p v2 reply $RUN"
drive live "activate;expect:p v2 reply $RUN@90" \
  && pass QA-212 "the peer's v2 reply paints in the chat that folded while open" \
  || fail QA-212 "the v2 reply did not paint in the open chat"
drive back "activate;tap:Back;expect:MESSAGES@15;tree:home"
new_rows="$(rows back home | grep -c ", p v2 reply $RUN, ")"
old_rows="$(rows back home | grep -c ", p v1 $RUN $SEED_N/$SEED_N, ")"
[[ "$new_rows" == 1 && "$old_rows" == 0 ]] && pass QA-192c "one chat row for the peer (no leftover v1 row)" \
  || fail QA-192c "rows: v2 preview=$new_rows, leftover v1 preview=$old_rows"
drive reopen "activate;tapc:p v2 reply $RUN;expect:Verify@15;expect:p v1 $RUN $SEED_N/$SEED_N@15;expect:resumed $RUN@10;tap:Back;expect:MESSAGES@15" \
  && pass QA-212b "after leaving, the row opens the folded chat with its v1 history" \
  || fail QA-212b "the folded chat's row did not reopen it"

"$M" upgrade-peer "$Q" >/dev/null 2>&1
sleep 15  # the peer's v2 KeyPackage must reach the relays first
peer_send "$Q" "q v2 first $RUN"
drive q-first "activate;expect:q v2 first $RUN@180;tapc:q v2 first $RUN;expect:q v1 $RUN 1/1@20;expect:q v2 first $RUN@10;tap:Back;expect:MESSAGES@15" \
  && pass QA-194 "a peer that updates and writes first folds onto its v1 chat" \
  || fail QA-194 "the updated peer's first v2 message did not fold onto its v1 chat"

xcrun simctl terminate "$QA_UDID" "$BUNDLE" >/dev/null 2>&1; sleep 2
if drive cold "launch;expect:p v2 reply $RUN@60;expect:q v2 first $RUN@30;tree:home" \
   && [[ "$(rows cold home | grep -c "^label: 'Note to Self, ")" == 1 ]]; then
  pass QA-190b "cold restart after the upgrade keeps every chat, one Note to Self"
else
  fail QA-190b "cold restart lost a chat or duplicated Note to Self"
fi
echo "failures: $FAILS (artifacts: $QA_HOME/idrive/iup-$RUN-*)"
exit "$FAILS"
