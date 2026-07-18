# Brainstorm: Telegram-style video notes

Date: 2026-07-18. Status: clarified, ready for `/ship --plan-only`.

## Clarified Problem Statement

**Goal:** Let Sonar users record, send, receive, and play short circular video
notes in direct and group chats with Telegram-like speed and gestures, while
preserving ordinary-video compatibility with other White Noise clients.

### Product decisions

- Ship in direct messages and group chats.
- Record on iOS and Android. Every supported Apple and Compose surface must be
  able to receive and play a video note; desktop camera capture is a documented
  v1 platform gap rather than a silent omission.
- The composer toggles between voice-note and video-note modes. Video recording
  uses the front camera by default and supports camera flip, hold to record,
  release to send, slide left to cancel, and swipe up to lock.
- Recording stops at 60 seconds. An unlocked recording sends on release. A
  locked recording exposes stop/cancel/send controls without requiring the
  finger to remain down.
- Playback uses a circular bubble with a progress ring. A downloaded note
  autoplays muted while sufficiently visible; tap toggles sound/playback. A
  poster remains when paused, offscreen, not downloaded, autoplay is disallowed,
  or the platform requests reduced motion/data use. Only one note may play
  audibly at a time.
- Support White Noise/Marmot and BLE mesh. Marmot keeps the full 60-second limit.
  Mesh encoding targets the existing 1 MiB payload ceiling by lowering square
  resolution, frame rate, and bitrate; if the budget cannot hold 60 seconds,
  recording stops early with the remaining limit visible in the UI.
- The payload remains a normal MP4 (H.264 + AAC). Other White Noise clients can
  render it as an ordinary playable video; Sonar-specific encrypted metadata
  selects the circular video-note presentation.

### Constraints

- Implement the feature together in `ios/` and `apps/sonar/`, with matching
  message semantics and observable behavior.
- Preserve Signal-style local-first transcript performance. Chat opening must
  render from bounded local rows and stored media metadata; it must never wait
  for camera setup, Blossom download, video decode, relay sync, or a transcript
  scan. Download and decode only visible/bounded notes in the background.
- Store a first-class media presentation role such as `video_note`; do not infer
  the role from dimensions alone. Persist it through the Rust message model,
  FFI models, platform transcript caches, pending send echoes, and both chat
  kinds (pure Marmot and mesh-folded).
- For Marmot, carry the role in a versioned custom tag inside the encrypted
  kind-9 rumor next to its MIP-04 `imeta`. Unknown clients ignore the tag and
  retain the standard MP4 attachment.
- For mesh, add an optional forward-compatible media-role TLV to
  `BitchatFilePacket`/`FilePacket`. Existing packets encode byte-for-byte as
  before when the role is absent; older clients skip the unknown TLV and receive
  a normal file/video.
- Capture and transcoding are file-backed. Do not retain a full 60-second video
  in SwiftUI/Compose reactive state or copy it repeatedly across FFI. Finalize
  and enforce size only on send, and remove temporary files on cancel, failed
  permission, background interruption, navigation exit, send failure, wipe,
  and successful ownership transfer.
- Derive and persist square dimensions, duration, and a poster/placeholder at
  ingestion so circular cells never reflow the transcript after decoding.
- Respect camera and microphone permission denial, OS autoplay/reduced-motion
  policy, audio focus/session ownership, app backgrounding, and camera/mic
  interruption.
- Keep current encrypted-media limits: 25 MiB aggregate receiver ceiling for
  Marmot and 1 MiB payload ceiling for mesh. Never silently reroute an oversized
  mesh note without showing the resulting transport behavior.

### Non-goals

- Stories, status videos, live streaming, video calls, filters, beauty effects,
  AR overlays, editing, captions, or gallery-imported videos masquerading as
  video notes.
- Changing the rectangular presentation or send workflow of ordinary video
  attachments.
- Requiring non-Sonar White Noise or stock bitchat clients to display a circular
  bubble; their supported fallback is an ordinary playable video/file.
- Desktop camera recording in v1. Desktop receive/play is required, and the
  capture gap needs an explicit follow-up path.
- Guaranteeing a full 60 seconds over BLE when the encoded clip cannot fit the
  existing 1 MiB protocol limit.

### Success criteria

- On iOS and Android, users can toggle to video mode, record with the specified
  hold/cancel/lock/flip gestures, and never produce a clip longer than 60 seconds.
- Direct and group sends paint an immediate local circular echo, survive restart,
  reconcile with the canonical row, and remain circular without waiting on relay
  sync or scanning history.
- Marmot video notes stay below 25 MiB. Mesh video notes stay at or below 1 MiB,
  adapt quality predictably, and show an early cutoff rather than failing after
  capture.
