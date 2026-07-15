#!/usr/bin/env bash
# White Noise CLI (wn/wnd) adapter for the relay agent smoke harness.
#
# The upstream CLI is AGPL software and stays an external process. This helper
# only normalizes its public JSON/Unix-socket interface into the same
# sender/content NDJSON contract used by sonar-cli.
#
# Required globals from the caller: WN_BIN, WND_BIN, TARGET_RELAY.
# Intended to be sourced; the caller owns shell options and process traps.

WN_READY_TIMEOUT_SECS="${WN_READY_TIMEOUT_SECS:-30}"
WN_KEYPACKAGE_TIMEOUT_SECS="${WN_KEYPACKAGE_TIMEOUT_SECS:-45}"
WN_MESSAGE_TIMEOUT_SECS="${WN_MESSAGE_TIMEOUT_SECS:-30}"

wn_require_bins() {
  [[ -n "${WN_BIN:-}" && -x "$WN_BIN" ]] || {
    echo "WN_BIN is not executable; set it to the upstream 'wn' binary." >&2
    return 2
  }
  [[ -n "${WND_BIN:-}" && -x "$WND_BIN" ]] || {
    echo "WND_BIN is not executable; set it to the upstream 'wnd' binary." >&2
    return 2
  }
  command -v jq >/dev/null 2>&1 || {
    echo "jq is required by the White Noise smoke adapter." >&2
    return 2
  }
  command -v python3 >/dev/null 2>&1 || {
    echo "python3 is required by the White Noise smoke adapter." >&2
    return 2
  }
}

wn_validate_relay() {
  case "$1" in
    wss://*) return 0 ;;
    *) echo "White Noise smoke relay must use wss://: $1" >&2; return 2 ;;
  esac
}

wn_validate_relays() {
  local csv="$1" relay old_ifs="$IFS"
  [[ -n "$csv" ]] || { echo "White Noise relay list must not be empty" >&2; return 2; }
  IFS=','
  for relay in $csv; do
    wn_validate_relay "$relay" || { IFS="$old_ifs"; return 2; }
  done
  IFS="$old_ifs"
}

wn_hex_to_npub() {
  python3 - "$1" <<'PY'
import sys

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

def polymod(values):
    generators = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
    chk = 1
    for value in values:
        top = chk >> 25
        chk = ((chk & 0x1FFFFFF) << 5) ^ value
        for index, generator in enumerate(generators):
            if (top >> index) & 1:
                chk ^= generator
    return chk

def hrp_expand(hrp):
    return [ord(ch) >> 5 for ch in hrp] + [0] + [ord(ch) & 31 for ch in hrp]

def convert_bits(values, from_bits, to_bits, pad=True):
    accumulator = bits = 0
    result = []
    maximum = (1 << to_bits) - 1
    for value in values:
        accumulator = (accumulator << from_bits) | value
        bits += from_bits
        while bits >= to_bits:
            bits -= to_bits
            result.append((accumulator >> bits) & maximum)
    if pad and bits:
        result.append((accumulator << (to_bits - bits)) & maximum)
    return result

def checksum(hrp, data):
    value = polymod(hrp_expand(hrp) + data + [0] * 6) ^ 1
    return [(value >> (5 * (5 - index))) & 31 for index in range(6)]

raw = bytes.fromhex(sys.argv[1])
if len(raw) != 32:
    raise SystemExit("pubkey must be 32 bytes")
data = convert_bits(raw, 8, 5)
print("npub1" + "".join(CHARSET[value] for value in data + checksum("npub", data)))
PY
}

wn_npub_to_hex() {
  python3 - "$1" <<'PY'
import sys

charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
value = sys.argv[1]
if not value.startswith("npub1"):
    if len(value) != 64:
        raise SystemExit("public key must be npub or 64 hex characters")
    bytes.fromhex(value)
    print(value.lower())
    raise SystemExit(0)

def polymod(values):
    generators = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
    chk = 1
    for item in values:
        top = chk >> 25
        chk = ((chk & 0x1FFFFFF) << 5) ^ item
        for index, generator in enumerate(generators):
            if (top >> index) & 1:
                chk ^= generator
    return chk

try:
    encoded = [charset.index(ch) for ch in value[5:]]
except ValueError as error:
    raise SystemExit("npub contains an invalid Bech32 character") from error
expanded = [ord(ch) >> 5 for ch in "npub"] + [0] + [ord(ch) & 31 for ch in "npub"]
if len(encoded) < 7 or polymod(expanded + encoded) != 1:
    raise SystemExit("npub checksum is invalid")
data = encoded[:-6]
accumulator = bits = 0
result = []
for item in data:
    accumulator = (accumulator << 5) | item
    bits += 5
    while bits >= 8:
        bits -= 8
        result.append((accumulator >> bits) & 0xFF)
raw = bytes(result)
if len(raw) != 32:
    raise SystemExit("npub must decode to 32 bytes")
print(raw.hex())
PY
}

