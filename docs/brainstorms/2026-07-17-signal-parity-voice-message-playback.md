# Signal-parity voice-message playback

## Clarified Problem Statement

**Goal:** Replace Sonar's bubble-owned voice-note players with an app-scoped playback session that matches the observable behavior of Signal iOS and Android across Apple, Compose Android, and Compose desktop surfaces.

The user-visible bug is that scrolling the active voice message offscreen or focusing the composer can destroy its row, stop playback, and reset the playhead. The deeper gap is architectural: Sonar's UI rows currently own playback, while Signal's rows bind to a longer-lived player keyed by attachment identity.

### Constraints

- Match Signal behavior, not Signal source code. Signal is AGPL while Sonar is Unlicense; implementation must be original and use Signal only as an architectural/behavioral reference.
- Playback is app-scoped and keyed by a stable `(conversation, message, attachment)` identity. A cell/bubble may attach or detach without owning the player.
- A voice message continues through transcript scrolling/recycling, composer focus, keyboard changes, chat switching, app backgrounding, and screen lock. It stops only on explicit stop, natural completion, account wipe/sign-out, attachment deletion, unrecoverable failure, or platform audio policy.
- Support one active voice stream, pause/resume without losing position, waveform seeking while playing or paused, live elapsed/remaining duration, and cached playheads for previously paused attachments.
- Match Signal's playback-rate cycle: `0.5x -> 1x -> 1.5x -> 2x`; persist the selected rate per logical conversation, including mesh-folded conversations with multiple Marmot group IDs.
- Autoplay consecutive voice messages from a bounded local transcript window, with Signal-style transition/end feedback. It must not scan full history or wait on relay sync.
- Handle mobile audio focus, interruptions, headset removal, proximity-based speaker/earpiece routing, background audio, lock-screen controls, and media-session commands. Hardware-specific behavior is `N/A` on desktop, but play/pause/seek/rate/queue are not.
- Preserve Signal-comparable local-first performance: an already-local note starts without network work; chat first paint and scrolling do no decode, full-file read, or player allocation per row.
- Prefer file-backed playback from the existing private media cache. Do not duplicate decrypted media into long-lived public storage; clean temporary data on completion, stop, wipe, crash recovery, and process shutdown.
- Cover pure Marmot and mesh-folded conversations on every platform. Conversation IDs must pass through the repository's existing canonical/folded identity rules.
- Keep controls accessible and localizable. Play/pause, progress, speed, download, failure, and listened state must be exposed correctly to assistive technology.

### Non-goals

- Pixel-for-pixel cloning of Signal's UI.
- Copying or adapting AGPL implementation code.
- Changing voice recording, AAC encoding, attachment encryption, or transport wire formats.
- Reworking general media upload/download reliability tracked elsewhere.
- Restoring an actively playing session after force-quit or device reboot.
- Cross-device playhead or playback-rate handoff.

### Success criteria

- Scrolling the active row offscreen and back, recomposing/reloading the transcript, or typing in the composer never interrupts or resets playback.
- Switching conversations, backgrounding, and locking the screen preserve playback; in-app and system controls remain synchronized.
- Recreated rows immediately render the correct active item, play/pause state, playhead, waveform progress, duration, and rate.
- Pause/resume, scrubbing while paused/playing, completion reset, single-player arbitration, cached per-attachment progress, and the four playback rates behave like Signal.
- Consecutive locally available voice messages autoplay in chronological order from a bounded window without delaying chat paint.
- Incoming voice messages acquire the local listened/viewed state when playback actually starts, using existing receipt semantics where possible.
- Audio focus, calls, route changes, wired/Bluetooth disconnects, proximity routing, and remote media commands have deterministic tested behavior.
- Apple, Android, and Compose desktop ship together. Desktop hardware-only exceptions are documented; core playback controls are implemented, not deferred silently.
- Tests cover both pure Marmot and mesh-folded chats, row disposal/recreation, chat switching, app lifecycle, position/rate caching, autoplay boundaries, interruptions, deletion, errors, and cleanup.
- Chat-open/frame benchmarks show no regression and playback of local media performs no relay request or full-history scan.

## Approaches Considered

### Approach A: Native playback engines behind one behavior contract

