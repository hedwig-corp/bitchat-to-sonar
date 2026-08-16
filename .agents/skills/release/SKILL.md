---
name: release
description: >-
  Cut a Sonar cross-platform alpha release (version bump, Android APKs,
  GitHub pre-release + Zapstore, iOS/macOS TestFlight). Use when the user asks
  to release, cut an alpha, ship TestFlight, publish Zapstore, or bump
  0.1-alpha.* / Apple marketing+build numbers.
---

# Sonar release (alpha / TestFlight / Zapstore)

One-shot or parallel-agent release for **Android + GitHub + Zapstore** and
**iOS/macOS TestFlight**. Never commit secrets. Prefer a clean git worktree so
dirty feature branches stay untouched.

## When to use

- Full cut: `v0.1-alpha.N` or cautious `v0.1-alpha.N.M` (pre-next-major)
- Apple-only hotfix: bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` + TestFlight
- Android-only: APKs + GitHub (+ Zapstore)

## Parallelism (preferred)

After the version bump is on `main`, run **two agents in parallel**:

1. **Android** — assemble phone + universal APKs → tag → GitHub pre-release → Zapstore
2. **Apple** — `core/build-ios.sh` → archive iOS + macOS → `exportArchive` upload

Do not run two `cargo`/`build-ios`/`build-android` jobs in the same worktree at
once (file-lock thrash). Parallel agents must share one worktree only if they
touch disjoint trees (`apps/sonar` vs `ios/` + `core/build-ios.sh`); otherwise
use sequential Apple after Android, or separate worktrees.

## Preconditions (presence only — never print secret values)

```bash
ROOT=<repo>
test -f "$ROOT/ios/Configs/Local.xcconfig" && echo Local.xcconfig=ok
awk -F= '/DEVELOPMENT_TEAM/{gsub(/ /,"",$2); print "DEVELOPMENT_TEAM="$2}' \
  "$ROOT/ios/Configs/Local.xcconfig"
awk -F= '/^BREEZ_API_KEY/{print ($2!="" && $2!~/^[[:space:]]*$/)?"Breez=yes":"Breez=NO"}' \
  "$ROOT/ios/Configs/Local.xcconfig"
test -f "$ROOT/ios/bitchat/GoogleService-Info.plist" && echo GoogleService=ok
test -f "$ROOT/apps/sonar/local.properties" && echo local.properties=ok
rg -n '^breez\.apiKey=|^sonar\.keystore=|^sonar\.key\.alias=' \
  "$ROOT/apps/sonar/local.properties" | sed 's/=.*/=set/'
test -n "${SIGN_WITH:-}" && echo SIGN_WITH=set || echo SIGN_WITH=unset
command -v zsp; command -v gh; xcodebuild -version | head -1
```

Abort if Breez is missing for a **Release** path (Android `requireBreezApiKeyForRelease`,
Apple Release script). Details: [reference.md](reference.md).

## Version bump (commit to `main` first)

### Sources of truth

| Surface | File | Fields |
|---------|------|--------|
| Android (+ desktop packagers) | `apps/sonar/composeApp/build.gradle.kts` | `SONAR_VERSION_CODE`, `SONAR_VERSION_NAME` |
| iOS / macOS | `ios/Configs/Release.xcconfig` | `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` |
| Website APK link | `web/src/lib/links.js` | GitHub download URL |
| Zapstore hint | `zapstore.yaml` | `# release_source: dist/sonar-…-android.apk` |
| Tester notes | `ios/TestFlight/WhatToTest.md` | Build line + headline |

### Rules

1. **Android `SONAR_VERSION_CODE`** must be **strictly greater** than every
   previously published code (check tags / last release APK). Example:
   `v0.1-alpha.13` used code **19** → `v0.1-alpha.13.1` must be **≥ 20**.
2. **`SONAR_VERSION_NAME`** matches the tag without `v` prefix:
   `0.1-alpha.13.1` ↔ tag `v0.1-alpha.13.1`.
3. **Apple `CURRENT_PROJECT_VERSION`** must be **new** every upload. App Store
   Connect rejects reusing the same `(MARKETING_VERSION, CURRENT_PROJECT_VERSION)`
   pair. Read the comment block in `Release.xcconfig` for the last consumed build.
4. **Marketing** for alpha.N.M cuts: `1.N.M` (e.g. alpha.13.1 → `1.13.1`).
5. Also refresh `WhatToTest.md`, `links.js`, `zapstore.yaml` comment.

Discover current + history:

```bash
git fetch origin main
git show origin/main:apps/sonar/composeApp/build.gradle.kts | head -12
git show origin/main:ios/Configs/Release.xcconfig | head -15
git tag -l 'v0.1-alpha.*' | sort -V | tail -12
gh release list --limit 8
# Highest Android code ever shipped (tag may be on a side branch):
for t in $(git tag -l 'v0.1-alpha.*'); do
  git show "$t:apps/sonar/composeApp/build.gradle.kts" 2>/dev/null | \
    awk '/SONAR_VERSION_CODE/{print t,$0}' t="$t"
done | sort -V | tail -5
```

Commit message pattern:

```text
chore(release): bump to 0.1-alpha.13.1 (iOS 1.13.1/42)
```

Push the bump to `main` (or open a tiny release PR if the user forbids direct push).

