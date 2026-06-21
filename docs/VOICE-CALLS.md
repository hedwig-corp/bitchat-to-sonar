# Sonar Voice & Video Calls — Architecture

How 1:1 real-time calls work in Sonar, end to end, and which libraries do what.
This is the reference for "what is actually going on" when you place or receive a
call. It reflects the implementation lifted from n0's [`callme`](https://github.com/n0-computer/callme)
reference and adapted to Sonar's identity + messaging model.

> TL;DR — A call has two independent planes:
> 1. **Signaling** (who's calling, accept/decline, exchange dialable addresses):
>    a tiny `☎CALL` text protocol that rides Sonar's **existing encrypted
>    messaging** (Marmot/MLS over Nostr, i.e. *the internet*). It is **not** a
>    server; it reuses the chat transport.
> 2. **Media** (the actual audio): a **peer-to-peer [iroh](https://www.iroh.computer)
>    QUIC connection** carrying **Opus** audio as **RTP-over-QUIC** (iroh-roq).
>
> The signaling carries each side's iroh address; the media connects directly
> (NAT-traversed, relay-assisted) over iroh. The two planes never mix: the call
> engine touches **no** MLS state.

---

## 1. Libraries / dependencies

All call code lives in the Rust core (`core/`), behind Cargo features so the
default messaging build never compiles iroh/audio.

| Crate | Version | Role |
|-------|---------|------|
| [`iroh`](https://docs.rs/iroh) | `1.x` | P2P QUIC transport. One long-lived `Endpoint` per app; Ed25519 `EndpointId` identity; NAT hole-punching; relay fallback; pkarr/DNS **discovery**. |
| `iroh-roq` | vendored (`core/vendor/iroh-roq`) | **RTP-over-QUIC** media session on top of an iroh `Connection`. Upstream pins iroh 0.33; we vendored + ported it to **iroh 1.0**. Provides `Session` + send/receive *flows* per track. |
| [`opus`](https://github.com/DCNick3/opus-rs) | git `unsafe-libopus` branch | Opus audio codec, **pure-Rust** backend (`unsafe-libopus`, no C lib) so it cross-compiles cleanly to iOS/Android. Mono 48 kHz, 20 ms frames. |
| [`cpal`](https://docs.rs/cpal) | `0.15.3` | Cross-platform audio capture/playback. CoreAudio on iOS/macOS; **oboe** (AAudio) on Android (`oboe-shared-stdcxx`). |
| `base64`, `serde_json` | — | Encode the iroh `EndpointAddr` into the opaque `nodeAddrB64` token carried in `☎CALL` lines. |
| `uniffi` | `0.31` | Generates the Swift/Kotlin bindings (`sonar-ffi`) the apps call. |

**Cargo features** (`core/sonar-core` + `core/sonar-ffi`):
- `calls` → pulls `iroh` + `iroh-roq` + the transport/signaling. *(transport only)*
- `calls-audio` → `calls` + `opus` + `cpal` (the full media path). **This is the
  default for the shipped iOS/Android builds** (`core/build-ios.sh`,
  `core/build-android.sh`). The Compose **desktop** build ships *without* it, so
  desktop calls are disabled by design.

---

## 2. The two planes (overview)

```
        ┌─────────────────────────── SIGNALING (internet) ───────────────────────────┐
        │  ☎CALL OFFER/ANSWER/END text lines over Marmot (MLS) / NIP-17 via Nostr     │
 caller │  relays — carries each peer's base64 iroh EndpointAddr + callId            │ callee
 (app)  └────────────────────────────────────────────────────────────────────────────┘ (app)
            │                                                                   │
            ▼                                                                   ▼
        ┌─────────────────────────────── MEDIA (iroh P2P) ──────────────────────────────┐
        │  iroh QUIC connection (ALPN "sonar/call/0"), NAT-traversed + relay-assisted    │
        │  → iroh-roq RTP-over-QUIC → Opus 48 kHz mono → cpal mic/speaker                │
        └────────────────────────────────────────────────────────────────────────────────┘
```

- **Signaling** is *out of band* for the media: iroh provides the encrypted P2P
  transport but **not** call setup, so Sonar supplies setup with `☎CALL`,
  exactly like the `⚡PAY` feature rides the chat.
- **Media** is fully P2P/end-to-end-encrypted by iroh's QUIC (TLS). The signaling
  is end-to-end-encrypted by Marmot/MLS (or NIP-17).

---

## 3. Signaling plane — `☎CALL`

**Code:** `core/sonar-core/src/call/signaling.rs` (pure, always compiled, shared
by both apps and unit-tested). Wire prefix: `☎CALL` (`CALL_PREFIX`).

Control messages (`CallControl`): `OFFER`, `ANSWER` (`accept`/`decline`/`busy`),
`CANCEL`, `END`. An OFFER/ANSWER carries the sender's dialable address as
`nodeAddrB64` (base64url of the JSON-serialized iroh `EndpointAddr`) plus the
`callId` and a unix timestamp (for staleness).

A `☎CALL` line is sent as an **ordinary encrypted message** over a conversation
and is **never rendered** as chat — both apps prefilter inbound messages for the
`☎CALL` prefix and route them to the call engine instead of the transcript.

### Transport for signaling — **always over the internet**

Signaling rides Sonar's existing encrypted channels. Historically it could go
over **BLE mesh** *or* **internet** (Marmot/NIP-17); **as of this design it
always goes over the internet** (`SNVia.internet`).

Rationale (measured): BLE mesh signaling required an *established Noise session*
between the two devices, but the BLE link flaps (connect/disconnect) so the Noise
handshake often never completes — `meshReachable()` returns true while the
encrypted route isn't actually ready, and the `☎CALL` control is dropped at send
(`BLEService: immediate BLE send unavailable … noise=false` →
`dropping control without established Noise route`). The callee then never gets
the OFFER ("nothing arrives"). The internet path (Marmot group message or NIP-17
to the peer's npub) does not depend on a local BLE Noise session, so calls now
require — and always use — an internet signaling route.

> Trade-off / gap: two BLE-only peers with no Marmot/Sonar relationship cannot
> currently call. Reliability of the internet path depends on Nostr relay
> delivery (see Known issues).

**App resolution** (`SonarAppStore.callSignalingVia` on iOS/macOS,
`SonarAppState` on Compose):
- A folded Marmot (White Noise) group for the peer → send the `☎CALL` line into
  that MLS group.
- Else a resolved Sonar descriptor/profile (npub) → send via NIP-17 to the npub.
- `canCall()` additionally requires the peer to advertise call capability
  (`SonarCapability.calls`) or `supportsMarmotCallSignaling`.

---

## 4. Transport plane — iroh `Endpoint`

**Code:** `core/sonar-core/src/call/transport.rs`, identity in
`core/sonar-core/src/call/identity.rs`.

- **One long-lived `Endpoint` per app session.** iroh's contract is *"an
  application will have a single endpoint instance"*; creating/dropping endpoints
  repeatedly "breaks peer reconnection." See the FFI ownership note below — the
  endpoint must **outlive** any messaging node so it survives reconnects.
- Bound with the `N0` preset (crypto + address discovery) **with relays
  enabled** for NAT traversal between two phones. ALPN: `b"sonar/call/0"`
  (`CALL_ALPN`). *(The `callme` reference uses `iroh_roq::ALPN`; Sonar uses its
  own — both ends agree, so it's internal.)*
- **Stable identity:** the iroh Ed25519 secret is derived **in-core** from the
  Sonar Nostr secret via HKDF (`call::identity::derive_iroh_secret`). So the
  `EndpointId` is deterministic and stable across launches → discovery resolves
  it, and the same identity is idempotent for binding.
- **Address exchange:** `local_addr_b64()` serializes the endpoint's
  `EndpointAddr` for the OFFER/ANSWER; `decode_addr()` parses the peer's.
- **Dialing:** the answerer dials the offerer (`endpoint.connect(addr, ALPN)`).
  With N0 discovery, even a partial address resolves via the relay.

### Roles & the security pin (plan §3.1/§4.3)

- **Offerer** = caller. After sending the OFFER and receiving `ANSWER|accept`, it
  **pins** the answerer's `EndpointId` and waits in the accept loop, admitting
  **only** an inbound connection whose QUIC-authenticated id matches the pin.
- **Answerer** = callee. On accept it **dials** the offerer and verifies the
  pinned id. QUIC authenticates the peer cryptographically, so pinning binds the
  media session to the signaling identity. Unknown inbound ids are dropped.

---

## 5. Media plane — iroh-roq + Opus + cpal

**Code:** `core/sonar-core/src/call/{media,codec,device}.rs`.

- Once connected, the QUIC `Connection` is wrapped in an `iroh_roq::Session`
  (`transport::rtc_session`). Audio is one RTP **flow**; video later is another.
- **Codec:** Opus, mono **48 kHz**, **20 ms** frames (960 samples) — `codec.rs`.
- **Devices (`device.rs`):** cpal opens default input/output on a dedicated
  thread (cpal `Stream` is `!Send`); mic frames are downmixed to mono, playback
  upmixes mono to the device's channel count. **A missing mic/speaker is
  non-fatal** — the call still connects (hermetically testable). Mute sends
  silence frames to keep RTP timing stable.

---

## 6. Call state machine — `CallEngine`

**Code:** `core/sonar-core/src/call/engine.rs`. Drives the 1:1 state map and
emits `CallEvent`s the host parks for via `next_event` (mirrors
`wait_for_marmot_event`). States: `Ringing → Connecting → Connected → Ended`
(plus `Failed/Declined/Busy/Missed`).

Key methods: `start` (bind endpoint + accept loop), `place` (offerer registers
Ringing), `on_incoming_offer` (answerer registers + pins+stores offerer addr),
`on_answer` (offerer pins answerer on accept), `accept` (answerer dials + starts
media), `hangup`, `set_muted`, `next_event`, and `close` (graceful
`Endpoint::close`).

---

## 7. FFI + ownership — the long-lived `call_session`

**Code:** `core/sonar-ffi/src/lib.rs` (`call_session` module + `call_*` methods).

The call engine is a **process-lived singleton** (`call_session`), **not** a
field on `SonarNode`, with **its own long-lived tokio runtime**. This is load
bearing: the messaging `SonarNode` is recreated on every relay reconnect
(local→relay first-paint swap, reconnects), and the iroh endpoint + its tasks
must **not** die with it. The singleton is keyed by the derived iroh secret:
idempotent for the same identity, and it gracefully `close()`s + rebinds on an
identity change. `call_start` binds once; `call_accept`/`call_wait_event` drive
on the call runtime; every `SonarNode` shares the one engine.

> Why it matters: before this, the endpoint was dropped (`Endpoint dropped …
> Aborting ungracefully`) ~1–2 min after binding, so a call placed afterwards had
> no transport and "rang forever." See Known issues / history.

The FFI exposes: `call_start`, `call_local_address`, `call_place`,
`call_on_incoming_offer`, `call_on_answer`, `call_accept`, `call_hangup`,
`call_set_muted`, `call_wait_event`, plus pure `call_encode_*` / `call_parse_control`
signaling helpers. All `SonarNode` call methods are **blocking** — hosts call
them off the main thread and poll `call_wait_event` on a dedicated thread.

---

## 8. App integration

### iOS / macOS (native SwiftUI — `ios/`)
- `SonarAppStore` owns the call UI state (`activeCall`) and the signaling glue:
  `placeCall`, `acceptCall`, `declineCall`, `hangupCall`, `toggleCallMute`,
  `processIncomingCallLines` (prefilter inbound for `☎CALL`), `handleCallControl`
  (route OFFER/ANSWER/END to the engine), `callSignalingVia` / `canCall`
  (route resolution — internet only), and the `callWaitEvent` loop.
- `MarmotService` delegates the `call_*` FFI on dedicated queues
  (`callQueue` for ops, `callWaitQueue` for the parked event loop).
- `MarmotChatModel` publishes `npub`/`relayConnected`; `ensureCallStarted()` binds
  the engine once at startup (the singleton makes this safe across reconnects).
- Audio routing: `SonarCallAudioRoute` configures `AVAudioSession`
  (`.playAndRecord`, `.voiceChat`), speaker/earpiece + proximity.

### Android / Desktop (Compose Multiplatform — `apps/sonar/`)
- `SonarAppState` mirrors the iOS call logic; `SonarCore` (expect/actual) wraps
  the same FFI. Android enables `calls-audio` (oboe); **desktop disables calls**
  (`callStart()` errors by design).

---

## 9. End-to-end call flow

```
Caller (offerer)                          Callee (answerer)
  placeCall(conv)                           
  callStart() [idempotent, singleton]       (engine already bound at launch)
  addr = call_local_address()               
  call_place(callId)  → Ringing             
  send ☎CALL OFFER(callId, addr) ───────▶  processIncomingCallLines → handleCallControl
  (over Marmot/NIP-17, internet)            canCall? → call_on_incoming_offer(addr) → Ringing
                                            UI rings
                                            user taps Accept:
                                            send ☎CALL ANSWER|accept(addr) ◀───────
  on_answer(accept, addr): pin id, Connecting                call_accept(): dial offerer
  accept loop admits pinned inbound ◀────── iroh QUIC connect (NAT/relay) ──────▶ connect_media
  connect_media → Connected                                  connect_media → Connected
  ── Opus/RTP audio both ways (iroh-roq) ──
  hangupCall(): send ☎CALL END ─────────▶  connection closes → Ended
```

---

## 10. Cross-platform matrix

| | Transport (iroh) | Media (opus/cpal) | Signaling | Notes |
|---|---|---|---|---|
| iOS (native) | ✅ | ✅ CoreAudio | internet | needs foreground (see CallKit gap) |
| macOS (native) | ✅ | ✅ CoreAudio | internet | reliable test peer (no background suspend) |
| Android (Compose) | ✅ | ✅ oboe | internet | `calls-audio` on |
| Desktop (Compose) | ❌ | ❌ | — | calls disabled by design |

---

## 11. Debugging & observability

- **Rust logs:** `init_logging()` (sonar-ffi) bridges `tracing` → stderr
  (iOS/macOS/desktop) / logcat (Android). `RUST_LOG=info,sonar_core=debug,iroh=info`
  (or `iroh=debug` for full magicsock/relay detail).
- **Swift logs:** set `BITCHAT_LOG_STDERR=1` to mirror `SecureLogger` (os_log) to
  stderr so the `SonarCall:` signaling path shows in `devicectl --console` /
  `open --stderr` captures. Gate verbosity with `BITCHAT_LOG_LEVEL=debug`.
- **Capture a device call (no root):**
  `xcrun devicectl device process launch --console --environment-variables
  '{"BITCHAT_LOG_STDERR":"1","BITCHAT_LOG_LEVEL":"debug","RUST_LOG":"info,sonar_core=debug,iroh=info"}'
  --device <UDID> sh.hedwig.sonar`. Grep `SonarCall` for `SENT control over
  internet …` (caller) and `RX control …` (callee).
- **Headless transport test:** `sonar-cli call` (build with
  `--features calls-audio`) connects two terminals directly over real iroh via a
  manual address handshake — the clean way to exercise the transport without the
  apps. `A$ sonar-cli call` (offerer) / `B$ sonar-cli call --offer <addr>`
  (answerer).
- **Key log markers:** `home is now relay …` (endpoint bound), `Endpoint dropped
  … Aborting ungracefully` (endpoint torn down — should NOT happen mid-session),
  `SonarCall: SENT/RX control …`, `dropping control without …` (signaling drop).

---

## 12. Known issues & roadmap

1. **iOS background suspension (no CallKit).** iOS freezes/`signal 9`s a
   backgrounded app, so its endpoint dies and it can't ring an incoming call.
   Live calls currently require **both apps foreground**. Fix: **CallKit + VoIP
   PushKit** (CallKit for ring UI/audio session, a VoIP push to wake the callee).
2. **Internet signaling reliability.** The `☎CALL` OFFER rides Nostr relays whose
   subscriptions can time out, delaying/dropping delivery. Consider a dedicated
   reliable signaling subscription or retry/ack.
3. **`NSLocalNetworkUsageDescription` missing** from the iOS Info.plist — add for
   LAN/direct iroh connectivity (not a hard blocker; relay path works without it).
4. **iroh-roq vendored** against iroh 1.0 — track upstream for a 1.0 release.
5. **Manual accept loop** vs callme's iroh `Router`+`ProtocolHandler` — Sonar's
   manual loop adds id-pinning; a future cleanup could adopt the Router pattern.

---

## References
- n0 `callme` reference: https://github.com/n0-computer/callme
- iroh docs (Endpoints/discovery/relays): https://www.iroh.computer / https://docs.iroh.computer
- Code: `core/sonar-core/src/call/`, `core/sonar-ffi/src/lib.rs` (`call_session`),
  `ios/bitchat/Views/Sonar/SonarAppStore.swift`,
  `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/SonarAppState.kt`.
