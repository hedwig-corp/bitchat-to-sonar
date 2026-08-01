# Group mentions by Sonar name (`@vincenzopalazzo`)

## Clarified Problem Statement

**Goal:** Let a member of a Marmot/Sonar group address another member by their Sonar
profile name (`@vincenzopalazzo`), with an autocomplete picker, a highlighted/tappable
mention in the transcript, and a "X mentioned you" notification that reaches the
mentioned person — on both `ios/` and `apps/sonar/`.

**Current state (verified, not assumed):**

- `@mention` exists **only** in the legacy bitchat mesh stack on iOS:
  [`AutocompleteService.swift`](../../ios/bitchat/Services/AutocompleteService.swift),
  the `mention` pattern in
  [`MessageFormattingEngine.swift:45`](../../ios/bitchat/Services/MessageFormattingEngine.swift:45),
  wired into the public-chat composer at
  [`ContentView.swift:594`](../../ios/bitchat/Views/ContentView.swift:594).
- Marmot group chats have **zero** mention support:
  [`MarmotChatView.swift`](../../ios/bitchat/Views/MarmotChatView.swift) has no
  autocomplete, and there is no mention parsing anywhere in Kotlin —
  **Android has no mention support at all**, not even for mesh.
- `NotificationKind::Mention` is declared at
  [`notification.rs:10`](../../core/sonar-core/src/notification.rs:10) and formats
  "X mentioned you" at
  [`notification.rs:208`](../../core/sonar-core/src/notification.rs:208), but
  **nothing in the codebase ever constructs it**. It is a dead branch.
- The mesh already uses the disambiguation convention we want:
  `@nickname#<last 4 hex of pubkey>`, produced at
  [`ChatViewModel.swift:1275`](../../ios/bitchat/ViewModels/ChatViewModel.swift:1275)
  and matched by the regex `@([\p{L}0-9_]+(?:#[a-fA-F0-9]{4})?)`. Because geohash
  identities are Nostr pubkeys, this suffix maps 1:1 onto Marmot member npubs.
- Raw material is in place: `groups().member_npubs`
  ([`lib.rs:1587`](../../core/sonar-ffi/src/lib.rs:1587)) plus per-npub kind-0
  profile caches on both platforms (`MarmotService.profilesByNpub`,
  `SonarAppState.profilesByNpub`, both with `bestName`).

**Decisions taken (from the question round):**

- **Wire format:** plain `@nickname` text inside the kind-9 rumor content. No new
  `p` tag, no NIP-27 `nostr:` URI, no change to `MessageInfo`'s wire shape.
