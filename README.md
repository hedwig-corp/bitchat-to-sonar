<img width="256" height="256" alt="Sonar" src="https://github.com/user-attachments/assets/90133f83-b4f6-41c6-aab9-25d0859d2a47" />

# Sonar

> Sense who's nearby before you see them.

Sonar is a decentralized, privacy-first messenger and Lightning wallet. It speaks
two transports — a local **Bluetooth LE mesh** for offline, proximity
communication and the internet-based **Nostr** protocol for global reach — and
adds end-to-end-encrypted group messaging (Marmot / MLS over Nostr), nearby
Bluetooth payments, and peer-to-peer voice/video calls on top. No accounts, no
phone numbers, no central servers — your identity is a key you hold.

Sonar grew out of [bitchat](https://github.com/permissionlesstech/bitchat) and
keeps its mesh + Nostr foundation, then rebuilds the product around a single
shared Rust core that drives native iOS/macOS and Compose Multiplatform
(Android/Desktop) apps.

## License

This project is released into the public domain. See the [LICENSE](LICENSE) file
for details.

## Features

- **Dual transport** — Bluetooth LE mesh for offline, Nostr for internet-based messaging, with automatic transport selection (Bluetooth → Nostr fallback → smart queueing).
- **White Noise secure DMs** — end-to-end-encrypted group messaging via [Marmot](https://github.com/marmot-protocol/mdk) (MLS over Nostr); interoperable with the White Noise client in both directions.
- **Encrypted media** — image / file / voice sharing over the Marmot media module (MIP-04).
- **⚡ Lightning wallet** — an embedded wallet (Breez SDK Liquid; BOLT12 / BIP-353 capable) tied to the same identity, so the same key restores the same wallet.
- **Nearby payments over BLE** — bidirectional, payments-only Lightning over Bluetooth (`⚡PAY`), no chat required.
- **Voice & video calls** — peer-to-peer `☎CALL` over an [iroh](https://github.com/n0-computer/iroh) QUIC transport (NodeId-authenticated, NAT hole-punching).
- **Location channels** — geographic chat rooms addressed by geohash, with live presence, over global Nostr relays.
- **Tor by default** — all internet traffic is routed through a local Tor SOCKS5 proxy, fail-closed when Tor isn't ready.
- **Privacy first** — no accounts, no phone numbers, no persistent identifiers; mesh DMs use the [Noise Protocol](https://noiseprotocol.org) (XX pattern), Nostr DMs use NIP-17 gift-wrapping.
- **Multi-platform** — native SwiftUI on iOS/macOS, Compose Multiplatform on Android/Desktop, all over one Rust core.

## Architecture

Sonar is **one headless Rust core, many thin app shells**. The core owns identity,
messaging, payments, and call signaling; each platform provides only the UI and
the OS-specific bits (radios, storage, notifications, wallet).

```
core/                     shared Rust core (Cargo workspace)
├── sonar-core/           identity + Marmot (MLS over Nostr) + geohash + mesh + call signaling
├── sonar-ffi/            UniFFI bindings → Swift (xcframework) + Kotlin (.so / JNA)
└── sonar-ble/            desktop BLE bridge (CoreBluetooth/BlueZ over JNA; own workspace)

ios/                      native SwiftUI reference app (iOS + macOS)
apps/sonar/               Compose Multiplatform app (Android + Desktop JVM)
web/                      SvelteKit marketing landing page
relays/                   curated Nostr relay list
design/                   vendored design handoff (source of truth for the UI)
docs/                     protocol & feature specs (payments, discovery, calls, Tor, …)
```

The core is generated into each app by the build scripts in `core/`
(`build-ios.sh`, `build-android.sh`, `build-desktop.sh`) — they compile the Rust
staticlib/cdylib and emit the UniFFI Swift/Kotlin bindings. The shipped binary
artifacts (e.g. `sonarffi.xcframework`) are **generated, not committed** — rebuild
them before archiving.

### Transports

**Bluetooth mesh (offline)** — direct peer-to-peer within range, multi-hop relay
(up to 7 hops), no internet required, Noise-encrypted with forward secrecy, over a
compact binary protocol tuned for BLE.

**Nostr (internet)** — global reach over a distributed relay network, NIP-17
gift-wrapped DMs, ephemeral per-geohash keys for location channels.

### Channel types

| Channel | Transport | Scope |
| --- | --- | --- |
| `mesh #bluetooth` | Bluetooth LE mesh | Local devices within multi-hop range — offline, protests, disasters, remote areas |
| Location (`block #dr5rsj7`, `neighborhood #dr5rs`, `country #dr`) | Nostr over internet | Geographic areas by geohash precision (`block` 7 → `region` 2 chars) |

### Account model

Your identity is a Nostr keypair (`npub`/`nsec`). The same key restores the same
profile **and** the same Lightning wallet across devices and transports — a single
person is one conversation whether they're reachable over BLE or White Noise.

For protocol detail, see the [Technical Whitepaper](WHITEPAPER.md), the Noise
write-up in [BRING_THE_NOISE.md](BRING_THE_NOISE.md), and the specs under
[`docs/`](docs/).

## Platform support

| Capability | iOS / macOS | Android | Desktop (JVM) |
|---|:---:|:---:|:---:|
| White Noise (Marmot) secure DMs | ✅ | ✅ | ✅ |
| Geohash channels + presence | ✅ | ✅ | ✅ |
| Encrypted media (MIP-04) | ✅ | ✅ | ✅ |
| BLE mesh — discovery | ✅ | ✅ | ✅ (scan + advertise) |
| BLE mesh — messaging | ✅ | ✅ | ⚪️ next stage (Noise-over-GATT) |
| Nearby payments over BLE (`⚡PAY`) | ✅ | ✅ | ⚪️ later |
| Lightning wallet | ✅ (Breez) | ✅ (Breez) | ⚪️ no desktop Breez build yet |
| Voice / video calls (`☎CALL`) | 🚧 in progress | 🚧 in progress | 🚧 |

See [`apps/sonar/README.md`](apps/sonar/README.md) for the full Android/Desktop matrix and its caveats.

## Build & run

### iOS / macOS

```bash
cd ios
open bitchat.xcodeproj
```

To run on a device:

- Copy the local config: `cp Configs/Local.xcconfig.example Configs/Local.xcconfig`
- Set your `DEVELOPMENT_TEAM` (and, if you fork it, `PRODUCT_BUNDLE_IDENTIFIER` / `APP_GROUP_ID`) in `Configs/Local.xcconfig`. The app group must stay `group.<bundle id>`.
- The Rust core is a generated artifact — rebuild it before building the app:

  ```bash
  ./core/build-ios.sh
  ```

For a quick macOS run from source: `brew install just && just run` (and `just clean` afterwards to restore the project for mobile builds).

### Android / Desktop (Compose Multiplatform)

```bash
cd apps/sonar
./gradlew :composeApp:assembleDebug        # Android APK
./gradlew :composeApp:run                  # Compose Desktop
```

The Gradle build invokes the Rust core build (`core/build-android.sh` /
`build-desktop.sh`) to produce the JNI `.so` / host dylib and the Kotlin bindings.

### Web (landing page)

```bash
cd web
npm install
npm run dev
```

## Localization

- Base app resources live under `ios/bitchat/Localization/Base.lproj/`. Add new copy to `Localizable.strings` and plural rules to `Localizable.stringsdict`.
- Share extension strings are separate in `ios/bitchatShareExtension/Localization/Base.lproj/Localizable.strings`.
- Prefer keys that describe intent (`app_info.features.offline.title`) and reuse existing ones where possible.
- Compile-check localization changes: `xcodebuild -project ios/bitchat.xcodeproj -scheme "bitchat (macOS)" -configuration Debug CODE_SIGNING_ALLOWED=NO build`.
