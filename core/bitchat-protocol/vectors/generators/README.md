# Vector generators

Each directory holds the test that produced the sibling `../bitchat-*.json`
by running inside the UPSTREAM reference codebase — the vectors are the
reference codec's own output, not a transliteration.

| generator | runs in | output |
|---|---|---|
| `bitchat-ios-swift/SonarVectorDump.swift` (+ `AppStubs.swift`; the `App*.swift` files are the pinned-revision copies of app-target codecs) | `localPackages/BitFoundation/Tests/BitFoundationTests` of permissionlesstech/bitchat, `swift test --filter SonarVectorDump` | `../bitchat-ios.json` |
| `bitchat-android-kotlin/SonarVectorDumpTest.kt` | `app/src/test/java/com/bitchat/android/protocol` of permissionlesstech/bitchat-android, `./gradlew :app:testDebugUnitTest --tests …SonarVectorDumpTest` | `../bitchat-android.json` |

Both read `SONAR_VECTOR_OUT` for the output path. Do not run them by hand:
`scripts/bitchat-vectors/regenerate.sh` clones upstream (HEAD or a given
revision), installs the generator, runs it, normalizes the dump
(`normalize.py`: drops the two 70000-byte stress cases, writes long
single-byte runs as `repeat:xx*N`) and diffs it against the committed file
(`diff.py`, keyed by kind + name). CI does the same daily and on every PR
touching the crate. The step that makes the iOS app-target codecs compile
inside BitFoundation's tests is shared with the cross-replay
(`scripts/bitchat-vectors/lib.sh`, `install_ios_app_codecs`).

Adding a case: extend the generator, run `regenerate.sh --write`, and replay
with `cargo test -p bitchat-protocol --test vectors`; the Rust harness fails on
an unknown kind, so a new kind needs a new arm there too.
