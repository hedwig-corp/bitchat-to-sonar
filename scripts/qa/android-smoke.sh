#!/usr/bin/env bash
# android-smoke.sh — scripted end-to-end smoke of the Compose app on a QA
# emulator against fresh sonar-cli peers. Each scenario maps to an entry in
# docs/QA-SCENARIOS.md; add one here whenever a QA pass finds a bug that can
# be driven headlessly (the registry says which ones are automated).
#
#   QA_SERIAL=emulator-5580 scripts/qa/android-smoke.sh [--only QA-003] [--max-idle-cpu 3]
#   (set QA_APP_NPUB to run a scenario that needs the app's npub with --only)
#
# Preconditions: an ONBOARDED Debug build on a QA emulator
# (scripts/qa/android-setup.sh), network access to the default relays, and the
# app on any screen. Runs ~5 min. Exit status = number of failed scenarios.
# Results: human summary on stdout + $QA_HOME/smoke-<run>.json.
#
# Relies on the spoken labels of icon controls ("Send", "Back",
# "Add to your message", …): if a scenario cannot find one, that is itself an
# accessibility regression (QA-A9), not a flaky script.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export QA_SERIAL="${QA_SERIAL:?set QA_SERIAL (see scripts/qa/android-setup.sh)}"
export QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa}"
UI="$ROOT/scripts/qa/android-ui.sh"
PEERS="$ROOT/scripts/qa/peers.sh"
ONLY=""; MAX_IDLE=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --max-idle-cpu) MAX_IDLE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
RUN="$(date +%m%d%H%M%S)"
RESULTS="$QA_HOME/smoke-$RUN.json"
mkdir -p "$QA_HOME"
declare -a ROWS=()
FAILED=0
APP_NPUB="${QA_APP_NPUB:-}"      # known app npub lets --only run later scenarios alone

record() { # id status detail
  ROWS+=("$1|$2|$3")
  printf '%-4s %-7s %s\n' "$2" "$1" "$3"
  [[ "$2" == FAIL ]] && FAILED=$((FAILED + 1))
  return 0
}
want() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }
ui() { "$UI" "$@" >/dev/null 2>&1; }
has() { [[ -n "$("$UI" find "$1" 2>/dev/null)" ]]; }
hasx() { [[ -n "$("$UI" findx "$1" 2>/dev/null)" ]]; }
ycoord() { "$UI" "$1" "$2" 2>/dev/null | awk '{print $2}'; }
# near_label <exact label> <y> <tolerance> — true when a node with that exact
# text/desc sits on the same row (within tolerance px of y).
near_label() {
  local i xy y
  for i in 1 2 3 4 5 6 7 8; do
    xy="$("$UI" findx "$1" "$i" 2>/dev/null)" || true
    [[ -z "$xy" ]] && return 1
    y="${xy#* }"
    (( y > $2 - $3 && y < $2 + $3 )) && return 0
  done
  return 1
}

go_home() {
  adb -s "$QA_SERIAL" shell am start -n chat.bitchat.sonar/.MainActivity >/dev/null 2>&1
  for _ in 1 2 3 4 5; do
    sleep 1
    hasx "Start a chat" && return 0
    ui key 4
  done
  hasx "Start a chat"
}

open_chat_by_npub() {
  go_home || return 1
  ui tapx "Search"; sleep 1
  ui tapedit; sleep 0.5                 # the search field (placeholder is not exposed)
  ui type "$1"
  "$UI" wait "Start secure chat" 10 >/dev/null || return 1
  ui tapx "Start secure chat" -1        # the button, not the row title
  "$UI" wait "Say hi to" 15 >/dev/null
}

focus_composer() {
  ui tapedit                            # the only editable field in a chat
  sleep 1
}

# --- scenarios ---------------------------------------------------------------