- **Naming:** kind-0 profile name, plus a disambiguating suffix — reuse the existing
  `#abcd` (last 4 hex of the member's pubkey) rather than inventing a second scheme.
- **Scope:** Marmot groups **and** unify the existing mesh mentions onto the same
  implementation, so there is one mention engine, not two.

**Constraints:**

- Cross-Platform Feature Rule: iOS and Compose ship together, or the gap is
  documented in the change.
- Signal-Comparable Performance Rule: mention resolution runs off the Compose render
  path and off the SwiftUI body — resolve in a background/derived layer and hand the
  view a prepared span list. Do not re-tokenize a transcript row per recomposition.
- Wire format stays plain text: a White Noise client (or an older Sonar) that knows
  nothing about mentions must still show a readable message.
- No `nsec`/account-key surface is touched.

**Non-goals:**

- `@everyone` / `@here` broadcast mentions.
- Mentioning someone who is **not** a member of the group (no invite-by-mention).
- Any change to mute behaviour. R-022 requires mute to suppress banner, sound,
  and haptic on every delivery path, so a mention does **not** pierce mute (see
  the resolved question below). No per-group "mentions only" mode in v1 either.
- Rich NIP-27 interop with non-Sonar clients — explicitly deferred by the wire-format
  decision above.

**Success criteria:**

1. Typing `@vin` in a group composer (both platforms) lists matching group members
   by profile name, showing the npub suffix when two members share a name.
2. Selecting a suggestion inserts `@name` (or `@name#abcd` when the name is
   ambiguous within that group) into the draft.
3. The sent message renders with the mention highlighted on **both** the sender's and
   the recipients' transcripts, and tapping it opens that member's profile.
4. The mentioned member gets a notification whose body is "X mentioned you"
   (`NotificationKind::Mention` stops being dead), subject to the existing mute
   and privacy rules — a muted group stays silent (R-022).
5. A client with no mention support renders the message as readable plain text.
6. Mesh public/geohash chat mentions still behave exactly as before after the
   unification — pinned by a test, since this is a refactor of live behavior.

## Approaches Considered

### Approach A: Per-platform client-side mention engine (no core change)
- **Sketch:** Keep everything above the FFI. Generalize iOS's existing
  `MessageFormattingEngine` mention pattern so it accepts a member roster instead of
  the mesh peer list, and write a Kotlin twin for Compose. Each host detects
  "mentions me" in its own drain handler and raises the local notification.
- **Affected files:** `ios/bitchat/Services/MessageFormattingEngine.swift`,
  `ios/bitchat/Services/AutocompleteService.swift`,
  `ios/bitchat/Views/MarmotChatView.swift`,
  `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/App.kt` (+ a new
  Kotlin mention module), both notification routers.
- **Tradeoffs:** No FFI/ABI churn, ships fastest of the "real" options. But it writes
  the tokenizer, the roster match, and the mentions-me rule **twice** — exactly the
  duplication `docs/REGRESSIONS.md` calls out for the
  `SonarAppState.kt` / `SonarAppStore.swift` mirror pair, which is where fixes in this
  repo most often land on one platform only. `NotificationKind::Mention` stays dead
  and each host invents its own mention notification.
- **Effort:** M

### Approach B: Core-owned mention resolution, native pickers on top (recommended)
- **Sketch:** Put the tokenizer and roster resolution in `sonar-core`. Core already
  precomputes `MessageClassInfo` per message and already owns the notification
  taxonomy, so it is the natural home: given a group id and the plain-text content,
  core returns resolved mention spans (UTF-16 code-unit range + npub + display
  name — Kotlin and Swift both index in UTF-16, so Rust byte offsets would
  misplace every span after a non-ASCII character) and a
  `mentions_me` flag, and classifies the resulting notification as
  `NotificationKind::Mention`. The wire stays plain `@name` text — core is only
  *parsing* it. Both apps then render prepared spans and build the composer picker
  from `member_npubs` + their local profile cache.
- **Affected files:** `core/sonar-core/src/marmot.rs` or a new
  `core/sonar-core/src/mention.rs`, `core/sonar-core/src/notification.rs`
  (make `Mention` reachable), `core/sonar-ffi/src/lib.rs` (`MessageInfo` /
  `MessageClassInfo` gain mention fields — a real UniFFI ABI change),
  `ios/bitchat/Views/MarmotChatView.swift` + `MessageFormattingEngine.swift`,
  `apps/sonar/composeApp/.../App.kt` + `SonarAppState.kt`.
- **Tradeoffs:** One implementation, one set of Rust tests, and the mesh path can be
  folded onto it afterwards so the unification is real rather than parallel. Costs a
  UniFFI checksum bump — `SonarFFI.swift` must be regenerated in the same change or
  the app `fatalError`s at runtime and no CI job catches it. Also the biggest diff.
- **Effort:** M/L

### Approach C: Composer picker only
- **Sketch:** Ship just the autocomplete sheet in both group composers, inserting
  `@name#abcd`. No rendering change, no notification change.
- **Affected files:** `ios/bitchat/Views/MarmotChatView.swift`,
  `apps/sonar/composeApp/.../App.kt`.
- **Tradeoffs:** Smallest, lowest risk, and gets the "I can address someone by name"
  affordance in front of users immediately. But it delivers none of the value that
  makes mentions worth having — the mentioned person still isn't told, and the mention
  still looks like grey text. It is a demo, not the feature.
- **Effort:** S

## Recommendation

**Approach B**, with C's composer picker as its UI layer — the picker has to be native
per platform regardless, so it is not really a separate option. B is the one that
satisfies the "unify with the existing mesh mentions" decision honestly: A produces two
mention engines and calls it unification, and the repo's own regression ledger says
that mirror-pair duplication is how these bugs come back.

Sequence it so risk lands early: core tokenizer + resolution + tests first (pure Rust,
no UI), then the ABI/regeneration step, then iOS, then Compose, then fold the mesh path
onto the same engine last with a test pinning existing mesh behavior.

## Open questions

- **Rename on the wire.** Plain-text `@name` means the receiver resolves by matching
  the string against member profile names. If someone renames between send and read,
  a bare `@name` no longer resolves. The `#abcd` suffix is rename-proof because it is
  the pubkey — so: always emit the suffix (uglier, always correct), or emit it only on
  ambiguity (matches today's mesh behavior, breaks on rename)? Leaning toward
  ambiguity-only for parity, and accepting the edge case.
- **Where does "mentions me" get evaluated for a push?** Push bodies come from the
  local drain, so the client can detect it — but it needs the local identity's own
  current profile name. Confirm core has that available at classification time before
  committing to core-side detection.
- ~~Does a mention pierce mute?~~ **Resolved: it does not.** R-022
  () states mute suppresses banner, sound, and haptic on
  every delivery path and has five guarding tests. Changing that is a deliberate
  product decision, not a side effect of adding mentions; tracked as a follow-up
  on #557.
- Is there a local petname/alias store that should win over the kind-0 name in the
  picker? I did not find one — if it exists, the picker should prefer it.
- Case sensitivity and non-Latin names: the mesh regex is `\p{L}`-based, so it already
  accepts non-Latin. Confirm the matching is case-insensitive and
  Unicode-normalized on both platforms.
