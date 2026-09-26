#!/usr/bin/env bash
# mdk-upgrade.sh — headless side of the MDK 0.8 → 0.9.14 upgrade QA
# (docs/QA-SCENARIOS.md QA-070…QA-077, PR #613).
#
# The upgrade cannot be faked with one binary: the app must build history on
# an MDK 0.8 (wire 0xf2ee) install, then be replaced IN PLACE by the 0.9.14
# build (wire 0xf2f1). Peers are the same: an 0.8 `sonar-cli` home is later
# "upgraded" by running the 0.9 `sonar-cli` on the same --home.
#
#   mdk-upgrade.sh peer <name> [08|09]          fresh peer on that CLI (default 08)
#   mdk-upgrade.sh seed <name> <app-npub> <n> [prefix]
#                                                 peer sends n numbered texts to the app
#   mdk-upgrade.sh upgrade-peer <name>           run the 0.9 CLI on the peer's home
#                                                 once (migrates its 0.8 store) and
#                                                 publish a 0.9 KeyPackage
#   mdk-upgrade.sh send|expect|listen <name> …   peers.sh verbs on the peer's CURRENT CLI
#   mdk-upgrade.sh groups <name>                 the peer's Marmot groups (JSON lines)
#   mdk-upgrade.sh wire <name>                   0.8 / 0.9 KeyPackage wire the peer
#                                                 publishes (0xf2ee vs 0xf2f1)
#   mdk-upgrade.sh store [udid]                  the app's Marmot store files in the
#                                                 simulator App Group (QA-070: after the
#                                                 upgrade a *.mdk08.bak must sit next
#                                                 to the live DB)
#
# Env:
#   QA_HOME     per-worktree artifacts (default $TMPDIR/sonar-qa-<worktree>)
#   QA_UDID     the QA simulator (never `booted`; see reference.md)
#   MDK08_CLI   sonar-cli built from an MDK 0.8 core (a pre-#613 main). Build it
#               from a second checkout:
#                 git worktree add --detach <dir> <pre-613 commit>
#                 cargo build --release -p sonar-cli --manifest-path <dir>/core/Cargo.toml
#   SONAR_CLI   the 0.9.14 sonar-cli (default core/target/release/sonar-cli)
#
# Each peer remembers which CLI owns its home in $QA_HOME/peers/<name>/cli, so
# `send`/`expect` never run the 0.8 binary on a migrated home (it cannot open
# the 0.9 store) or the 0.9 binary on a home that must stay 0.8 (QA-073).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QA_HOME="${QA_HOME:-${TMPDIR:-/tmp}/sonar-qa-$(basename "$ROOT")}"
export QA_HOME
CLI09="${SONAR_CLI:-$ROOT/core/target/release/sonar-cli}"
CLI08="${MDK08_CLI:-}"
PEERS="$QA_HOME/peers"
BUNDLE=sh.hedwig.sonar
mkdir -p "$PEERS"

die() { echo "mdk-upgrade: $*" >&2; exit 1; }
home() { echo "$PEERS/${1:?peer name}"; }
cli_for() {
  local f; f="$(home "$1")/cli"
  [[ -f "$f" ]] || die "peer '$1' has no CLI marker — create it with '$0 peer $1'"
  cat "$f"
}
need08() {
  [[ -n "$CLI08" && -x "$CLI08" ]] || die "MDK08_CLI must point at an MDK 0.8 sonar-cli (see header)"
}
need09() { [[ -x "$CLI09" ]] || die "no 0.9 sonar-cli at $CLI09 (cargo build -p sonar-cli --release)"; }
# peers <verb> <name> … — run a peers.sh verb on that peer's CURRENT CLI.
# Resolve the binary in its own assignment: a failing `$(cli_for …)` used as a
# command prefix is ignored by `set -e`, and peers.sh would then silently fall
# back to its default (0.9) CLI — migrating a peer that must stay on 0.8.
peers() {
  local bin
  bin="$(cli_for "${2:?peer name}")"
  SONAR_CLI="$bin" "$ROOT/scripts/qa/peers.sh" "$@"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  peer)
    name="${1:?peer <name> [08|09]}"; wire="${2:-08}"
    case "$wire" in
      08) need08; bin="$CLI08" ;;
      09) need09; bin="$CLI09" ;;
      *) die "wire must be 08 or 09" ;;
    esac
    SONAR_CLI="$bin" "$ROOT/scripts/qa/peers.sh" new "$name"
    echo "$bin" > "$(home "$name")/cli" ;;
  seed)
    name="${1:?seed <name> <app-npub> <n> [prefix]}"; to="${2:?app npub}"; n="${3:?count}"
    prefix="${4:-$name}"
    bin="$(cli_for "$name")"
    for i in $(seq 1 "$n"); do
      # --push-settle-secs 0: history seeding does not need MIP-05 pushes.
      "$bin" --home "$(home "$name")" send --to "$to" --text "$prefix $i/$n" \
        --push-settle-secs 0 2>/dev/null | grep -q '"type"' \
        || die "seed send $i/$n failed for '$name'"
    done
    echo "seeded $n messages from $name" ;;
  upgrade-peer)
    name="${1:?upgrade-peer <name>}"; need09
    [[ "$(cli_for "$name")" != "$CLI09" ]] || die "peer '$name' is already on the 0.9 CLI"
    # The first 0.9 open detects the 0.8 SQLCipher file, extracts the
    # transcript and renames it *.mdk08.bak — the same core path the app runs.
    "$CLI09" --home "$(home "$name")" publish 2>/dev/null | grep '"type"' \
      || die "0.9 CLI could not open/migrate '$name'"
    echo "$CLI09" > "$(home "$name")/cli"
    find "$(home "$name")" -name '*.mdk08.bak*' | grep -q . \
      && echo "peer '$name' migrated (*.mdk08.bak present)" \
      || echo "WARNING: no *.mdk08.bak under $(home "$name") — check where the CLI keeps its DB" >&2 ;;
  send|expect|listen|npub|send-image)
    name="${1:?$cmd <name> …}"
    peers "$cmd" "$@" ;;
  groups)
    name="${1:?groups <name>}"
    "$(cli_for "$name")" --home "$(home "$name")" groups 2>/dev/null ;;
  wire)
    name="${1:?wire <name>}"
    [[ "$(cli_for "$name")" == "$CLI09" ]] && echo "0.9 (0xf2f1)" || echo "0.8 (0xf2ee)" ;;
  store)
    udid="${1:-${QA_UDID:?store [udid] or QA_UDID}}"
    found=0
    while IFS= read -r line; do
      dir="${line#*	}"
      [[ -d "$dir" ]] || continue
      while IFS= read -r f; do
        found=1
        printf '%s\t%s bytes\n' "${f#"$dir"/}" "$(stat -f %z "$f")"
      done < <(find "$dir" -maxdepth 3 -type f \( -name '*marmot*' -o -name '*.mdk08.bak*' \
                 -o -name '.sonar-*' -o -name '*.sqlite*' -o -name '*.db*' \) 2>/dev/null | sort)
    done < <(xcrun simctl get_app_container "$udid" "$BUNDLE" groups 2>/dev/null)
    (( found )) || die "no Marmot store files found for $BUNDLE on $udid" ;;
  *)
    sed -n '2,33p' "$0"; exit 2 ;;
esac
