---
name: qa-run
description: >-
  Run Sonar's QA for a change before it is merged — for any contributor, with
  any coding agent. scripts/qa/plan.sh reads the diff and the machine and
  says which checks the change needs and which this machine can run: static
  checks, unit tests, an end-to-end smoke on a dedicated emulator/simulator
  against sonar-cli peers, and the docs/QA-SCENARIOS.md sections to walk.
  Ends with a QA report for the PR: pass / fail / not run per scenario, with
  evidence. Use when asked to "run QA", "test my change", "QA this PR" or
  "check this before I open a PR". To hunt for bugs and fix them in a loop,
  use qa-pass instead.
---

# Sonar QA run

For anyone changing Sonar, whatever agent they use: the only tools needed are
a shell and git. macOS runs iOS, Android and core; Linux runs Android and
core. A run **verifies and reports**. It does not fix, push or merge. When
the user wants the findings fixed, follow `qa-pass` step 6 (a test that fails
without the fix, and a registry entry).

## Ground rules (from CLAUDE.md — never bend them)

- **Dedicated emulators and simulators only.** Never install on, uninstall
  from or wipe a physical phone: that is where a user's account key lives.
  The setup scripts refuse non-emulators. If an install fails, stop and
  report it; never uninstall to make it pass.
- **Address devices by serial or UDID**, never `booted`: other agents and
  apps share the machine's simulators.
- **Gradle device tasks run on every attached device.** `installDebug` and
  `connectedDebugAndroidTest` use every attached device unless
  `ANDROID_SERIAL` names one. On top of that, connected tests **uninstall
  the app when they finish**. So on a plugged-in phone they would delete
  Sonar and its account key. Set `ANDROID_SERIAL` to a disposable emulator
  for any Gradle device task. After connected tests, onboard the QA emulator
  again.
- **Secrets: presence only.** Never print, commit or ask for the Breez key,
  `local.properties`, `google-services.json` or `GoogleService-Info.plist`.
  When they are missing, pass `--allow-missing-config` and report the
  affected scenarios as NOT RUN.
- **No real money.** Wallet scenarios that move sats run against local
  fakewallet mints only. Money code is always reviewed by a maintainer by
  hand; a green QA run does not replace that.
- **Evidence or it did not run.** Each PASS cites its evidence: an exit
  status, the smoke JSON, a tree dump or a screenshot. Anything skipped is
  NOT RUN with the reason. Never mark a scenario passed from reading code.

## 1. Plan

From the branch that holds the change:

```bash
scripts/qa/plan.sh                      # against origin/main
scripts/qa/plan.sh --base <ref>         # a PR aimed at another branch
scripts/qa/plan.sh --head <ref>         # plan for a commit you have not checked out
```

It prints the areas the diff touches, what this machine has, and three
lists: **RUN** (commands in tier order), **NOT RUN here** (with the reason)
and **WALK** (registry sections). Show the user the plan and the rough cost
before starting:

| Tier | What | First run | Later runs |
|---|---|---|---|
| T0 | static checks CI runs | seconds | seconds |
| T1 | unit / UI tests at the call site | 10–30 min (builds Rust) | 2–10 min |
| T2 | setup + end-to-end smoke | 15–40 min (app + core builds) | 5–10 min |
| T3 | walk the WALK sections | 15–60 min | same |

If the user asked for a quick check, stop after T1 and list T2 and T3 as NOT
RUN. When a tool is missing, the NOT RUN line says what to install. After
installing it, re-run `plan.sh` rather than guessing the command.

## 2. T0 and T1

Run the RUN lines in order and keep every exit status. A T0 or T1 failure on
the contributor's own change is the first finding: report it, and fix it only
if the user asks, before spending time on devices.

Two traps:
- `core-flake-check.sh` failing means a test that is order-dependent (QA-125),
  not a slow machine. Report which test failed.
- `xcodebuild … | tee` hides the exit status. Use `set -o pipefail` and look
  for `** TEST SUCCEEDED **`.

## 3. iOS unit suite (macOS)

Use a **second** simulator, never the QA one: the test run clones and reboots
its destination. It needs `sonarffi.xcframework`. If `plan.sh` says
"after ios-setup.sh --build-core", run that setup (step 4) first.

```bash
set -o pipefail
name="Sonar Tests $(basename "$PWD")"
T_UDID="$(xcrun simctl list devices available | sed -nE "s/^[[:space:]]+$name \(([0-9A-F-]+)\).*/\1/p" | head -1)"
if [[ -z "$T_UDID" ]]; then
  read -r TYPE RUNTIME < <(scripts/qa/ios-sim-type.sh)
  T_UDID="$(xcrun simctl create "$name" "$TYPE" "$RUNTIME")"
fi
xcodebuild test -project ios/bitchat.xcodeproj -scheme 'bitchat (iOS)' \
  -configuration Debug -destination "id=$T_UDID" -only-testing:bitchatTests_iOS \
  -parallel-testing-enabled NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```

This is the command CI runs. A run that fails with simulator clone errors
before any test ran is the machine, not the change. Delete the test
simulator, create it again, and re-run.

## 4. T2 — end-to-end smoke

```bash
export QA_HOME="${TMPDIR:-/tmp}/sonar-qa-$(basename "$PWD")"   # artifacts, per checkout
cargo build -p sonar-cli --release --manifest-path core/Cargo.toml   # the peers (plan says when)
```

**Android.** Take the `android-setup.sh` line from the plan. The setup:
- boots the AVD by serial and installs the Debug build in place;
- builds the Rust core for the emulator's ABI, so x86_64 works on Linux and
  Intel machines;
- captures logcat.

Then:

