#!/usr/bin/env bash
# Manual device smoke for Marmot Blossom account backup (PR #368 residuals).
# Run after installing a Debug build that includes the auto-backup tip.
set -euo pipefail

cat <<'EOF'
Account backup smoke checklist
==============================

1) Fresh install / onboarding
   - Complete onboarding (discloses auto-backup).
   - Settings → Privacy: Auto-backup toggle ON; copy mentions Blossom + nsec restore.
   - Send a chat message. Wait for opportunistic debounce (or force via Backup chats).
   - Confirm toast / status "Last backup …" after upload.

2) Upgrade / existing install without disclosure
   - Clear only `pref.auto_backup_disclosed` / UserDefaults `sonar.auto_backup_disclosed`
     (or install over an older build that never opened Settings backup).
   - Confirm NO auto-upload for 45s+15m until Settings Privacy is opened.
   - Open Settings → Privacy (discloses). Then auto-backup may run when due.

3) Seal → reconnect → upload
   - While chatting, tap Backup chats.
   - UI must stay usable after reconnect; upload finishes without freezing send.

4) Dirty during upload
   - Start Backup chats; send another message before upload completes.
   - After success, policy stays dirty (next opportunistic still due after debounce).

5) Restore
   - Note nsec. Wipe / reinstall. Restore with nsec.
   - Expect chats recovered when a Blossom backup exists for that nsec.

6) Background (OS)
   - Android: WorkManager unique work `sonar-auto-backup` enqueued after disclosure.
   - iOS: BGAppRefresh `sh.hedwig.sonar.auto-backup` scheduled; backgrounding
     also begins a short background task if due.

Core unit coverage (CI):
  cd core && cargo test -p sonar-core --lib account_backup
EOF
