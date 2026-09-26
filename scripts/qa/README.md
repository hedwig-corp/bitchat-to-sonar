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
scripts/qa/idle-cpu.sh ios "$QA_UDID" 60 --max 3
```

| Script | Purpose |
|---|---|
| `android-setup.sh` | Boot the dedicated AVD (`Sonar_QA_API_36`) by serial — refusing a port owned by another AVD, or an emulator another worktree set up in the same boot (`--take-over` overrides) — `installDebug` in place, logcat to `$QA_HOME`. `--fresh` clears app data for onboarding scenarios (emulators only). Refuses a missing Breez key / `google-services.json` unless `--allow-missing-config`. |
| `ios-setup.sh` | Create/boot this worktree's "Sonar QA <worktree>" simulator (so parallel agents never share one), build **signed** Debug (App Group ⇒ the Marmot store opens), install, stream the unified log. Refuses a stale `sonarffi.xcframework` (`--build-core` / `--trust-core`) and missing Breez / Firebase config unless `--allow-missing-config`; `BREEZ_API_KEY` in the environment counts. |
| `android-ui.sh` | uiautomator driver: `dump`, `tapx`/`tapt`/`tapedit`, `wait`/`gone`, `ime`, `shot`. |
| `peers.sh` | Fresh `sonar-cli` counterparties: `new`, `send`, `send-image`, `listen`, `expect`, and for reactions `id-of`, `react`, `expect-reaction`. |
| `android-smoke.sh` | Automated registry scenarios (`qaNNN` = `QA-NNN`). |
| `idle-cpu.sh` | Average app CPU over a window on Android or an iOS simulator. |
| `ios-drive.sh` | Headless iOS UI driver: one XCUITest (generated from `ios-driver/`, outside the app's Xcode project) runs a `;`-separated step script — `launch`, `tapc:<label>`, `longpress:<text>`, `tap:👍`, `expect:<text>`, `count:<text>=n`, `shot`, `tree` — against the installed app by UDID. No Simulator panel needed. |
| `qr-decode.swift` | Print QR payloads found in a screenshot (macOS CoreImage). |

Safety: nothing here uninstalls or resets an app on a physical device; the
Android scripts refuse non-emulators, the iOS scripts only touch the named QA
simulator. See the CLAUDE.md "Never Uninstall Device Apps" rule.

iOS is driven headlessly with `ios-drive.sh` (or by hand through the iOS
Simulator MCP when the panel is available). There is no scripted `ios-smoke`
yet: scenario steps are composed per pass from the registry. Read labels from
the `tree:` dump, never coordinates off a screenshot; `tapid:`/`tapxy:` exist
only for controls that have no label (itself an accessibility finding).
