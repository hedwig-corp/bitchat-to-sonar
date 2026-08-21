## Clarified Problem Statement

**Goal:** When the user enables Share local time, automatically read the phone's current system timezone and share that IANA identifier inside encrypted private conversations, allowing contacts to see that user's current local time without exposing it on Nostr relays.

**Constraints:**
- Default **off**. Sharing starts only after the user enables Settings → Privacy & safety → Share local time.
- While enabled, use the operating system's current timezone (`TimeZone.autoupdatingCurrent` / `ZoneId.systemDefault()`); do not infer it from geohash, and do not let the user pick a fake zone in v1.
- Share an IANA timezone identifier such as `Europe/Zurich`, not coordinates, geohash, city, or GPS data.
- Transport must match Marmot reactions (#603): an **unsigned kind-449 application rumor inside MLS (kind 445)**. Relays only ever see the same opaque group ciphertext they already store for chat. Do **not** publish timezone as a public Nostr event (kind-0, descriptors, kind-7 likes) and do **not** send it as a pairwise NIP-44 gift wrap that would add a distinct event kind on relays.
- Timezone metadata must be visible only to current MLS members of the relevant private DM or encrypted group.
- Show a contact's live local time beneath their name in the DM header.
- Show each member's live local time in the encrypted group's member list/profile surface.
- Update shared metadata when the device timezone changes (while the pref is on) and when a conversation is first established or its membership changes.
- Turning the pref off must clear the process-local share cache so later membership changes cannot keep publishing.
- Each encrypted DM and group can override the default: Settings is the default for chats without an override; contact/group info can turn sharing on or off for that conversation only.
- Implement the feature for native Apple (`ios/`) and Compose Multiplatform (`apps/sonar/`) together.
- Preserve local-first chat opening: render cached timezone data immediately and never wait for relay sync or profile fetching.
- Compute the displayed clock locally and refresh only visible UI at minute boundaries; do not generate network traffic every minute.

**Non-goals:**
- Publishing timezone in public Nostr kind-0 profiles, Sonar descriptors, BLE announcements, public geohash channels, or presence events.
- Pairwise NIP-44 / NIP-59 gift wraps of a kind-449 rumor (the original #398 sketch). Relays would then see extra 1059s distinct from chat.
- Sharing exact location, city, geohash, travel history, or GPS coordinates.
- Letting users manually choose or override their timezone in v1.
- Showing timezone beside every message.
- Putting multiple clocks in the group chat header.
- Inferring whether someone is currently awake or available.
- A retraction rumor that wipes peer caches on disable (v1 just stops sending; peers keep the last cached zone until a newer share arrives).

**Success criteria:**
- With the pref off, the host never calls `update_local_timezone` with a zone id, and core has no process-local zone to fan out.
- Enabling the pref reads the phone timezone and encrypts one kind-449 rumor per active MLS group through the chat outbox (kind 445).
- Existing DM peers see a header subtitle such as `4:10 PM · 6 hours behind` when metadata is available; the header remains normal when it is absent or invalid.
- Group members' current local times appear in the group member list when their encrypted timezone metadata is available.
- Changing the OS timezone while the pref is on causes a bounded background update to private conversations without blocking chat UI.
- DST and offset changes display correctly because clients store the zone identifier and calculate the current offset locally.
- Opening a conversation offline uses the cached timezone immediately.
- Timezone control payloads never appear as transcript messages, unread messages, notifications, or chat previews.
- Tests cover parsing/validation, DST behavior, hidden control messages, local cache hydration, timezone-change updates, MLS (not gift-wrap) transport, and Apple/Compose UI formatting.

## Approaches Considered

### Approach A: MLS application rumor (kind 449 inside kind 445)
- **Sketch:** Define a versioned JSON payload `{ "v": 1, "zone": "Europe/Zurich" }`. Encrypt it with `mdk.create_message` as an unsigned kind-449 rumor, the same outbox path as chat and as kind-7 reactions (#603). `process_group_message` classifies kind 449 as `Incoming::TimezoneShare` so it never becomes a transcript row. Persist the latest value by sender in core-owned local storage. Hosts report the phone IANA id only while Share local time is on; send on enable, OS timezone change, conversation establishment, and membership changes.
- **Affected files:** `core/sonar-core/src/timezone.rs`, `core/sonar-core/src/marmot.rs`, `core/sonar-core/src/client.rs`, `core/sonar-ffi/src/lib.rs`; `ios/bitchat/Views/Sonar/SonarDMScreen.swift`, `ios/bitchat/Views/Sonar/SonarGroupInfoScreen.swift`, `ios/bitchat/Views/Sonar/SonarAppStore.swift`, `ios/bitchat/Views/Sonar/SonarSettingsScreen.swift`; `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/SonarAppState.kt`, `App.kt`, `screens/SonarGroupInfoScreen.kt`, `screens/SonarSettingsScreen.kt`, and platform-specific timezone observers.
- **Tradeoffs:** Matches the private-sharing requirement, works offline from cache, and does not introduce a new relay-visible event kind. It adds a small protocol extension, persistence/migration work, and bounded per-group fan-out when a timezone changes. Older clients persist the application rumor in MDK but filter non-kind-9 rows out of the transcript.
- **Effort:** L

### Approach B: Public profile field with UI privacy
- **Sketch:** Add timezone to the existing Nostr kind-0 profile or Sonar descriptor, cache it with other profile data, and only render it in private chat UI.
- **Affected files:** Existing profile publication/fetch paths in `core/sonar-core/src/client.rs`, `MarmotChatView.swift`, `SonarAppStore.swift`, `SonarCore.kt`, and `SonarAppState.kt`.
- **Tradeoffs:** Smallest implementation and naturally available for group members, but the data is still publicly observable on relays. UI-only hiding does not satisfy the selected privacy requirement.
- **Effort:** M

### Approach C: Pairwise NIP-44 gift wraps of kind 449
- **Sketch:** The original #398 wire: account-level gift wraps intercepted before MLS, one per unique peer.
- **Tradeoffs:** Encrypted to each recipient, but relays see extra kind-1059 events distinct from chat, the fan-out is per-person rather than per-group, and it is a different control channel from reactions (#603). Rejected in favor of MLS application rumors.
- **Effort:** L

### Approach D: Derive timezone from shared geohash
- **Sketch:** Resolve a timezone from a participant's geohash and display the corresponding local time without introducing explicit timezone metadata.
- **Affected files:** Existing geohash/location managers, geohash identity paths, and DM/group headers on both clients.
- **Tradeoffs:** Reuses location machinery, but geohashes are not available for normal Marmot identities, boundary resolution can be wrong, travel updates would reveal location-derived information, and it couples a private-chat feature to public location channels. It also conflicts with the selected system-timezone source.
- **Effort:** M

## Recommendation

Use **Approach A: MLS application rumor**. It is the only approach that satisfies private visibility, DM + encrypted group support, and the same relay-leak bar as message reactions (#603). Keep the payload versioned and limited to the IANA zone ID; make storage local/core-owned so transcript first paint remains independent of network state.

## Open questions

- Should a timezone change be sent immediately to every existing conversation, or lazily on next send/open plus a bounded background queue? Recommendation: bounded background queue with retry, because changes are rare and should propagate without requiring chat activity. Cap fan-out at 256 groups.
- For groups, should all members proactively publish after joining, or should the new member's client request a refresh? Recommendation: each member sends their own timezone after observing a membership change; never allow one member to assert another member's timezone.
- Exact copy and formatting need localization decisions, including 12/24-hour preference and whether to show only `4:10 PM` or also `6 hours behind`. Recommendation: respect the viewer's clock-format preference and include the relative offset in DMs when it is non-zero.
- Should disable send a tombstone so peers drop the cached zone? Deferred: v1 clears only the sender's process cache and stops publishing.
