# Sonar: bitchat-compatible messenger with Marmot interop and Nostr identity

Date: 2026-06-11
Status: decided — **Approach B chosen** (thick headless Rust core, thin native shells)

## Context findings (research, June 2026)

1. **Identity is closer than expected.** This bitchat fork already keeps a *persistent* Nostr keypair in the Keychain (`bitchat/Nostr/NostrIdentityBridge.swift`), uses NIP-17 gift-wrap DMs for mutual favorites, and derives unlinkable per-geohash ephemeral keys (HMAC over a device seed). Missing: kind-0 profile support, nsec import, and surfacing identity as a "login". Anonymous mode is already the default behavior.
2. **Marmot is buildable today, in Rust.** The protocol layer is **MDK** (`marmot-protocol/mdk`, MIT, OpenMLS + rust-nostr, Least Authority audit completed 2026-03-20, API still alpha), with UniFFI bindings published as `mdk-swift` and `MDK-Kotlin` (no tagged releases yet). White Noise itself is a Flutter UI over `whitenoise-rs` (**AGPL — do not link**; build on MIT MDK). NIP-EE is officially superseded by Marmot. Interop with White Noise/Amethyst/Pika is a spec'd path: KeyPackages kind 30443, Welcome kind 444 inside NIP-59 gift wrap (1059), group messages kind 445 from ephemeral keys, KeyPackage relay list kind 10051.
3. **Bitkey today is ~95% Kotlin Multiplatform with Compose Multiplatform UI on both platforms** (Swift shell is near-empty). Its transferable assets for a Rust-core strategy are the *patterns*: `model(props) → ScreenModel` unidirectional state machines, `public/impl/fake` module splits, fakes + model-stream tests (Molecule/Turbine) + snapshot tests of screen models. The framework itself (Compose runtime, kotlin-inject) does not port to Swift.
4. **Current codebase reality:** ~33k LOC Swift, MVVM with ~9 `static let shared` singletons, `ChatViewModel.swift` is a 3,889-LOC god object, `BLEService.swift` is 4,591 LOC. Wire-compat invariants documented in `WHITEPAPER.md` and `BRING_THE_NOISE.md`. `permissionlesstech/bitchat-android` (Kotlin/Compose, claims 100% protocol parity, active as of June 2026) is the Android seed.

## Decisions taken (user)

- **Soft fork on the wire, hard fork in code:** must keep messaging stock bitchat users; free to restructure the codebase.
- **Shared Rust core** for protocol logic; native SwiftUI + Compose UIs.
- **Marmot added alongside** Noise-over-BLE and NIP-17 (interop with both bitchat and White Noise users), not a replacement.
- **Identity:** generate a fresh Nostr key silently by default; support nsec import; anonymous/ephemeral mode stays first-class forever. No NIP-46 in v1.

## Clarified Problem Statement

**Goal:** Evolve this bitchat fork into a cross-platform (iOS + Android ASAP) secure messenger — "Sonar" — that stays wire-compatible with bitchat (Noise-XX BLE mesh + NIP-17/geohash Nostr), additionally interoperates with White Noise users via the Marmot protocol (MLS over Nostr), and adds opt-in persistent Nostr identity/profiles, built around a shared Rust core and bitkey-grade engineering standards.

**Constraints:**
- Wire compatibility with stock bitchat is non-negotiable: `Noise_XX_25519_ChaChaPoly_SHA256`, the 13-byte BitchatPacket framing, TTL gossip, fragmentation, rekey rules (per `WHITEPAPER.md` / `BRING_THE_NOISE.md`), and NIP-17 gift-wrap DMs + kind-20000/20001 geohash events.
- Marmot interop must follow the MIPs (KeyPackages 30443, Welcome 444 in 1059 gift wrap, group messages 445) so White Noise/Amethyst/Pika users are reachable.
- Security floor: no protocol downgrade; secrets in platform keychains; build on the audited MIT MDK, not AGPL whitenoise-rs (also a license constraint — bitchat is public domain).
- Onboarding floor: zero-friction default (silently generated identity, anonymous/ephemeral mode stays first-class); nsec import for existing nostriches. No NIP-46 for v1.
- BLE mesh transport must remain native per platform (CoreBluetooth / Android BLE) — only the packet/crypto engine can be shared.

