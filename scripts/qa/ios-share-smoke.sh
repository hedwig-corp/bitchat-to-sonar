#!/usr/bin/env bash
# ios-share-smoke.sh — scripted QA of the iOS share extension (docs/QA-SCENARIOS.md,
# "Share sheet"). Shares real documents into Sonar through the SYSTEM share
# sheet — from the Files app and from a stand-in third-party app — picks the
# chat with a fresh sonar-cli peer, and then checks what the PEER received:
# filename, MIME and the decrypted bytes (sha256), and that no stray text
# message rode along. Asserting on the recipient is the point: #559's bug
# staged a file named "file URL" holding a path, and every app-side screen
# looked fine.
#
#   QA_UDID=<udid> scripts/qa/ios-share-smoke.sh [--rebuild] [--keep-peer] [QA-080 …]
#
# QA_UDID comes from scripts/qa/ios-setup.sh (the signed Debug build must be
# installed). With no scenario ids every scenario runs. Exit status = number
# of failed scenarios.
#
# The app runs as a throwaway identity ($QA_HOME/share/app, `sonar-cli init`,
# never published from the CLI) handed over as SONAR_BENCH_NSEC; DEBUG builds
# then skip onboarding. Every scenario relaunches Sonar with that env first:
# the extension's `sonar://share` open must foreground THAT process — a cold
# launch without the env would derive a different database key.
#
# Output: $QA_HOME/share/run-<ts>/<scenario>/ — driver steps.log, screenshots,
# accessibility trees, the peer's received JSON and fetched bytes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa-$(basename "$ROOT")}"
UDID="${QA_UDID:?set QA_UDID (see scripts/qa/ios-setup.sh)}"
CLI="${SONAR_CLI:-$ROOT/core/target/release/sonar-cli}"
PEERS="$ROOT/scripts/qa/peers.sh"
S="$QA_HOME/share"
DRIVER="$S/driver"
FIX="$S/fixtures"
RUN="$S/run-$(date +%Y%m%d-%H%M%S)"
REBUILD=0; KEEP_PEER=0; ONLY=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) REBUILD=1; shift ;;
    --keep-peer) KEEP_PEER=1; shift ;;
    QA-*) ONLY+=("$1"); shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$S" "$RUN"

if [[ ! -x "$CLI" ]]; then
  echo ">> building sonar-cli" >&2
  (cd "$ROOT/core" && cargo build -q -p sonar-cli --release)
fi

# ---------------------------------------------------------------- driver build
SRC_HASH="$(find "$ROOT/scripts/qa/ios-share" -type f -print0 | sort -z | xargs -0 shasum | shasum | cut -c1-16)"
if (( REBUILD )) || [[ ! -d "$DRIVER/dd/Build/Products" ]] ||
   [[ "$(cat "$DRIVER/.src-hash" 2>/dev/null)" != "$SRC_HASH" ]]; then
  echo ">> building the share driver ($DRIVER)" >&2
  ruby "$ROOT/scripts/qa/ios-share/gen.rb" "$DRIVER"
  set -o pipefail
  xcodebuild build-for-testing -project "$DRIVER/QAShare.xcodeproj" -scheme QAShare \
    -destination "id=$UDID" -derivedDataPath "$DRIVER/dd" > "$DRIVER/build.log" 2>&1 ||
    { grep -E "error:" "$DRIVER/build.log" | head >&2; echo "driver build failed: $DRIVER/build.log" >&2; exit 1; }
  echo "$SRC_HASH" > "$DRIVER/.src-hash"
fi

# -------------------------------------------------------------------- fixtures
# Deterministic, so a failed byte comparison always means the transfer, never
# the fixture.
python3 - "$FIX" <<'FIXTURES_PY'
import os, struct, sys, zipfile, zlib
fix = sys.argv[1]
os.makedirs(fix, exist_ok=True)
def write(rel, data):
    path = os.path.join(fix, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())