wn_socket_path() {
  local home="$1"
  if [[ -S "$home/release/wnd.sock" ]]; then
    printf '%s' "$home/release/wnd.sock"
  elif [[ -S "$home/dev/wnd.sock" ]]; then
    printf '%s' "$home/dev/wnd.sock"
  elif [[ -d "$home/dev" && ! -d "$home/release" ]]; then
    printf '%s' "$home/dev/wnd.sock"
  else
    printf '%s' "$home/release/wnd.sock"
  fi
}

wn_json() {
  local home="$1"
  shift
  "$WN_BIN" --json --socket "$(wn_socket_path "$home")" "$@"
}

wn_result() {
  local home="$1" raw
  shift
  raw=$(wn_json "$home" "$@") || return $?
  if printf '%s' "$raw" | jq -e '.error != null' >/dev/null 2>&1; then
    printf '%s\n' "$raw" >&2
    return 1
  fi
  if printf '%s' "$raw" | jq -e 'type == "object" and has("result")' >/dev/null 2>&1; then
    printf '%s' "$raw" | jq -c '.result'
  elif printf '%s' "$raw" | jq -e 'type == "object" and length == 0' >/dev/null 2>&1; then
    # v0.2.1 returns an empty object for successful void commands.
    printf 'null'
  else
    echo "unexpected White Noise JSON response: $raw" >&2
    return 1
  fi
}

wn_start_daemon() {
  local home="$1" relays="${2:-$TARGET_RELAY}" deadline socket
  wn_require_bins || return $?
  wn_validate_relays "$relays" || return $?
  mkdir -p "$home/logs"
  chmod 700 "$home" "$home/logs"
  if [[ -f "$home/wnd.pid" ]]; then
    echo "refusing to overwrite existing White Noise daemon PID: $home/wnd.pid" >&2
    return 1
  fi
  "$WND_BIN" \
    --data-dir "$home" \
    --logs-dir "$home/logs" \
    --discovery-relays "$relays" \
    --default-account-relays "$relays" \
    >"$home/wnd.log" 2>&1 &
  echo "$!" >"$home/wnd.pid"

  deadline=$(( $(date +%s) + WN_READY_TIMEOUT_SECS ))
  while (( $(date +%s) < deadline )); do
    socket=$(wn_socket_path "$home")
    if [[ -S "$socket" ]] && wn_json "$home" whoami >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$(cat "$home/wnd.pid")" 2>/dev/null; then
      echo "wnd exited before becoming ready; see $home/wnd.log" >&2
      return 1
    fi
    sleep 0.25
  done
  echo "wnd did not become ready within ${WN_READY_TIMEOUT_SECS}s; see $home/wnd.log" >&2
  return 1
}

wn_stop_daemon() {
  local home="$1" pid deadline
  [[ -f "$home/wnd.pid" ]] || return 0
  pid=$(cat "$home/wnd.pid")
  case "$pid" in
    ''|*[!0-9]*) echo "invalid wnd pid in $home/wnd.pid" >&2; return 1 ;;
  esac
  wn_json "$home" daemon stop >/dev/null 2>&1 || kill -TERM "$pid" 2>/dev/null || true
  deadline=$(( $(date +%s) + 5 ))
  while kill -0 "$pid" 2>/dev/null && (( $(date +%s) < deadline )); do sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  rm -f "$home/wnd.pid"
}

