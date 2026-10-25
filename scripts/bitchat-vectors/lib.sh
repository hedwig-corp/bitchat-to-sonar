# Shared helpers for regenerate.sh and cross-replay.sh. Sourced, not run.
# Expects GEN (core/bitchat-protocol/vectors/generators) to be set.

clone_at() { # url dir rev -> prints the short revision
  git clone --quiet --filter=blob:none "$1" "$2"
  git -C "$2" checkout --quiet "$3"
  git -C "$2" rev-parse --short HEAD
}

# Make the app-target codecs of a permissionlesstech/bitchat checkout
# compilable inside localPackages/BitFoundation/Tests/BitFoundationTests, so
# `swift test` can run them without the app target or a simulator. The files
# are taken FRESH from the checkout, so an upstream change to them changes
# what the generators and observers see (the committed App*.swift under
# generators/ are only the pinned-revision copies, for reading).
install_ios_app_codecs() { # checkout tests-dir
  local dir="$1" tests="$2"
  # Stubs that stand in for app-target types the codecs reference.
  cp "$GEN/bitchat-ios-swift/AppStubs.swift" "$tests/"
  cp "$dir/bitchat/Protocols/Packets.swift" "$tests/AppPackets.swift"
  cp "$dir/bitchat/Models/NoisePayload.swift" "$tests/AppNoisePayload.swift"
  cp "$dir/bitchat/Services/BLE/BLEOutboundFragmentPlanner.swift" "$tests/AppBLEOutboundFragmentPlanner.swift"
  # BitchatFilePacket drags in BitLogger and PrivateMediaMessageIdentity
  # (app-only); drop both, the TLV codec is self-contained above them.
  python3 - "$dir/bitchat/Protocols/BitchatFilePacket.swift" "$tests/AppBitchatFilePacket.swift" <<'PY'
import sys
src = open(sys.argv[1]).read().split("\n")
out = []
for line in src:
    if line.strip() == "import BitLogger":
        continue
    if line.startswith("/// Wire-compatible identity for private media"):
        break
    out.append(line)
open(sys.argv[2], "w").write("\n".join(out).rstrip() + "\n")
PY
  # The receive-side fragment parser (BLEFragmentHeader) lives in the same
  # file as the reassembly buffer, which needs app services; keep only the
  # header and its key.
  python3 - "$dir/bitchat/Services/BLE/BLEFragmentAssemblyBuffer.swift" "$tests/AppBLEFragmentHeader.swift" <<'PY'
import sys
src = open(sys.argv[1]).read()
cut = src.index("struct BLEFragmentAssemblyBuffer")
open(sys.argv[2], "w").write(src[:cut].rstrip() + "\n")
PY
}
