# Telegram-style video notes: implementation plan

Date: 2026-07-18

Source brainstorm:
`docs/brainstorms/2026-07-18-telegram-style-video-notes.md`

## Outcome

Ship circular, short video notes in direct and group chats. Mobile users record
with the composer’s Telegram-style hold/cancel/lock interaction; Sonar preserves
the video-note role through local persistence, White Noise/Marmot, and BLE mesh.
The payload is a regular H.264/AAC MP4 so clients that ignore Sonar metadata can
still play it as an ordinary video.

## Documented v1 platform gaps

- iOS and Android record video notes. macOS and Compose Desktop receive them
  with the same persisted role and circular/native-open fallback, but do not
  capture because their camera/session implementations are not yet present.
  Follow-up path: add desktop recorder actuals and permission UX in a dedicated
  cross-desktop capture change without weakening the mobile lifecycle checks.
- Internet notes cap at 60 seconds. BLE mesh notes conservatively cap at 30
  seconds with low-bitrate capture to remain inside the existing 1 MiB packet
  ceiling. Follow-up path: tune bitrate and the early cutoff from physical-device
  evidence before increasing the mesh duration.

## Invariants

1. Apple and Compose implementations ship together.
2. Existing chats paint from bounded local rows. Camera setup, relay sync,
   Blossom download, video decode, and history scans never gate first paint.
3. Existing ordinary video attachments keep their rectangular/file behavior.
4. Existing mesh file packets encode byte-for-byte unchanged when no media role
   is present; old decoders skip the new optional TLV.
5. Video-note cleartext remains file-backed until the existing media send API
   boundary, and every cancel/failure/background/wipe path cleans owned files.
6. Marmot notes remain under 25 MiB; mesh notes remain under 1 MiB. Recording
   never exceeds 60 seconds.

## Slice 1 — Core media-role contract

- Add a small `MediaRole` enum (`standard`, `video_note`) to the Rust media
  reference and FFI record. Unknown wire values map to `standard`.
- Add a versioned encrypted rumor tag for a single video-note attachment. The
  `imeta` remains standard MIP-04; the role tag only controls presentation.
- Add a dedicated `send_video_note` core/FFI entry so ordinary `send_media` and
  album callers cannot accidentally acquire video-note semantics.
- Parse the role while mapping stored messages, before rows cross FFI, and
  persist it in each host’s local transcript/cache envelope.
- Extend the mesh `FilePacket` with optional media role TLV `0x05`. Preserve the
  exact legacy byte vector when the field is absent, and skip unknown roles.
- Thread the optional role through `MeshEngine::send_file`, `FileReceived`, FFI,
  and the Apple/Compose mesh bridges.

Primary files:

- `core/sonar-core/src/marmot.rs`
- `core/sonar-core/src/client.rs`
- `core/sonar-core/src/mesh.rs`
- `core/sonar-core/src/mesh_engine.rs`
- `core/sonar-core/tests/bitchat_interop.rs`
- `core/sonar-ffi/src/lib.rs`
- generated Swift/Kotlin UniFFI bindings

Tests:

- Marmot standard media and video-note tag round trips.
- Unknown/malformed role tags remain ordinary media.
- Mesh legacy encoding stays byte-for-byte identical.
- Mesh role TLV round trips and old/unknown TLVs remain tolerated.
- FFI mapping exposes the role without changing ordinary attachments.

## Slice 2 — Shared host models and send routing

- Add `videoNote`/`VideoNote` to `SNMediaItem` and `SonarMedia` without inferring
  from dimensions or filenames.
- Preserve the role in pending upload echoes, canonical reconciliation, Compose
  `MessageStore`, mesh media ingestion, chat-list previews, and retry state.
- Add `sendVideoNote` to `MarmotService`, `SonarAppStore`, `SonarCore`, and
  `SonarAppState`.
- Direct and group routes use the same role. Mesh sends only validated clips at
  or below 1 MiB; otherwise the UI must surface the route/size outcome rather
  than silently relabeling it.
- Derive/store 1:1 dimensions and duration at capture/ingestion so the transcript
  reserves a fixed circular cell before decode.

Primary files:

- `ios/bitchat/Services/MarmotService.swift`
- `ios/bitchat/Views/Sonar/SonarAppStore.swift`
- `apps/sonar/composeApp/src/commonMain/.../SonarCore.kt`
- `apps/sonar/composeApp/src/commonMain/.../SonarAppState.kt`
- `apps/sonar/composeApp/src/commonMain/.../store/MessageStore.kt`
- Android/JVM `SonarCore` and `MeshRadio` actuals

Tests:

- Host mapping and persistence retain `video_note` across restart.
- Pending/canonical media reconciliation keeps the role.
- Pure Marmot and mesh-folded chat rows produce one correctly typed attachment.

## Slice 3 — iOS capture and composer UX

- Implement an iOS-only, file-backed `VideoNoteRecorder` around
  `AVCaptureSession` + `AVAssetWriter`/movie output. Request camera and microphone
  together; prefer the front wide-angle camera and fall back to any available
  camera.
- Capture a square H.264/AAC MP4, enforce the 60-second ceiling, expose elapsed
  time/level/preview session, and support safe camera flipping.
- Extend `SNComposer` with a voice/video mode toggle while keeping the gesture
  host mounted. Reuse voice-note drag semantics for hold, slide-left cancel, and
  swipe-up lock. Locked state exposes stop/cancel/send controls.