wn_wait_relay_connected() {
  local home="$1" relay="${2:-$TARGET_RELAY}" timeout deadline pubkey
  pubkey=$(cat "$home/pubkey.hex")
  timeout="${WN_RELAY_CONNECT_TIMEOUT_SECS:-20}"
  deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    if wn_result "$home" --account "$pubkey" relays list 2>/dev/null \
      | jq -e --arg relay "$relay" \
        '[.[] | select(.url == $relay)] | length > 0 and all(.status == "Connected")' \
        >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  # wn 0.2.1 can keep this status stale even when key-package requests and
  # publishes succeed. Treat it as diagnostic signal; the bidirectional
  # preflight remains the authoritative transport check.
  echo "warn: White Noise relay status did not report Connected: $relay" >&2
  return 0
}

wn_start_notifications() {
  local home="$1" out="$2" err="$3" pubkey pid
  pubkey=$(cat "$home/pubkey.hex")
  wn_json "$home" --account "$pubkey" notifications subscribe >"$out" 2>"$err" &
  pid=$!
  sleep "${WN_SUBSCRIPTION_SETTLE_SECS:-2}"
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    echo "White Noise notification subscription exited before readiness; see $err" >&2
    return 1
  fi
  # shellcheck disable=SC2034 # consumed by the sourcing orchestrator
  WN_NOTIFICATION_PID="$pid"
}

wn_has_valid_key_package() {
  local home="$1" peer="$2" result
  result=$(wn_result "$home" keys check "$peer") || return 2
  printf '%s' "$result" | jq -e '.status == "valid"' >/dev/null 2>&1
}

wn_wait_key_package() {
  local home="$1" peer="$2" deadline rc
  deadline=$(( $(date +%s) + WN_KEYPACKAGE_TIMEOUT_SECS ))
  while (( $(date +%s) < deadline )); do
    if wn_has_valid_key_package "$home" "$peer"; then
      return 0
    else
      rc=$?
      if [[ "$rc" == "2" ]]; then
        echo "White Noise KeyPackage check failed for $peer" >&2
        return 2
      fi
    fi
    sleep 1
  done
  echo "White Noise did not find a valid KeyPackage for $peer within ${WN_KEYPACKAGE_TIMEOUT_SECS}s" >&2
  return 1
}

wn_provision_identity() {
  local home="$1" relays="${2:-$TARGET_RELAY}" target_relay="${3:-$TARGET_RELAY}"
  local result pubkey npub key_package_status
  wn_start_daemon "$home" "$relays" || return $?
  result=$(wn_result "$home" create-identity) || return $?
  pubkey=$(printf '%s' "$result" | jq -r '.pubkey // .public_key // empty')
  [[ "$pubkey" =~ ^[0-9a-fA-F]{64}$ ]] || {
    echo "create-identity returned an invalid pubkey" >&2
    return 1
  }
  pubkey=$(printf '%s' "$pubkey" | tr '[:upper:]' '[:lower:]')
  npub=$(wn_hex_to_npub "$pubkey")
  printf '%s' "$pubkey" >"$home/pubkey.hex"
  printf '%s' "$npub" >"$home/npub.txt"
  : >"$home/seen_msg_ids.txt"
  mkdir -p "$home/groups"
  chmod 700 "$home/groups"

  wn_wait_relay_connected "$home" "$target_relay" || return $?
  if wn_has_valid_key_package "$home" "$pubkey"; then
    key_package_status=0
  else
    key_package_status=$?
  fi
  if [[ "$key_package_status" == "2" ]]; then
    return 2
  fi
  if [[ "$key_package_status" != "0" ]]; then
    wn_result "$home" --account "$pubkey" keys publish >/dev/null || return $?
    wn_wait_key_package "$home" "$pubkey" || return $?
  fi
  printf '%s\n' "$npub"
}

wn_group_id_hex() {
  python3 -c '
import json, sys
value = json.load(sys.stdin)
if isinstance(value, dict) and "group" in value:
    value = value["group"]
field = value.get("mls_group_id") or value.get("group_id") or value.get("id")
if isinstance(field, str):
    print(field)
    raise SystemExit(0)
if isinstance(field, dict):
    vector = (field.get("value") or {}).get("vec") or field.get("vec")
    if isinstance(vector, list):
        print("".join(f"{int(byte):02x}" for byte in vector))
        raise SystemExit(0)
raise SystemExit("missing mls_group_id")
'
}

