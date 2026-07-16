# :baselineprofile

Macrobenchmark module that generates the Baseline Profile baked into release
APKs of `:composeApp` (issue #305: chat-open first-composition jank). The
generated rules live in `composeApp/src/androidRelease/generated/baselineProfiles/`
and are committed; regenerate after large UI/startup changes.

## Generate

Needs a connected device or emulator on API 33+ (unrooted is fine — e.g. the
`Medium_Phone_API_36` AVD). With two devices attached, pin one via
`ANDROID_SERIAL`.

```bash
cd apps/sonar
ANDROID_SERIAL=emulator-5556 ./gradlew :composeApp:generateBaselineProfile \
  -Pandroid.testInstrumentationRunnerArguments.sonarBenchNsec=nsec1...
```

`sonarBenchNsec` is optional but strongly recommended: it onboards a bench
account (restore path) with a seeded **"Sonar agent DM"** conversation holding
text + image messages, so the profile covers the chat-open and
transcript-scroll journey — the jank this profile exists to fix.

**Seeding order matters.** An MLS welcome encrypts to the *specific
KeyPackage* the sender fetched, and its private key lives in the app's local
DB — a reinstalled app cannot decrypt a welcome sent to its previous install.
So seed AFTER the target install has published its KeyPackage:

1. Run generation once with the key (it restores the account and publishes a
   fresh KeyPackage; the chat journey logs "Seeded chat never appeared" —
   expected on the first pass). Pass
   `-Pandroid.injected.androidTest.leaveApksInstalledAfterTest=true` so the
   onboarded install survives the run.
2. Seed the conversation from a **freshly minted** cli identity (a reused cli
   home resends into the old, undecryptable group):
   ```bash
   SONAR_CLI_HOME=$(mktemp -d) sh -c '
     sonar-cli init &&
     sonar-cli send --to <bench npub> --text "seed" &&
     sonar-cli send --to <bench npub> --file photo.png --kind image'
   ```
3. Re-run generation (same flags). It finds the chat already synced and
   profiles the open/scroll journey ("seeded chat already present").

Never pass a real user's key; mint a throwaway identity with `sonar-cli init`.

## Verify it ships

```bash
unzip -l composeApp/build/outputs/apk/release/composeApp-release.apk \
  | grep baseline.prof            # should be tens of KB, not the 7 KB default
adb install composeApp/build/outputs/apk/release/composeApp-release.apk
adb shell dumpsys package dexopt | grep -A2 chat.bitchat.sonar   # speed-profile
```

Measure the effect with `scripts/bench/android-chat-open-bench.sh` (Debug
marker) or `dumpsys gfxinfo chat.bitchat.sonar` around a chat open.
