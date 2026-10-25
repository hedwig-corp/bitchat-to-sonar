# Cross-replay: bitchat iOS against bitchat-android

`../bitchat-ios.json` and `../bitchat-android.json` are each one reference
client's own output. `regenerate.sh` shows each client still produces its own
file; `tests/vectors.rs` shows the Rust crate agrees with both. This directory
shows whether the two reference clients agree **with each other**.

```
scripts/bitchat-vectors/cross-replay.sh            # both upstreams at HEAD
scripts/bitchat-vectors/cross-replay.sh --only ios # one observer
scripts/bitchat-vectors/cross-replay.sh --only ios \
  --ios-repo https://github.com/<fork>/bitchat --ios-rev <branch>   # a proposed fix
```

How it works:

1. `scripts/bitchat-vectors/cross.py ops` rewrites each vector file into
   neutral operations: encode a packet, decode a frame, rebuild the signature
   preimage of the decoded packet (the verify path), re-encode it (the relay
   path), and encode/decode every TLV. Each operation carries the producing
   codec's output as the expected value.
2. `SonarCrossObserver.swift` (installed into BitFoundation's tests with the
   app-target codecs, as `regenerate.sh` does) and `SonarCrossObserverTest.kt`
   (installed into bitchat-android's unit tests) run every operation through
   the real codec and record the result. They compare nothing.
3. `cross.py compare` checks four directions. Self-replay (iOS on iOS,
   Android on Android) must agree completely; that is what shows the harness
   is right. Cross-replay differences must each match an entry in
   `ledger.json`, including fields a codec cannot express ("not modeled"),
   and every entry must still reproduce.

`ledger.json` is the machine-checked form of SPEC.md §12.1. When upstream
changes one side, CI fails in one of two ways: an unexplained difference (a
new divergence: decide which side is right, then record it with its wire
consequence) or a stale entry (a divergence went away: remove the entry and the
SPEC row).
