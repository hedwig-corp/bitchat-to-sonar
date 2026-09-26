# Agent QA harness

Scripts behind the `qa-pass` skill (`.agents/skills/qa-pass/SKILL.md`). They
let an agent — or a human — run an end-to-end QA pass of the Sonar apps
against real White Noise/Marmot peers, and they grow with every pass: each
bug found adds a scenario to [`docs/QA-SCENARIOS.md`](../../docs/QA-SCENARIOS.md)
and, when it can be driven headlessly, a function to `android-smoke.sh`.

```bash
cargo build -p sonar-cli --release --manifest-path core/Cargo.toml
export QA_HOME="$TMPDIR/sonar-qa-$(basename "$PWD")"   # per worktree (the default)

export QA_SERIAL="$(scripts/qa/android-setup.sh)"   # QA emulator + Debug build + logcat
scripts/qa/android-smoke.sh                          # scripted scenarios, exit = failures

export QA_UDID="$(scripts/qa/ios-setup.sh)"          # QA simulator + signed Debug + log
scripts/qa/ios-share-smoke.sh                        # share-sheet scenarios, exit = failures
scripts/qa/idle-cpu.sh ios "$QA_UDID" 60 --max 3
```

| Script | Purpose |
|---|---|
| `android-setup.sh` | Boot the dedicated AVD (`Sonar_QA_API_36`) by serial — refusing a port owned by another AVD, or an emulator another worktree set up in the same boot (`--take-over` overrides) — `installDebug` in place, logcat to `$QA_HOME`. `--fresh` clears app data for onboarding scenarios (emulators only). Refuses a missing Breez key / `google-services.json` unless `--allow-missing-config`. |
| `ios-setup.sh` | Create/boot this worktree's "Sonar QA <worktree>" simulator (so parallel agents never share one), build **signed** Debug (App Group ⇒ the Marmot store opens), install, stream the unified log. Refuses a stale `sonarffi.xcframework` (`--build-core` / `--trust-core`) and missing Breez / Firebase config unless `--allow-missing-config`; `BREEZ_API_KEY` in the environment counts. |
| `android-ui.sh` | uiautomator driver: `dump`, `tapx`/`tapt`/`tapedit`, `wait`/`gone`, `ime`, `shot`. |
| `peers.sh` | Fresh `sonar-cli` counterparties: `new`, `send`, `send-image`, `listen`, `expect`. |
| `android-smoke.sh` | Automated registry scenarios (`qaNNN` = `QA-NNN`). |
| `ios-share-smoke.sh` | iOS share-sheet scenarios QA-080…092: shares real files into Sonar through the system share sheet (Files, Photos, and `ios-share/QAShareHost`, a stand-in third-party app), picks the chat with a fresh peer, and asserts on what the **peer** received (name, MIME, sha256). XCUITest driver in `ios-share/`, generated into `$QA_HOME/share/driver` — the app project is untouched. Pass scenario ids to run a subset. |
| `idle-cpu.sh` | Average app CPU over a window on Android or an iOS simulator. |
| `ios-drive.sh` | Headless iOS UI driver: one XCUITest (generated from `ios-driver/`, outside the app's Xcode project) runs a `;`-separated step script — `launch`, `tapc:<label>`, `longpress:<text>`, `tap:👍`, `expect:<text>`, `count:<text>=n`, `shot`, `tree` — against the installed app by UDID. No Simulator panel needed. |
| `qr-decode.swift` | Print QR payloads found in a screenshot (macOS CoreImage). |

Safety: nothing here uninstalls or resets an app on a physical device; the
Android scripts refuse non-emulators, the iOS scripts only touch the named QA
simulator. See the CLAUDE.md "Never Uninstall Device Apps" rule.

iOS has two headless XCUITest drivers: `ios-share-smoke.sh` for the share
sheet (traps below) and `ios-drive.sh` for everything else; the iOS Simulator
MCP still works by hand when the panel is available. There is no scripted
`ios-smoke` yet: scenario steps are composed per pass from the registry. Read
labels from the `tree:` dump, never coordinates off a screenshot;
`tapid:`/`tapxy:` exist only for controls that have no label (itself an
accessibility finding). Both drivers speak a `;`-separated step language — fold
them into one `ios-smoke` rather than growing a third.

Share-sheet traps (all handled by the script, listed so a manual pass does not
fall into them):

- **The extension cannot open Sonar.** `extensionContext.open(sonar://share)`
  is refused for share extensions, so after "Open Sonar to send" the user
  switches to Sonar by hand. Activating Sonar *before* the payload is committed
  interrupts the extension mid-copy — wait for `payload.json` in the App
  Group's `SharedInbox/` first (the driver's `handoff` step).
- **Files hides extensions** in labels (`report`); its cells are identified
  `report, csv`. Two elements are labelled "Browse" (tab and back button).
- **Stale payloads:** an abandoned picker leaves its payload staged for 24 h
  and it will be offered again; the script clears `SharedInbox` before each
  scenario (QA-089 builds that situation on purpose).
- **XCTFail unwinds past Swift `defer`** when `continueAfterFailure` is off —
  write logs eagerly.
- A notification prompt from a normal launch survives relaunches and holds
  startup behind it (`tapif@sb:Allow`).
