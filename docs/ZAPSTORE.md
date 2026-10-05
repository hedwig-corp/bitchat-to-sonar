# Zapstore deploy (Android)

Publish Sonar’s Android alpha to [Zapstore](https://zapstore.dev) with
[`zsp`](https://github.com/zapstore/zsp). Config lives at repo root:
[`zapstore.yaml`](../zapstore.yaml).

## What is already wired

| Piece | Status |
|--------|--------|
| `zapstore.yaml` | App metadata + GitHub source + phone-APK match |
| `scripts/zapstore-publish.sh` | Check / build+sign local / publish |
| Release APK signing (Gradle) | Optional via env or `local.properties` |
| GitHub release assets | Phone + universal APKs on `v0.1-alpha.9` (pre-release) |
| `zsp` CLI | Install: `go install github.com/zapstore/zsp/cmd/zsp@latest` |

## What you must provide (secrets — never commit)

1. **Nostr publisher identity** — env `SIGN_WITH`:
   - `nsec1…` (dev only), or
   - `bunker://…` (preferred for CI; also what a human uses).

   `zsp` 0.5.x accepts only these (and raw hex). `SIGN_WITH=browser` fails
   with `signer_unavailable`. A bunker must also be allowed to sign kind
   24242 (the Blossom upload authorization), not just the release kinds;
   when it is not, the APK upload never starts and `zsp` reports a
   misleading `source_failed` with `"uploaded": 0`. Approve that kind in the
   signer app, then retry: nothing reaches the relays until the upload
   succeeds.

2. **Android upload keystore** (APK **must** be signed with v2+; targetSdk 35):
   - Path: e.g. `~/upload-keystore.jks` (or `.p12`)
   - Password, key alias, key password

   Put them in **gitignored** `apps/sonar/local.properties`:

   ```properties
   sonar.keystore=/Users/you/upload-keystore.jks
   sonar.keystore.password=…
   sonar.key.alias=upload
   sonar.key.password=…
   ```

   Or export `SONAR_KEYSTORE`, `SONAR_KEYSTORE_PASSWORD`, `SONAR_KEY_ALIAS`,
   `SONAR_KEY_PASSWORD`.

3. **Publisher `pubkey` in `zapstore.yaml`** (npub matching `SIGN_WITH`) so the
   Zapstore relay can auto-whitelist the repo on first publish. Commit after
   filling it in.

Optional: `GITHUB_TOKEN` (or `gh auth login`) so `zsp` is not rate-limited when
fetching release assets.

## Why unsigned GitHub APKs fail

`zsp` parses the APK and verifies its signature. Our earlier
`assembleRelease` builds without a signing config produce **unsigned** APKs;
with `targetSdk 35` that fails:

```text
target SDK version 35 requires a minimum of signature scheme v2
```

Always ship a **signed** phone APK to Zapstore (and preferably re-upload that
signed asset to the GitHub release as well).

## Alpha tags are pre-releases

All `v0.1-alpha.*` GitHub releases are marked **pre-release**. `zsp` ignores
those unless you pass **`--prerelease-channel <name>`** (zsp 0.5+; older zsp used
`--pre-release`). The publish script detects the installed version and passes
the right one.

## Commands

```bash
# Install publisher CLI
go install github.com/zapstore/zsp/cmd/zsp@latest
export PATH="$PATH:$(go env GOPATH)/bin"

# Dry-run: can we fetch the phone APK from GitHub?
export GITHUB_TOKEN="$(gh auth token)"
scripts/zapstore-publish.sh --check

# Full path: build phone release, sign, publish to Zapstore
export SIGN_WITH='nsec1…'   # or bunker://…
# (keystore passwords via local.properties — see above)
scripts/zapstore-publish.sh --local

# If you already have dist/sonar-android-signed.apk:
export SIGN_WITH='bunker://…'
scripts/zapstore-publish.sh
```

First-time flow recommended by Zapstore:

```bash
zsp publish --wizard
# → fills zapstore.yaml, prompts for source, signing, cert link
# Commit zapstore.yaml (with pubkey) so the relay can whitelist you.
```

Link the APK signing cert to your Nostr identity once (NIP-C1):

```bash
export SIGN_WITH=…          # bunker / nsec
export KEYSTORE_PASSWORD=…  # PKCS12 / JKS password
# JKS is not accepted by zsp identity — use PKCS12:
# keytool -importkeystore -srckeystore ~/upload-keystore.jks \
#   -destkeystore ~/upload-keystore.p12 -deststoretype PKCS12
zsp identity --link-key ~/upload-keystore.p12
```

If the bunker returns `no permission` / “secret used with a different application”,
create a **new** bunker connection URL from your signer (e.g. [nsec.app](https://nsec.app))
authorized for this client (`zsp`), then re-export `SIGN_WITH` and retry.

## GitHub asset naming

| Asset | Role |
|--------|------|
| `sonar-*-android.apk` | **Phone** (arm64 + armeabi-v7a) — selected by `match` in `zapstore.yaml` |
| `sonar-*-android-universal.apk` | Fat APK for emulators — ignored by Zapstore match |

## Related

- Android build: [`docs/ANDROID-BUILD.md`](ANDROID-BUILD.md)
- Official guide: https://zapstore.dev/docs/publish