- **Sketch:** Define the same state machine and commands on every surface (`idle/loading/playing/paused/ended/failed`, stable item ID, position, duration, rate, queue, interruption reason), but implement playback with the platform's native media stack. Apple owns one AVFoundation-backed service; Android owns one Media3 `MediaSessionService`; Compose desktop uses a bundled controllable decoder/output backend. UI bubbles only observe state and dispatch commands.
- **Affected Apple files/modules:** replace `SNAudioPlayer` in `ios/bitchat/Views/Sonar/SonarComponents.swift`; fold or retire `ios/bitchat/Features/voice/VoiceNotePlaybackController.swift`; rebind `ios/bitchat/Views/Media/VoiceNoteView.swift`; own/inject the session from `SonarAppStore.swift` or the app environment; add playback, route, remote-command, persistence, and lifecycle tests under `ios/bitchatTests/`.
- **Affected Compose files/modules:** replace the `AudioNotePlayer` expect/actual surface in `VoiceRecorder.kt`, `VoiceRecorder.android.kt`, and `VoiceRecorder.jvm.kt`; add a common observable playback model/controller; bind `AudioBubble` in `App.kt`; integrate ownership and bounded queue lookup with `SonarAppState.kt`; add Android Media3 service/session/notification and manifest/dependency entries; add a controllable desktop backend and common/platform tests.
- **Data-model seams:** pass stable message/attachment IDs and conversation IDs into both bubbles; preserve `durationMs` on the Apple `SNMediaItem` mapping; persist per-conversation rate separately from transient playhead cache; expose the existing local media URL/path directly to the player.
- **Tradeoffs:** Best match for OS audio behavior and Signal's architecture; easiest path to reliable lock-screen, audio-focus, and proximity support. It duplicates some orchestration code across Apple and Compose, so a written contract plus mirrored tests are required to prevent drift.
- **Effort:** L.

### Approach B: Rust core owns the cross-platform playback state machine

- **Sketch:** Put queue arbitration, progress/rate caches, logical conversation identity, and playback transitions in a new Rust core module. Native Apple/Android/desktop adapters execute media commands and report timing/interruption events through FFI.
- **Affected files/modules:** new core playback module plus `sonar-ffi`; generated Swift/Kotlin bindings; the same UI and native player files listed in Approach A; core state-machine tests in addition to platform integration tests.
- **Tradeoffs:** Gives the strongest semantic parity and one place for folded-chat queue rules. It substantially expands FFI surface area, couples a UI/media lifecycle to the messaging core, and still cannot centralize platform media sessions, proximity sensors, or lock-screen integration. More moving parts lie on a latency-sensitive path.
- **Effort:** L, with higher architectural risk than A.

### Approach C: Lift the existing players just above the rows

- **Sketch:** Move `SNAudioPlayer` and `AudioNotePlayer` into the current chat screen/store, remove row-disposal stop calls, and add basic position state. Keep AVAudioPlayer, Android MediaPlayer, and `afplay` otherwise intact.
- **Affected files/modules:** mostly `SonarComponents.swift`, `VoiceNotePlaybackController.swift`, `App.kt`, `SonarAppState.kt`, and the existing expect/actual player files.
- **Tradeoffs:** Fastest fix for scrolling/composer interruption and could be a temporary patch. It cannot honestly satisfy selected scope: raw `MediaPlayer`/`afplay` lack the required queue, rate, remote-control, and consistent lifecycle model; chat-scoped ownership also conflicts with continued playback after switching chats. It creates another migration before full parity.
- **Effort:** M, but incomplete for the stated goal.

## Recommendation

Choose **Approach A: Native playback engines behind one behavior contract**. It is closest to Signal's proven ownership model while preserving first-class OS behavior and keeping media execution out of the messaging core. Use a shared written state/command contract and mirrored scenario tests rather than trying to share player implementation code.

Deliver it in reviewable vertical slices under the same final acceptance gate: establish stable IDs and the app-scoped state contract first; then Apple and Compose/Android native engines; then desktop's controllable backend; finally autoplay, listened state, remote controls, lifecycle QA, and performance verification. Issue #320 remains open until all selected surfaces meet the criteria.

## Open questions

- Compose desktop needs a bundled, controllable AAC/M4A backend. A short spike should choose between a Rust `cpal` + decoder path (aligned with existing native audio work) and another redistributable backend; relying on a user-installed `ffplay`/VLC does not meet parity.
- Confirm whether system next/previous commands should traverse only consecutive voice notes in the originating conversation (recommended, matching the bounded queue) or may cross conversations.
- Sonar currently has conversation-level read state but no obvious cross-device voice-note listened receipt. The implementation should add local listened state and reuse existing receipts; a new wire-level listened event, if desired, should be separately specified rather than smuggled into playback work.

## Signal references

- iOS playback continuity and per-attachment cache: https://github.com/signalapp/Signal-iOS/blob/main/Signal/ConversationView/CVAudioPlayback.swift
- iOS waveform, scrubbing, and row binding: https://github.com/signalapp/Signal-iOS/blob/main/Signal/ConversationView/CellViews/AudioMessageView.swift
- iOS playback-rate behavior: https://github.com/signalapp/Signal-iOS/blob/main/Signal/ConversationView/CellViews/AudioMessagePlaybackRateView.swift
- Android lifecycle-aware controller: https://github.com/signalapp/Signal-Android/blob/main/app/src/main/java/org/thoughtcrime/securesms/components/voice/VoiceNoteMediaController.kt
- Android media session and consecutive playback: https://github.com/signalapp/Signal-Android/blob/main/app/src/main/java/org/thoughtcrime/securesms/components/voice/VoiceNotePlaybackService.java
- Android player and audio focus: https://github.com/signalapp/Signal-Android/blob/main/app/src/main/java/org/thoughtcrime/securesms/components/voice/VoiceNotePlayer.kt
