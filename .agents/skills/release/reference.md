# Sonar release — reference (where to find things)

Companion to [SKILL.md](SKILL.md). **Never print secret values** — only presence,
lengths, and non-secret IDs (team, hostnames, version numbers).

## Secrets & local config map

| Need | Location | How to verify (safe) |
|------|----------|----------------------|
| Breez API key (Apple) | gitignored `ios/Configs/Local.xcconfig` → `BREEZ_API_KEY = …` | `awk` presence check in SKILL |
| Apple signing team (TestFlight) | same file → `DEVELOPMENT_TEAM=ZQB239SHCM` | print team ID only |
| Firebase iOS (payment push) | gitignored `ios/bitchat/GoogleService-Info.plist` | `test -f` |
| Breez + Android keystore | gitignored `apps/sonar/local.properties` | `breez.apiKey=`, `sonar.keystore=`, `sonar.key.alias=`, passwords — print `=set` only |
| FCM Android | gitignored `apps/sonar/composeApp/google-services.json` | `test -f` |
| Zapstore Nostr signer | env `SIGN_WITH` = `nsec1…` \| `bunker://…` \| `browser` | `test -n`; scheme only (`bunker`/`nsec`/`browser`) |
| Zapstore publisher npub | committed `zapstore.yaml` → `pubkey:` | may print npub |
| GitHub API | `gh auth token` → `GITHUB_TOKEN` | `gh auth status` |
| `zsp` CLI | `$(go env GOPATH)/bin/zsp` | `command -v zsp` or add GOPATH/bin to `PATH` |

### Recovering `SIGN_WITH` without pasting into chat

Prefer a local env file the human already has (e.g. shell profile, password
manager, previous `/tmp/sonar-*-sign.env`). If recovering from agent transcripts,
search for `bunker://` with `secret=` and write to a **mode-0600** temp env file;
**never echo** the URI into the conversation or commit it. Delete the temp file
after Zapstore publish.

Committed publisher identity (safe to read):

```bash
awk '/^pubkey:/{print}' zapstore.yaml
```

### What must not be committed

- `ios/Configs/Local.xcconfig`
- `ios/bitchat/GoogleService-Info.plist`
- `apps/sonar/local.properties`
- `apps/sonar/composeApp/google-services.json`
- Any `SIGN_WITH` / bunker / nsec / keystore password
- `/tmp/sonar-*-sign.env`

## Version archaeology

Main tip may lag a side-branch release tag. Always check **tags**, not only
`origin/main`:

```bash
# Last tags
git tag -l 'v0.1-alpha.*' | sort -V | tail -15
gh release view v0.1-alpha.13 --json tagName,createdAt,isPrerelease

# Android code/name on a tag (may differ from main)
git show v0.1-alpha.13:apps/sonar/composeApp/build.gradle.kts | head -12
git show v0.1-alpha.13:ios/Configs/Release.xcconfig | head -15

# Highest SONAR_VERSION_CODE across tags
for t in $(git tag -l 'v0.1-alpha.*'); do
  c=$(git show "$t:apps/sonar/composeApp/build.gradle.kts" 2>/dev/null | \
      sed -n 's/.*SONAR_VERSION_CODE = \([0-9]*\).*/\1/p' | head -1)
  [ -n "$c" ] && echo "$c $t"
done | sort -n | tail -10
```

Apple build numbers are documented in comments inside
`ios/Configs/Release.xcconfig` (which builds ASC already accepted).

### Naming examples

| Tag | Android name / code | Apple marketing / build |
|-----|---------------------|-------------------------|
| `v0.1-alpha.13` | `0.1-alpha.13` / 19 (as shipped on that tag) | `1.13.0` / 41 |
| `v0.1-alpha.13.1` | `0.1-alpha.13.1` / ≥20 | `1.13.1` / 42 |
| Apple-only hotfix | leave Android alone | bump build (and marketing patch if desired) |

## ExportOptions (TestFlight upload)

Create once per worktree under `dist/`:

`dist/ExportOptions-iOS.plist` and `dist/ExportOptions-macOS.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key>
	<string>upload</string>
	<key>method</key>
	<string>app-store-connect</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>ZQB239SHCM</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
```

Reuse from a previous release worktree if present:
`.claude/worktrees/*/dist/ExportOptions-*.plist`.

## NDS / Release URL sanity (Apple)

In `.xcconfig`, `//` starts a comment. `NDS_URL` must be the **bare host**
`nds.sonar.hedwig.sh` (committed Release default). Check without secrets:

```bash
xcodebuild -project ios/bitchat.xcodeproj \
  -scheme 'bitchat (iOS)' -configuration Release -showBuildSettings \
  | awk '/^[[:space:]]+NDS_URL = /{print}'
```