write("report.csv", "name,qty\nwidget,3\ngadget,5\n")
write("notes.txt", "Sonar share QA notes.\nThis is a document, not a message.\n")
write("data.json", '{"sonar":"share-qa","items":[1,2,3]}\n')
write("README", "extension-less document\n")
write("dup1/IMG_0001.txt", "first of two same-named files\n")
write("dup2/IMG_0001.txt", "second of two same-named files, different bytes\n")
with zipfile.ZipFile(os.path.join(fix, "archive.zip"), "w") as z:
    # Fixed timestamp: a zip rebuilt every run with the current time made a
    # stale staged copy look like a corrupted transfer (same size, other bytes).
    z.writestr(zipfile.ZipInfo("inside.txt", date_time=(2026, 1, 1, 0, 0, 0)), "zipped payload\n")
def png(w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
write("photo.png", png(32, 32, (40, 120, 200)))
write("old-draft.csv", "abandoned,share\n1,2\n")
write("fresh.csv", "the,share,just,made\n")
write("Folder QA/one.txt", "inside a shared folder\n")
write("Folder QA/two.txt", "also inside\n")
big = os.path.join(fix, "big.bin")
if not os.path.exists(big) or os.path.getsize(big) != 26 * 1024 * 1024:
    with open(big, "wb") as f:
        f.write(b"\x5a" * (26 * 1024 * 1024))
FIXTURES_PY

# Host-share item lists (JSON the QA share host reads).
items() { # items <name> <json>
  printf '%s' "$2" > "$S/items-$1.json"; echo "$S/items-$1.json"
}
IT_DOCS="$(items docs "[{\"kind\":\"file\",\"path\":\"$FIX/data.json\"},{\"kind\":\"file\",\"path\":\"$FIX/archive.zip\"}]")"
IT_DUP="$(items dup "[{\"kind\":\"file\",\"path\":\"$FIX/dup1/IMG_0001.txt\"},{\"kind\":\"file\",\"path\":\"$FIX/dup2/IMG_0001.txt\"}]")"
IT_PHOTO="$(items photo "[{\"kind\":\"file\",\"path\":\"$FIX/photo.png\"}]")"
IT_LINK="$(items link '[{"kind":"url","value":"https://sonar.hedwig.sh/qa-share-link"}]')"
IT_NOEXT="$(items noext "[{\"kind\":\"file\",\"path\":\"$FIX/README\"}]")"
IT_BIG="$(items big "[{\"kind\":\"file\",\"path\":\"$FIX/big.bin\"}]")"
IT_EXPORT="$(items export "[{\"kind\":\"export\",\"path\":\"$FIX/notes.txt\",\"type\":\"public.plain-text\",\"name\":\"export.txt\"}]")"
IT_OLD="$(items old "[{\"kind\":\"file\",\"path\":\"$FIX/old-draft.csv\"}]")"
IT_FRESH="$(items fresh "[{\"kind\":\"file\",\"path\":\"$FIX/fresh.csv\"}]")"

# ------------------------------------------------ Files app "On My iPhone" seed
DEV="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data"
local_storage() {
  for meta in "$DEV"/Containers/Shared/AppGroup/*/.com.apple.mobile_container_manager.metadata.plist; do
    [[ -f "$meta" ]] || continue
    if [[ "$(plutil -extract MCMMetadataIdentifier raw "$meta" 2>/dev/null)" == group.com.apple.FileProvider.LocalStorage ]]; then
      dirname "$meta"; return 0
    fi
  done
  return 1
}
if ! LS="$(local_storage)"; then
  # The container only exists once Files has run.
  xcrun simctl launch "$UDID" com.apple.DocumentsApp >/dev/null; sleep 4
  xcrun simctl terminate "$UDID" com.apple.DocumentsApp >/dev/null 2>&1 || true
  LS="$(local_storage)" || { echo "no FileProvider LocalStorage container on $UDID" >&2; exit 1; }
fi
ON_MY_IPHONE="$LS/File Provider Storage"
mkdir -p "$ON_MY_IPHONE"
for f in report.csv notes.txt; do cp "$FIX/$f" "$ON_MY_IPHONE/$f"; done
rm -rf "$ON_MY_IPHONE/Folder QA"; cp -R "$FIX/Folder QA" "$ON_MY_IPHONE/Folder QA"

# Sonar's App Group, to inspect staged payloads.
APP_PATH="$(xcrun simctl get_app_container "$UDID" sh.hedwig.sonar app)"
GROUP_ID="$(plutil -extract AppGroupID raw "$APP_PATH/Info.plist")"
SONAR_GROUP="$(xcrun simctl get_app_container "$UDID" sh.hedwig.sonar "$GROUP_ID")"
INBOX="$SONAR_GROUP/SharedInbox"

# ---------------------------------------------------------------- identities
APP_HOME="$S/app"
if [[ ! -f "$APP_HOME/config.json" ]]; then
  "$CLI" --home "$APP_HOME" init 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["npub"])' > "$APP_HOME.npub"
fi
APP_NPUB="$(cat "$APP_HOME.npub")"
NSEC="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nsec"])' "$APP_HOME/config.json")"
PEER_FILE="$S/peer-name"
if (( KEEP_PEER )) && [[ -f "$PEER_FILE" ]]; then
  PEER="$(cat "$PEER_FILE")"
else
  PEER="share$(date +%s)"
  "$PEERS" new "$PEER" >/dev/null
  echo "$PEER" > "$PEER_FILE"
fi
PEER_HOME="$QA_HOME/peers/$PEER"
echo ">> app $APP_NPUB · peer $PEER ($(cat "$PEER_HOME/npub"))" >&2

# ---------------------------------------------------------------- driver runs
drive() { # drive <out dir> <steps>
  local out="$1" steps="$2" rc=0
  mkdir -p "$out"
  TEST_RUNNER_QA_STEPS="$steps" TEST_RUNNER_QA_OUT="$out" TEST_RUNNER_QA_NSEC="$NSEC" \
    xcodebuild test-without-building -project "$DRIVER/QAShare.xcodeproj" -scheme QAShare \
    -destination "id=$UDID" -derivedDataPath "$DRIVER/dd" \
    -only-testing:QAShareUITests/QAShareDriver/testDrive > "$out/xcodebuild.log" 2>&1 || rc=$?
  # A run that "passes" without finishing its steps (e.g. a test method XCTest
  # never executed) is a failure.
  (( rc != 0 )) || grep -q "ALL STEPS OK" "$out/steps.log" 2>/dev/null || rc=1
  (( rc == 0 )) || { echo "   driver failed — $out/steps.log" >&2; tail -3 "$out/steps.log" >&2 || true; }
  return "$rc"
}

# (Re)launch Sonar with the throwaway identity and PROVE it took: the process
# must log "identity from env". XCUITest's launchEnvironment is sometimes not
# applied (3 of ~25 launches, each the first launch after the peer messaged
# the app — XCUITest attached to a Sonar process it had not started with its
# environment; the exact trigger is unconfirmed), and a Sonar without SONAR_BENCH_NSEC
# derives another database key ("Wrong encryption key"), so every send in that
# scenario fails. A real install keeps its key in the keychain; this hazard is
# the harness's, so relaunch rather than report it as an app bug.
#
# Checked with `log show` against the running pid, NOT the $QA_HOME capture:
# `log stream > file` is block-buffered, so a line can reach that file minutes
# late and a check on it misses what already happened.
sonar_pid() {
  xcrun simctl spawn "$UDID" launchctl list 2>/dev/null |
    awk '/UIKitApplication:sh\.hedwig\.sonar\[/ { print $1; exit }'
}
launched_with_identity() { # launched_with_identity <pid>
  xcrun simctl spawn "$UDID" log show --last 3m --info --style compact \
    --predicate "processID == $1 AND eventMessage CONTAINS \"identity from env\"" 2>/dev/null |
    grep -q "identity from env"
}
launch_sonar() { # launch_sonar <out dir>
  local out="$1" try pid
  mkdir -p "$out"
  for try in 1 2 3; do
    drive "$out/launch-$try" "launch@sonar;tapif@sb:Allow;wait:3" >/dev/null 2>&1 || true
    pid="$(sonar_pid)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && launched_with_identity "$pid"; then
      return 0
    fi
    echo "   (harness: Sonar pid ${pid:-none} started without SONAR_BENCH_NSEC — relaunching, try $try)" >&2
  done
  echo "   FAIL could not launch Sonar with its test identity" >&2
  return 1
}

# Wait for the peer to receive what the app sent; compare against fixtures.
#   verify <out dir> <secs> <expected spec…>
# spec: file:<name>=<fixture path>=<mime> · image:<name>=<fixture>=<mime> (MDK
#       strips EXIF by RE-ENCODING images, so bytes differ by design — compare
#       name, MIME and pixel dimensions) · media:<mime prefix> (any file of that
#       type, bytes not compared — e.g. Photos may re-encode) · text:<substring>
#       · notext · nofile
# <mime> ("a|b" for alternatives) is what arrives on the wire: the app keeps MDK's MIME allowlist
# (snEncryptedAttachmentMime) and sends everything else as
# application/octet-stream with the filename's extension intact.
verify() {
  local out="$1" secs="$2"; shift 2
  python3 - "$CLI" "$PEER_HOME" "$out" "$secs" "$@" <<'VERIFY_PY'
import hashlib, json, os, subprocess, sys, time
cli, home, out, secs, specs = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5:]
want_files = []  # (name, fixture, mime)
want_images = []  # (name, fixture, mime)
want_media = []  # mime prefixes
want_texts, no_text, no_file = [], False, False
for s in specs:
    kind, _, rest = s.partition(":")
    if kind == "file":
        name, fixture, mime = rest.split("=")
        want_files.append((name, fixture, mime))
    elif kind == "image":
        name, fixture, mime = rest.split("=")
        want_images.append((name, fixture, mime))
    elif kind == "media":
        want_media.append(rest)
    elif kind == "text":
        want_texts.append(rest)
    elif kind == "notext":
        no_text = True
    elif kind == "nofile":
        no_file = True
got = []
start = time.monotonic()
proc = subprocess.Popen([cli, "--home", home, "listen", "--timeout-secs", str(secs), "--poll-secs", "5"],
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
def satisfied():
    names = [m["filename"] for msg in got for m in msg.get("media", [])]
    texts = [msg.get("content", "") for msg in got]
    mimes = [m["mime"] for msg in got for m in msg.get("media", [])]
    files_ok = all(names.count(n) >= sum(1 for w in want_files + want_images if w[0] == n)
                   for n, _, _ in want_files + want_images)
    media_ok = all(any(x.startswith(p) for x in mimes) for p in want_media)
    texts_ok = all(any(t in c for c in texts) for t in want_texts)
    return files_ok and media_ok and texts_ok and (want_files or want_images or want_media or want_texts)
try:
    for line in proc.stdout:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("type") != "message" or msg.get("mine"):
            continue
        got.append(msg)
        if satisfied():
            # Linger briefly: a stray extra message (e.g. the document's text
            # sent as a body) lands within a few seconds of the files.
            time.sleep(8)
            break
finally:
    proc.kill()
# One more short listen to pick up anything that arrived during the linger.
tail = subprocess.run([cli, "--home", home, "listen", "--timeout-secs", "6", "--poll-secs", "3"],
                      capture_output=True, text=True)
for line in tail.stdout.splitlines():
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    if msg.get("type") == "message" and not msg.get("mine"):
        got.append(msg)
with open(os.path.join(out, "received.json"), "w") as f:
    json.dump(got, f, indent=1)
problems = []
media = [(msg["group_id"], m) for msg in got for m in msg.get("media", [])]
used = set()
fetched = {}
def fetch(i):
    if i not in fetched:
        gid, m = media[i]
        dest = os.path.join(out, f"fetched-{i}-{m['filename']}")
        r = subprocess.run([cli, "--home", home, "fetch", "--group", gid, "--url", m["url"], "--out", dest],
                           capture_output=True, text=True)
        fetched[i] = open(dest, "rb").read() if r.returncode == 0 and os.path.exists(dest) else None
        if fetched[i] is None:
            problems.append(f"{m['filename']}: fetch failed: {r.stderr.strip()[-200:]}")
    return fetched[i]
for name, fixture, mime in want_files:
    want = open(fixture, "rb").read()
    # Same-named files (two IMG_0001.txt) may arrive in either order: match
    # on content among the files carrying that name.
    candidates = [i for i, (_, m) in enumerate(media) if m["filename"] == name and i not in used]
    if not candidates:
        problems.append(f"file {name!r} never arrived (got {[m['filename'] for _, m in media]})")
        continue
    match = next((i for i in candidates if fetch(i) == want), None)
    if match is None:
        got_bytes = fetch(candidates[0])
        problems.append(f"{name}: bytes differ ({len(got_bytes or b'')} B received, {len(want)} B sent)")
        used.add(candidates[0])
        continue
    used.add(match)
    m = media[match][1]
    if m["mime"] not in mime.split("|"):
        problems.append(f"{name}: mime {m['mime']!r}, want {mime!r}")
    else:
        print(f"   ok {name} · {m['mime']} · {len(want)} B · sha256 match")
def dims(path):
    r = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
                       capture_output=True, text=True)
    vals = [l.split(":")[1].strip() for l in r.stdout.splitlines() if "pixel" in l]
    return tuple(vals) if len(vals) == 2 else None
for name, fixture, mime in want_images:
    match = next((i for i, (_, m) in enumerate(media) if m["filename"] == name and i not in used), None)
    if match is None:
        problems.append(f"image {name!r} never arrived (got {[m['filename'] for _, m in media]})")
        continue
    used.add(match)
    m = media[match][1]
    if fetch(match) is None:
        continue
    got_dims = dims(os.path.join(out, f"fetched-{match}-{m['filename']}"))
    want_dims = dims(fixture)
    if m["mime"] != mime:
        problems.append(f"{name}: mime {m['mime']!r}, want {mime!r}")
    elif got_dims is None or got_dims != want_dims:
        problems.append(f"{name}: decoded {got_dims}, want {want_dims}")
    else:
        print(f"   ok {name} · {m['mime']} · {got_dims[0]}x{got_dims[1]} (re-encoded, EXIF stripped)")
for prefix in want_media:
    match = next((i for i, (_, m) in enumerate(media) if m["mime"].startswith(prefix) and i not in used), None)
    if match is None:
        problems.append(f"no {prefix}* file arrived")
        continue
    used.add(match)
    m = media[match][1]
    body = fetch(match)
    ext = os.path.splitext(m["filename"])[1].lower()
    if body is not None:
        print(f"   ok {m['filename']} · {m['mime']} · {len(body)} B")
    if m["filename"] in ("file URL", "attachment") or not ext:
        problems.append(f"{prefix}*: unhelpful filename {m['filename']!r}")
for t in want_texts:
    if any(t in msg.get("content", "") for msg in got):
        print(f"   ok text {t!r}")
    else:
        problems.append(f"text {t!r} never arrived")
extra = [i for i in range(len(media)) if i not in used]
if extra and (want_files or want_images or want_media):
    problems.append(f"unexpected extra files: {[media[i][1]['filename'] for i in extra]}")
if no_file and media:
    problems.append(f"no file expected, got {[m['filename'] for _, m in media]}")
if no_text:
    bodies = [msg["content"] for msg in got if msg.get("content") and not msg.get("media")]
    if bodies:
        problems.append(f"no text message expected, got {bodies!r}")
if not got and (no_file or no_text) and not (want_files or want_images or want_media or want_texts):
    print("   ok nothing delivered")
for p in problems:
    print(f"   FAIL {p}")
print(f"   ({len(got)} message(s) in {time.monotonic() - start:.0f}s)")
sys.exit(1 if problems else 0)
VERIFY_PY
}

inbox_dirs() { find "$INBOX" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
# Scenarios are independent: a payload an earlier scenario left staged (its
# picker abandoned by a relaunch) would otherwise be offered first. QA-089
# builds that situation on purpose.
reset_inbox() { rm -rf "${INBOX:?}"/* 2>/dev/null || true; }

# Every scenario first runs launch_sonar (a fresh Sonar with the throwaway
# identity, verified in the app log); its steps then start from that process.
PRE="activate@sonar;wait:1"
# The picker, then the chat with the peer. The chat row is found by the title
# the bootstrap recorded.
# `pick "<checks>"` runs those steps once the picker is up, before choosing.
pick() {
  local checks="${1:-}"
  echo "handoff:$INBOX#${HANDOFF_N:-1};expect:Send to…@40;${checks:+$checks;}shot:picker;tree:picker;tapc:$CHAT_ROW;wait:4;shot:sent"
}

declare -a RESULTS=()
FAILED=0
want() { (( ${#ONLY[@]} == 0 )) && return 0; local id; for id in "${ONLY[@]}"; do [[ "$id" == "$1" ]] && return 0; done; return 1; }
record() { # record <id> <rc> <summary>
  if (( $2 == 0 )); then RESULTS+=("PASS $1 $3"); else RESULTS+=("FAIL $1 $3"); FAILED=$((FAILED + 1)); fi
}

# ------------------------------------------------------------------ bootstrap
# The peer opens a 1:1 chat with the app (inbound-first), so the picker has a
# row to pick. Its title is what `tapc` targets afterwards.
echo ">> bootstrap: peer opens a chat with the app" >&2
HELLO="share-qa hello $(date +%s)"
launch_sonar "$RUN/bootstrap-launch" ||
  { echo "bootstrap failed: could not launch Sonar" >&2; exit 1; }
# The app publishes its KeyPackage a few seconds after launch; until it lands
# on the relays the peer cannot open the chat.
sent=0
for _ in $(seq 1 12); do
  if "$PEERS" send "$PEER" "$APP_NPUB" "$HELLO" >/dev/null 2>&1; then sent=1; break; fi
  sleep 10
done
(( sent )) || { echo "bootstrap failed: the app's KeyPackage never reached the relays" >&2; exit 1; }
drive "$RUN/bootstrap" "activate@sonar;expect:$HELLO@120;tree:home;shot:home" ||
  { echo "bootstrap failed: the app never showed the peer's chat" >&2; exit 1; }
CHAT_ROW="$(python3 - "$RUN/bootstrap/home.txt" "$HELLO" <<'ROW_PY'
import re, sys
tree, hello = open(sys.argv[1]).read(), sys.argv[2]
# The row whose label carries the hello preview; its title is the first part.
for line in tree.splitlines():
    if hello in line:
        m = re.search(r"label: '([^']*)'", line)
        if m:
            label = m.group(1)
            title = label.split(hello)[0].strip(" ,·")
            print(title.split(",")[0].strip() or hello)
            break
ROW_PY
)"
[[ -n "$CHAT_ROW" ]] || CHAT_ROW="$HELLO"
echo ">> chat row: '$CHAT_ROW'" >&2

scenario() { # scenario <id> <summary> <steps> <verify secs> <spec…>
  local id="$1" summary="$2" steps="$3" secs="$4"; shift 4
  want "$id" || return 0
  echo ">> $id $summary" >&2
  local out="$RUN/$id" rc=0
  reset_inbox
  launch_sonar "$out" || rc=1
  (( rc == 0 )) && { drive "$out" "$steps" || rc=$?; }
  (( rc == 0 )) && { verify "$out" "$secs" "$@" || rc=$?; }
  record "$id" "$rc" "$summary"
}

# ------------------------------------------------------------------ scenarios
scenario QA-080 "Files app: a CSV arrives as the file, not its path" \
  "$PRE;files:report.csv;sheet:Sonar;$(pick "expect:report.csv;absent:file URL;absent:widget,3")" 150 \
  "file:report.csv=$FIX/report.csv=application/octet-stream" notext

scenario QA-081 "Third-party app: JSON + ZIP keep their names and bytes" \
  "$PRE;hostshare:$IT_DOCS;sheet:Sonar;$(pick "expect:data.json;expect:archive.zip")" 180 \
  "file:data.json=$FIX/data.json=application/octet-stream" \
  "file:archive.zip=$FIX/archive.zip=application/octet-stream" notext

scenario QA-082 "Two same-named files both arrive, no index prefix" \
  "$PRE;hostshare:$IT_DUP;sheet:Sonar;$(pick "expect:IMG_0001.txt;absent:0-IMG;absent:1-IMG")" 180 \
  "file:IMG_0001.txt=$FIX/dup1/IMG_0001.txt=text/plain" "file:IMG_0001.txt=$FIX/dup2/IMG_0001.txt=text/plain" notext

scenario QA-083 "Photo file keeps its real name and pixels" \
  "$PRE;hostshare:$IT_PHOTO;sheet:Sonar;$(pick "expect:photo.png")" 150 \
  "image:photo.png=$FIX/photo.png=image/png" notext

# An app exporting a text document from memory: bytes registered as
# public.plain-text plus a suggestedName. The body reader used to read those
# bytes as the message text on top of staging the file.
scenario QA-084 "An in-app text export is a file, never also the message" \
  "$PRE;hostshare:$IT_EXPORT;sheet:Sonar;$(pick "expect:export.txt;absent:not a message")" 150 \
  "file:export.txt=$FIX/notes.txt=text/plain" notext

if want QA-085; then
  echo ">> QA-085 Folder share never copies the folder tree" >&2
  reset_inbox; rc=0
  launch_sonar "$RUN/QA-085" || rc=1
  (( rc == 0 )) && drive "$RUN/QA-085" "$PRE;files:Folder QA;sheet:Sonar;expect:no shareable content@15;shot:status;wait:3;absent@sonar:Send to…@2" || rc=$?
  # Whatever Files hands over, a payload must never hold a copied directory.
  if find "$INBOX" -mindepth 3 -type d 2>/dev/null | grep -q .; then
    echo "   FAIL a directory tree was copied into SharedInbox" >&2; rc=1
    find "$INBOX" | sed 's/^/     /' >&2
  fi
  (( rc == 0 )) && { verify "$RUN/QA-085" 20 nofile notext || rc=$?; }
  record QA-085 "$rc" "Folder share never copies the folder tree"
fi

scenario QA-086 "Web link arrives as text, never as a file" \
  "$PRE;hostshare:$IT_LINK;sheet:Sonar;$(pick "expect:qa-share-link")" 90 \
  "text:https://sonar.hedwig.sh/qa-share-link" nofile

scenario QA-087 "Extension-less document keeps its name" \
  "$PRE;hostshare:$IT_NOEXT;sheet:Sonar;$(pick "expect:README")" 150 \
  "file:README=$FIX/README=text/plain|application/octet-stream" notext

if want QA-088; then
  echo ">> QA-088 Oversized file is refused before the picker" >&2
  reset_inbox; rc=0
  launch_sonar "$RUN/QA-088" || rc=1
  (( rc == 0 )) && drive "$RUN/QA-088" "$PRE;hostshare:$IT_BIG;sheet:Sonar;expect:too large@20;shot:status;wait:3;absent@sonar:Send to…@2" || rc=$?
  [[ "$(inbox_dirs)" == 0 ]] || { echo "   FAIL a payload directory was left in SharedInbox" >&2; rc=1; }
  (( rc == 0 )) && { verify "$RUN/QA-088" 20 nofile notext || rc=$?; }
  record QA-088 "$rc" "Oversized file is refused before the picker"
fi

# An abandoned share must not hijack the next one. Share old-draft.csv, leave
# its picker up and relaunch Sonar (the payload stays staged, as after a
# crash — the picker comes back), then share fresh.csv: the picker must offer
# fresh.csv, and the peer must receive fresh.csv — not last time's file.
if want QA-089; then
  echo ">> QA-089 An abandoned share does not replace the one just made" >&2
  reset_inbox; rc=0
  launch_sonar "$RUN/QA-089" || rc=1
  (( rc == 0 )) && { drive "$RUN/QA-089/old" \
    "$PRE;hostshare:$IT_OLD;sheet:Sonar;handoff:$INBOX#1;expect:Send to…@40;expect:old-draft.csv" || rc=$?; }
  (( rc == 0 )) && { launch_sonar "$RUN/QA-089/relaunch" || rc=1; }
  (( rc == 0 )) && { drive "$RUN/QA-089" \
    "$PRE;expect:old-draft.csv@40;hostshare:$IT_FRESH;sheet:Sonar;handoff:$INBOX#2;expect:fresh.csv@40;absent:old-draft.csv;$(pick)" || rc=$?; }
  (( rc == 0 )) && { verify "$RUN/QA-089" 150 "file:fresh.csv=$FIX/fresh.csv=application/octet-stream" notext || rc=$?; }
  record QA-089 "$rc" "An abandoned share does not replace the one just made"
fi

scenario QA-091 "A text document from Files arrives as the file only" \
  "$PRE;files:notes.txt;sheet:Sonar;$(pick "expect:notes.txt;absent:not a message")" 150 \
  "file:notes.txt=$FIX/notes.txt=text/plain" notext

# The Photos app, the most common source. Photos may re-encode, so the check
# is "an image with a real filename", not a byte match.
if want QA-090; then
  xcrun simctl addmedia "$UDID" "$FIX/photo.png" >/dev/null 2>&1 || true
fi
scenario QA-090 "A photo from the Photos app arrives as an image" \
  "$PRE;photos:;sheet:Sonar;$(pick)" 150 \
  "media:image/" notext

echo
printf '%s\n' "${RESULTS[@]}"
echo "ios-share-smoke: $FAILED failed → $RUN"
exit "$FAILED"
