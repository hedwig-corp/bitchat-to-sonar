## Clarified Problem Statement

**Goal:** Give Sonar on macOS remote chat/call and silent Breez wallet wakeups that reuse the existing Transponder/APNs + NDS stack, covering both the native Sonar.app and Compose Desktop surfaces, including best-effort delivery when the Mac is asleep.

**Constraints:**
- Web Push (VAPID / service workers) is out of scope for the native/desktop apps.
- Prefer reusing iOS Transponder (MIP-05 encrypted APNs tokens, platform `0x01`) and Breez NDS webhook registration — not a new provider.
- Existing product decision: mobile push is shipped; desktop remote wake is the tracked gap ([#54](https://github.com/hedwig-tech/bitchat-to-sonar/issues/54)); `docs/SONAR-NOTIFICATIONS.md` still says desktop = local/tray-only.
- Today: `SonarPushRegistration` is `#if os(iOS)` only; `MacAppDelegate` does not call `registerForRemoteNotifications()`; Compose JVM `Notifier` is AWT tray, no push webhooks.
- Cross-platform rule: if one Mac surface gets remote wake and the other cannot, document the explicit gap + follow-up.
- Asleep / lid-closed delivery on macOS is **best-effort** (APNs + Power Nap / network); cannot promise iPhone-parity wake rates.
- No secrets in git; APNs `.p8` / bundle IDs stay in deploy secrets (same Transponder instances).

**Non-goals:**
- Browser / PWA Web Push.
- Guaranteed delivery with lid closed or offline Mac.
- Redesigning MIP-05 or replacing Transponder.
- Full Windows/Linux remote-wake parity in the same change (unless a later approach explicitly expands).

**Success criteria:**
- Native macOS Sonar.app registers an APNs token, encrypts/shares it via existing core MIP-05 path, and receives Transponder chat/call pushes when quit (and best-effort when asleep).
- Silent Breez NDS wakes work on native macOS the same way as iOS (no user-visible NDS duplicate; user-visible payment still via `⚡PAY` / local router).
- Compose Desktop behavior is either wired to a real wake path or explicitly tracked as local-only with a follow-up path.
- Docs (`SONAR-NOTIFICATIONS.md`, #54) updated so “desktop” is no longer a blanket local-only claim without nuance.
- Sandbox vs production APNs still works with the existing dual-transponder setup (`deploy/transponder/APNS-ENVIRONMENTS.md`).

## Approaches Considered

### Approach A: Native macOS APNs parity (primary); Compose Desktop stays local-only
- Sketch: Lift push registration from iOS-only to shared Apple code (`SonarPushRegistration`, `MacAppDelegate.registerForRemoteNotifications`, entitlements `aps-environment`, optional macOS Notification Service Extension for killed-app generic copy). Same Transponder + NDS as iPhone. Treat native Sonar.app as the Mac product that gets remote wake; Compose JVM remains tray-while-running (#54 refined, not closed for JVM).
- Affected files: `ios/bitchat/Services/SonarPushRegistration.swift`, `ios/bitchat/BitchatApp.swift` (`MacAppDelegate`), entitlements / Xcode capabilities for macOS target, possibly `ios/SonarNotificationService/`, `docs/SONAR-NOTIFICATIONS.md`, #54.
- Tradeoffs: Reuses proven stack; smallest server change (bundle ID must be allowed for Mac if distinct from iOS). Does not give Compose Desktop remote wake. Asleep delivery still best-effort.
- Effort: M

### Approach B: Always-on desktop helper / LaunchAgent (no APNs)
- Sketch: Ship a lightweight background agent that keeps relay sync (or a push subscription) alive and posts local notifications when the main UI is quit. Apply similarly on JVM via a companion process. Avoids Apple push entitlements for Desktop.
- Affected files: new macOS LaunchAgent / helper target, packaging/autostart, secure storage sharing with main app, Compose desktop packaging; little/no Transponder change.
- Tradeoffs: Does not solve lid-closed/asleep (agent sleeps too). Large security and packaging surface; duplicates sync/wakeup logic already owned by Transponder+APNs on mobile. Worse fit for “reuse iOS Transponder.”
- Effort: L

### Approach C: Unified Mac remote wake via native APNs bridge; JVM defers
- Sketch: Same as A for native Sonar.app (Transponder APNs + NDS). For Compose Desktop on macOS only, either (C1) document “use native Sonar.app for background push” as the product answer, or (C2) later add a thin native helper that only owns the APNs token and forwards wakes into the JVM app — only if JVM Mac remains a first-class distributed binary.
- Affected files: same as A, plus a short product/docs decision on whether Compose Desktop is a Mac shipping target for notifications; optional future helper project.
- Tradeoffs: Honest about APNs requiring a real Apple app identity. Avoids fake Web Push. Leaves Windows/Linux remote wake open. Matches answer 4C (prefer Transponder reuse).
- Effort: M (C1) / L if C2 helper is in scope now

## Recommendation

**Approach A, framed as C1:** implement native macOS APNs + Breez NDS by extending the existing iOS Transponder path; keep Compose Desktop local/tray-only with an updated #54 that names native Mac as the remote-wake surface. Web Push is the wrong protocol. Lid-closed success is best-effort APNs, not a separate daemon.

Rationale: Transponder already speaks APNs; MIP-05 already has platform `0x01`; MacAppDelegate is the missing registration hook; a LaunchAgent does not beat APNs for sleep. Only invest in a JVM APNs bridge if Compose Desktop remains a shipped Mac binary alongside Sonar.app.

## Open questions (resolved for v1)

- Bundle ID / APNs topic: **shared** `sh.hedwig.sonar` (same Transponder config).
- Compose Desktop: **local/tray only**; native Sonar.app is the Mac remote-wake surface (#54).
- macOS NSE: **deferred** for v1 (visible APNs + in-process processor); track under #54.
- Breez NDS: same FCM→APNs path when `GoogleService-Info.plist` is present; `platform=ios` webhook unchanged (Firebase bridges by bundle id).
- Asleep: document as **best-effort APNs**.
