#!/usr/bin/env bash
# Measures Compose chat-open first-frame time on a connected Android device
# using the Debug-only `SONAR_BENCH chat_open_first_frame` marker (issue #305).
#
# The app must be a DEBUG build (markers never ship in Release), onboarded,
# with the target conversation visible in the chat list. The script drives
# N open/close cycles via uiautomator taps and aggregates the logcat markers.
#
# Usage:
#   scripts/bench/android-chat-open-bench.sh [--serial SERIAL] \
#     [--chat "Chat row title"] [--runs N]
#
# Output: one line per run plus min/median/max, e.g.
#   run 3: rows=38 ms=41.2
#   chat_open_first_frame ms: min=38.1 median=42.9 max=55.0 (n=10)
set -euo pipefail

SERIAL=""
CHAT="Sonar agent DM"
RUNS=10
while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --chat) CHAT="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

ADB=(adb)
[[ -n "$SERIAL" ]] && ADB=(adb -s "$SERIAL")

PKG=chat.bitchat.sonar
if ! "${ADB[@]}" shell pm list packages | grep -q "^package:$PKG$"; then
  echo "error: $PKG is not installed on the target device" >&2
  exit 1
fi

export BENCH_CHAT="$CHAT" BENCH_RUNS="$RUNS" BENCH_SERIAL="$SERIAL"
exec python3 - <<'PYEOF'
import os
import re
import statistics
import subprocess
import sys
import time

SERIAL = os.environ.get("BENCH_SERIAL") or ""
CHAT = os.environ["BENCH_CHAT"]
RUNS = int(os.environ["BENCH_RUNS"])
PKG = "chat.bitchat.sonar"
ADB = ["adb"] + (["-s", SERIAL] if SERIAL else [])
MARKER = re.compile(r"SONAR_BENCH chat_open_first_frame chat=(\S+) rows=(\d+) ms=([0-9.]+)")


def adb(*args):
    return subprocess.run(ADB + list(args), capture_output=True).stdout.decode(errors="replace")


def ui_texts():
    xml = adb("exec-out", "uiautomator", "dump", "/dev/tty")
    return [(m.group(1), m.group(2)) for m in
            re.finditer(r'text="([^"]+)"[^>]*bounds="(\[[^"]+\])"', xml)]


def bounds(b):
    return tuple(map(int, re.findall(r"\d+", b)))


def center(b):
    x1, y1, x2, y2 = bounds(b)
    return (x1 + x2) // 2, (y1 + y2) // 2


def find(rows, needle):
    for t, b in rows:
        if needle.lower() in t.lower():
            return center(b)
    return None


def tap(x, y):
    subprocess.run(ADB + ["shell", "input", "tap", str(x), str(y)], capture_output=True)


DENSITY = None


def dp(value):
    """dp -> px for this device (the header geometry below is in dp)."""
    global DENSITY
    if DENSITY is None:
        m = re.search(r"(\d+)", adb("shell", "wm", "density"))
        DENSITY = int(m.group(1)) if m else 160
    return round(value * DENSITY / 160.0)


def chat_header(rows):
    """The chat screen's header title node, or None if not in a chat.

    Identified by the transport subtitle the header always renders next to
    the peer name ('Via internet' / 'Nearby · Bluetooth' / 'Offline — ...').
    """
    if not any(t.startswith(("Via internet", "Nearby ·", "Offline —")) for t, _ in rows):
        return None
    titles = [b for t, b in rows if CHAT.lower() in t.lower()]
    return min(titles, key=lambda b: bounds(b)[1]) if titles else None


def leave_chat(title_bounds):
    """Tap the header's back arrow. Its position is derived from the header
    row, never hardcoded: the arrow is a 36dp button at 12dp start padding,
    vertically centred on the title. (System back is NOT usable here — the
    Compose app has no back handler, so KEYCODE_BACK exits to the launcher.)
    """
    _, y1, _, y2 = bounds(title_bounds)
    tap(dp(30), (y1 + y2) // 2)
    time.sleep(1.5)


def ensure_chat_list():
    """Return the chat row's tap point, navigating there only when we know
    where we are. Never taps blind: a stray tap on the chat list can pop the
    nav stack to a blank screen."""
    for _ in range(6):
        rows = ui_texts()
        target = find(rows, CHAT)
        if target and find(rows, "MESSAGES"):
            return target
        header = chat_header(rows)
        if header is not None:
            leave_chat(header)
            continue
        if find(rows, "MESSAGES"):
            # On the list but the row is out of view (the list orders by
            # recency, so the target can drop below the fold).
            sys.exit(f"'{CHAT}' is not visible in the chat list; scroll to it "
                     f"and rerun, or pass --chat with a row that is on screen")
        subprocess.run(ADB + ["shell", "monkey", "-p", PKG, "-c",
                              "android.intent.category.LAUNCHER", "1"], capture_output=True)
        time.sleep(5)
    sys.exit(f"could not reach a chat list showing '{CHAT}'; "
             f"on screen: {[t for t, _ in ui_texts()][:8]}")


samples = []
for run in range(1, RUNS + 1):
    cx, cy = ensure_chat_list()
    adb("logcat", "-c")
    tap(cx, cy)
    time.sleep(2.5)
    m = None
    for line in adb("logcat", "-d", "-s", "SonarCore").splitlines():
        got = MARKER.search(line)
        if got:
            m = got
    if m:
        ms = float(m.group(3))
        samples.append(ms)
        print(f"run {run}: rows={m.group(2)} ms={ms}", flush=True)
    else:
        print(f"run {run}: no marker (is this a Debug build?)", flush=True)
    header = chat_header(ui_texts())
    if header is not None:
        leave_chat(header)

if not samples:
    sys.exit("no chat_open_first_frame markers captured")
print(
    f"chat_open_first_frame ms: min={min(samples):.1f} "
    f"median={statistics.median(samples):.1f} max={max(samples):.1f} (n={len(samples)})"
)
PYEOF
