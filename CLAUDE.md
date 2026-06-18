# Repository Guidance

## Cross-Platform Feature Rule

Sonar is a multi-platform product. New user-facing features must be designed and implemented for every supported app surface unless a platform limitation is documented in the change itself.

When adding or changing a feature, cover the native Apple app (`ios/`) and the Compose Multiplatform app (`apps/sonar/`) together. If a capability cannot ship on one platform in the same change, leave an explicit tracked gap with the platform, reason, and follow-up path.

## Signal-Comparable Performance Rule

Conversation and transcript changes must preserve Signal-comparable local-first performance. Opening an existing chat must paint from local storage first and must not wait on relay/server sync, full-history scans, or unrelated groups before first paint. If a change can make chat opening, sending, or scrolling meaningfully slower than Signal-style local database windowing, design a bounded local page/window path, move sync to the background, and document any platform gap with a follow-up path.

## Fix What We Break Rule

When a change breaks existing behavior, fix the broken behavior directly before considering the work complete. Do not leave regressions for users to route around, and do not hide them with UI-only workarounds.

For conversation identity specifically, a person must never be split into separate chats just because discovery arrives over different transports or in a different order. If a peer is first seen as Bitchat/mesh and later advertises Sonar features, fold the Bitchat, Sonar Discovery, and White Noise/Marmot legs into one conversation using the stable Noise fingerprint and NIP/npub identity link.