wn_list_group_ids() {
  python3 -c '
import json, sys
value = json.load(sys.stdin)
if not isinstance(value, list):
    raise SystemExit("White Noise group list must be a JSON array")
for item in value:
    if isinstance(item, dict) and "group" in item:
        item = item["group"]
    if not isinstance(item, dict):
        continue
    field = item.get("mls_group_id") or item.get("group_id") or item.get("id")
    if isinstance(field, str):
        print(field)
    elif isinstance(field, dict):
        vector = (field.get("value") or {}).get("vec") or field.get("vec")
        if isinstance(vector, list):
            print("".join(f"{int(byte):02x}" for byte in vector))
'
}

wn_accept_invites() {
  local home="$1" pubkey invites group_id group_ids
  pubkey=$(cat "$home/pubkey.hex")
  invites=$(wn_result "$home" --account "$pubkey" groups invites) || return $?
  group_ids=$(printf '%s' "$invites" | wn_list_group_ids) || return $?
  while IFS= read -r group_id; do
    [[ -n "$group_id" ]] || continue
    wn_result "$home" --account "$pubkey" groups accept "$group_id" >/dev/null || return $?
  done <<EOF
$group_ids
EOF
}

wn_find_group_with() {
  local home="$1" peer="$2" pubkey peer_hex groups group_id group_ids members
  pubkey=$(cat "$home/pubkey.hex")
  peer_hex=$(wn_npub_to_hex "$peer") || return $?
  groups=$(wn_result "$home" --account "$pubkey" groups list) || return $?
  group_ids=$(printf '%s' "$groups" | wn_list_group_ids) || return $?
  while IFS= read -r group_id; do
    [[ -n "$group_id" ]] || continue
    members=$(wn_result "$home" --account "$pubkey" groups members "$group_id") || return $?
    if printf '%s' "$members" | jq -e --arg npub "$peer" --arg hex "$peer_hex" \
      '.. | strings | select(. == $npub or ascii_downcase == ($hex | ascii_downcase))' \
      >/dev/null 2>&1; then
      printf '%s\n' "$group_id"
      return 0
    fi
  done <<EOF
$group_ids
EOF
  return 1
}

wn_ensure_group_with() {
  local home="$1" peer="$2" cache pubkey group_id created
  # Validate before using the peer identifier as a cache filename.
  wn_npub_to_hex "$peer" >/dev/null || return $?
  cache="$home/groups/${peer}.gid"
  if [[ -f "$cache" ]]; then
    cat "$cache"
    return 0
  fi
  if group_id=$(wn_find_group_with "$home" "$peer"); then
    printf '%s' "$group_id" >"$cache"
    printf '%s\n' "$group_id"
    return 0
  fi

  pubkey=$(cat "$home/pubkey.hex")
  wn_wait_key_package "$home" "$peer" || return $?
  created=$(wn_result "$home" --account "$pubkey" groups create "Sonar smoke DM" "$peer") \
    || return $?
  group_id=$(printf '%s' "$created" | wn_group_id_hex) || return $?
  [[ "$group_id" =~ ^[0-9a-fA-F]+$ ]] || {
    echo "White Noise returned an invalid group id" >&2
    return 1
  }
  printf '%s' "$group_id" >"$cache"
  printf '%s\n' "$group_id"
}

wn_send_to() {
  local home="$1" peer="$2" message="$3" pubkey group_id
  pubkey=$(cat "$home/pubkey.hex")
  group_id=$(wn_ensure_group_with "$home" "$peer") || return $?
  wn_result "$home" --account "$pubkey" messages send "$group_id" "$message" >/dev/null
}

