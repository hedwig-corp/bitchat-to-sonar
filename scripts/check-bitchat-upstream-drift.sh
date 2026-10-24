#!/usr/bin/env bash
# Fails when a bitchat reference client changed one of the codec files that
# core/bitchat-protocol/SPEC.md and vectors/ were derived from.
#
# "Compatible with upstream" is only true for the revisions the vectors were
# generated at. This check makes a newer upstream revision a visible event
# instead of a silent assumption: when it fails, re-run the vector generators
# (core/bitchat-protocol/vectors/generators/) against upstream HEAD, replay
# them with `cargo test -p bitchat-protocol --test vectors`, update the
# revision pins below and the SPEC.md header, and decide on every changed
# expected value — a changed value is a wire change, not a test to edit.
#
# Usage: scripts/check-bitchat-upstream-drift.sh [--update-pins]
#   exit 0  no codec file changed upstream since the pinned revision
#   exit 1  drift (lists the changed files and the upstream commits)
#   exit 2  could not reach an upstream repository
#
# Runs weekly and on every PR that touches the crate
# (.github/workflows/bitchat-upstream-drift.yml).
set -euo pipefail

# Pinned revisions: the ones the vectors were generated from. Keep in lockstep
# with the header table of core/bitchat-protocol/SPEC.md.
IOS_REPO="https://github.com/permissionlesstech/bitchat"
IOS_PIN="30c58eee"
IOS_PATHS=(
  localPackages/BitFoundation/Sources/BitFoundation/BinaryProtocol.swift
  localPackages/BitFoundation/Sources/BitFoundation/BitchatPacket.swift
  localPackages/BitFoundation/Sources/BitFoundation/MessagePadding.swift
  localPackages/BitFoundation/Sources/BitFoundation/CompressionUtil.swift
  localPackages/BitFoundation/Sources/BitFoundation/Constants.swift
  localPackages/BitFoundation/Sources/BitFoundation/PeerCapabilities.swift
  localPackages/BitFoundation/Sources/BitFoundation/PeerID.swift
  localPackages/BitFoundation/Sources/BitFoundation/MessageType.swift
  localPackages/BitFoundation/Sources/BitFoundation/PacketPayloadLimits.swift
  localPackages/BitFoundation/Sources/BitFoundation/FileTransferLimits.swift
  bitchat/Protocols/Packets.swift
  bitchat/Protocols/BitchatFilePacket.swift
  bitchat/Protocols/BitchatProtocol.swift
  bitchat/Models/NoisePayload.swift
  bitchat/Noise/NoiseProtocol.swift
  bitchat/Noise/NoiseSession.swift
  bitchat/Services/BLE/BLENoisePayloadFactory.swift
  bitchat/Services/BLE/BLEOutboundPacketPolicy.swift
)
ANDROID_REPO="https://github.com/permissionlesstech/bitchat-android"
ANDROID_PIN="dfc67dad"
ANDROID_PATHS=(
  app/src/main/java/com/bitchat/android/protocol/BinaryProtocol.kt
  app/src/main/java/com/bitchat/android/protocol/MessagePadding.kt
  app/src/main/java/com/bitchat/android/protocol/CompressionUtil.kt
  app/src/main/java/com/bitchat/android/model/IdentityAnnouncement.kt
  app/src/main/java/com/bitchat/android/model/PeerCapabilities.kt
  app/src/main/java/com/bitchat/android/model/NoiseEncrypted.kt
  app/src/main/java/com/bitchat/android/model/BitchatFilePacket.kt
  app/src/main/java/com/bitchat/android/model/FragmentPayload.kt
  app/src/main/java/com/bitchat/android/model/AuthenticatedPeerState.kt
  app/src/main/java/com/bitchat/android/noise/NoiseSession.kt
  app/src/main/java/com/bitchat/android/noise/NoisePeerIdentity.kt
  app/src/main/java/com/bitchat/android/util/AppConstants.kt
)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

drift=0

check_repo() {
  local name="$1" url="$2" pin="$3"; shift 3
  local paths=("$@")
  local dir="$WORK/$name"
  # Blobless clone: full history (so the pin resolves) without file contents.
  if ! git clone --quiet --filter=blob:none --no-checkout "$url" "$dir" 2>/dev/null; then
    echo "ERROR  cannot clone $url"
    return 2
  fi
  local head
  head="$(git -C "$dir" rev-parse --short HEAD)"
  if ! git -C "$dir" cat-file -e "${pin}^{commit}" 2>/dev/null; then
    echo "ERROR  pinned revision $pin not found in $url (force-push or branch move?)"
    return 2
  fi
  local changed
  changed="$(git -C "$dir" diff --name-only "$pin" HEAD -- "${paths[@]}" || true)"
  if [[ -z "$changed" ]]; then
    echo "OK     $name: codec files unchanged $pin..$head"
    return 0
  fi
  echo "DRIFT  $name: codec files changed between pinned $pin and upstream $head:"
  echo "$changed" | sed 's/^/         /'
  echo "       upstream commits touching them:"
  git -C "$dir" log --format='         %h %ad %s' --date=short "$pin..HEAD" -- "${paths[@]}" | head -40
  return 1
}

for spec in "ios|$IOS_REPO|$IOS_PIN|IOS_PATHS" "android|$ANDROID_REPO|$ANDROID_PIN|ANDROID_PATHS"; do
  IFS='|' read -r name url pin arr <<<"$spec"
  eval "paths=(\"\${${arr}[@]}\")"
  set +e
  check_repo "$name" "$url" "$pin" "${paths[@]}"
  rc=$?
  set -e
  case $rc in
    1) drift=1 ;;
    2) exit 2 ;;
  esac
done

if [[ $drift -ne 0 ]]; then
  cat <<'MSG'

A reference client changed its wire codec. Regenerate the vectors from the
new revision (core/bitchat-protocol/vectors/generators/), replay them with
`cargo test -p bitchat-protocol --test vectors`, update the pins in this script
and the SPEC.md header, and treat any changed expected value as a wire-format
decision. See CLAUDE.md "bitchat Wire Protocol Rule".
MSG
  exit 1
fi
