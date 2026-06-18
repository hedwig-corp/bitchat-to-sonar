# Native Sonar Stickers Implementation Plan

Status: in progress on `codex/native-sticker-full-loop`.

This plan extends the `core/sonar-stickers`, `sonar-cli post`, and `/stickers`
web work into a production-ready native sticker loop across both supported app
surfaces:

- `ios/`: native SwiftUI iOS/macOS app.
- `apps/sonar/`: Compose Multiplatform Android/Desktop app.

Per `AGENTS.md`, no user-facing sticker send feature is complete unless both
surfaces can install, pick, send, receive, and render the same sticker reference
format. If a platform cannot ship in a given patch, that patch must keep the
feature hidden or document a tracked gap with the reason and follow-up path.

## Safety Model

Native sticker support is safe to enable only when all of these are true:

- Sticker UI remains behind a feature flag until the final parity commit.
- Relay events and Blossom URLs are treated as untrusted input.
- Clients render only HTTPS sticker URLs that contain the advertised SHA-256.
- Downloaded sticker bytes are hash-verified before entering the local cache.
- Pack size, sticker dimensions, blob size, and local cache size are bounded.
- Sent sticker references include:
  - pack address: `30030:<author-pubkey-hex>:<identifier>`;
  - shortcode;
  - plaintext sticker SHA-256.
- Received sticker refs resolve only when the current pack contains both the
  referenced shortcode and referenced plaintext hash.
- Missing, edited, malformed, or hash-mismatched packs render an explicit
  missing/untrusted state instead of substituting another image.
- Signal `pack_key` material is never stored in native Sonar app messages,
  published through Nostr, uploaded to Blossom, logged, or exposed in shareable
  Sonar links.
- Chat rendering never blocks on network fetches. Pack/sticker resolution runs
  asynchronously and updates the row after completion.
- BLE mesh sticker support is explicit. Until a mesh-safe sticker transport
  exists, native stickers are a White Noise/Marmot feature and the UI must not
  imply BLE delivery support.

## Current PR Progress

This branch now covers the safe foundation for both native app surfaces:

- shared Rust/Kotlin/Swift sticker chat-message contract;
- native installed-pack store and exact shortcode-plus-hash resolver;
- native Nostr sticker pack and installed-pack-list tag parsing;
- bounded, SHA-256 verified sticker-byte cache primitives;
- feature-gated received-sticker rendering with verified HTTPS asset fetch;
- feature-gated picker and send flow for already installed packs on existing
  White Noise/Marmot conversations;
- bounded recent-sticker state shown in the native pickers;
- validated persisted installed-pack and recent-sticker snapshots across app
  relaunches;
- feature-gated manual install UI for pasted Nostr sticker pack event JSON on
  Compose, iOS, and macOS.

The feature must remain disabled until the remaining production gaps are closed:

- automatic fetch orchestration from `/stickers` links, Nostr profile metadata,
  or relay pack discovery into the native install flow;
- full native target builds and end-to-end install/pick/send/render tests.

## Patch Sequence

Use separate commits inside one PR so reviewers can validate the complete
cross-platform contract while still reviewing each layer independently.

1. `docs: plan native sticker integration`
   - Add this plan.
   - Update `docs/SONAR-STICKERS.md` with native app rollout constraints.

2. `test: add sticker contract fixtures`
   - Add shared JSON fixtures for:
     - valid pack event;
     - installed-pack list;
     - valid sent sticker ref;
     - edited-pack hash mismatch;
     - malformed non-HTTPS URL;
     - duplicate shortcode/hash;
     - missing pack fallback.
   - Cover the fixtures in Rust, Swift, and Kotlin tests where practical.

3. `feat(core): add chat sticker reference contract`
   - Add stable parsing/building helpers for sticker control payloads used by
     native chat messages.
   - Keep this transport-neutral and compatible with existing Marmot messages.
   - Preserve graceful fallback for clients that do not understand stickers.

4. `feat(ios): add sticker store and resolver`
   - Add an installed-pack store, local cache metadata, recent-use state, and
     async resolver.
   - Validate pack refs and sticker hashes before returning renderable state.
   - Keep user-facing entry points hidden behind the feature flag.

5. `feat(compose): add sticker store and resolver`
   - Add the same installed-pack, cache, recent-use, and async resolver model for
     Compose Multiplatform.
   - Mirror iOS validation and fallback states.

6. `feat(ios): render received sticker messages`
   - Render sticker rows for loaded, loading, missing-pack, untrusted, and failed
     states.
   - Avoid network work on the main thread.
   - Keep send/install UI hidden.

7. `feat(compose): render received sticker messages`
   - Implement the same received-render states in Compose.
   - Keep layout stable on Android and Desktop.

8. `feat(ios): add sticker picker and send flow`
   - Add picker tabs for installed packs and recent stickers.
   - Selecting a sticker sends the immutable sticker ref over Marmot/White Noise.
   - Update recent-use only after local send acceptance.

9. `feat(compose): add sticker picker and send flow`
   - Add equivalent picker, send flow, and recent-use handling.
   - Match iOS labels, unavailable states, and error behavior.

10. `feat: enable native sticker feature behind rollout flag`
    - Wire install/share affordances from `/stickers` links to native apps.
    - Keep a runtime flag or conservative rollout switch if network/cache
      behavior still needs staged validation.

11. `test: cover native sticker install and render cases`
    - Add focused tests for install, valid render, missing pack, hash mismatch,
      and send payload generation across the supported native surfaces.

12. `docs: document production rollout and known limits`
    - Document enabled transports, limits, cache behavior, privacy behavior, and
      operational rollout notes.

## Verification Plan

Run the narrow checks after each layer and the full relevant checks before PR:

```sh
cd core
cargo fmt --all --check
cargo test -p sonar-stickers --features signal-import
cargo test -p sonar-cli
cargo clippy -p sonar-stickers --features signal-import -- -D warnings
cargo clippy -p sonar-cli -- -D warnings

cd apps/sonar
./gradlew :composeApp:jvmTest
./gradlew :composeApp:assembleDebug

cd web
npm run check
npm run build

xcodebuild -project ios/bitchat.xcodeproj \
  -scheme "bitchat (macOS)" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

If generated Rust/FFI artifacts are stale or unavailable, rebuild them with the
documented `core/build-*` scripts before treating native compile failures as
feature failures.

## Production Readiness Gate

The feature is production-ready only after:

- the native feature flag is still safe to keep off by default;
- both native clients pass the same fixture cases;
- both native clients can complete install -> pick -> send -> receive -> render;
- missing or edited packs never render an incorrect sticker;
- cache/download limits are enforced;
- local verification passes or any pre-existing blocker is documented;
- a production-safety self-review finds no blocking issues;
- PR CI is green or any red CI is proven unrelated.

Before this gate, the correct release state is alpha/beta or disabled-by-default,
not production enabled.
