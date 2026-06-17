# Marmot Group Chat Feature Complete Plan

## Clarified Problem Statement

**Goal:** Implement feature-complete White Noise-compatible Marmot group chats across Sonar iOS/macOS and Compose Android/Desktop, including group creation, invite acceptance, membership management, and group-safe messaging behavior.

**Constraints:**
- Stay wire-compatible with White Noise / Marmot: KeyPackage kind 30443, welcome kind 444 inside gift wrap kind 1059, group messages kind 445, and MDK-managed MLS state.
- Build on Sonar's existing MDK-based Rust core and expose behavior through UniFFI to every app shell.
- Ship the feature across all device surfaces, not iOS-only.
- Use parallel implementation tracks where possible: core/FFI, iOS/macOS UI, Compose Android/Desktop UI, and tests can be developed independently once the core contract is defined.
- Group invites require an explicit accept screen; Sonar should stop silently auto-joining group welcomes for user-visible group chats.
- Initial recipient selection supports pasted npubs and local contacts only.
- Preserve existing 1:1 DM behavior and BLE-to-White-Noise conversation folding.
- Prevent group chats from accidentally exposing 1:1-only features such as peer calls or direct payments unless separately designed.

**Non-goals:**
- Public directory/search for arbitrary Nostr users beyond pasted npubs.
- Rich role/permission management beyond what is needed for safe add/remove/leave.
- Message reactions, threads, polls, disappearing messages, or moderation tooling.
- Replacing existing public geohash channels or BLE mesh rooms.

**Success criteria:**
- A user can create a named Marmot group with multiple recipients selected from local contacts or pasted npubs.
- Invited users see an explicit pending group invite screen and can accept or decline.
- Accepted members can send and receive encrypted text and media in the group across iOS/macOS and Compose Android/Desktop.
- Existing White Noise clients can join/read/send in Sonar-created groups, and Sonar can accept compatible White Noise group invites.
- A user can add members, remove members where permitted, and leave a group without corrupting MLS state for the remaining participants.
- Group chats render as standalone group conversations and are never folded into 1:1 BLE peer rows.
- Calls/payments remain disabled or clearly unsupported in multi-member groups.
- Core, FFI, Swift, Kotlin, and end-to-end tests cover create, accept, decline, add, remove, leave, restart persistence, and interop-shaped event flow.

## Ambiguity Resolved

- Scope: feature-complete group chats, not only initial multi-member creation.
- Platforms: all current device surfaces, not a single-platform spike.
- Invite UX: explicit accept/decline screen.
- Recipient inputs: pasted npubs and local contacts for v1.

## Approaches Considered

### Approach A: Initial Multi-Member MVP
- Sketch: Expose `start_group(peers, name)` through core/FFI and render groups correctly. Keep auto-accept and defer membership changes.
- Affected files: `core/sonar-core/src/client.rs`, `core/sonar-core/src/marmot.rs`, `core/sonar-ffi/src/lib.rs`, `ios/bitchat/Services/MarmotService.swift`, `ios/bitchat/Views/Sonar/SonarAppStore.swift`, `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/SonarCore.kt`, `SonarAppState.kt`.
- Tradeoffs: Fast and lower risk, but it does not satisfy the requested feature-complete scope.
- Effort: Medium.

### Approach B: Full Group Lifecycle In Core First
- Sketch: Define a group lifecycle contract in `sonar-core`: pending welcomes, accept/decline, create group, add member, remove member, leave group, list members, and group metadata. Expose this through UniFFI, then wire iOS/macOS and Compose UI in parallel against the same API.
- Affected files: `core/sonar-core/src/marmot.rs`, `core/sonar-core/src/client.rs`, `core/sonar-ffi/src/lib.rs`, generated Swift/Kotlin bindings, `MarmotService.swift`, `MarmotChatView.swift`, `SonarAppStore.swift`, `SonarCore.kt`, platform actuals, `SonarAppState.kt`, chat list/detail screens.
- Tradeoffs: Best matches product scope and shared-core architecture. More work because MDK proposal/commit/evolution-event publication needs to be made explicit and tested.
- Effort: Large.

### Approach C: UI-First Spike With Core Backfill
- Sketch: Build a visible group UI first, backed by only create/read/send primitives, then fill in accept/add/remove/leave later.
- Affected files: mostly SwiftUI and Compose screens plus thin wrappers around existing `start_dm`.
- Tradeoffs: Useful for design exploration, but likely creates throwaway state and does not satisfy all-device feature completeness.
- Effort: Medium, with high rework risk.

## Recommendation

Use **Approach B: Full Group Lifecycle In Core First**.

The key engineering boundary is the core contract. Once `sonar-core` owns pending invites and membership mutations, the app shells can be implemented in parallel without inventing platform-specific group semantics. This also avoids the biggest existing bug class: UI code assuming every Marmot group has exactly one other member.

## Implementation Plan

1. Core contract and state model
   - Add a core model for pending group invites instead of auto-accepting every welcome.
   - Add APIs for `pending_group_invites`, `accept_group_invite`, `decline_group_invite`, `create_group`, `add_group_members`, `remove_group_member`, and `leave_group`.
   - Make multi-member groups identifiable through member count and metadata so shells can avoid 1:1 folding.

2. MDK lifecycle wiring
   - Rework welcome processing so incoming welcomes can be stored pending, accepted later, or discarded.
   - Implement group creation for multiple KeyPackages.
   - Implement membership updates using MDK proposals/commits and publish required evolution/group events.
   - Keep commit merge timing conservative: merge after publish succeeds where MDK requires it.

3. FFI surface
   - Add UniFFI records for group invite summaries, group member summaries, and group lifecycle errors.
   - Expose all group lifecycle APIs through `SonarNode`.
   - Regenerate Swift and Kotlin bindings.

4. iOS/macOS implementation
   - Add group creation UI that accepts local contacts and pasted npubs.
   - Add pending invite screen with accept/decline.
   - Update chat list and transcript rendering so multi-member groups are standalone rows.
   - Disable or hide calls/payments in multi-member groups.
   - Add member list and group management surfaces for add/remove/leave.

5. Compose Android/Desktop implementation
   - Mirror the same flows in common Compose UI where possible.
   - Wire platform actuals to the new FFI APIs.
   - Keep local contacts and pasted npub input as the only v1 recipient sources.
   - Match iOS behavior for invite accept/decline and group-safe feature gating.

6. Tests and verification
   - Add Rust integration tests for multi-member create, accept, decline, send, add, remove, leave, and restart persistence.
   - Add FFI smoke tests for new APIs.
   - Add Swift and Kotlin state tests for group rendering and 1:1 folding avoidance.
   - Add interop-shaped tests that verify event kinds and membership transitions stay White Noise-compatible.

## Parallel Workstreams

- Core subagent: Rust MDK lifecycle, pending invites, membership mutations, core tests.
- FFI subagent: UniFFI records/methods, generated binding updates, Swift/Kotlin compile fixes.
- iOS/macOS subagent: Swift service facade, group creation, invite acceptance, chat/member UI.
- Compose subagent: common state model, Android/Desktop UI, platform actuals.
- QA subagent: end-to-end test matrix, regression tests for 1:1 DMs, media, calls/payments gating.

## Open Questions

- What exact local-contact source should group creation use first: BLE-discovered Sonar contacts, existing DM rows, or both?
- Should decline be local-only, or should Sonar publish a visible rejection/leave signal when the Marmot spec supports it cleanly?
- Should group names be creator-controlled only for v1, or editable by members?
- How strict should remove-member permissions be in v1 if all invited members are currently admins?
