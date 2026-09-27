# Repository Guidance

## Cross-Platform Feature Rule

Sonar is a multi-platform product. New user-facing features must be designed and implemented for every supported app surface unless a platform limitation is documented in the change itself.

When adding or changing a feature, cover the native Apple app (`ios/`) and the Compose Multiplatform app (`apps/sonar/`) together. If a capability cannot ship on one platform in the same change, leave an explicit tracked gap with the platform, reason, and follow-up path.

## Signal-Comparable Performance Rule

Conversation and transcript changes must preserve Signal-comparable local-first performance. Opening an existing chat must paint from local storage first and must not wait on relay/server sync, full-history scans, or unrelated groups before first paint. If a change can make chat opening, sending, or scrolling meaningfully slower than Signal-style local database windowing, design a bounded local page/window path, move sync to the background, and document any platform gap with a follow-up path.

## Signal-Style Conversation Design Notes

Signal treats the local database as the chat state. Network receive/send/sync paths write into local storage first, then the chat list and transcript UI react to local database invalidation. Android pages local conversation rows from `ThreadTable` through `ConversationListDataSource` with a small paging window; iOS builds chat-list render state from local thread IDs through `CLVLoader` and caches row view models/content. Sonar conversation work should follow that model: maintain core-owned local conversation summaries ordered by latest message, hydrate visible chat rows from bounded local pages, open transcripts from bounded local message windows, and run relay sync only as a background database updater.

## Local Secrets Rule

Do not commit payment, wallet, relay, signing, or API secrets. The Breez wallet key must stay in gitignored local configuration (`ios/Configs/Local.xcconfig` with `BREEZ_API_KEY = ...`) or an equivalent CI secret. When creating a new workspace/worktree or rebuilding for device testing, preserve the local secret by recreating/copying the gitignored config or passing the key through the build environment; verify presence without printing the value.

## QA

Before a change is merged, run the QA it needs with the `qa-run` skill
([`.agents/skills/qa-run/SKILL.md`](.agents/skills/qa-run/SKILL.md)). Any
agent can follow it; the only tools needed are a shell and git. Start with
`scripts/qa/plan.sh`, which reads the diff and this machine and prints what
to run, what cannot run here and why, and which sections of
[`docs/QA-SCENARIOS.md`](docs/QA-SCENARIOS.md) to walk. The run ends with a
QA report for the PR.

The rules that matter most:
- only dedicated emulators and simulators, never a physical phone;
- `ANDROID_SERIAL` set for every Gradle device task;
- secrets checked for presence only;
- no real money.

To hunt for bugs and fix them in a loop, use the maintainer skill `qa-pass`
([`.agents/skills/qa-pass/SKILL.md`](.agents/skills/qa-pass/SKILL.md)).
CLAUDE.md holds the full repository rules.