Reject empty, `https:`, or `http:`.

## Breez release gates

- Android: Gradle task `requireBreezApiKeyForRelease` on release packaging
- Apple: Xcode Run Script “Require Breez API key for Release” on iOS/macOS targets
- Optional script (if present): `scripts/require-breez-api-key.sh`

## Zapstore commands

```bash
# Preferred helper (always passes --pre-release for alphas)
SIGN_WITH=… GITHUB_TOKEN="$(gh auth token)" scripts/zapstore-publish.sh --local
scripts/zapstore-publish.sh --check   # dry fetch

# Direct zsp (phone APK)
zsp publish --pre-release --skip-metadata \
  -r https://github.com/hedwig-corp/bitchat-to-sonar \
  dist/sonar-<version>-android.apk
```

Config: root `zapstore.yaml`. App id: `chat.bitchat.sonar`.

## Apple archive verification

```bash
/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' \
  dist/archives/Sonar-iOS.xcarchive/Info.plist
/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' \
  dist/archives/Sonar-iOS.xcarchive/Info.plist
/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:Team' \
  dist/archives/Sonar-iOS.xcarchive/Info.plist
```

Expect marketing / build / `ZQB239SHCM`.

## Common failure modes

| Symptom | Cause | Action |
|---------|-------|--------|
| `Failed to Use Accounts` | No Xcode ASC session for `ZQB239SHCM` | User signs into Xcode Accounts; retry export only |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Debug vs release keystore on device | Uninstall then install (wipes data) |
| Zapstore `zsp: command not found` | GOPATH/bin not on PATH | `export PATH="$PATH:$(go env GOPATH)/bin"` |
| `target SDK … requires signature scheme v2` | Unsigned APK | Use Gradle-signed release + keystore props |
| ASC reject duplicate build | Reused `CURRENT_PROJECT_VERSION` | Bump build number; re-archive |
| Android code too low | Main lagged a higher-coded tag | Archaeology above; pick max+1 |
| Cargo/file lock during core build | Parallel Rust builds | Serialize `core/build-ios.sh` / Android NDK |

## Historical device IDs (dogfood)

May change; re-discover with `adb devices -l` / Xcode.

- Pixel 10 Pro: adb serial often `61020DLCH008PZ`
- Prefer `adb -s <serial> install -r` over Gradle install (avoids emulator)

## Worktree layout used in practice

```text
.claude/worktrees/release-alpha-13.1/
  dist/
    sonar-0.1-alpha.13.1-android.apk
    sonar-0.1-alpha.13.1-android-universal.apk
    ExportOptions-iOS.plist
    ExportOptions-macOS.plist
    archives/Sonar-iOS.xcarchive
    archives/Sonar-macOS.xcarchive
    *.log
```

## Release notes skeleton (GitHub `--notes`)

```markdown
## Sonar 0.1-alpha.X.Y

Cautious pre-alpha.(X+1) cut after …

| Platform | Version |
|----------|---------|
| Android | `0.1-alpha.X.Y` (versionCode N) |
| iOS / macOS TestFlight | **M.m.p (build)** |

### Assets
| File | Purpose |
|------|---------|
| `sonar-…-android.apk` | Phone (arm64-v8a + armeabi-v7a), Zapstore + sideload |
| `sonar-…-android-universal.apk` | Fat (incl. x86_64 emulators) |

### Headline
- …

### What to test
Paste the same tester note produced for chat (see below).
```

## Tester note example

Filled example from `v0.1-alpha.13.1` / Apple **1.13.1 (42)** — agents should
regenerate from `WhatToTest.md` + changelog, not copy this blindly next cut:

```markdown
**Sonar 1.13.1 (42) — Apple TestFlight · v0.1-alpha.13.1 (pre-alpha.14)**

Cautious cut after alpha.13. Please dogfood before we cut alpha.14.

**Please try**
- **Reply to a message** — long-press / hold a message → **Reply** → send. Your
  message should show a quote snapshot of the parent (Signal-style).
- **@mention** in a group — type `@` and pick someone by their Sonar name.
- Open an existing chat — history should paint immediately from local storage
  (not blank / spinner).
- Background / lock the phone, get a push or wait, then reopen — watch for
  crashes while locked or right after wake.
- Push banners — shouldn’t double up when a message arrives.
- Onboarding — long steps should scroll if content overflows.
- Auto-backup — shouldn’t chew the data plan (no runaway upload).
- Profile / kind-0 — republishing yourself shouldn’t wipe fields set by other
  clients.

**Highest priority:** crash on launch, while locked, or right after send /
photo / payment / reply. If sync feels wrong or a message is missing:
**Settings → Diagnostics → Share** and send the log.

**Note:** Reply is for White Noise / relay messages in this build; mesh BLE
reply is a follow-up.
```
