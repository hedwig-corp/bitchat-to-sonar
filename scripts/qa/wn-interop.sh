#!/usr/bin/env bash
# wn-interop.sh — Sonar ↔ White Noise interop QA, headless (QA-078…QA-085).
#
# White Noise iOS runs MDK's own runtime (marmot-app). The MDK checkout Sonar
# pins ships the White Noise CLI (`crates/cli`: `wn` + daemon `wnd`) on that
# same runtime, so it stands in for a White Noise user against `sonar-cli`.
#
#   wn-interop.sh setup                build wn/wnd from the pinned MDK rev, start
#                                      wnd, create the White Noise identity
#   wn-interop.sh run [--members N]    the whole matrix; prints PASS/FAIL per
#                                      scenario id, exit status = failures
#   wn-interop.sh teardown             stop wnd
#
# Env:
#   RELAY      relay both clients use (default ws://127.0.0.1:17447). It must
#              serve kind-1059 to unauthenticated readers (sonar-core has no
#              NIP-42) and accept events of 64 KiB+ (a 25-member welcome is
#              ~38 KB). Stock `relayer`-based relays reject both: run one with
#              those limits lifted, or a public relay both clients reach.
#   SONAR_CLI  sonar-cli under test (default core/target/release/sonar-cli)
#   QA_HOME    artifacts (default $TMPDIR/sonar-qa-<worktree>)
#
# What this does NOT cover: the White Noise iOS app itself (UI, push), public
# relay overlap, and relays that require NIP-42.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa-$(basename "$ROOT")}"
RELAY="${RELAY:-ws://127.0.0.1:17447}"
SCLI="${SONAR_CLI:-$ROOT/core/target/release/sonar-cli}"
Q="$QA_HOME/wn-interop"
export WN_HOME="$Q/wn" WN_SECRET_STORE=file WN_ALLOW_LOOPBACK_RELAYS=1
# A Unix socket path must stay under 104 bytes, and wnd derives a longer
# temporary path from it: keep it short but stable per worktree.
export WN_SOCKET="${TMPDIR:-/tmp/}"
WN_SOCKET="${WN_SOCKET%/}/wnqa-$(printf %s "$Q" | cksum | cut -c1-6).sock"
WN_BIN="$Q/wn-target/release"
export PATH="$WN_BIN:$PATH" # `wn daemon start` spawns `wnd`
FAILS=0

die() { echo "wn-interop: $*" >&2; exit 2; }
wn() { "$WN_BIN/wn" --json "$@"; }
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
pass() { echo "PASS $1 $2"; }
fail() { echo "FAIL $1 $2"; FAILS=$((FAILS + 1)); }

mdk_checkout() {
  local rev
  rev=$(grep -oE 'marmot-protocol/mdk", rev = "[0-9a-f]+' "$ROOT/core/Cargo.toml" | head -1 | grep -oE '[0-9a-f]{40}')
  [ -n "$rev" ] || die "no MDK rev in core/Cargo.toml"
  local dir
  dir=$(ls -d "${CARGO_HOME:-$HOME/.cargo}"/git/checkouts/mdk-*/"${rev:0:7}" 2>/dev/null | head -1)
  [ -n "$dir" ] || die "MDK $rev not checked out; run a core build first"
  echo "$dir"
}

sonar() { # sonar <home> <verb> [args]
  local home=$1; shift
  "$SCLI" --home "$Q/$home" "$@" --relay "$RELAY" 2>/dev/null | grep '^{' || true
}

sonar_npub() { "$SCLI" --home "$Q/$1" identity 2>/dev/null | jget 'd["npub"]'; }

sonar_new() { # sonar_new <home>
  [ -f "$Q/$1/config.json" ] || "$SCLI" --home "$Q/$1" init --relay "$RELAY" >/dev/null 2>&1
  sonar "$1" publish >/dev/null
}

sonar_listen() { # sonar_listen <home> [secs]
  timeout 90 "$SCLI" --home "$Q/$1" listen --relay "$RELAY" --timeout-secs "${2:-10}" \
    --poll-secs 3 --no-publish 2>/dev/null | grep '^{' || true
}

