# Sonar as an official Beeper network

## Clarified Problem Statement

**Goal:** Make Sonar available as a first-class network inside Beeper, similar
to Telegram or WhatsApp, so a Beeper user can create a bridge-owned Sonar
identity and exchange 1:1 Marmot text and encrypted media messages with Sonar
users from the normal Beeper inbox.

### Product shape

- A user selects **Sonar** in Beeper's network/account settings.
- The connector creates a new Sonar identity for that Beeper account, publishes
  its Marmot KeyPackage, and shows the resulting `npub` for sharing.
- The user starts a chat by entering or resolving another Sonar `npub`.
- Each Sonar 1:1 Marmot group maps to one Matrix portal room; each remote Sonar
  identity maps to a Matrix ghost/user.
- Text, images, video, ordinary audio, and files flow both ways in v1. Voice-note
  classification remains an explicit cross-platform wire-model gap.
- Sonar's local database remains authoritative on the Sonar side. Relay sync
  updates that database in the background; it does not gate portal creation,
  chat opening, or local transcript reads.

### Constraints

- Use Beeper's current production extension point: a Matrix bridge built on
  `mautrix-go` bridgev2. Beeper documents bridgev2 as the supported route for
  third-party bridges and `bbctl` as the self-hosted proving path.
- The end target is an official Beeper-hosted network. Repository transfer,
  account-settings listing, cloud deployment, and operational ownership require
  Beeper's acceptance and cannot be completed solely from the Sonar repository.
- Generate a separate Sonar identity in v1. Logging out, process restarts, and
  upgrades must not silently rotate or lose it. Explicit account deletion is
  the only normal destructive path.
- Put identity access behind a versioned `IdentityProvider`/account contract.
  Initially it returns a generated local `nsec`; later it must be possible to
  add a linked-device or remote-signer implementation when Sonar gains
  multi-device support without changing portal or message identifiers.
- Never place `nsec`, database keys, relay credentials, signing material, or
  decrypted media in Matrix state, command arguments, logs, crash reports, or
  source control. Encrypt bridge credentials and Sonar state at rest.
- The bridge is an encryption endpoint: it decrypts Marmot/MLS messages and
  re-encrypts them into Matrix E2EE, and does the reverse outbound. This trust
  boundary must be disclosed clearly; bridge operators can access plaintext
  while translating it.
- Preserve Signal-comparable local-first performance. Do not implement inbound
  delivery by repeatedly scanning all groups and full transcripts. Consume
  persisted change notifications/incremental cursors and use bounded local
  pages for backfill.
- Media must be file-backed across the Go/Rust boundary. Sonar media is
  downloaded, authenticated, and decrypted to a temporary file before Matrix
  upload; Matrix media is downloaded to a temporary file before Sonar encrypts
  and uploads it to Blossom. Clean up every success, failure, cancellation, and
  restart path.
- This is a relay-only integration. A cloud bridge cannot provide BLE mesh
  presence or transport.
- No Sonar app UI change is required for v1, but interoperability must be tested
  with both native Apple (`ios/`) and Compose (`apps/sonar/`) clients.

### Non-goals for v1

- Reusing the user's existing mobile Sonar identity or synchronizing one
  `nsec` across Beeper and Sonar devices.
- Group chat creation/management, reactions, replies, edits, deletion,
  read receipts, typing indicators, profiles/contact synchronization, stickers,
  calls, payments, geohash channels, or BLE mesh.
- Embedding the Sonar iOS or Compose UI inside a Beeper client.
- Making the Beeper Desktop API simulate a new network; that API automates an
  existing Beeper installation and is not the bridge/network extension point.
- Guaranteeing that Beeper will host or list the integration before technical,
  security, product, and operational review.

### Success criteria

- A Beeper user completes a Sonar add-account flow without supplying an `nsec`,
  sees the generated `npub`, and receives the same identity after bridge
  restarts and upgrades.
- From Beeper, the user can resolve an `npub` and open a portal immediately.
  Established DMs can commit text locally before relay setup completes; a new
  DM reports a retriable pending send until the peer KeyPackage is available.
- Text and supported media work bidirectionally between Beeper and both the
  Apple and Compose Sonar apps.
- Mapping tables make Matrix event ID, Sonar event/message ID, Marmot group ID,
  peer `npub`, and portal room ID idempotent. Retries and restarts produce no
  duplicate portals or messages.
- Inbound relay events enter Sonar local storage first, then emit an incremental
  bridge event. Initial history import and later backfill use bounded cursor
  pages and do not scan every transcript before first paint.
- Media round trips preserve MIME type, filename, caption, dimensions, and
  duration where the current wire model provides them; large payloads do not
  cross IPC as in-memory byte arrays. Voice-note classification is tracked as
  `BRIDGE-PLATFORM-1` until Apple and Compose share an explicit marker.
- Automated tests cover reconnects, replayed events, out-of-order arrival,
  process crashes during media transfer, and identity persistence without
  exposing secrets.
- The connector runs first as a self-hosted bridge through `bbctl`, passes
  bridgev2 behavior/security review, and has a documented deployment and
  migration path suitable for Beeper-operated hosting.

## Approaches Considered