```bash
scripts/qa/android-smoke.sh                  # exit status = failed scenarios
scripts/qa/android-smoke.sh --only QA-003    # one scenario
```

The smoke needs the app **open and onboarded**. `installDebug` does not start
the app, and when onboarding is still showing, every scenario fails with
"chat list not reached". A fresh install always shows onboarding. Tap through
it once and record it as QA-022:

```bash
adb -s "$QA_SERIAL" shell am start -n chat.bitchat.sonar/.MainActivity
UI=scripts/qa/android-ui.sh
$UI tapx "Get started"; sleep 2; $UI tapx "Surprise me"; sleep 1; $UI tapx "Continue"; sleep 3
$UI tapx "Start chatting"; sleep 3
$UI dump | grep -E "Allow|While using the app"    # tap each prompt with $UI tapx "<label>"
$UI dump | grep -q "Start a chat" && echo onboarded
```

`QA_ALLOW_WIPE=1` adds QA-118, which **clears the app's data**. Use it only
on an emulator you created for this run. On API 34+ images, turn stylus
handwriting off first:
`adb -s "$QA_SERIAL" shell settings put secure stylus_handwriting_enabled 0`.

**iOS.** Take the `ios-setup.sh` line from the plan. The setup:
- creates the "Sonar QA <checkout>" simulator;
- builds, installs and starts a log capture.

It builds signed, because an unsigned build has no App Group and the chat
store cannot open. A simulator build needs no Hedwig Apple team and no
`Local.xcconfig`. In 2026-09-27 testing, a build signed for a team the
machine had no Xcode account for:
- still built;
- kept the App Group;
- created an account and opened the chat store.

That test had other Apple accounts signed in to Xcode. If Xcode still
refuses to sign, put your own team in the gitignored
`ios/Configs/Local.xcconfig`:

```
DEVELOPMENT_TEAM = <your team id>
```

Keep the bundle id `sh.hedwig.sonar` for simulator QA: the QA scripts address
the app by it. The example file's bundle-id line is only for running on your
own phone, which this skill never does.

After setup:
- the share sheet: `scripts/qa/ios-share-smoke.sh`;
- any other scenario: `scripts/qa/ios-drive.sh`, which reads a
  `;`-separated step script (`launch; tapc:<label>; expect:<text>; tree; shot`).
  Read labels from `tree`, never coordinates from a screenshot.

**Peers.** The other side of every conversation is a fresh `sonar-cli`
identity:

```bash
scripts/qa/peers.sh new alice
scripts/qa/peers.sh send alice <app-npub> "hello"
scripts/qa/peers.sh expect alice "text the app sent" 60
```

Get the app's npub from the `sender` field of a message a peer received
(`scripts/qa/peers.sh listen alice 30`). Peers use the public relays, so T2
needs network access.

## 5. T3 — walk the registry

For each WALK section, open `docs/QA-SCENARIOS.md` and run every scenario on
each platform in the plan that the smoke did not already cover. Each scenario
lists its steps, what good looks like, and **How** (automated, a guarding
test, or manual). Before driving any UI, read
[`../qa-pass/reference.md`](../qa-pass/reference.md): it lists the harness
traps that cost earlier passes hours, such as lost keystrokes, coordinate
scaling and taps that land on the wrong control.

When something looks wrong:
1. Reproduce it twice with the exact steps.
2. Run a control to tell the app from the harness: the same action from
   `sonar-cli`, or on the other platform.
3. Only then report it as a finding, with the steps, the platform and the
   log lines (`$QA_HOME/logcat-*.txt`, `$QA_HOME/ios-log-*.txt`).

### A change that adds a feature

If the feature has no scenario in `docs/QA-SCENARIOS.md`, the QA for it
includes writing one: steps, expectations on both platforms, **How**, and
**Guard** (the tests that fail without it). If it can be driven headlessly,
add a `qaNNN` step to `scripts/qa/android-smoke.sh` too, so the next pass runs
it by default.

Pick ids that neither main nor an open PR already uses. Parallel PRs have
collided before, and git merges two different `### QA-NNN` headings without a
conflict:

```bash
grep -oE '^### QA-[0-9]+' docs/QA-SCENARIOS.md | sort -t- -k2 -n | tail -1
for pr in $(gh pr list --state open --json number -q '.[].number'); do
  gh pr diff "$pr" | grep -oE '^\+### QA-[0-9]+' | sed "s/^/#$pr /"; done
```

A test that pins a helper can stay green while the real call site is broken.
Where you can, point the guard at the call site the UI renders, and check it
goes red with the fix removed (see the regression-ledger rules in CLAUDE.md).

## 6. Report

Put this in the PR description or a comment. Every row has evidence or a
reason:

```markdown
### QA run — <branch> @ <short sha>
Machine: <OS>, <Android image / iOS runtime> · plan: `scripts/qa/plan.sh` (areas: …)

| Tier | Check | Result | Evidence |
|---|---|---|---|
| T0 | check-regression-ledger.sh | pass | exit 0 |
| T1 | cargo test --workspace | pass | 412 passed |
| T2 | android-smoke.sh | 20/21 | smoke-<run>.json, QA-005 failed (below) |
| T3 | QA-110 (iOS) | pass | tree dump shows "Pay 1,000 sats" |

**Findings:** id · platform · steps · expected / actual · evidence
**Not run:** each NOT RUN line from plan.sh, plus anything skipped, with why
```

Finish by stopping what the run started. Only touch what this run started;
other agents may be using the same machine.
- Kill the log captures: `$QA_HOME/ios-log-*.pid`, and the logcat process
  `android-setup.sh` launched.
- Leave the QA emulator and simulator in place, unless the user asks you to
  shut them down.
