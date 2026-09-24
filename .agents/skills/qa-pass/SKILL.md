---
name: qa-pass
description: >-
  Run an end-to-end QA pass of the Sonar apps (iOS simulator and/or Android
  emulator) against real sonar-cli peers: find bugs, performance and UI
  problems, fix them with tests, open a PR, and repeat on the fixed build until
  a round comes back clean. Every bug found grows docs/QA-SCENARIOS.md and,
  where possible, scripts/qa/android-smoke.sh. Use when asked to "QA the app",
  "test messaging in the simulator/emulator", "find bugs before a release", or
  to re-verify a build.
---

# Sonar QA pass

A QA pass is a loop, not a checklist:

```
setup → automated smoke → scenario pass (registry) → exploratory pass
      → triage → fix + test (both platforms) → grow the registry
      → PR → rebuild → repeat until one full round finds nothing new
```

Read [reference.md](reference.md) before driving a UI — it lists the harness
traps that cost previous passes hours (coordinate scaling, shared simulators,
keystrokes lost after navigation, "bugs" that were the tester's own taps).

## Ground rules (from CLAUDE.md — non-negotiable)

- **Never uninstall, wipe or reset the app on a physical device.** QA runs on
  a dedicated emulator/simulator that you created. Install in place.
- **Target devices by serial/UDID, never `booted`** — other agents share this
  Mac's simulators.
- **No secrets in output or commits** (Breez key, `local.properties`,
  `google-services.json`, `GoogleService-Info.plist`). Check presence only.
- **Cross-Platform Feature Rule:** a bug found on one app is checked on the
  other; fix both in the same PR or record a tracked gap in the PR body.
- **Regression ledger:** read `docs/REGRESSIONS.md` before touching
  conversation/transcript/send/unread code; a bug seen twice gets an entry.
- **Wallet/money code needs manual human review** — report, don't auto-merge.

## 1. Setup

Branch from fresh `main` for fixes (`claude/<platform>-qa-pass`); a PR whose
base is not `main` gets **zero CI runs**.

```bash
cargo build -p sonar-cli --release --manifest-path core/Cargo.toml   # peers
export QA_HOME="$TMPDIR/sonar-qa-$(basename "$PWD")"                 # all artifacts, per worktree

# Android (boots the QA AVD, installs Debug in place, captures logcat)
export QA_SERIAL="$(scripts/qa/android-setup.sh)"          # --fresh = new account
# iOS (creates/boots "Sonar QA <worktree>", signed Debug build, log stream)
export QA_UDID="$(scripts/qa/ios-setup.sh --build-core)"   # later runs: no flag
```

Both setups refuse to continue when the Breez key or the Firebase config is
missing (presence-only check): the Debug build would install fine but wallet
flows and offline-payment pushes would be silently off. Copy the gitignored
files from the primary checkout, or pass `--allow-missing-config` and list
the gaps from `$QA_HOME/config-gaps.txt` as "not run" in the report.
`ios-setup.sh` also refuses a `sonarffi.xcframework` not built from this
worktree's `core/` tree (`--build-core` rebuilds, `--trust-core` overrides).
`android-setup.sh` refuses an emulator on the port whose AVD is not the one
requested, or one another worktree set up in the same boot — it is another
agent's (create a second AVD and pass `--avd`/`--port`; `--take-over` only
when that agent is gone). The iOS simulator and `QA_HOME` are per worktree by
default, so parallel agents never share a device or artifacts. Each setup
rewrites its platform's lines in `config-gaps.txt`, so the file always
reflects the latest run.

If the app is not onboarded yet, onboard it by hand (nickname, *Start
chatting*, grant prompts) — that *is* scenario QA-022 on a fresh install.

## 2. Automated smoke (Android)

```bash
scripts/qa/android-smoke.sh            # exit status = failed scenarios
```