wn_drain_new() {
  local home="$1" pubkey groups group_id group_ids messages tmp
  pubkey=$(cat "$home/pubkey.hex")
  wn_accept_invites "$home" || return 1
  groups=$(wn_result "$home" --account "$pubkey" groups list) || return $?
  group_ids=$(printf '%s' "$groups" | wn_list_group_ids) || return $?
  while IFS= read -r group_id; do
    [[ -n "$group_id" ]] || continue
    messages=$(wn_result "$home" --account "$pubkey" messages list "$group_id" --limit 100) || return $?
    tmp=$(mktemp "$home/drain.XXXXXX") || return $?
    printf '%s' "$messages" >"$tmp" || { rm -f "$tmp"; return 1; }
    if ! WN_DRAIN_FILE="$tmp" WN_DRAIN_HOME="$home" WN_DRAIN_OWN="$pubkey" \
      WN_DRAIN_GROUP="$group_id" python3 <<'PY'
import hashlib
import json
import os

with open(os.environ["WN_DRAIN_FILE"], encoding="utf-8") as handle:
    messages = json.load(handle)
if not isinstance(messages, list):
    raise SystemExit("White Noise message list must be a JSON array")

home = os.environ["WN_DRAIN_HOME"]
own = os.environ["WN_DRAIN_OWN"].lower()
group_id = os.environ["WN_DRAIN_GROUP"]
seen_path = os.path.join(home, "seen_msg_ids.txt")
with open(seen_path, encoding="utf-8") as handle:
    seen = {line.strip() for line in handle if line.strip()}

charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def to_npub(pubkey):
    if pubkey.startswith("npub1"):
        return pubkey
    raw = bytes.fromhex(pubkey)
    accumulator = bits = 0
    data = []
    for value in raw:
        accumulator = (accumulator << 8) | value
        bits += 8
        while bits >= 5:
            bits -= 5
            data.append((accumulator >> bits) & 31)
    if bits:
        data.append((accumulator << (5 - bits)) & 31)
    def polymod(values):
        generators = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
        chk = 1
        for value in values:
            top = chk >> 25
            chk = ((chk & 0x1FFFFFF) << 5) ^ value
            for index, generator in enumerate(generators):
                if (top >> index) & 1:
                    chk ^= generator
        return chk
    expanded = [ord(ch) >> 5 for ch in "npub"] + [0] + [ord(ch) & 31 for ch in "npub"]
    check = polymod(expanded + data + [0] * 6) ^ 1
    checksum = [(check >> (5 * (5 - index))) & 31 for index in range(6)]
    return "npub1" + "".join(charset[value] for value in data + checksum)

own_npub = to_npub(own)
new_ids = []
for message in messages:
    if not isinstance(message, dict):
        continue
    message_id = message.get("id") or message.get("event_id") or ""
    if not message_id:
        encoded = json.dumps(message, sort_keys=True, separators=(",", ":")).encode()
        message_id = "sha256:" + hashlib.sha256(encoded).hexdigest()
    elif not isinstance(message_id, str):
        message_id = json.dumps(message_id, sort_keys=True, separators=(",", ":"))
    content = message.get("content") or ""
    author = message.get("author") or message.get("pubkey") or message.get("sender") or ""
    if isinstance(author, dict):
        author = author.get("pubkey") or author.get("hex") or ""
    if not isinstance(author, str) or not isinstance(content, str) or not content:
        continue
    author_hex = author.lower()
    if author_hex.startswith("npub1"):
        if len(author_hex) != 63 or any(char not in charset for char in author_hex[5:]):
            continue
        sender = author_hex
        if sender == own_npub:
            continue
    else:
        if author_hex == own:
            continue
        try:
            sender = to_npub(author_hex)
        except (ValueError, IndexError):
            continue
    if message_id and message_id in seen:
        continue
    if message_id:
        new_ids.append(message_id)
    cache = os.path.join(home, "groups", f"{sender}.gid")
    with open(cache, "w", encoding="utf-8") as handle:
        handle.write(group_id)
    print(json.dumps({"sender": sender, "content": content, "id": message_id}, separators=(",", ":")))

if new_ids:
    with open(seen_path, "a", encoding="utf-8") as handle:
        for message_id in new_ids:
            handle.write(message_id + "\n")
PY
    then
      rm -f "$tmp"
      return 1
    fi
    rm -f "$tmp" || return $?
  done <<EOF
$group_ids
EOF
}

wn_wait_for_message() {
  local home="$1" expected="$2" deadline line content drained
  deadline=$(( $(date +%s) + WN_MESSAGE_TIMEOUT_SECS ))
  while (( $(date +%s) < deadline )); do
    drained=$(wn_drain_new "$home") || return $?
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      content=$(printf '%s' "$line" | jq -r '.content // empty') || return $?
      if [[ "$content" == "$expected" ]]; then
        printf '%s\n' "$line"
        return 0
      fi
    done <<EOF
$drained
EOF
    sleep 1
  done
  echo "White Noise did not receive expected message within ${WN_MESSAGE_TIMEOUT_SECS}s" >&2
  return 1
}
