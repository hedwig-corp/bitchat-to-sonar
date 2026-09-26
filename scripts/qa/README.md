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
| `peers.sh` | Fresh `sonar-cli` counterparties: `new`, `send`, `send-image`, `listen`, `expect`. |
| `android-smoke.sh` | Automated registry scenarios (`qaNNN` = `QA-NNN`). |
| `idle-cpu.sh` | Average app CPU over a window on Android or an iOS simulator. |
| `qr-decode.swift` | Print QR payloads found in a screenshot (macOS CoreImage). |
| `mint-proxy.py` | Fault-injecting HTTP proxy between a DEBUG app (or `sonar-cashu-cli`) and a local fake-Lightning `cdk-mintd`: `arm lose-melt-answer`, `drop-melt` + `deliver`/`discard`, `delay-melt N`, `delay-mint-answer N`, one fault per arm. Test sats only; wallet scenarios QA-091…093. |

Safety: nothing here uninstalls or resets an app on a physical device; the
Android scripts refuse non-emulators, the iOS scripts only touch the named QA
simulator. See the CLAUDE.md "Never Uninstall Device Apps" rule.

iOS has no headless UI driver yet: agents drive it through the iOS Simulator
MCP. A future `ios-smoke` would need an XCUITest target — track it as a gap
rather than faking it with coordinates.