sonar_has() { # sonar_has <home> <group> <text>
  sonar "$1" messages --group "$2" | grep -qF "\"content\":\"$3\""
}

sonar_members() { # sonar_members <home> <group>
  sonar "$1" groups | python3 -c "
import json,sys
for l in sys.stdin:
    g=json.loads(l)
    if g['id']=='$2': print(len(g['members']))"
}

sonar_accept_named() { # sonar_accept_named <home> <group-name>
  local id
  id=$(sonar "$1" invites | python3 -c "
import json,sys
for l in sys.stdin:
    i=json.loads(l)
    if i.get('name')=='$2': print(i['id']); break")
  [ -z "$id" ] || sonar "$1" accept "$id" >/dev/null
}

wn_has() { # wn_has <group> <text>
  # wnd does not backfill what arrived before an accept until a sync, which
  # the app runs when a chat opens.
  wn --account "$W" sync >/dev/null 2>&1 || true
  wn --account "$W" messages list "$1" --limit 50 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); r=d.get('result')
rows=r if isinstance(r,list) else (r or {}).get('messages',[])
sys.exit(0 if any((m.get('plaintext') or '')==sys.argv[1] for m in rows) else 1)" "$2"
}

wn_members() { wn --account "$W" groups members "$1" 2>/dev/null | jget 'len(d["result"]["members"])'; }

eventually() { # eventually <secs> <cmd…>: retry until it succeeds
  local deadline=$((SECONDS + $1)); shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 3
  done
}

png() { # png <path> <seed>: a small unique image
  python3 - "$1" "$2" <<'PY'
import struct, zlib, sys
w = h = 16; s = int(sys.argv[2])
raw = b"".join(b"\0" + b"".join(bytes([(x * s) % 256, (y * 7) % 256, s % 256]) for x in range(w)) for y in range(h))
ch = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b""))
PY
}

sha() { shasum -a 256 "$1" | cut -c1-64; }

cmd_setup() {
  mkdir -p "$Q"
  if [ ! -x "$WN_BIN/wn" ]; then
    cargo build --release --locked --manifest-path "$(mdk_checkout)/Cargo.toml" \
      -p wn-cli --bins --target-dir "$Q/wn-target" >&2
  fi
  local started
  started=$(wn daemon start --discovery-relays "$RELAY" --default-account-relays "$RELAY" 2>&1 || true)
  case "$started" in
    *'"ok":true'* | *already*) ;;
    *) die "wnd did not start: $started" ;;
  esac
  # A daemon already on this socket must serve this home (and this build).
  local home
  home=$(wn daemon status 2>/dev/null | jget 'd["result"]["home"]' 2>/dev/null || true)
  [ "$home" = "$WN_HOME" ] || die "wnd on $WN_SOCKET serves '${home:-?}', not $WN_HOME; run teardown"
  if [ ! -s "$Q/w.npub" ]; then
    wn create-identity | jget 'd["result"]["npub"]' >"$Q/w.npub"
  fi
  echo "White Noise identity: $(cat "$Q/w.npub")"
}

cmd_teardown() { wn daemon stop >/dev/null 2>&1 || true; }