qa001() { # first message in a new chat: delivered, keyboard stays up (A10)
  A_NPUB="$("$PEERS" new "a-$RUN")" || { record QA-001 FAIL "peer init failed"; return; }
  open_chat_by_npub "$A_NPUB" || { record QA-001 FAIL "could not open a chat by npub from Search"; return; }
  focus_composer
  ui type "qa001 hello $RUN"
  ui tapx "Send" || { record QA-001 FAIL "no 'Send' control (QA-A9 label missing?)"; return; }
  sleep 2
  local ime; ime="$("$UI" ime)"
  "$UI" wait "Sent ·" 60 >/dev/null || { record QA-001 FAIL "bubble never reached 'Sent'"; return; }
  local got; got="$("$PEERS" expect "a-$RUN" "qa001 hello $RUN" 60 2>/dev/null)"
  [[ -n "$got" ]] || { record QA-001 FAIL "peer never received the first message"; return; }
  APP_NPUB="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["sender"])' "$got")"
  if [[ "$ime" != shown ]]; then
    record QA-001 FAIL "delivered, but the keyboard closed after the first send (QA-A10)"
  else
    record QA-001 PASS "delivered; keyboard stayed up"
  fi
}

qa002() { # reply arrives in the open chat
  [[ -n "${A_NPUB:-}" && -n "$APP_NPUB" ]] || { record QA-002 SKIP "needs QA-001"; return; }
  local t0=$SECONDS
  "$PEERS" send "a-$RUN" "$APP_NPUB" "qa002 reply $RUN" >/dev/null
  if "$UI" wait "qa002 reply $RUN" 30 >/dev/null; then
    record QA-002 PASS "reply visible $((SECONDS - t0))s after the peer started sending (incl. CLI publish)"
  else
    record QA-002 FAIL "reply not visible in the open chat within 30s"
  fi
}

qa003() { # draft typed while the chat is pending survives reconcile (A19)
  local b; b="$("$PEERS" new "b-$RUN")" || { record QA-003 FAIL "peer init failed"; return; }
  open_chat_by_npub "$b" || { record QA-003 FAIL "could not open chat"; return; }
  focus_composer
  ui type "qa003 draft $RUN"
  sleep 20                                  # pending → real group reconcile
  if ! has "qa003 draft $RUN"; then
    record QA-003 FAIL "draft typed during pending setup vanished (QA-A19)"; return
  fi
  ui tapx "Send"
  if "$PEERS" expect "b-$RUN" "qa003 draft $RUN" 60 >/dev/null; then
    record QA-003 PASS "draft survived reconcile and was delivered"
  else
    record QA-003 FAIL "draft survived but never reached the peer"
  fi
}

qa004() { # inbound-first chat appears on the chat list, marked unread
  [[ -n "$APP_NPUB" ]] || { record QA-004 SKIP "needs the app npub from QA-001"; return; }
  "$PEERS" new "c-$RUN" >/dev/null || { record QA-004 FAIL "peer init failed"; return; }
  go_home || { record QA-004 FAIL "could not reach the chat list"; return; }
  local t0=$SECONDS
  "$PEERS" send "c-$RUN" "$APP_NPUB" "qa004 inbound $RUN" >/dev/null
  if ! "$UI" wait "qa004 inbound $RUN" 45 >/dev/null; then
    record QA-004 FAIL "inbound-first chat did not appear within 45s"; return
  fi
  local t1=$((SECONDS - t0)) ry
  # The unread dot is announced as "Unread" (A29) — and it must be on THIS
  # row, not on some older unread chat further down the list.
  ry="$(ycoord find "qa004 inbound $RUN")"
  if [[ -n "$ry" ]] && near_label "Unread" "$ry" 120; then
    record QA-004 PASS "new chat row after ${t1}s, marked unread"
  else
    record QA-004 FAIL "row appeared after ${t1}s but has no unread indicator"
  fi
}

