# QA pass — reference (harness, traps, known non-bugs)

Companion to [SKILL.md](SKILL.md). Everything here was learned the hard way in
the 2026-09-23 iOS (#615) and Android (#616) passes.

## Tools

| Tool | What it does |
|---|---|
| `scripts/qa/android-setup.sh` | boots the QA AVD by serial, `installDebug` in place, logcat → `$QA_HOME` |
| `scripts/qa/ios-setup.sh` | creates/boots a named QA simulator, signed Debug build, install, log stream |
| `scripts/qa/android-ui.sh` | adb/uiautomator driver: `dump`, `tapx`/`tapt`, `wait`, `ime`, `shot` |
| `scripts/qa/peers.sh` | fresh `sonar-cli` peers: `new`, `send`, `send-image`, `listen`, `expect` |
| `scripts/qa/android-smoke.sh` | scripted registry scenarios on Android; exit status = failures |
| `scripts/qa/idle-cpu.sh` | average CPU of the app over a window (Android `/proc`, iOS host `ps`) |
| iOS Simulator MCP | `attach` first, then `tap`/`text`/`swipe`/`screenshot` in **points** |

## Android traps

- **Coordinates come from `android-ui.sh dump`, never from a screenshot.**
  `shot` downscales 1080×2400 to 405×900 (÷2.667); reading pixels off it and
  tapping produced several phantom "bugs".
- **Prefer `tapx` (exact) over `tapt` (substring).** "Allow" matches the dialog
  title "Allow Sonar to…"; "Nickname" matches the heading "Pick a nickname".
  `tapx "Start secure chat" -1` picks the button, not the row title.
- **Search is not auto-focused:** tap `"Search chats"` before typing.
- **`input text`:** spaces become `%s` (the helper does it); avoid `&'"()` in
  test strings. Keystrokes typed right after a navigation can be lost — sleep
  ~1 s after the screen changes.
- **Back twice from a chat exits the app** when the keyboard is already
  hidden. Use `am start -n chat.bitchat.sonar/.MainActivity` to return.
- **Some `KEYCODE`s open the system clipboard editor** — stick to 3 (home),
  4 (back), 67 (delete).
- Keyboard state: `android-ui.sh ime` (reads `mInputShown`).
- Notifications: `adb shell cmd statusbar expand-notifications`, then tap by
  text; content via `dumpsys notification --noredact | grep android.text=`.
- Gallery images: `adb push x.png /sdcard/Pictures/` then
  `am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/x.png`.
  Picker: tap the thumbnail → *Done* → the preview's send button.
- **Stale Rust core:** after `core/` edits Gradle can ship an old `.so`. Run
  `core/build-android.sh` and check a new symbol with `strings`.
- **zsh:** `A="adb -s X"; $A shell …` does not word-split (nothing runs), and
  `PIPESTATUS` does not exist — use explicit commands and `set -o pipefail`.

## iOS traps

- **Build signed, not with `scripts/bench/build-sim.sh`:** the unsigned bench
  build has no App Group, so the Marmot store never opens.
- **Rust core:** `ios-setup.sh` needs `sonarffi.xcframework`. Copy it from a
  worktree whose `git rev-parse HEAD:core` matches; after a core change rebuild
  only the simulator slice (`cargo build --release --target aarch64-apple-ios-sim
  -p sonar-ffi --lib --features calls-audio`, `strip -x`, copy over
  `ios-arm64-simulator/libsonar_ffi.a`).
- **Shared Mac:** another agent once ran `simctl uninstall booted` and wiped
  the app under test. Everything by UDID; tests on a *second* simulator
  (`xcodebuild test` clones and reboots its destination).
- **Points, not pixels:** MCP screenshots are ~2.29 px per point on an
  iPhone 17 Pro (920 px wide ↔ 402 pt). A long-press "bug" was a ÷2.5 error.
- `inspect` is sometimes unavailable — fall back to `screenshot`.
- Text injection works: tap the field, wait ≥ 1 s, then `text`. There is no
  backspace — to clear a search sheet, `simctl terminate` + `launch`.
  Swiping a sheet's handle does not always dismiss it.
- Long-press = `tap` with `duration` ≥ 0.9; the first attempt right after a
  navigation sometimes misses.
- Location: `xcrun simctl location <udid> set 39.15,-123.21` (the "Around
  you" card needs it).
- `xcodebuild … | grep` masks failures: use `set -o pipefail` and look for
  `BUILD SUCCEEDED` / `TEST SUCCEEDED`. A suite failing with simulator-clone
  errors is CoreSimulator exhaustion, not your diff.
- `main` hides the iOS composer while a chat hydrates (fixed in #615): on a
  build without it, typing right after opening a chat goes nowhere.

## Peers (`sonar-cli`)

- Only **1:1 welcomes auto-join**; multi-member group invites stay pending,
  so group delivery cannot be verified with CLI peers (group support: #547).
- The default Blossom server (`push.sonar.hedwig.sh`) took **~36 s** for a
  33 KB upload on 2026-09-23 from both the app and the CLI; `nostr.download`
  took 6 s. Report upload time separately; do not file it as an app bug.
- `auth-required` warnings from `relay.damus.io` are harmless.
- A peer created with `peers.sh new` has published a KeyPackage; if the app
  cannot start a chat with an old peer, create a new one.

## Known behaviour that is NOT a bug

- Notification body "Open Sonar to read it." — message previews are **off by
  default** (`notifPreview`).
- A chat titled "Sonar agent DM" — that is `sonar-cli`'s default group name.
- No reaction bar on long-press — reactions are not implemented on either app.
- "N here now" counts include you.

## CI notes

- iOS tests do **not** run in CI; run the ones you touched locally and say so.
- Known red checks not caused by app changes: "Wallet Breez island" (upstream
  repo recreated; see #614) and the `SystemBackAndroidTest` window-focus flake.