cmd_run() {
  local n=25
  [ "${1:-}" = "--members" ] && n=$2
  [ -s "$Q/w.npub" ] || die "run 'setup' first"
  W=$(cat "$Q/w.npub")
  local run
  run=$(date +%s)
  sonar_new a; sonar_new b
  local A B
  A=$(sonar_npub a); B=$(sonar_npub b)
  for npub in "$A" "$B"; do wn keys fetch "$npub" --bootstrap-relays "$RELAY" >/dev/null 2>&1 || true; done

  # QA-078: White Noise starts a DM with a Sonar user (KeyPackage accepted,
  # capabilities met, welcome routed by the kind-10050 inbox list).
  local g
  g=$(wn --account "$W" groups create "" "$A" | jget 'd["result"]["group_id"]') || g=""
  if [ -n "$g" ]; then
    wn --account "$W" messages send "$g" "wn hello $run" >/dev/null
    sonar_listen a 12 >/dev/null
    if sonar_has a "$g" "wn hello $run"; then pass QA-078 "White Noise → Sonar DM"; else fail QA-078 "Sonar never got the DM"; fi
  else
    fail QA-078 "White Noise could not create a chat with Sonar"
  fi

  # QA-079: the Sonar reply lands in the same chat (no split).
  local sent
  sent=$(sonar a send --to "$W" --text "sonar reply $run" | jget 'd["group_id"]' || true)
  if [ "$sent" = "$g" ] && eventually 30 wn_has "$g" "sonar reply $run"; then
    pass QA-079 "Sonar replies in White Noise's DM"
  else
    fail QA-079 "reply went to ${sent:-nowhere} (want $g) or never reached White Noise"
  fi

  # QA-080: Sonar starts a DM with a White Noise user.
  local g2
  g2=$(sonar b send --to "$W" --text "sonar starts $run" | jget 'd["group_id"]' || true)
  sleep 4
  wn --account "$W" groups accept "$g2" >/dev/null 2>&1 || true
  wn --account "$W" messages send "$g2" "wn answers $run" >/dev/null 2>&1 || true
  sonar_listen b 10 >/dev/null
  if eventually 30 wn_has "$g2" "sonar starts $run" && sonar_has b "$g2" "wn answers $run"; then
    pass QA-080 "Sonar → White Noise DM, both directions"
  else
    fail QA-080 "Sonar-started DM did not carry both ways"
  fi

  # QA-081: a White Noise group with two Sonar members.
  local g3
  g3=$(wn --account "$W" groups create "wn-grp-$run" "$A" "$B" | jget 'd["result"]["group_id"]' || true)
  wn --account "$W" messages send "$g3" "wn group $run" >/dev/null 2>&1 || true
  for h in a b; do sonar_listen "$h" 10 >/dev/null; sonar_accept_named "$h" "wn-grp-$run"; done
  sonar a group-send --group "$g3" --text "a in wn group $run" >/dev/null
  sonar_listen b 8 >/dev/null
  if sonar_has b "$g3" "wn group $run" && sonar_has b "$g3" "a in wn group $run" &&
    eventually 30 wn_has "$g3" "a in wn group $run"; then
    pass QA-081 "White Noise group with Sonar members"
  else
    fail QA-081 "White Noise group did not deliver every way"
  fi

  # QA-082: a Sonar group with a White Noise member (and it requires media V2).
  local g4
  g4=$(sonar b group-create --name "sonar-grp-$run" --member "$W" --member "$A" | jget 'd["group_id"]' || true)
  sonar b group-send --group "$g4" --text "b created $run" >/dev/null
  sleep 4
  wn --account "$W" groups accept "$g4" >/dev/null 2>&1 || true
  wn --account "$W" messages send "$g4" "wn in sonar group $run" >/dev/null 2>&1 || true
  sonar_listen a 8 >/dev/null; sonar_accept_named a "sonar-grp-$run"; sonar_listen a 8 >/dev/null
  local media_required
  media_required=$(wn --account "$W" groups show "$g4" 2>/dev/null | python3 -c "
import json,sys
def f(o):
    if isinstance(o,dict):
        if 'encrypted_media' in o: return o['encrypted_media']
        for v in o.values():
            x=f(v)
            if x: return x
em=f(json.load(sys.stdin)) or {}
print(em.get('component_id'), em.get('required'))")
  if eventually 30 wn_has "$g4" "b created $run" && sonar_has a "$g4" "wn in sonar group $run" &&
    [ "$media_required" = "32779 True" ]; then
    pass QA-082 "Sonar group with a White Noise member (media V2 required)"
  else
    fail QA-082 "Sonar group interop failed (media component: $media_required)"
  fi

  # QA-083: encrypted media both ways (MDK 0.9 encrypted-media-v2).
  png "$Q/s-$run.png" 11; png "$Q/w-$run.png" 23
  sonar a send --to "$W" --file "$Q/s-$run.png" --kind image >/dev/null
  local hs ok_s=1
  hs=$(sha "$Q/s-$run.png")
  eventually 30 sh -c "'$WN_BIN/wn' --json --account '$W' media list '$g' 2>/dev/null | grep -q '$hs'" &&
    wn --account "$W" media download "$g" "$hs" --output "$Q/s-got-$run.png" >/dev/null 2>&1 &&
    [ "$(sha "$Q/s-got-$run.png")" = "$hs" ] || ok_s=0
  wn --account "$W" media upload "$g4" "$Q/w-$run.png" --send --message "wn photo $run" >/dev/null 2>&1 || true
  local url ok_w=1
  url=$(sonar_listen a 12 | python3 -c "
import json,sys
for l in sys.stdin:
    m=json.loads(l)
    if m.get('content')=='wn photo $run' and m.get('media'): print(m['media'][0]['url']); break")
  [ -n "$url" ] && sonar a fetch --group "$g4" --url "$url" --out "$Q/w-got-$run.png" >/dev/null &&
    [ "$(sha "$Q/w-got-$run.png")" = "$(sha "$Q/w-$run.png")" ] || ok_w=0
  if [ "$ok_s" = 1 ] && [ "$ok_w" = 1 ]; then
    pass QA-083 "media both ways (Sonar→WN DM, WN→Sonar in a Sonar group)"
  else
    fail QA-083 "media: sonar→wn=$ok_s wn→sonar=$ok_w"
  fi

  # QA-084: a Sonar member's leave is committed and every roster drops it.
  local before
  before=$(sonar_members b "$g4")
  sonar a leave --group "$g4" >/dev/null
  sonar_listen b 12 >/dev/null
  if [ "$(sonar_members b "$g4")" = "$((before - 1))" ] && eventually 40 sh -c "[ \"\$('$WN_BIN/wn' --json --account '$W' groups members '$g4' 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)[\"result\"][\"members\"]))')\" = $((before - 1)) ]"; then
    pass QA-084 "Sonar leave committed for Sonar and White Noise"
  else
    fail QA-084 "leave not committed (sonar b: $(sonar_members b "$g4"), was $before)"
  fi

  # QA-085: N-member groups created by each side.
  local members=() i
  for i in $(seq -w 1 $((n - 2))); do sonar_new "n$i" & done; wait
  for i in $(seq -w 1 $((n - 2))); do members+=("$(sonar_npub "n$i")"); done
  for npub in "${members[@]}"; do wn keys fetch "$npub" --bootstrap-relays "$RELAY" >/dev/null 2>&1 || true; done
  local gw
  gw=$(wn --account "$W" groups create "wn-$n-$run" "$A" "${members[@]}" | jget 'd["result"]["group_id"]' || true)
  wn --account "$W" messages send "$gw" "hello $n $run" >/dev/null 2>&1 || true
  for i in $(seq -w 1 $((n - 2))); do
    (sonar_listen "n$i" 10 >/dev/null; sonar_accept_named "n$i" "wn-$n-$run"; sonar_listen "n$i" 8 >/dev/null) &
  done
  wait
  sonar n01 group-send --group "$gw" --text "n01 in wn-$n $run" >/dev/null
  local joined=0
  for i in $(seq -w 1 $((n - 2))); do sonar_has "n$i" "$gw" "hello $n $run" && joined=$((joined + 1)); done
  if [ "$joined" = "$((n - 2))" ] && eventually 40 wn_has "$gw" "n01 in wn-$n $run"; then
    pass QA-085 "$n-member White Noise group: $joined/$((n - 2)) Sonar members joined and replied"
  else
    fail QA-085 "$n-member group: $joined/$((n - 2)) joined"
  fi

  echo "failures: $FAILS"
  return "$FAILS"
}

case "${1:-}" in
  setup) cmd_setup ;;
  run) shift; cmd_run "$@" ;;
  teardown) cmd_teardown ;;
  *) sed -n '2,24p' "$0"; exit 2 ;;
esac