It drives the app with `scripts/qa/android-ui.sh` against fresh peers and
checks the automated registry scenarios (first message + keyboard, reply
latency, pending draft, inbound-first, unread divider, labels, partial npub,
profile QR decodes to the npub, idle CPU). A failure is a finding — reproduce it by hand before fixing.
iOS has no headless driver yet: run the same scenarios through the iOS
Simulator MCP (`mcp__Claude_Code_iOS_Simulator__control`), see reference.md.

## 3. Scenario pass

Walk **every** scenario in `docs/QA-SCENARIOS.md` on each platform under test
that the smoke did not cover. Use `scripts/qa/peers.sh` for the other side:

```bash
P=$(scripts/qa/peers.sh new alice)            # fresh identity + KeyPackage
scripts/qa/peers.sh send alice <app-npub> "hello"
scripts/qa/peers.sh expect alice "text the app sent" 60
scripts/qa/peers.sh send-image alice <app-npub> image.png
```

Get the app's npub from the `sender` field of any message a peer received
(`peers.sh listen alice 30`).

## 4. Exploratory pass

Then go off-script for at least as long as the scenario pass: new chat from
both ends, long drafts, rapid sends, back/forward during sends, background and
foreground, rotate, offline then online, search every entry point, settings,
profile, channels. Watch the logs (`$QA_HOME/logcat-*.txt`,
`$QA_HOME/ios-log-*.txt`) for errors, retry storms and repeated EOSE/sync
lines while idle. Measure: `scripts/qa/idle-cpu.sh`, and the cold-start
benchmarks in `docs/PERFORMANCE.md` when startup code changed.

Look for three classes: **bugs** (wrong behaviour), **performance** (latency,
idle churn, jank, redundant work), **UI/UX** (layout jumps, invisible or
unlabelled controls, dead-end actions, copy that lies).

## 5. Triage — prove it before you fix it

For each candidate finding:

1. **Reproduce twice** with the exact steps. If it will not reproduce after 3–4
   tries, record it as "seen once" with the sequence and move on.
2. **Run a control**: is it the app or the harness? (A "long-press does
   nothing" bug was the tester's wrong coordinates; a "slow upload" was the
   Blossom server — the same upload from `sonar-cli` took as long.)
3. **Check the other platform** for the same shape.
4. Find the root cause in code before writing a fix; cite `file:line`.

Give findings ids per pass (`A1…` Android, `i1…` iOS) and keep a table:
id · platform · symptom · root cause · fix/decision.

## 6. Fix, test, grow the registry

- Fix the root cause on every affected platform.
- Add a test that **fails without the fix** at the real call site where
  feasible (Compose UI tests in `apps/sonar/composeApp/src/jvmTest`, Swift
  Testing in `ios/bitchatTests`, `cargo test` in core). Run the negative
  control: revert the fix locally, watch the test go red, restore.
- Add/extend the scenario in `docs/QA-SCENARIOS.md` (steps, expectation,
  guard, origin).
- If the scenario can be driven headlessly, add a `qaNNN` function to
  `scripts/qa/android-smoke.sh` whose name matches the registry id.
- New user-facing strings go through `ios/bitchat/Localizable.xcstrings` then
  `python3 scripts/i18n/xcstrings_to_compose.py`.
- Verify: `./gradlew :composeApp:jvmTest`, the iOS tests you touched (on a
  second dedicated simulator), `scripts/check-regression-ledger.sh`,
  `scripts/check-rng-hygiene.sh`, and an iOS build.

## 7. PR and repeat

Open the PR against `main` with the findings table, what was verified on
device, the tests (and which were negative-controlled), and **known gaps**
(unreproduced, product decisions, infra). Then rebuild from the PR head,
reinstall in place, and run steps 2–5 again. Stop when a full round finds
nothing new; say so explicitly in the PR.

## Report format

End every pass with: platforms/builds tested, scenarios run (pass/fail per
id), findings table, what was fixed vs deferred, perf numbers (idle CPU,
message latency), and the PR link.