qa005() { # divider sits exactly between the last read row and the first unread one (A12)
  has "qa004 inbound $RUN" || { record QA-005 SKIP "needs QA-004"; return; }
  # Read QA-004's message, leave, then receive TWO more while on the list:
  # the boundary now has a read row above it and two unread rows below.
  ui tapt "qa004 inbound $RUN"
  "$UI" wait "Back" 10 >/dev/null; sleep 2
  go_home || { record QA-005 FAIL "could not reach the chat list"; return; }
  "$PEERS" send "c-$RUN" "$APP_NPUB" "qa005 unread one $RUN" >/dev/null
  "$PEERS" send "c-$RUN" "$APP_NPUB" "qa005 unread two $RUN" >/dev/null
  "$UI" wait "qa005 unread two $RUN" 45 >/dev/null || { record QA-005 FAIL "second unread never reached the list"; return; }
  ui tapt "qa005 unread two $RUN"
  "$UI" wait "Unread messages" 10 >/dev/null || { record QA-005 FAIL "no unread divider on open"; return; }
  local ry dy u1 u2
  ry="$(ycoord find "qa004 inbound $RUN")"; dy="$(ycoord findx "Unread messages")"
  u1="$(ycoord find "qa005 unread one $RUN")"; u2="$(ycoord find "qa005 unread two $RUN")"
  # Strict order read < divider < first unread < second unread catches the
  # divider one row too high (above the read row) or too low (between unreads).
  if [[ -n "$ry" && -n "$dy" && -n "$u1" && -n "$u2" ]] && (( ry < dy && dy < u1 && u1 < u2 )); then
    record QA-005 PASS "read row | divider | 2 unread rows, in order"
  else
    record QA-005 FAIL "order read=$ry divider=$dy unread1=$u1 unread2=$u2 (want strictly increasing)"
  fi
}

