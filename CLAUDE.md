# Repository Guidance

## Cross-Platform Feature Rule

Sonar is a multi-platform product. New user-facing features must be designed and implemented for every supported app surface unless a platform limitation is documented in the change itself.

When adding or changing a feature, cover the native Apple app (`ios/`) and the Compose Multiplatform app (`apps/sonar/`) together. If a capability cannot ship on one platform in the same change, leave an explicit tracked gap with the platform, reason, and follow-up path.

## Signal-Comparable Performance Rule

Conversation and transcript changes must preserve Signal-comparable local-first performance. Opening an existing chat must paint from local storage first and must not wait on relay/server sync, full-history scans, or unrelated groups before first paint. If a change can make chat opening, sending, or scrolling meaningfully slower than Signal-style local database windowing, design a bounded local page/window path, move sync to the background, and document any platform gap with a follow-up path.

## Signal-Style Conversation Design Notes

Signal treats the local database as the chat state. Network receive/send/sync paths write into local storage first, then the chat list and transcript UI react to local database invalidation. Android pages local conversation rows from `ThreadTable` through `ConversationListDataSource` with a small paging window; iOS builds chat-list render state from local thread IDs through `CLVLoader` and caches row view models/content. Sonar conversation work should follow that model: maintain core-owned local conversation summaries ordered by latest message, hydrate visible chat rows from bounded local pages, open transcripts from bounded local message windows, and run relay sync only as a background database updater.

## Signal-First Design Rule

Before implementing any well-known chat feature (media sending, reactions, read receipts, typing indicators, group management, voice/video calls, stories, disappearing messages, link previews, contact sharing, location sharing, stickers, etc.), study how Signal implements it in their open-source clients:

- **Signal-iOS**: https://github.com/signalapp/Signal-iOS
- **Signal-Android**: https://github.com/nicegram/nicegram-Signal-Android

Check Signal's architecture for: data models, state lifecycle, memory management (file-backed vs in-memory), compression/processing timing (lazy vs eager), UI structure (navigation, editing, multi-item), cleanup paths (cancel, back, crash), and send pipeline (queued vs direct). Document in the PR description which Signal patterns were adopted, which were deferred (with tracked follow-ups), and why.

The goal is not to copy Signal — it is to avoid designing seams that make it expensive to reach Signal-quality later. A v1 can be minimal, but its data model and state flow should not preclude adding captions, multi-image, editing, or quality controls without a rewrite.

Concrete checklist for media features specifically (derived from Signal's `AttachmentApprovalViewController` + `SendMediaNavigationController`):

1. **Lazy finalization**: show full-quality preview; compress/re-encode only on send confirmation, not on pick
2. **File-backed large data**: for images >1MB, prefer file URLs / temp paths with ownership cleanup over holding raw bytes in reactive state
3. **Caption support**: design the preview data model with an optional message/caption field from day one, even if the UI doesn't expose it yet
4. **Multi-item ready**: use a list/collection for pending items, not a single nullable field, so multi-select doesn't require a model rewrite
5. **Cleanup on all exit paths**: cancel, back gesture, navigation pop, app backgrounding — verify each one releases resources

## Local Secrets Rule

Do not commit payment, wallet, relay, signing, or API secrets. The Breez wallet key must stay in gitignored local configuration (`ios/Configs/Local.xcconfig` with `BREEZ_API_KEY = ...`) or an equivalent CI secret. When creating a new workspace/worktree or rebuilding for device testing, preserve the local secret by recreating/copying the gitignored config or passing the key through the build environment; verify presence without printing the value.

## Fix What We Break Rule

When a change breaks existing behavior, fix the broken behavior directly before considering the work complete. Do not leave regressions for users to route around, and do not hide them with UI-only workarounds.

For conversation identity specifically, a person must never be split into separate chats just because discovery arrives over different transports or in a different order. If a peer is first seen as Bitchat/mesh and later advertises Sonar features, fold the Bitchat, Sonar Discovery, and White Noise/Marmot legs into one conversation using the stable Noise fingerprint and NIP/npub identity link.
