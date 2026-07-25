# Plan: Signal-parity voice-message playback

**Source:** [brainstorm](../brainstorms/2026-07-17-signal-parity-voice-message-playback.md) · [issue #320](https://github.com/hedwig-corp/bitchat-to-sonar/issues/320)

## Goal

Replace every bubble-owned voice-note player with one app-scoped playback session per app process, matching Signal iOS/Android behavior across native Apple, Compose Android, and Compose desktop: uninterrupted playback across row disposal, chat navigation, backgrounding, and lock screen; pause/resume/seek/rate/queue parity; native audio routing and system controls; bounded local-first autoplay; deterministic cleanup.

## Starting state

- The worktree is detached at `d0adfcd90`, two commits behind `origin/main`; both newer commits touch `App.kt`/`SonarComponents.swift`. After approval, create `codex/signal-voice-playback` from current `origin/main` rather than modifying the detached stale base.
- Preserve the untracked brainstorm and this plan when switching.
- The implementation targets `hedwig-corp/bitchat-to-sonar` and closes its issue #320. Although GitHub reports that repository as a historical fork of `vincenzopalazzo/bitchat`, the feature and issue belong to the current repository; the PR must target `hedwig-corp/bitchat-to-sonar:main`.

## Architecture contract

Implement the same observable contract on Apple and Compose, using original code and platform-native engines:

```text
VoicePlaybackItem
  logicalConversationId    canonical UI conversation / rate + queue scope
  sourceConversationId     exact group/mesh source used by local media
  messageId
  attachmentId             stable URL/path/index-derived identity
  localFile                 private already-local file only
  durationHint

VoicePlaybackState
  item?                     exactly one active item app-wide
  phase                     idle | loading | playing | paused | ended | failed
  position / duration
  rate                      0.5 | 1.0 | 1.5 | 2.0
  interruptionReason?
  generation                rejects stale callbacks

VoicePlaybackCommands
  play(item) | pause | resume | seek | cycleRate | next | previous | stop(reason)
```

- The app-scoped controller serializes every command/callback (`@MainActor` on Apple; a single coroutine dispatcher/mutex reducer on Compose).
- Every load carries a generation token. Completion, timers, route notifications, service callbacks, deletion, or wipe from an older generation cannot mutate a newer item.
- Rows only observe state and send commands. Disappearance/disposal detaches observation and never stops playback.
- Calls preempt voice playback; starting voice recording pauses playback before taking the audio session. Automatic resume occurs only for a transient system interruption when the item was previously playing, never after a user pause, call, recording, deletion, or wipe.
- Queue/rate scope is the canonical logical conversation. Decryption and deletion retain the exact source conversation/group.
- System next/previous remains inside the originating logical conversation and never crosses chats.
- Until the wire format distinguishes generic audio from a recorded voice note, retain Sonar's current `audio/*` rendering heuristic; autoplay only items rendered by the voice-message bubble.

## Affected files

### Shared documentation and localization

- `docs/brainstorms/2026-07-17-signal-parity-voice-message-playback.md` — clarified behavioral scope.
- `docs/plans/2026-07-18-signal-parity-voice-message-playback.md` — implementation and verification plan.
- `ios/bitchat/Localizable.xcstrings` — accessibility labels/actions and recoverable playback errors; regenerate Compose resources with `scripts/i18n/xcstrings_to_compose.py`.
- `docs/REGRESSIONS.md` — add an invariant only if history confirms this is a recurring fix; otherwise disclose the new guards without forcing a ledger entry.

### Native Apple

- `ios/bitchat/Features/voice/VoiceNotePlaybackController.swift` — replace row-scoped behavior with the app-scoped playback state machine, injected engine/clock/preferences/queue/listened seams, AVFoundation file playback, bounded progress cache, rate persistence, generation safety, interruptions, route changes, proximity, Now Playing, and remote commands.
- `ios/bitchat/Views/Sonar/SonarAppStore.swift` — own/expose the controller, build stable playback items from canonical/folded identities, carry `durationMs` into `SNMediaItem`, expose existing private `localURL`, provide a bounded successor/predecessor list, and stop/clear playback on deletion/wipe.
- `ios/bitchat/Views/Sonar/SonarComponents.swift` — remove `SNAudioPlayer`; make `SNAudioBubble` an observer/controller, add interactive waveform progress, elapsed/remaining time, speed control, listened indicator, and accessibility actions without full-file `Data` loading.
- `ios/bitchat/Views/Media/VoiceNoteView.swift` — migrate the legacy voice bubble to the same app-scoped session and remove `onDisappear { stop() }`.
- `ios/bitchat/BitchatApp.swift`, `ios/bitchat/Views/Sonar/SonarRootView.swift`, and legacy root injection points as needed — ensure one owner survives navigation/backgrounding and both Apple bubble paths share it.
- `ios/bitchat/Services/VoiceNoteRecorder.swift` and call-audio ownership in `SonarAppStore.swift` — explicit playback/call/record arbitration rather than competing `AVAudioSession` mutations.
- `ios/bitchatTests/VoiceMessagePlaybackControllerTests.swift` (new) — fake-engine state-machine and queue scenarios.
- Existing Apple transcript/projection tests — add pure Marmot and mesh-folded item identity/ordering coverage at the real mapping call sites.

### Compose common

- `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/VoiceMessagePlayback.kt` (new) — shared item/state/commands, reducer/controller, engine/clock/preferences/queue/listened interfaces, bounded LRU playheads, generation safety, and deterministic lifecycle policy.
- `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/VoiceRecorder.kt` — keep recording responsibilities; replace the destructive `AudioNotePlayer` API with the controllable playback engine contract.
- `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/SonarAppState.kt` — own the controller, canonicalize conversation identity with `transcriptGroupIds`, project bounded local queue candidates across folded sources, expose private local paths, persist per-conversation rates, mark listened state, and integrate delete/wipe/call/record arbitration.
- `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/App.kt` — make `AudioBubble` observe global playback state; remove row-local `playing` and disposal stop; add seek/progress/rate/listened/accessibility behavior; never call `mediaData()` for playback.
- `apps/sonar/composeApp/src/commonTest/kotlin/chat/bitchat/sonar/VoiceMessagePlaybackControllerTest.kt` (new) — pure mirrored state-machine scenarios.
- `apps/sonar/composeApp/src/jvmTest/kotlin/chat/bitchat/sonar/VoiceMessagePlaybackUiTest.kt` (new) — compose/dispose/recreate a real bubble and prove it never stops the session.

### Android

- `apps/sonar/gradle/libs.versions.toml` and `composeApp/build.gradle.kts` — pin Media3 session/player dependencies.
- `apps/sonar/composeApp/src/androidMain/AndroidManifest.xml` — media-playback foreground-service permissions, service declaration/type, and media-session receiver requirements.
- `apps/sonar/composeApp/src/androidMain/kotlin/chat/bitchat/sonar/VoiceMessagePlayback.android.kt` (new/replaces player portion of `VoiceRecorder.android.kt`) — Media3 controller/engine adapter, audio focus/noisy route policy, and state bridge.
- `apps/sonar/composeApp/src/androidMain/kotlin/chat/bitchat/sonar/VoiceMessagePlaybackService.kt` (new) — `MediaSessionService` + ExoPlayer, notification/system commands, background/lock-screen ownership, queue commands, privacy-safe metadata, and teardown.
- Existing `CallAudioRoute.android.kt` and app lifecycle — coordinate proximity and call priority; never leave `MODE_IN_COMMUNICATION` or a proximity wake lock held after pause/end/error.
- Add an Android test source set for reducer/service command integration where it can run without real hardware; keep focus/proximity/route behavior in a manual device matrix if instrumentation is unavailable in CI.

### Compose desktop

- `apps/sonar/composeApp/src/jvmMain/kotlin/chat/bitchat/sonar/VoiceMessagePlayback.jvm.kt` (new/replaces `AudioNotePlayer` in `VoiceRecorder.jvm.kt`) — bundled controllable M4A/AAC engine with play/pause/seek/rate/queue/progress and no user-installed executable dependency.
- `apps/sonar/composeApp/src/jvmMain/kotlin/chat/bitchat/sonar/Main.kt` — retain startup orphan cleanup only if the selected backend still creates temporary material; otherwise remove the obsolete `afplay` sweep.
- Desktop packaging/dependency files selected by the backend spike.
- Add a short redistributable AAC fixture and JVM engine tests that execute play/pause/seek/rate/error/cleanup on CI-supported hosts.

## Implementation sequence

### 1. Dependency and desktop feasibility gate

1. Validate a bundled controllable AAC/M4A backend on the repository's Java 17/DMG/MSI/Deb packaging model. First candidate: OpenJFX Media with host-classified native artifacts; fallback: a narrowly scoped Rust decoder/output feature using the existing native-library packaging seam.
2. The gate must prove local file open, pause/resume, seek, dynamic rates, progress callbacks, end/error callbacks, Linux CI startup, and acceptable redistributable licensing.
3. Reject any design that requires user-installed `ffplay`, VLC, GStreamer packages, or a GPL binary. Do not proceed with an `afplay`-only gap.

### 2. Pure contract, identity, and tests first

1. Land mirrored Apple/Compose item keys, phases, commands, reducer rules, fake clocks/engines, generation checks, LRU playheads, and rate stores.
2. Add test vectors before UI migration: user pause vs transient interruption, stale callback, switching items, completion reset, seek/rate, call/record preemption, missing/deleted file, wipe, listened-on-first-play, queue next/previous, and bounded-end behavior.
3. Define one stable item-key builder per platform using canonical logical conversation + exact source + message ID + attachment ordinal/key. Handle empty mesh URLs and optimistic-to-canonical URL changes without filename-only identity.

### 3. File-backed Apple migration

1. Use the existing protected private cache URL directly. Older media with no duration hint probes metadata off-main once.
2. Implement AVFoundation playback with pitch-preserving rates, 50–100 ms UI progress updates only while observed/playing, interruption/route notifications, headset-noisy pause, call/record arbitration, and proximity route changes without resetting the playhead.
3. Register `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`; use privacy-safe title metadata and clear it on stop/delete/wipe.
4. Migrate `SNAudioBubble` and legacy `VoiceNoteView`; no Apple row owns an engine or stops on disappearance.

### 4. Compose controller and Android Media3 migration

1. Move common state ownership into the app-scoped `SonarAppState` lifetime while keeping Android's actual engine/session owned by the service, not the Activity/composable.
2. Play `MediaTransferState.localPath` directly; row composition may prepare/probe transfer state but never read the whole file or start network for playback.
3. Add Media3 session/service notification, audio focus, noisy route, foreground-service lifecycle, privacy-safe metadata, system commands, and Activity recreation/rebind handling.
4. Coordinate voice calls/recording and proximity. Calls always win; user-paused content never auto-resumes.

### 5. Compose desktop engine

1. Implement the backend chosen in gate 1 behind the same common engine contract.
2. Package all runtime/native components for current desktop targets, preserve private file-backed playback, and retain generation-safe cleanup.
3. Run the AAC fixture through the real packaged/runtime path on macOS and Linux CI; document Windows packaging evidence or the exact manual verification performed.

### 6. Fold-aware queue, preferences, listened state, and UI polish

1. Build next/previous from the already-published bounded local transcript projection, merged by `(timestamp, source, messageId, attachmentIndex)` and restricted to the originating logical conversation. Never call relay sync or scan full history.
2. If the next voice item is not local, stop cleanly with end feedback; autoplay does not block on a download. A future background-prefetch policy can be independent.
3. Persist only rate and bounded local listened metadata using Apple app-local preferences and Compose's existing `loadBlob/saveBlob` seam; transient playheads remain memory-only. Clear account/chat-scoped state on wipe/deletion and migrate fold aliases.
4. Add interactive progress over the existing waveform visual, elapsed/remaining labels, rate cycle, played indicator, localized errors, and accessibility custom actions. Functional parity is required; pixel copying is not.

### 7. Deletion, cleanup, observability, and performance

1. Stop/invalidate the session generation before deleting an active file. Integrate account wipe, erase-all, per-chat deletion, attachment deletion, and process shutdown on both stacks.
2. Avoid secondary decrypted copies. If the desktop backend requires temp material, use restrictive generation-scoped files, teardown on every path, and startup orphan sweep.
3. Log bounded state transitions, reason, route/focus changes, local-open latency, autoplay decisions, engine failures, and cleanup failures using hashed item IDs. Never log raw paths/URLs, conversation IDs, names, bytes, or secrets.
4. Add a debug-only local tap-to-first-audio marker without adding work to chat first paint.

## Edge cases and failure policy

- Pure Marmot, mesh-only, and mesh-folded chats with duplicate Marmot groups.
- Empty mesh URL, shared filenames, shared Blossom URLs, optimistic media reconciliation, and multiple audio attachments in one message.
- Row disposal/recreation and chat switch while loading, playing, paused, or seeking.
- A newer item starting while an old duration probe/completion/timer/service callback is in flight.
- Message/attachment/chat deletion or account wipe during load/play; cache cleanup must not delete a blob still referenced elsewhere.
- App background/foreground, screen lock, Android Activity/service recreation, Apple route/interruption notification ordering.
- Incoming phone/voice call, outgoing call, microphone recording, permanent/transient audio focus loss, headset/Bluetooth disconnect, proximity near/far, and speaker toggle.
- Rate change while paused/playing, seek near completion, corrupt/zero-duration media, unsupported codec, missing local file, and player initialization failure.
- Autoplay at a bounded window edge, newly arriving/deleted/reconciled messages, unavailable next local file, and no crossing into another conversation.
- Privacy settings on lock-screen metadata and foreground notifications.
- Older records with nil duration and no new wire-format assumptions.

## Test plan

### Automated

- Compose reducer/common tests for every state/identity/queue/interruption scenario above.
- Compose UI test that disposes/recreates `AudioBubble` and focuses a text field without issuing stop or losing playhead state.
- JVM engine test using a short checked-in AAC fixture, including cleanup and failure paths.
- Android compile plus service/session command tests where host/instrumented tooling permits.
- Mirrored Swift tests with fake engine/clock/preferences/queue/listened adapters and real mapping tests for pure Marmot + mesh-folded conversations.
- Existing media, transcript, call-route, wipe, and regression suites remain green.

### Local commands

```bash
scripts/check-regression-ledger.sh
python3 scripts/i18n/xcstrings_to_compose.py --check
cd apps/sonar && SONAR_SKIP_BLE=1 ./gradlew :composeApp:jvmTest --console=plain
cd apps/sonar && ./gradlew :composeApp:compileKotlinMetadata :composeApp:compileKotlinJvm
cd apps/sonar && ./gradlew :composeApp:assembleDebug
cd core && cargo test --workspace
xcodebuild -project ios/bitchat.xcodeproj -scheme 'bitchat (macOS)' -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ios/bitchat.xcodeproj -scheme 'bitchat (iOS)' -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Run targeted iOS tests on an available simulator. iOS tests are not currently executed by repository CI, so the PR must disclose the exact local destination/result.

### Manual/device matrix

- Incoming/outgoing, short/long, mesh and Marmot notes.
- Rapid scroll offscreen/back, composer typing/keyboard, switch chat, background, screen lock.
- Pause/resume/seek/rate/next/previous from bubble, notification, and lock screen.
- Wired and Bluetooth attach/detach; speaker/earpiece and proximity; incoming/outgoing calls; record a new note while one plays.
- Delete active message/chat, erase all chats, panic wipe, corrupt/missing media, process kill/relaunch cleanup.
- Native Apple iOS/macOS, Android API 26 and current API, Compose desktop macOS/Linux/Windows packaging as available.

### Performance

- Compare existing Android chat-open frame benchmark before/after on the same device when available.
- Confirm an already-local play command performs no relay request, no full-history query, no full-file reactive-state read, and no per-row player allocation.
- Report local tap-to-first-audio timing and disclose any device/platform benchmark not available locally.

## Conventions and safeguards

- Read and obey `docs/CHAT-TYPES.md`, `docs/REGRESSIONS.md`, and `docs/PERFORMANCE.md` throughout; test both chat kinds and real call sites.
- Use `SecureLogger` category `.session` on Apple and `sonarLog` on Compose; redact private identifiers.
- `Localizable.xcstrings` is the localization source of truth; regenerate all Compose locales and run the sync check.
- Do not commit `Local.xcconfig`, Breez/Firebase/signing secrets, generated native libraries, or generated UniFFI Kotlin artifacts.
- Signal source is an AGPL behavioral reference only. The PR describes patterns adopted/deferred and contains no adapted code.
- Preserve current wire formats, recording/encoding, encrypted-media handling, and local-first chat startup.

## Review and PR

1. Review the complete diff for lifecycle races, stale callbacks, cache/file ownership, logging privacy, dependency licenses, packaging, first-frame work, and both platform mirrors.
2. Re-run verification after every review fix.
3. Stage only intentional source/docs/test/resource files.
4. Conventional commit: `feat(voice): add Signal-parity playback`, with `Fixes #320` in the body.
5. Push `codex/signal-voice-playback` and open a PR against `hedwig-corp/bitchat-to-sonar:main` with Summary, Signal patterns adopted, cross-platform coverage, test/performance evidence, manual gaps, dependency/license notes, and `Fixes #320`.
6. Monitor GitHub Actions until all registered checks are green; fix change-related failures and re-review before pushing follow-up commits.

## Open risks

- **Desktop backend is the release gate.** The selected dependency must actually decode Sonar AAC/M4A, support dynamic rate/seek, work from private local files, bundle cleanly for DMG/MSI/Deb, and have acceptable licensing. No external executable fallback.
- **Device-only audio behavior cannot be proven by unit tests.** Proximity, Bluetooth routes, calls, background/lock screen, and Android foreground-service behavior require explicit device evidence; unavailable combinations must be disclosed, not claimed.
- **Listened status has no dedicated cross-device protocol.** This plan implements bounded local listened state and reuses existing receipt semantics; it does not invent a wire event.
- **File protection vs lock-screen playback:** Apple cache protection must allow the already-open item to continue while locked without weakening unrelated media. Validate on device.
- **Scope is large:** expect well over 200 LOC across Swift, Kotlin, Android service/config, desktop backend, localization, and tests. The PR is not complete while either Apple bubble remains row-owned or Compose desktop remains `afplay`-only.

**Estimated size:** L (>200 LOC; multi-platform architectural change).