qa040() { # chat, home and search controls carry spoken labels (A9/A21)
  local missing=() label
  # Chat screen (QA-005 left QA-004's chat open).
  for label in "Add to your message" "Emoji and stickers" "Back"; do
    hasx "$label" || missing+=("chat:$label")
  done
  hasx "Send" || hasx "Record voice message" || missing+=("chat:Send/Record voice message")
  # uiautomator marks an edit field with no spoken label NAF (shown as E!).
  "$UI" dump 2>/dev/null | awk -F'\t' '$2 == "E!"' | grep -q . && missing+=("chat:composer field")
  # Home.
  if go_home; then
    for label in "Settings" "Start a chat" "Nearby"; do hasx "$label" || missing+=("home:$label"); done
  else
    missing+=("home:unreachable")
  fi
  # Search field.
  if ui tapx "Search"; then
    sleep 1
    "$UI" dump 2>/dev/null | awk -F'\t' '$2 == "E!"' | grep -q . && missing+=("search:field")
  else
    missing+=("search:unreachable")
  fi
  go_home >/dev/null
  if (( ${#missing[@]} == 0 )); then
    record QA-040 PASS "chat, home and search controls labelled"
  else
    record QA-040 FAIL "unlabelled: ${missing[*]} (QA-A9/A21)"
  fi
}

qa007() { # a partial npub offers no chat or channel action (A18)
  [[ -n "${A_NPUB:-}" ]] || A_NPUB="npub1pqm5mzn6ph0ldzd2ldflq9g9xv25yc5tqrzkyll042mggs40p5fsh2d6mz"
  go_home || { record QA-007 FAIL "could not reach the chat list"; return; }
  ui tapx "Search"; sleep 1; ui tapedit; sleep 0.5
  ui type "${A_NPUB:0:9}"; sleep 1.5
  local bad=()
  hasx "Start secure chat" && bad+=("Start secure chat")
  hasx "Join channel" && bad+=("Join channel")
  if (( ${#bad[@]} )); then
    record QA-007 FAIL "partial npub offered: ${bad[*]} (QA-A18)"; go_home >/dev/null; return
  fi
  # Positive path: the complete npub must still offer the chat, or a search
  # that rejects every npub would pass the check above.
  go_home >/dev/null; ui tapx "Search"; sleep 1; ui tapedit; sleep 0.5
  ui type "$A_NPUB"
  if "$UI" wait "Start secure chat" 10 >/dev/null; then
    record QA-007 PASS "partial npub: no action; complete npub: Start secure chat"
  else
    record QA-007 FAIL "a complete npub no longer offers Start secure chat"
  fi
  go_home >/dev/null
}

qa041() { # the profile "scan this to add you" code is a real QR of the npub (A25)
  [[ -n "$APP_NPUB" ]] || { record QA-041 SKIP "needs the app npub from QA-001"; return; }
  command -v swift >/dev/null || { record QA-041 SKIP "needs macOS swift (CoreImage) to decode"; return; }
  go_home || { record QA-041 FAIL "could not reach the chat list"; return; }
  ui tapx "Settings"; sleep 1.5
  ui tapt "${APP_NPUB:0:12}"; sleep 2.5              # the profile card on Settings
  local png; png="$("$UI" shot "qa041-$RUN")"; png="${png%.png}-full.png"
  local decoded; decoded="$(swift "$ROOT/scripts/qa/qr-decode.swift" "$png" 2>/dev/null | tail -1)"
  if [[ "$decoded" == "$APP_NPUB" ]]; then
    record QA-041 PASS "profile QR decodes to the app npub"
  else
    record QA-041 FAIL "profile QR decodes to '${decoded:-nothing}', expected the app npub (QA-A25)"
  fi
  go_home >/dev/null
}

qa043() { # no unlabelled interactive node on the main screens (A9/A21/A22/A28)
  local bad=() entry
  naf_check() { # label — a failed dump is a failure, never an empty (passing) sweep
    local out
    if ! out="$("$UI" naf 2>/dev/null)"; then bad+=("$1:dump-failed"); return; fi
    [[ -z "$out" ]] || bad+=("$1:$(printf '%s\n' "$out" | wc -l | tr -d ' ')")
  }
  sweep() { # label control settle — a control that cannot be tapped fails the screen
    go_home >/dev/null || { bad+=("$1:home-unreachable"); return; }
    if ui tapx "$2"; then sleep "$3"; naf_check "$1"; else bad+=("$1:no '$2' control"); fi
    ui key 4
  }
  go_home || { record QA-043 FAIL "could not reach the chat list"; return; }
  naf_check home
  sweep search "Search" 1.5
  sweep start-chat "Start a chat" 1.5
  sweep nearby "Nearby" 2
  sweep settings "Settings" 1.5
  if [[ -n "${A_NPUB:-}" ]]; then
    go_home >/dev/null
    if ui tapt "qa001 hello $RUN"; then
      sleep 2; naf_check chat
      ui tap 400 188; sleep 2; naf_check contact-profile   # header → contact profile
    else
      bad+=("chat:QA-001 row not found")
    fi
    go_home >/dev/null
  fi
  if (( ${#bad[@]} == 0 )); then
    record QA-043 PASS "no NAF nodes on the swept screens"
  else
    record QA-043 FAIL "unlabelled nodes (screen:count): ${bad[*]} — run android-ui.sh naf there"
  fi
}

qa050() { # idle CPU on the chat list
  go_home >/dev/null; sleep 10
  local out; out="$("$ROOT/scripts/qa/idle-cpu.sh" android "$QA_SERIAL" 30 --max "$MAX_IDLE" 2>&1)"
  if [[ $? -eq 0 ]]; then record QA-050 PASS "$out"; else record QA-050 FAIL "$out (max $MAX_IDLE%)"; fi
}

echo "Sonar Android smoke — run $RUN on $QA_SERIAL (peers in $QA_HOME/peers)"
# Order matters: QA-002 reuses QA-001's chat, QA-005 opens QA-004's, and
# QA-040 inspects the chat QA-005 left open.
for s in qa001 qa002 qa003 qa004 qa005 qa040 qa007 qa041 qa043 qa050; do
  id="QA-${s#qa}"
  want "$id" || continue
  "$s"
done

python3 - "$RESULTS" "$RUN" "$QA_SERIAL" "${ROWS[@]}" <<'PY'
import json, sys
path, run, serial, rows = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
out = {"run": run, "serial": serial, "scenarios": [
    dict(zip(("id", "status", "detail"), r.split("|", 2))) for r in rows]}
json.dump(out, open(path, "w"), indent=2)
PY
echo "results: $RESULTS — $FAILED failed"
exit "$FAILED"
