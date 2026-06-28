## Clarified Problem Statement

**Goal:** make existing Sonar notifications useful at a glance by showing the sender/group and payment amount while keeping provider pushes plaintext-free.

**Chosen approach:** Approach C, a core-owned notification envelope.

## Scope

- Existing local and remote notification types keep using the same app delivery paths.
- The Rust core owns notification kind classification, payment amount parsing, amount formatting, and title/body copy.
- Apple and Compose hosts pass only local context into the core renderer: sender label, group label, content preview, unread count, and preference flags.
- Sender/group names are visible by default. Message previews still require the existing preview opt-in. Payment amounts are visible by default.

## Constraints

- APNS/FCM payloads stay plaintext-free. The notification text is still rendered locally after the client processes local/decrypted data.
- Chat opening performance must stay local-first. Notification rendering uses already available message summary/drain data and must not fetch full history before display.
- The change covers native Apple and Compose Multiplatform notification surfaces together.

## Implementation Notes

- Core model: `core/sonar-core/src/notification.rs`.
- FFI surface: `SonarNotificationRenderInputInfo` -> `SonarNotificationEnvelopeInfo`.
- Apple adapter: `SonarLocalNotificationRouter` calls `sonarRenderNotification`.
- Compose adapter: `SonarNotificationRouter` delegates to `SonarCore.renderNotification`, which calls the Rust FFI on Android/JVM. The Kotlin mirror remains only as a fallback if native bindings are unavailable.

## Follow-Up

- **Compose Android remote push group labels:** `SonarConversationSummary` exposes the conversation name and latest sender but not whether the summary is a group. Remote Android push therefore shows the sender by default and omits the group label to avoid rendering direct chats as `sender in Alice`. Follow-up path: add group/direct metadata, or member count, to the core conversation summary and pass it into the notification envelope.
- Add a dedicated user setting for payment amount visibility if lock-screen payment privacy needs to be independent from message previews.
- Move more host-only notification kinds, such as network availability, through the same envelope as those paths are consolidated.