**Non-goals:**
- Replacing NIP-17 or Noise (Marmot is additive, not a migration).
- NIP-46 remote signers, multi-device identity sync, desktop/web clients (v1).
- Staying code-mergeable with upstream bitchat.
- Building our own relay infrastructure.

**Success criteria:**
- A Sonar user exchanges DMs with (a) a stock bitchat iOS user over BLE mesh, (b) a stock bitchat user over Nostr NIP-17, and (c) a White Noise user via a Marmot group — all from the same conversation list.
- Fresh install reaches a usable chat with zero sign-up steps; settings allow nsec import and kind-0 profile edit that other Nostr clients can read.
- One Rust crate owns Marmot + Nostr identity/profile logic, consumed by both apps via UniFFI; protocol logic is not duplicated in Swift and Kotlin.
- Android app ships on the same protocol core with feature parity for DMs.
- New code follows bitkey patterns: unidirectional screen models, public/impl/fake separation, fakes-based tests; no new singletons.

## Approaches Considered

### Approach A: Thin Rust protocol core, two native apps (fork bitchat-android)
- Sketch: Create `sonar-core` (Rust: MDK + rust-nostr + identity/profile + Marmot session state, SQLite via `mdk-sqlite-storage`), expose via UniFFI. Keep this Swift app and fork `permissionlesstech/bitchat-android` as the two UIs. Each app keeps its existing native Noise/BLE/NIP-17 stack untouched for bitchat compat; Marmot + login are new features wired to the core. Bitkey patterns applied to *new* modules only.
- Affected files: new `core/` Rust workspace; iOS: `bitchat/Nostr/NostrIdentityBridge.swift` (nsec import, kind-0), new `MarmotTransport` beside `bitchat/Services/NostrTransport.swift`, `bitchat/Services/MessageRouter.swift` (third route), onboarding/profile views; Android: equivalent in the forked repo.
- Tradeoffs: Fastest to ship Android (it already exists and is protocol-compatible); lowest regression risk to mesh compat. But app/chat logic stays duplicated per platform, the legacy Noise/NIP-17 stacks remain duplicated forever, and the god-object architecture persists around the new core.
- Effort: M (iOS) + M (Android fork integration) — first interop demo in weeks.

