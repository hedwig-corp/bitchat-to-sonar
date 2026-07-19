# Plan: ios-backup-chats-click

**Goal:** Settings → Backup chats on iOS must stay responsive, always leave Marmot reconnected, and never leave a sticky completion toast.

**PR:** https://github.com/hedwig-corp/bitchat-to-sonar/pull/378  
**Branch:** `fix/ios-backup-chats-click`  
**Status:** Implementation landed (2 commits); this plan drives the production-readiness review loop.

## Affected files

- `ios/bitchat/Services/MarmotService.swift` — off-MainActor Blossom backup/restore FFI queue; `import BitLogger`
- `ios/bitchat/Views/MarmotChatView.swift` — always reconnect after upload attempt; clear `busy` before relay kick
- `ios/bitchat/Views/Sonar/SonarAppStore.swift` — sticky progress + epoch-gated `showToast`
- `ios/bitchat/Views/Sonar/SNToastSession.swift` — toast epoch helper
- `ios/bitchat/Views/Sonar/MarmotAccountBackupFlow.swift` — reconnect / toast-priority policy
- `ios/bitchatTests/{MarmotAccountBackupFlow,SNToastSession}Tests.swift` — unit pins

## Approach

Match Compose `backupAccountNow`:
1. Close node → seal/upload on a dedicated IO queue (not MainActor / not `workQueue` network park)
2. Always `performConnect` + relay attach after the attempt
3. Sticky “Backing up…” then auto-dismissing result toast via epoch + `Task.detached`

## Edge cases (review loop targets)

- Cancellation of the Settings `Task` must not leave completion toast stuck
- Upload failure must not leave node closed / local-only
- Double-tap Backup while in flight
- `CancellationError` must not surface as “Backup failed — try again when online”
- Direct `toast =` assignments elsewhere must not desync `SNToastSession` on this path
- Restore-account toasts that still set `toast =` without dismiss (related sticky-toast class)

## Test plan

- [x] `cargo test -p sonar-core --lib account_backup`
- [x] Remote CI (Rust core + regression ledger)
- [x] Device install on Vincenzo’s iPhone (Debug, in-place)
- [ ] Manual: Backup chats → progress → result clears ~1.6s
- [ ] Manual: kill network mid-backup → failure toast + chats still usable
- [ ] Goose + GLM 5.2 production-readiness review → GO

## Conventions

- Cross-platform: Compose already correct; iOS catches up (document any remaining gap)
- Account Key Durability: never delete/replace nsec during backup
- Signal-comparable: backup must not block chat UI (MainActor) beyond sticky toast
- Tests pin real policy helpers used at the call site

## Estimated size

M (~220 LOC across 7 files)

## Production-readiness loop

1. Self `/review-pr --specialists` on #378
2. `/review-feedback` fixes until Production Readiness: GO
3. `goose review` with `--provider zai --model glm-5.2` on `main...HEAD`
4. Address Goose findings; re-run until GLM also says production-ready
5. Final self-review ACK on HEAD