- Sonar recipients on Apple and Compose render the role consistently. A client
  that ignores Sonar metadata still receives a valid MP4 or mesh file.
- Visible downloaded notes autoplay muted, poster fallback works, tapping manages
  sound/playback, the progress ring advances, and audio focus allows only one
  audible note at once.
- Cancel, permission denial, camera interruption, backgrounding, failed encode,
  failed upload, and wipe leave no owned temporary cleartext video behind.
- Tests cover metadata round trips through Marmot and mesh, unknown-tag/TLV
  tolerance, MIME fallback, duration/size enforcement, pending-echo reconciliation,
  both chat kinds, bounded local first paint, and recorder state transitions on
  both mobile implementations.

## Approaches Considered

### Approach A: Convention-only MP4

- **Sketch:** Name captures with a reserved prefix such as `vn-video-*` and let
  each shell infer the circular role from filename, square dimensions, and MIME.
  The core and wire formats remain unchanged.
- **Affected files:** `ios/bitchat/Services/` (new recorder),
  `SonarDMScreen.swift`, `SonarComponents.swift`, `SonarAppStore.swift`;
  Compose `App.kt`, `SonarAppState.kt`, new Android recorder/player actuals.
- **Tradeoffs:** Fastest path and maximum old-client compatibility, but filenames
  are user-controlled, imports can be misclassified, semantic state can disappear
  during sanitization, and every shell must repeat the heuristic. It creates a
  fragile seam for caching, forwarding, and future media roles.
- **Effort:** M.

### Approach B: Explicit encrypted media role

- **Sketch:** Add a versioned `video_note` media role to core models. Marmot
  writes it as a custom tag inside the encrypted rumor alongside `imeta`; mesh
  writes an optional role TLV that old decoders skip. The hosts render the
  first-class role and keep the underlying attachment as a normal MP4.
- **Affected files:** `core/sonar-core/src/marmot.rs`, `client.rs`, `mesh.rs`,
  `mesh_engine.rs`; `core/sonar-ffi/src/lib.rs` and generated host bindings;
  `ios/bitchat/Services/VoiceNoteRecorder.swift` or a sibling video recorder,
  `Views/Sonar/SonarDMScreen.swift`, `SonarComponents.swift`,
  `SonarAppStore.swift`, `Protocols/BitchatFilePacket.swift`; Compose
  `VoiceRecorder.kt` or a sibling `VideoNoteRecorder`, Android actuals,
  `App.kt`, `SonarCore.kt`, `SonarAppState.kt`, `MessageStore.kt`, and
  `MeshRadio` bridges.
- **Tradeoffs:** Robust classification, one semantic contract across transports,
  safe fallback for older clients, and an extensible seam for future media roles.
  It touches the core, FFI, mesh interop tests, persistence, and both UIs; capture,
  encoding, and playback remain substantial native work.
- **Effort:** L.

### Approach C: Upstream protocol extension first

- **Sketch:** Define a general MIP-04 attachment-role extension with MDK/White
  Noise and a corresponding bitchat file metadata extension, land those upstream,
  then consume the standardized role in Sonar.
- **Affected files:** The same Sonar surfaces as Approach B plus upstream MDK,
  White Noise, and bitchat protocol/spec repositories and dependency revisions.
- **Tradeoffs:** Best route to circular rendering across ecosystems and avoids a
  Sonar-specific convention. It depends on external design and release cycles,
  delays the feature, and still requires all native capture/playback work.
- **Effort:** L+, with external coordination.

## Recommendation

Choose **Approach B: Explicit encrypted media role**. It preserves the user's
compatibility requirement because the blob remains an ordinary MP4, while giving
Sonar a durable, locally persisted semantic that works across Marmot, BLE mesh,
restart, forwarding, and both UIs. Approach A is tempting but would reproduce
classification logic in Swift and Kotlin and eventually require a migration;
Approach C is worth proposing upstream after Sonar has a working versioned field.

Implement it in vertical slices: first the core role and round-trip tests; then
file-backed capture/encoding and send on iOS and Android; then circular bounded
playback on all surfaces; finally mesh quality tuning and physical-device gesture,
size, thermal, and interruption tests.

## Open questions / follow-ups

- Tune the mesh encoder on real low/mid-range devices. Start with a 240×240,
  12–15 fps H.264/AAC profile and make the actual bitrate/cutoff evidence-driven.
- Decide whether locked recording's stop action opens a short review state or
  keeps Telegram's fastest send behavior; unlocked release always sends.
- Define the desktop capture follow-up separately after desktop receive/play is
  complete; it must not block the mobile feature.
- Consider proposing the versioned attachment-role field upstream once its Sonar
  behavior and unknown-client fallback have shipped and been exercised.
