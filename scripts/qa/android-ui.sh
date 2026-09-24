#!/usr/bin/env bash
# android-ui.sh — adb/uiautomator driver for agent QA passes on the Sonar
# Compose app. Targets ONE device by serial; never "the" connected device.
#
#   export QA_SERIAL=emulator-5580          # required
#   export QA_SHOTS=/tmp/sonar-qa/shots     # optional, default below
#
#   android-ui.sh shot <name>        screencap → $QA_SHOTS/<name>.png (≤900 px)
#   android-ui.sh dump               "x,y  C|E|E!  text  desc" for every labelled node and
#                                    every edit field (E); E! = uiautomator flags the field
#                                    NAF (no spoken label) — an accessibility finding
#   android-ui.sh find <substr>      first node whose text/desc CONTAINS substr → "x y"
#   android-ui.sh findx <exact>      first node whose text/desc EQUALS exact   → "x y"
#   android-ui.sh tapt <substr>      tap first CONTAINS match
#   android-ui.sh tapx <exact> [n]   tap the n-th EXACT match (default 1, -1 = last);
#                                    use for "Allow", "Send"… where substrings collide
#   android-ui.sh wait <substr> [s]  poll dumps until substr appears (default 20 s)
#   android-ui.sh gone <substr> [s]  poll dumps until substr disappears
#   android-ui.sh tap <x> <y> | type <text> | key <code> | swipe x1 y1 x2 y2 [ms]
#   android-ui.sh tapedit [n]        tap the n-th editable field (default 1)
#   android-ui.sh naf                list unlabelled interactive nodes (class, bounds);
#                                    empty output = the screen passes the a11y sweep
#   android-ui.sh longpress <x> <y>
#   android-ui.sh ime                prints "shown" / "hidden" (soft keyboard)
#   android-ui.sh bounds <exact>     "x1 y1 x2 y2" of first EXACT match
#
# Coordinates are device pixels, straight from `dump` — never read them off a
# downscaled screenshot (the ÷2.667 conversion error cost hours in QA runs).
# Prefer tapx/tapt on content descriptions: every icon control in the app has
# one (QA-A9), so taps survive layout changes.
set -euo pipefail

SER="${QA_SERIAL:?set QA_SERIAL to the emulator/device serial (adb devices)}"
SHOTS="${QA_SHOTS:-${TMPDIR:-/tmp}/sonar-qa/shots}"
XML="${TMPDIR:-/tmp}/sonar-qa-ui-$SER.xml"
ADB=(adb -s "$SER")
mkdir -p "$SHOTS"

_dump_xml() {
  "${ADB[@]}" shell uiautomator dump /sdcard/sonar-qa-ui.xml >/dev/null 2>&1 || true
  "${ADB[@]}" exec-out cat /sdcard/sonar-qa-ui.xml > "$XML"
}

