## Clarified Problem Statement

**Goal:** Automatically share each Sonar user's current system timezone inside encrypted private conversations, allowing contacts to see that user's current local time without exposing location publicly.

**Constraints:**
- Use the operating system's current timezone; do not infer it from geohash.
- Share an IANA timezone identifier such as `Europe/Zurich`, not coordinates, geohash, city, or GPS data.
- Timezone metadata must be visible only to participants in the relevant private DM or encrypted group.
- Show a contact's live local time beneath their name in the DM header.
- Show each member's live local time in the encrypted group's member list/profile surface.
- Update shared metadata when the device timezone changes and when a conversation is first established or its membership changes.
- Implement the feature for native Apple (`ios/`) and Compose Multiplatform (`apps/sonar/`) together.
- Preserve local-first chat opening: render cached timezone data immediately and never wait for relay sync or profile fetching.
- Compute the displayed clock locally and refresh only visible UI at minute boundaries; do not generate network traffic every minute.

**Non-goals:**
- Publishing timezone in public Nostr kind-0 profiles, Sonar descriptors, BLE announcements, public geohash channels, or presence events.
- Sharing exact location, city, geohash, travel history, or GPS coordinates.
- Letting users manually choose or override their timezone in v1.
- Showing timezone beside every message.
- Putting multiple clocks in the group chat header.
- Inferring whether someone is currently awake or available.

**Success criteria:**
- Starting a DM sends the sender's timezone as encrypted conversation metadata and stores received metadata locally.
- Existing DM peers see a header subtitle such as `4:10 PM · 6 hours behind` when metadata is available; the header remains normal when it is absent or invalid.
- Group members' current local times appear in the group member list when their encrypted timezone metadata is available.
- Changing the OS timezone causes a bounded background update to private conversations without blocking chat UI.
- DST and offset changes display correctly because clients store the zone identifier and calculate the current offset locally.
- Opening a conversation offline uses the cached timezone immediately.
- Timezone control payloads never appear as transcript messages, unread messages, notifications, or chat previews.
- Tests cover parsing/validation, DST behavior, hidden control messages, local cache hydration, timezone-change updates, and Apple/Compose UI formatting.

## Approaches Considered

### Approach A: Encrypted conversation control metadata
- **Sketch:** Define a versioned Sonar application-control payload carrying the sender's IANA timezone. Send it through each Marmot DM/group, intercept it before transcript insertion, and persist the latest value by conversation and sender in core-owned local storage. Send on conversation establishment, relevant membership changes, and OS timezone changes; calculate the visible clock locally.
- **Affected files:** `core/sonar-core/src/marmot.rs`, `core/sonar-core/src/client.rs`, `core/sonar-ffi/src/lib.rs`; `ios/bitchat/Views/Sonar/SonarDMScreen.swift`, `ios/bitchat/Views/Sonar/SonarGroupInfoScreen.swift`, `ios/bitchat/Views/Sonar/SonarAppStore.swift`; `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/SonarAppState.kt`, `App.kt`, `screens/SonarGroupInfoScreen.kt`, and platform-specific timezone observers.
- **Tradeoffs:** Matches the private-sharing requirement and works offline from cache. It adds a small protocol extension, persistence/migration work, and bounded fan-out when a timezone changes. Older clients safely ignore the hidden payload only if the envelope is designed as a backward-compatible non-chat application message.
- **Effort:** L

### Approach B: Public profile field with UI privacy
- **Sketch:** Add timezone to the existing Nostr kind-0 profile or Sonar descriptor, cache it with other profile data, and only render it in private chat UI.
- **Affected files:** Existing profile publication/fetch paths in `core/sonar-core/src/client.rs`, `MarmotChatView.swift`, `SonarAppStore.swift`, `SonarCore.kt`, and `SonarAppState.kt`.
- **Tradeoffs:** Smallest implementation and naturally available for group members, but the data is still publicly observable on relays. UI-only hiding does not satisfy the selected privacy requirement.
- **Effort:** M

### Approach C: Derive timezone from shared geohash
- **Sketch:** Resolve a timezone from a participant's geohash and display the corresponding local time without introducing explicit timezone metadata.
- **Affected files:** Existing geohash/location managers, geohash identity paths, and DM/group headers on both clients.
- **Tradeoffs:** Reuses location machinery, but geohashes are not available for normal Marmot identities, boundary resolution can be wrong, travel updates would reveal location-derived information, and it couples a private-chat feature to public location channels. It also conflicts with the selected system-timezone source.
- **Effort:** M

## Recommendation

Use **Approach A: Encrypted conversation control metadata**. It is the only approach that satisfies private visibility while supporting DMs and encrypted groups. Keep the payload versioned and limited to the IANA zone ID; make storage local/core-owned so transcript first paint remains independent of network state.

Before implementation, verify how unknown Marmot application payloads behave on older Sonar clients. If they would render as text, introduce a backward-compatible typed envelope or capability gate before sending updates.

## Open questions

- Should a timezone change be sent immediately to every existing conversation, or lazily on next send/open plus a bounded background queue? Recommendation: bounded background queue with retry, because changes are rare and should propagate without requiring chat activity.
- For groups, should all members proactively publish after joining, or should the new member's client request a refresh? Recommendation: each member sends their own timezone after observing a membership change; never allow one member to assert another member's timezone.
- Exact copy and formatting need localization decisions, including 12/24-hour preference and whether to show only `4:10 PM` or also `6 hours behind`. Recommendation: respect the viewer's clock-format preference and include the relative offset in DMs when it is non-zero.