### Approach A: bridgev2 connector plus a dedicated Sonar bridge daemon

- **Sketch:** Build a Go `mautrix-go/bridgev2` connector that owns Matrix login,
  portals, ghosts, media conversion, and Beeper capabilities. Add a small Rust
  `sonar-bridge-daemon` using `sonar-core`; communicate over a bounded,
  versioned child-process RPC/event stream. Run isolated durable Sonar state per Beeper
  account, supervised by the connector or deployment platform.
- **Affected modules:** a new bridge repository (candidate layout
  `cmd/mautrix-sonar`, `pkg/connector`, `pkg/sonaripc`, bridge database and
  deployment); new `core/sonar-bridge-daemon/`; existing
  `core/sonar-core/src/client.rs` and
  `core/sonar-core/src/conversation_index.rs` only where stable incremental,
  path-based bridge APIs are missing; `core/Cargo.toml`; interoperability and
  operator documentation.
- **Tradeoffs:** Best boundary between Beeper's Go-native ecosystem and Sonar's
  Rust protocol implementation. The daemon can preserve Sonar local-first
  semantics and avoids unsafe cross-language callbacks, but introduces RPC,
  process supervision, per-account lifecycle management, and coordinated
  versioning. The first implementation uses bounded, versioned NDJSON over
  child-process stdin/stdout rather than a filesystem socket.
- **Effort:** L.

### Approach B: bridgev2 connector linked directly to Sonar Rust through CGo

- **Sketch:** Keep the Go bridgev2 connector, but expose a narrow C ABI from a
  new Rust bridge library and link it into one bridge binary. Go calls account,
  conversation, cursor, send, and path-based media functions directly; Rust
  forwards change events through a carefully bounded callback/queue API.
- **Affected modules:** new bridge repository; new
  `core/sonar-bridge-ffi/` or an additional C ABI in `core/sonar-ffi/`; native
  build scripts, headers, packaging, and cross-platform CI; the same core
  incremental APIs as Approach A.
- **Tradeoffs:** One deployable process and lower IPC overhead. In return, CGo
  ownership, cancellation, callbacks, Tokio runtime lifecycle, native crashes,
  cross-compilation, and allocator boundaries substantially raise integration
  and operational risk. The performance gain is unlikely to matter compared
  with relay, Blossom, and Matrix network latency.
- **Effort:** L.

### Approach C: bridgev2 prototype around long-lived `sonar-cli` sidecars

- **Sketch:** Extend `sonar-cli` with a persistent JSON-lines or local RPC mode,
  then have the Go connector run one sidecar per Beeper account. Reuse existing
  `init`, `publish`, `send`, `listen`, `messages`, and `fetch` behavior to prove
  account creation and bidirectional text/media before defining a stronger
  daemon contract.
- **Affected modules:** `core/sonar-cli/src/main.rs`,
  `core/sonar-cli/README.md`, CLI packaging, and a new bridgev2 connector
  repository.
- **Tradeoffs:** Fastest route to a real `bbctl` pilot and validates the product
  mappings early. It is not a good official-cloud endpoint as currently shaped:
  CLI process supervision and error typing are weak, and `listen` scans every
  group and complete transcript to find unseen messages, conflicting with the
  repository's bounded local-first performance rule. It should be treated as a
  disposable protocol spike or evolved into Approach A before production.
- **Effort:** M.

## Recommendation

Choose **Approach A** and deliver it in two gates.

1. Build a self-hosted `bbctl` pilot to validate Beeper login, `npub` contact
   resolution, portal/ghost mapping, idempotency, and two-way text/media with
   both Sonar app surfaces.
2. Harden the same bridgev2 connector and daemon for multi-tenant operations,
   then pursue Beeper review, repository ownership, account-settings listing,
   and official hosting.

This follows Beeper's supported bridge architecture while keeping all Marmot,
Nostr, local database, and media cryptography in `sonar-core`. A dedicated
versioned daemon is slightly more work than wrapping the current CLI, but it
creates the lifecycle, incremental-event, security, and compatibility contract
an official hosted bridge needs. Contact Beeper before deep implementation to
confirm product sponsorship, hosting expectations, bridge naming, and the
required account-login/capabilities surface.

## Open questions

- Will Beeper sponsor/accept Sonar as an official hosted network, or should the
  first public release remain a third-party self-hosted bridge?
- What encrypted secret store and per-account isolation mechanism does Beeper
  require for cloud bridges that generate network identity keys?
- Which Matrix E2EE mode, media limits, backfill limits, capability events, and
  observability conventions are mandatory for a new official bridge?
- Should removing the Beeper connection destroy the generated Sonar identity,
  or offer an encrypted export/recovery flow first?
- Does v1 expose only exact `npub` resolution, or also a Sonar descriptor/BIP-353
  lookup flow for human-readable discovery?

## References

- [Beeper bridges and self-hosting](https://developers.beeper.com/bridges)
- [Beeper Bridge Manager](https://github.com/beeper/bridge-manager)
- [Beeper LINE bridgev2 implementation](https://github.com/beeper/line)
- [Sonar headless CLI contract](../../core/sonar-cli/README.md)
- [Sonar architecture](../../README.md)