- Select an internet profile for Marmot and a low-bitrate mesh profile before
  capture. Stop early when the mesh byte budget is reached.
- Clean up recorder/session/temp files on cancel, permission denial, failed
  writer finalization, navigation exit, app backgrounding, send completion, and
  wipe.

Primary files:

- new `ios/bitchat/Services/VideoNoteRecorder.swift`
- `ios/bitchat/Views/Sonar/SonarDMScreen.swift`
- `ios/bitchat/Views/Sonar/SonarComponents.swift`
- `ios/bitchat/Views/Sonar/SonarAppStore.swift`
- iOS recorder/state tests

## Slice 4 — Android capture and composer UX

- Add AndroidX CameraX video/view/lifecycle dependencies and Media3 ExoPlayer.
- Implement `VideoNoteRecorder` as an expect/actual contract. Android owns a
  cache MP4, CameraX preview/video capture, camera selector, audio permission,
  recording finalization, size/time cutoff, and cleanup.
- Add camera permission to the manifest and shared runtime permission request.
- Extend the existing Compose composer gesture state with the same mode,
  hold/cancel/lock/flip behavior as iOS; keep the recording gesture node mounted
  across state transitions.
- Provide a deterministic JVM actual that cannot record but keeps desktop
  compilation and receive behavior explicit.

Primary files:

- `apps/sonar/gradle/libs.versions.toml`
- `apps/sonar/composeApp/build.gradle.kts`
- `apps/sonar/composeApp/src/androidMain/AndroidManifest.xml`
- `MainActivity.kt`
- new common/Android/JVM `VideoNoteRecorder` files
- `apps/sonar/composeApp/src/commonMain/.../App.kt`

## Slice 5 — Circular bounded playback

- Render a fixed circular cell from stored role/dimensions before bytes arrive.
- Auto-prepare only visible video notes. Remote notes show a poster/download
  affordance until local; normal chat opening does no video work.
- iOS/macOS use a scoped `AVPlayer` surface. Android uses one lifecycle-aware
  Media3 player per active note. A playback coordinator guarantees only one
  audible note at a time.
- Default autoplay is muted; tap toggles play/sound, progress ring follows the
  current item, and offscreen/background items pause and release resources.
- Compose Desktop uses the circular poster/tap fallback and opens the validated
  local MP4 with the existing native file handler when inline playback is not
  available. This is the documented desktop fallback, not a silent ordinary
  file bubble.
- Respect reduced motion/autoplay limitations and retain native/fullscreen open
  as an accessible fallback.

Primary files:

- `ios/bitchat/Views/Sonar/SonarComponents.swift`
- new Apple video-note player helper if separation improves lifecycle ownership
- `apps/sonar/composeApp/src/commonMain/.../App.kt`
- Android/JVM media UI actuals
- UI/state tests for role dispatch, bounded preparation, and player arbitration

## Slice 6 — Verification and product-quality pass

Run targeted checks after each slice, then the full relevant matrix:

```text
cd core && cargo fmt --check
cd core && cargo test -p sonar-core
cd core && cargo test -p sonar-ffi
cd core && cargo test --workspace
./scripts/check-regression-ledger.sh
cd apps/sonar && ./gradlew :composeApp:jvmTest --console=plain
cd apps/sonar && ./gradlew :composeApp:compileKotlinMetadata
cd apps/sonar && ./gradlew :composeApp:compileKotlinJvm
xcodebuild -project ios/bitchat.xcodeproj -scheme "bitchat (macOS)" -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ios/bitchat.xcodeproj -scheme "bitchat (iOS)" -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

Also verify on physical iOS and Android devices when available:

- camera/microphone permission denial and recovery;
- front/back camera availability and flip;
- hold, slide-cancel, lock, stop/send, and automatic 60-second stop;
- background/foreground and incoming-call/audio-focus interruption;
- Marmot and mesh sends at/near size limits;
- direct, group, pure Marmot, and mesh-folded chats;
- muted visibility autoplay, tap-to-sound, single-audible-player behavior;
- restart/wipe cleanup and local-first chat-open stability.

## Review and delivery

1. Run two clean production-safety passes over every changed file, focusing on
   cleartext cleanup, permission/session races, mesh compatibility, bounded
   transcript work, and Apple/Compose parity.
2. Commit only the feature, tests, generated bindings, brainstorm, and this plan.
3. Push `codex/telegram-video-notes` and open a PR with adopted Signal patterns,
   the desktop fallback, mesh quality tradeoff, and full test evidence.
4. Run a formal `review-pr --self-review`; fix every actionable finding before
   declaring the review clean.
5. Monitor CI to green, then run `review-feedback` against all pending review
   threads, push fixes, reply with commit references, resolve addressed threads,
   and request re-review where needed.

## Main risks and containment

- **Mesh bitrate/quality:** enforce the byte ceiling during capture and tune on
  devices; never upload an unplayable or oversized note.
- **Player/resource leaks:** player and capture ownership follows view visibility
  and lifecycle; tests pin stop/release transitions.
- **Protocol drift:** optional/versioned metadata only; legacy byte-vector and
  unknown-field tests are blocking.
- **Transcript regressions:** role is mapped once from local stored metadata;
  rendering never scans messages or decodes video to classify it.
- **Generated binding churn:** regenerate from the Rust definition and review the
  generated diff separately from handwritten behavior.