## Worktree setup

```bash
ROOT=<repo>
WT="$ROOT/.claude/worktrees/release-<slug>"
git -C "$ROOT" worktree add -B release/<tag> "$WT" origin/main
# Copy gitignored secrets into the worktree (never commit):
cp "$ROOT/ios/Configs/Local.xcconfig" "$WT/ios/Configs/Local.xcconfig"
cp "$ROOT/ios/bitchat/GoogleService-Info.plist" "$WT/ios/bitchat/GoogleService-Info.plist"
cp "$ROOT/apps/sonar/local.properties" "$WT/apps/sonar/local.properties"
cp "$ROOT/apps/sonar/composeApp/google-services.json" \
   "$WT/apps/sonar/composeApp/google-services.json" 2>/dev/null || true
mkdir -p "$WT/dist"
```

Ensure `ExportOptions-*.plist` exist under `dist/` — see [reference.md](reference.md).

Team for TestFlight uploads: **`ZQB239SHCM`** (from `Local.xcconfig`
`DEVELOPMENT_TEAM`, not the committed `L3N5LHJD5Y` default in `Release.xcconfig`).

## Android + GitHub + Zapstore

```bash
cd "$WT/apps/sonar"
./gradlew :composeApp:assembleRelease --no-daemon
# phone APK → dist/sonar-<versionName>-android.apk
./gradlew :composeApp:assembleRelease -Psonar.universalApk=true --no-daemon
# universal → dist/sonar-<versionName>-android-universal.apk

# Verify (no secrets):
"$HOME/Library/Android/sdk/build-tools/"*/apksigner verify --print-certs \
  "$WT/dist/sonar-…-android.apk" | head -8

git tag -a "v0.1-alpha.…" -m "Sonar v0.1-alpha.…"
git push origin "v0.1-alpha.…"
gh release create "v0.1-alpha.…" --prerelease --title "Sonar v0.1-alpha.…" \
  dist/sonar-…-android.apk dist/sonar-…-android-universal.apk \
  --notes "…"

# Zapstore — phone APK only, always --pre-release for alphas
source /path/to/sign.env   # export SIGN_WITH=… (nsec|bunker|browser); never echo
export GITHUB_TOKEN="$(gh auth token)"
export PATH="$PATH:$(go env GOPATH)/bin"
scripts/zapstore-publish.sh --local
# Confirm: chat.bitchat.sonar@<versionName>
```

Docs: `docs/ZAPSTORE.md`, `scripts/zapstore-publish.sh`.

## Apple TestFlight (iOS + macOS)

```bash
cd "$WT"
core/build-ios.sh

xcodebuild -project ios/bitchat.xcodeproj -scheme "bitchat (iOS)" \
  -configuration Release -destination generic/platform=iOS \
  -archivePath dist/archives/Sonar-iOS.xcarchive archive \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=ZQB239SHCM

xcodebuild -project ios/bitchat.xcodeproj -scheme "bitchat (macOS)" \
  -configuration Release -destination generic/platform=macOS \
  -archivePath dist/archives/Sonar-macOS.xcarchive archive \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=ZQB239SHCM

# Verify version + team in archive Info.plist (PlistBuddy)
xcodebuild -exportArchive \
  -archivePath dist/archives/Sonar-iOS.xcarchive \
  -exportOptionsPlist dist/ExportOptions-iOS.plist \
  -exportPath dist/archives/ios-export \
  -allowProvisioningUpdates
# same for macOS + ExportOptions-macOS.plist
```

### Accounts failure

If you see `Failed to Use Accounts` / no ASC access for `ZQB239SHCM`:

1. Stop. Leave archives in place.
2. Ask the user to sign into **Xcode → Settings → Accounts** with ASC access.
3. Retry `exportArchive` only (do not bump again).

Non-blocking: missing dSYM for `breez_sdk_liquidFFI` (tracked separately).

## Device install (optional)

- **Pixel**: prefer `adb -s <serial> install -r` of the **phone** APK. If
  `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (debug vs release keystore), uninstall
  first — **wipes app data**. Serial used historically: `61020DLCH008PZ` (Pixel 10 Pro).
- **iPhone**: Release install via `devicectl` / Xcode; keep team `ZQB239SHCM`.

## Tester note

After Apple upload, offer a short paste-ready note from `ios/TestFlight/WhatToTest.md`
(headline + 5–8 try bullets + crash/diagnostics priority).

## Done checklist

- [ ] Version bump on `main`
- [ ] Tag `v0.1-alpha.*` pushed
- [ ] GitHub pre-release with phone + universal APKs
- [ ] Zapstore `chat.bitchat.sonar@<versionName>` (if full Android cut)
- [ ] TestFlight iOS + macOS uploaded (or Accounts blocker reported)
- [ ] No secrets in git, logs, or chat (SIGN_WITH / Breez / keystore passwords)

## Additional resources

- Secret locations, ExportOptions template, version archaeology:
  [reference.md](reference.md)
- Zapstore: [`docs/ZAPSTORE.md`](../../../docs/ZAPSTORE.md)
- Android build: [`docs/ANDROID-BUILD.md`](../../../docs/ANDROID-BUILD.md)
- Repo rules: [`AGENTS.md`](../../../AGENTS.md) (Local Secrets, Breez release gate, NDS URL)