### Approach B: Thick headless Rust core, thin native shells
- Sketch: Rust owns everything below the screen: identity, Noise packet engine, NIP-17, Marmot, message store, routing, chat state machines emitting bitkey-style screen models over UniFFI callbacks; SwiftUI/Compose render models and forward events. Native code keeps only BLE radio I/O, keychain, notifications (bitkey's "thin shell" philosophy, with Rust where they used KMP). The Swift app's Services/ViewModels layers are progressively strangled.
- Affected files: everything — `bitchat/Noise/`, `bitchat/Nostr/`, `bitchat/Services/` (~11k LOC) reimplemented in Rust; `ChatViewModel.swift` (3.9k LOC) replaced by model-rendering views; Android written fresh against the core.
- Tradeoffs: Protocol + logic written and audited once; best long-term security posture and true bitkey-grade structure. But re-implementing bitchat's Noise/packet layer in Rust must be byte-perfect against an unversioned-spec moving target, and "Android ASAP" slips by months. Highest risk of compat regressions.
- Effort: L/XL — 4–6+ months before parity.

### Approach C: Bitkey-verbatim KMP + Compose Multiplatform, Rust only for Marmot
- Sketch: Adopt bitkey's actual current architecture: one Kotlin Multiplatform codebase (state machines, kotlin-inject-anvil, public/impl/fake), Compose Multiplatform UI on both platforms, near-empty Swift shell. Reuse bitchat-android's Kotlin protocol code as the seed for commonMain/androidMain; Rust enters only as MDK via MDK-Kotlin bindings (Quartz/Amethyst's KMP Nostr lib as reference). The existing Swift app is retired.
- Affected files: new Gradle KMP workspace; bitchat-android's `noise/nostr/mesh/geohash` packages migrated to shared modules; this repo's Swift code becomes reference-only.
- Tradeoffs: Single UI + single logic codebase, the most literal reading of "follow bitkey standards," and Android-first by construction. But it abandons the working 33k-LOC iOS app (the shipped platform) for a Compose-on-iOS bet, and contradicts the shared-Rust-core choice except at the crypto layer.
- Effort: L — Android fast, iOS parity slow.

## Decision

**Approach B chosen by the user (2026-06-11): thick headless Rust core, thin native shells.** Rationale: the security-critical ecosystem (MDK/OpenMLS, rust-nostr, Arti/Tor) is Rust and audited; writing protocol + app logic once is worth the longer road. The user explicitly accepted the cost over the thin-core option (A) after weighing the KMP/Compose-Multiplatform alternative (C).

Recommended delivery sequencing within B (avoids a big-bang rewrite; every milestone ships):
1. **M1 — `sonar-core` bootstrap:** Rust workspace with MDK + rust-nostr; identity (generate/import nsec, kind-0 profiles) and Marmot 1:1 DMs in the core; iOS integrates via UniFFI alongside the existing native stack. Validate `mdk-swift`/`MDK-Kotlin` bindings here (fallback: vendor our own UniFFI layer over `mdk-core`).
2. **M2 — Android shell:** thin Compose app against the core (mesh can lag; Marmot + Nostr DMs first). Reuse bitchat-android's BLE/mesh code as the native radio layer when mesh lands.
3. **M3 — bitchat wire stack into the core:** Noise XX + BitchatPacket framing + NIP-17 in Rust, verified byte-for-byte against the Swift implementation with cross-implementation test vectors; native BLE radios feed bytes to the core on both platforms.
4. **M4 — strangle the Swift logic:** message store, routing, chat state machines emit bitkey-style screen models over UniFFI; `ChatViewModel` (3.9k LOC) and the singleton services retire incrementally.

Main risks: byte-perfect reimplementation of the unversioned bitchat wire protocol (mitigate with test vectors generated from the existing Swift code before porting); MDK API is alpha; Android arrives at M2 rather than immediately.

## Open questions

- Group chats in v1, or 1:1 Marmot DMs first? (MLS shines at groups; scope driver.)
- How do we *discover* that a peer supports Marmot — extend the bitchat announce, or just look up their kind-30443 KeyPackage on relays?
- Push notifications for Marmot messages (MIP-05/transponder is still Draft) — acceptable to start with foreground/polling + relay subscriptions over Tor?
- Does Marmot traffic route through the existing Arti/Tor stack like other Nostr traffic? (Recommend yes, but affects latency.)
- Product/branding: app name, store listing, and whether the Android fork keeps bitchat branding during transition.
- Multi-device (Marmot supports multiple KeyPackages) — explicitly deferred, but the identity design should not preclude it.

## Sources

- Marmot spec: https://github.com/marmot-protocol/marmot (MIP-00…05)
- MDK: https://github.com/marmot-protocol/mdk • bindings: https://github.com/marmot-protocol/mdk-swift , MDK-Kotlin (see https://github.com/marmot-protocol/awesome-marmot)
- MDK audit: https://leastauthority.com/blog/audit-of-white-noise-marmot-development-kit-mdk/
- White Noise: https://github.com/marmot-protocol/whitenoise (Flutter) + https://github.com/marmot-protocol/whitenoise-rs (AGPL)
- Bitkey architecture: https://github.com/proto-at-block/bitkey/tree/main/app • https://engineering.block.xyz/blog/how-bitkey-uses-cross-platform-development
- bitchat Android: https://github.com/permissionlesstech/bitchat-android
- Local wire-compat invariants: `WHITEPAPER.md`, `BRING_THE_NOISE.md`, `docs/TOR-INTEGRATION.md`