_query() { # mode(dump|find|findx|bounds) [needle] [nth]
  python3 - "$XML" "$1" "${2:-}" "${3:-1}" <<'PY'
import html, re, sys
xml, mode, needle, nth = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
hits = []
data = open(xml, encoding="utf-8", errors="replace").read()
node = re.compile(r'<node [^>]*?text="([^"]*)"[^>]*?class="([^"]*)"[^>]*?content-desc="([^"]*)"[^>]*?'
                  r'clickable="(\w+)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
for m in node.finditer(data):
    t, cls, d, c, x1, y1, x2, y2 = m.groups()
    t, d = html.unescape(t), html.unescape(d)
    cx, cy = (int(x1) + int(x2)) // 2, (int(y1) + int(y2)) // 2
    edit = cls.endswith("EditText")
    naf = 'NAF="true"' in m.group(0)       # uiautomator: not accessibility-friendly
    if mode == "dump":
        if t or d or edit:
            tag = ("E!" if naf else "E") if edit else ("C" if c == "true" else " ")
            print(f"{cx},{cy}\t{tag}\t{t[:70]}\t{d[:50]}")
    elif mode == "edit" and edit:
        hits.append(f"{cx} {cy}")
    elif mode == "find" and (needle.lower() in t.lower() or needle.lower() in d.lower()):
        print(cx, cy); break
    elif mode in ("findx", "bounds") and (t == needle or d == needle):
        hits.append(f"{cx} {cy}" if mode == "findx" else f"{x1} {y1} {x2} {y2}")
if mode == "naf":
    for n in re.finditer(r'<node [^>]*>', data):
        tag = n.group(0)
        if 'NAF="true"' in tag:
            cls = re.search(r'class="([^"]*)"', tag).group(1).split(".")[-1]
            b = re.search(r'bounds="([^"]*)"', tag).group(1)
            print(f"{cls}\t{b}")
if hits:
    idx = nth - 1 if nth > 0 else nth
    if -len(hits) <= idx < len(hits):
        print(hits[idx])
PY
}

cmd="${1:-}"; shift || true
case "$cmd" in
  shot)
    name="${1:?shot <name>}"
    "${ADB[@]}" exec-out screencap -p > "$SHOTS/$name-full.png"
    if command -v sips >/dev/null; then
      sips -Z 900 "$SHOTS/$name-full.png" --out "$SHOTS/$name.png" >/dev/null 2>&1
    else
      cp "$SHOTS/$name-full.png" "$SHOTS/$name.png"
    fi
    echo "$SHOTS/$name.png" ;;
  dump)   _dump_xml; _query dump ;;
  find)   _dump_xml; _query find "${1:?find <substr>}" ;;
  findx)  _dump_xml; _query findx "${1:?findx <exact>}" "${2:-1}" ;;
  bounds) _dump_xml; _query bounds "${1:?bounds <exact>}" ;;
  tapt|tapx)
    needle="${1:?$cmd <text>}"
    _dump_xml
    xy="$(_query "$([[ $cmd == tapx ]] && echo findx || echo find)" "$needle" "${2:-1}")"
    [[ -z "$xy" ]] && { echo "NOT FOUND: $needle" >&2; exit 1; }
    # shellcheck disable=SC2086
    "${ADB[@]}" shell input tap $xy
    echo "tapped '$needle' at $xy" ;;
  wait|gone)
    needle="${1:?$cmd <substr> [secs]}"; secs="${2:-20}"
    deadline=$((SECONDS + secs))
    while (( SECONDS < deadline )); do
      _dump_xml
      hit="$(_query find "$needle")"
      if [[ $cmd == wait && -n "$hit" ]] || [[ $cmd == gone && -z "$hit" ]]; then
        echo "$cmd ok: '$needle' after $((secs - (deadline - SECONDS)))s"; exit 0
      fi
      sleep 1
    done
    echo "$cmd TIMEOUT: '$needle' (${secs}s)" >&2; exit 1 ;;
  tapedit)  # tapedit [n] — n-th editable field (EditText), works when unlabelled
    _dump_xml; xy="$(_query edit "" "${1:-1}")"
    [[ -z "$xy" ]] && { echo "NOT FOUND: edit field ${1:-1}" >&2; exit 1; }
    # shellcheck disable=SC2086
    "${ADB[@]}" shell input tap $xy
    echo "tapped edit field ${1:-1} at $xy" ;;
  naf)       # naf — every interactive node uiautomator flags as unlabelled
    _dump_xml; _query naf ;;
  tap)       "${ADB[@]}" shell input tap "${1:?x}" "${2:?y}" ;;
  type)      t="$*"; "${ADB[@]}" shell input text "${t// /%s}" ;;
  key)       "${ADB[@]}" shell input keyevent "${1:?keycode}" ;;
  swipe)     "${ADB[@]}" shell input swipe "$1" "$2" "$3" "$4" "${5:-300}" ;;
  longpress) "${ADB[@]}" shell input swipe "$1" "$2" "$1" "$2" 900 ;;
  ime)
    if "${ADB[@]}" shell dumpsys input_method | grep -q "mInputShown=true"; then
      echo shown; else echo hidden; fi ;;
  *)
    sed -n '2,25p' "$0"; exit 2 ;;
esac
