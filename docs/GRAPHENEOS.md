# Sonar on GrapheneOS

Support status, user setup guide, and the device verification checklist for
running the Compose Android app (`apps/sonar/`) on GrapheneOS. Notification
architecture: [`NOTIFICATIONS-MATRIX.md`](NOTIFICATIONS-MATRIX.md). Plan of
record: `docs/brainstorms/2026-07-26-sonar-android-grapheneos-compat.md`.

## Support matrix

| Configuration | Chat (foreground) | BLE mesh | Chat wakeups (killed) | Wallet (foreground) | Offline BOLT12 receive (killed) |
| --- | --- | --- | --- | --- | --- |
| GrapheneOS + sandboxed Google Play | yes | yes | yes (FCM) | yes | yes (FCM webhook) |
| GrapheneOS degoogled + UnifiedPush distributor | yes | yes | pending upstream transponder support (platform `0x03`) | yes | no (gap — NDS is FCM-only) |
| GrapheneOS degoogled, no distributor | yes | yes | no — explicit "none" state in Diagnostics | yes | no |

Settings → Diagnostics shows the live transport: `Push transport: FCM — registered`,
`UnifiedPush — endpoint registered (server support pending)`, or
`none — no Play Services and no UnifiedPush distributor`.

## User setup

### With sandboxed Google Play (recommended today)

1. Install Google Play (GrapheneOS Apps → Google Play services) **in the same
   profile** as Sonar.
2. Install Sonar (Zapstore / GitHub APK).
3. For reliable wake latency: Settings → Apps → Google Play services →
   Battery → Unrestricted, and the same for Sonar.

### Degoogled (no Google apps)

1. Install a UnifiedPush distributor — [ntfy](https://ntfy.sh) from F-Droid is
   the common choice. Self-hosting the ntfy server gives the best privacy.
2. Open ntfy once and allow its background connection.
3. Install/open Sonar. Diagnostics should show `UnifiedPush`.
4. Until the transponder rollout completes (gap #1 below), messages are
   fetched when the app is open; BLE mesh delivery is unaffected.

### GrapheneOS-specific behaviors to know

- **Network permission revoked**: Sonar keeps working on BLE mesh; relay sync
  is offline. This must never look like a missing account.
- **Auto-reboot (default 18 h)**: after reboot the device is BFU; pushes may
  arrive but the encrypted DB is locked until first unlock. Sonar recovers on
  unlock with the same identity (Account Key Durability Rule).
- **Storage Scopes**: media send uses the system photo picker; full storage
  access is never required.

## Native hardening compatibility

GrapheneOS runs hardened_malloc, optional per-app MTE (Pixel 8+), and a 16 KB
page-size kernel.

- **16 KB alignment**: `core/build-android.sh` links with
  `-Wl,-z,max-page-size=16384`; verify any build with:

  ```sh
  scripts/check-so-alignment.sh                 # jniLibs
  scripts/check-so-alignment.sh path/to/app.apk # full APK
  ```

  Enforced for 64-bit ABIs (arm64-v8a, x86_64). armeabi-v7a is 32-bit and
  never runs a 16 KB kernel — reported but not enforced.

## Device verification checklist

Run on a physical GrapheneOS device. **Never uninstall Sonar on a personal
device** (Never Uninstall Device Apps Rule) — use `adb install -r` /
`installDebug` over the existing app, and a **secondary user profile** for
fresh-install scenarios. Record results here.

| # | Check | How | Result |
| --- | --- | --- | --- |
| 1 | 16 KB LOAD alignment | `scripts/check-so-alignment.sh <apk>` | arm64-v8a + x86_64 pass on current builds (2026-07-27, local); v7a is 4 KB (32-bit, exempt) |
| 2 | hardened_malloc | Exercise Arti bootstrap, SQLCipher open, Breez node start, BLE mesh, media send, call setup; watch logcat for SIGABRT + tombstones | pending |
| 3 | MTE | Per-app exploit protection → force MTE on, repeat #2, look for `SEGV_MTESERR` | pending |
| 4 | INTERNET revoked | Revoke Network permission → clear offline UI, BLE mesh alive, no account reset | pending |
| 5 | Play in another profile | Sonar must report `none`/`UnifiedPush`, not half-register FCM | pending |
| 6 | Auto-reboot / BFU | After 18 h reboot: unlock → same identity, DB key, onboarding flag | pending |
| 7 | Storage Scopes / photo picker | Media send with Storage Scopes enabled | pending |
| 8 | FCM latency w/ sandboxed Play | Measure push→notification with/without battery exemption | pending |

## Tracked gaps

1. **Upstream transponder support** for platform `0x03` (`unifiedpush`) —
   change lives in `marmot-protocol/transponder` (not this repo): decrypt MIP-05
   blob, see byte `0x03`, POST the wake body to the endpoint URL. Until the
   deployed instances understand it, degoogled chat wakeups do not fire.
2. **Breez offline receive without FCM** — NDS (`breez/notify`) translates the
   Boltz webhook into FCM. Candidate: register the UnifiedPush endpoint
   directly as the Boltz webhook URL, bypassing NDS; needs a payload
   experiment to confirm the app can drive the wallet from the raw POST.
3. **Distributor picker UI** — with multiple distributors installed Sonar
   auto-picks the first (deterministic); `UnifiedPush.tryUseDefaultDistributor`
   needs an Activity and a small settings UI.
4. **iOS**: APNs-only by platform design — no UnifiedPush equivalent exists on
   iOS. Documented platform limitation per the Cross-Platform Feature Rule.
