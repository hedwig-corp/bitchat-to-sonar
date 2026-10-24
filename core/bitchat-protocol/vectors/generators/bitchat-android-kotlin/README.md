# bitchat-android vector generator

`SonarVectorDumpTest.kt` is the verbatim JUnit test that produced
`vectors/bitchat-android.json` from upstream
`permissionlesstech/bitchat-android@dfc67dad` (release 2.0.3). It calls the
real upstream Kotlin codec (`BinaryProtocol`, `MessagePadding`,
`CompressionUtil`, `IdentityAnnouncement`, `PeerCapabilities`, `NoisePayload`,
`PrivateMessagePacket`, `BitchatFilePacket`, `FragmentPayload`,
`NoisePeerIdentity`) and writes the JSON with a hand-rolled sorted-key emitter.

## Regenerate

1. Check out upstream at the pinned rev (use a detached worktree so you do not
   touch your working branch):

   ```sh
   git -C ~/github/work/bitchat-android fetch origin
   git -C ~/github/work/bitchat-android worktree add /tmp/bitchat-android-upstream dfc67dad --detach
   cp ~/github/work/bitchat-android/local.properties /tmp/bitchat-android-upstream/   # sdk.dir=...
   ```

2. Drop the test into the upstream `app` module's JVM unit-test source set:

   ```
   app/src/test/java/com/bitchat/android/protocol/SonarVectorDumpTest.kt
   ```

   Set `SONAR_VECTOR_OUT` to where the JSON should be written (the parent
   directory is created); without it the test writes
   `app/build/sonar-bitchat-android-vectors.json`. Prefer
   `scripts/bitchat-vectors/regenerate.sh --only android`, which does all of
   this against upstream HEAD (or `--android-rev`), normalizes the dump and
   diffs it against the committed file.

3. Run only this test through the upstream Gradle unit-test harness
   (JDK 17; `android.util.Log` is already stubbed upstream by
   `app/src/test/kotlin/android/util/Log.kt`, no `returnDefaultValues` needed):

   ```sh
   cd /tmp/bitchat-android-upstream
   ANDROID_HOME=~/Library/Android/sdk \
   ./gradlew :app:testDebugUnitTest --tests 'com.bitchat.android.protocol.SonarVectorDumpTest'
   ```

   `--offline` fails unless AGP (9.3.1 at this rev) is already in the Gradle
   cache. The test prints `SONAR_VECTORS_WRITTEN <path> cases=<n>` to the test
   stdout (see `app/build/test-results/testDebugUnitTest/`).

4. Remove the worktree: `git -C ~/github/work/bitchat-android worktree remove --force /tmp/bitchat-android-upstream`.

Notes for consumers: `signing_preimage` is `toBinaryDataForSigning()`, which
upstream encodes with padding and TTL=0; `compress` outputs are Java raw
DEFLATE (`Deflater(DEFAULT_COMPRESSION, nowrap=true)`) and must be inflated,
not byte-compared, by other encoders.
