//
// BitchatApp.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Tor
import SwiftUI
import os
#if DEBUG
import BitLogger
#endif
import UserNotifications
#if os(iOS)
import FirebaseCore
import FirebaseMessaging
#endif

@main
struct BitchatApp: App {
    static let bundleID = Bundle.main.bundleIdentifier ?? "chat.bitchat"

    // The Sonar UI is the app root. The store owns the real backends
    // (ChatViewModel: mesh + Nostr + geohash channels, MarmotChatModel:
    // White Noise secure chats) and maps them to the screens.
    @StateObject private var sonarStore = SonarAppStore()

    #if os(iOS)
    @Environment(\.scenePhase) var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // Skip the very first .active-triggered Tor restart on cold launch
    @State private var didHandleInitialActive: Bool = false
    @State private var didEnterBackground: Bool = false
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate
    #endif

    init() {
        // Diagnostics: tee SecureLogger into the bounded on-device log file so
        // "Share debug bundle" works on shipped builds (Settings → Diagnostics).
        // Configure before t0 so Wi-Fi / CoreDevice benches can pull markers from
        // the app log when idevicesyslog (USB) is unavailable.
        SonarDiagnostics.configureAppSink()
        #if DEBUG
        // SONAR_BENCH: earliest in-process cold-start marker (T0) + benchmark
        // provisioning. DEBUG-only — the markers are only %{public}@ (visible in
        // the unified log) in DEBUG anyway. See docs/PERFORMANCE.md, scripts/bench/.
        SecureLogger.info("SONAR_BENCH t0_launch", category: .session)
        // When provisioning the benchmark (SONAR_BENCH_NSEC set), skip the
        // onboarding gate so the Marmot relay-sync path starts on cold launch
        // without UI. Must run before SonarAppStore reads `onboarded`.
        if let n = ProcessInfo.processInfo.environment["SONAR_BENCH_NSEC"], !n.isEmpty {
            UserDefaults.standard.set(true, forKey: "sonar.onboarding.complete")
        }
        #endif
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        // Must run before any notification is posted. Nothing registered
        // categories before this, so the NSE's `categoryIdentifier` referred to
        // a category that did not exist and iOS ignored it silently.
        NotificationService.shared.registerNotificationCategories()
        // Warm up georelay directory and refresh if stale (once/day)
        GeoRelayDirectory.shared.prefetchIfNeeded()
    }

    private var chatViewModel: ChatViewModel { sonarStore.chatViewModel }

    var body: some Scene {
        WindowGroup {
            SonarRootView()
                .environmentObject(sonarStore)
                .onAppear {
                    NotificationDelegate.shared.bind(
                        chatViewModel: chatViewModel,
                        sonarStore: sonarStore
                    )
                    // Inject live Noise service into VerificationService to avoid creating new BLE instances
                    VerificationService.shared.configure(with: chatViewModel.meshService.getNoiseService())
                    // Prewarm Nostr identity and QR to make first VERIFY sheet fast
                    let nickname = chatViewModel.nickname
                    let idBridge = sonarStore.idBridge
                    DispatchQueue.global(qos: .utility).async {
                        let npub = try? idBridge.getCurrentNostrIdentity()?.npub
                        _ = VerificationService.shared.buildMyQRString(nickname: nickname, npub: npub)
                    }

                    appDelegate.chatViewModel = chatViewModel
                    #if os(iOS)
                    appDelegate.sonarStore = sonarStore
                    #endif

                    // Initialize network activation policy; will start Tor/Nostr only when allowed
                    NetworkActivationService.shared.start()

                    // Start presence service (will wait for Tor readiness)
                    GeohashPresenceService.shared.start()

                    // Check for shared content
                    checkForSharedContent()
                }
                .onOpenURL { url in
                    handleURL(url)
                }
                // Universal Links (https invite) arrive as a browsing activity,
                // not via onOpenURL. Dormant until the associated-domains
                // entitlement + hosted AASA file activate the domain.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { handleURL(url) }
                }
                #if os(iOS)
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .background:
                        // Keep BLE mesh running in background; BLEService adapts scanning automatically
                        // Stop advertising as a Unify receiver: iOS strips the BLE
                        // local name and restricts service-UUID advertising in the
                        // background, so receiving payments is foreground-only.
                        sonarStore.setForeground(false)
                        // Always send Tor to dormant on background for a clean restart later.
                        TorManager.shared.setAppForeground(false)
                        TorManager.shared.goDormantOnBackground()
                        // Stop geohash sampling while backgrounded
                        Task { @MainActor in
                            chatViewModel.endGeohashSampling()
                        }
                        // Proactively disconnect Nostr to avoid spurious socket errors while Tor is down
                        NostrRelayManager.shared.disconnect()
                        didEnterBackground = true
                    case .active:
                        // Restart services when becoming active
                        chatViewModel.meshService.startServices()
                        // Resume Unify receiver advertising (gated internally on a
                        // ready wallet) now that we're foreground again.
                        sonarStore.setForeground(true)
                        TorManager.shared.setAppForeground(true)
                        // On initial cold launch, Tor was just started in onAppear.
                        // Skip the deterministic restart the first time we become active.
                        let wasBackgrounded = didEnterBackground
                        if didHandleInitialActive && didEnterBackground {
                            if TorManager.shared.isAutoStartAllowed() && !TorManager.shared.isReady {
                                TorManager.shared.ensureRunningOnForeground()
                            }
                        } else {
                            didHandleInitialActive = true
                        }
                        didEnterBackground = false
                        if TorManager.shared.isAutoStartAllowed() {
                            Task.detached {
                                let _ = await TorManager.shared.awaitReady(timeout: 60)
                                await MainActor.run {
                                    // Rebuild proxied sessions to bind to the live Tor after readiness
                                    TorURLSession.shared.rebuild()
                                    // Reconnect Nostr via fresh sessions; will gate until Tor 100%
                                    NostrRelayManager.shared.resetAllConnections()
                                }
                            }
                        } else if wasBackgrounded {
                            // Tor disabled: backgrounding disconnected Nostr above, so
                            // reconnect directly on foreground (no Tor readiness to await).
                            NostrRelayManager.shared.resetAllConnections()
                        }
                        checkForSharedContent()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // Check for shared content when app becomes active
                    checkForSharedContent()
                }
                #elseif os(macOS)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // App became active
                }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    NotificationCenter.default.post(name: .sonarMacOpenSearch, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appSettings) {
                Button("Sonar Settings...") {
                    NotificationCenter.default.post(name: .sonarMacOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Sonar") {
                Button("Search") {
                    NotificationCenter.default.post(name: .sonarMacOpenSearch, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("People Nearby") {
                    NotificationCenter.default.post(name: .sonarMacShowRadar, object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)
                Button("Profile") {
                    NotificationCenter.default.post(name: .sonarMacOpenProfile, object: nil)
                }
                .keyboardShortcut("2", modifiers: .command)
            }
        }
        #endif
    }

    private func handleURL(_ url: URL) {
        // The share extension opens `sonar://share` right after staging;
        // `bitchat://share` stays accepted for older staged payloads.
        if (url.scheme == "sonar" || url.scheme == "bitchat") && url.host == "share" {
            checkForSharedContent()
        } else if let token = InviteShare.token(from: url) {
            // Covers both sonar://invite/sinvite1… and https://<host>/join#sinvite1…
            sonarStore.submitInviteLink(token)
        }
    }

    /// Hand anything the share extension staged to the recipient picker.
    ///
    /// This used to send immediately via `chatViewModel.sendMessage`, which
    /// with no private chat selected broadcasts to the **public mesh** — a
    /// shared link went out to everyone in range instead of the person the
    /// user meant. The app now always asks who it goes to.
    private func checkForSharedContent() {
        Task { @MainActor in
            sonarStore.ingestPendingShares()
        }
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate {
    private static let pushLog = Logger(subsystem: "sh.hedwig.sonar", category: "push")

    weak var chatViewModel: ChatViewModel?
    weak var sonarStore: SonarAppStore?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Firebase powers the Breez wallet-wakeup push (breez/notify is FCM-only;
        // Firebase bridges FCM → APNs on iOS). The Transponder chat/call push stays
        // on the raw APNs token — see SonarPushRegistration. Guard on the (gitignored)
        // GoogleService-Info.plist so a build without it still launches — FCM /
        // offline-receive just stays disabled rather than crashing at startup.
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
            Messaging.messaging().delegate = self
            Self.pushLog.info("Firebase configured for Breez NDS")
        } else {
            Self.pushLog.warning("GoogleService-Info.plist missing; Breez NDS offline receive disabled")
        }
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // Transponder (chat/calls) uses the raw APNs token directly.
        SonarPushRegistration.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        // Firebase needs the APNs token to mint an FCM token (used for the Breez webhook).
        if FirebaseApp.app() != nil {
            Messaging.messaging().apnsToken = deviceToken
            refreshFCMToken(reason: "apns-token")
        }
    }

    // FCM token (re)issued — register it as the Breez NDS webhook target.
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        handleFCMToken(fcmToken, source: "delegate")
    }

    private func refreshFCMToken(reason: String) {
        Messaging.messaging().token { [weak self] token, error in
            if let error {
                Self.pushLog.warning("FCM token fetch failed after \(reason, privacy: .public): \(String(describing: error), privacy: .public)")
                return
            }
            guard let token else {
                Self.pushLog.warning("FCM token fetch returned nil after \(reason, privacy: .public)")
                return
            }
            self?.handleFCMToken(token, source: reason)
        }
    }

    private func handleFCMToken(_ fcmToken: String, source: String) {
        Self.pushLog.info("FCM token available from \(source, privacy: .public)")
        let wallet = (sonarStore?.wallet as? BridgedWallet)?.walletService
        SonarPushRegistration.shared.didReceiveFCMToken(fcmToken, wallet: wallet)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Logger(subsystem: "sh.hedwig.sonar", category: "push").error("APNS registration FAILED: \(error)")
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            SonarPushProcessor.process(
                userInfo: userInfo,
                marmot: sonarStore?.marmot,
                wallet: sonarStore?.wallet,
                fetchCompletionHandler: completionHandler
            )
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        chatViewModel?.applicationWillTerminate()
    }
}
#endif

#if os(macOS)
import AppKit

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    weak var chatViewModel: ChatViewModel?

    func applicationWillTerminate(_ notification: Notification) {
        chatViewModel?.applicationWillTerminate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
#endif

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    weak var chatViewModel: ChatViewModel?
    weak var sonarStore: SonarAppStore? {
        didSet {
            // A cold-launch notification tap can fire `didReceive` before the
            // root view's `.onAppear` wires `sonarStore`. When that happens we
            // stash `pendingPushRefresh`; consume it as soon as the store lands
            // so the catch-up refresh isn't silently dropped. Hop to @MainActor
            // because SonarAppStore/MarmotChatModel are main-actor-isolated (and
            // `pendingPushRefresh` is only ever touched from @MainActor here and
            // in `didReceive`).
            guard sonarStore != nil else { return }
            Task { @MainActor in
                guard self.pendingPushRefresh, let store = self.sonarStore else { return }
                self.pendingPushRefresh = false
                store.marmot.refreshAfterForeground()
            }
        }
    }
    /// Set when a Transponder/Marmot chat push is tapped before `sonarStore`
    /// has been wired (cold launch). Consumed in `sonarStore.didSet`. Only
    /// touched from @MainActor contexts (the tap callback and onAppear both
    /// run on the main thread).
    private var pendingPushRefresh = false
    /// Cold-launch taps can arrive before `bind` wires the store.
    private var pendingConversationId: String?
    private var pendingJumpMessageId: String?

    func bind(chatViewModel: ChatViewModel, sonarStore: SonarAppStore) {
        self.chatViewModel = chatViewModel
        self.sonarStore = sonarStore
        if let pending = pendingConversationId {
            let jump = pendingJumpMessageId
            pendingConversationId = nil
            pendingJumpMessageId = nil
            openConversation(pending, jumpMessageId: jump)
        }
    }

    private func openConversation(_ conversationId: String, jumpMessageId: String? = nil) {
        let id = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let jump = jumpMessageId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let jumpOrNil = (jump?.isEmpty == false) ? jump : nil
        guard let store = sonarStore else {
            pendingConversationId = id
            pendingJumpMessageId = jumpOrNil
            return
        }
        DispatchQueue.main.async {
            store.openConversationFromNotification(id, jumpMessageId: jumpOrNil)
        }
    }

    /// True when the tapped notification came from the Transponder/Marmot chat
    /// push path. The NSE copies the push userInfo onto the delivered content,
    /// so these keys survive to the tap. Mirrors
    /// `SonarNotificationService/NotificationService.isTransponderPush` — the
    /// Breez exclusion and lowercased source comparison must match so a Breez
    /// payment push can never trigger a Marmot chat refresh.
    private static func isBreezPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        let source = (userInfo["source"] as? String)?.lowercased()
        return source == "breez" || userInfo["notification_type"] != nil
    }

    private static func isTransponderChatPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        if isBreezPush(userInfo) { return false }
        if SonarNotificationHandoff.isMarmotWake(from: userInfo) { return true }
        let source = (userInfo["source"] as? String)?.lowercased()
        if source == "transponder" || source == "marmot" { return true }
        if userInfo["mip05"] != nil || userInfo["transponder"] != nil || userInfo["wn_nse_prototype"] != nil {
            return true
        }
        if let kind = userInfo["kind"] as? Int, kind == 446 { return true }
        if let kind = userInfo["kind"] as? String, kind == "446" { return true }
        return false
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let userInfo = response.notification.request.content.userInfo

        // Sonar local notifications carry `sonarConversationId`; private-message
        // notifications carry `peerID` (also mirrored as conversation id). The
        // Sonar root owns DM navigation — prefer that over the legacy
        // ChatViewModel private-chat path so the tap lands on the real chat.
        if let conversationId = SonarNotificationHandoff.conversationId(from: userInfo) {
            openConversation(
                conversationId,
                jumpMessageId: SonarNotificationHandoff.messageId(from: userInfo)
            )
        } else if identifier.hasPrefix("private-"),
                  let peerID = userInfo[SonarNotificationKeys.peerID] as? String {
            DispatchQueue.main.async {
                self.chatViewModel?.startPrivateChat(with: PeerID(str: peerID))
                NotificationService.shared.clearNotifications(forConversationIds: [peerID])
            }
        }
        // Handle deeplink (e.g., geohash activity)
        if let deep = userInfo["deeplink"] as? String, let url = URL(string: deep) {
            #if os(iOS)
            DispatchQueue.main.async { UIApplication.shared.open(url) }
            #else
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            #endif
        }
        // Tapping a Transponder/Marmot chat push: kick an immediate catch-up
        // sync so the user sees the pushed message instead of a stale list.
        if Self.isTransponderChatPush(userInfo) {
            Task { @MainActor in
                if let store = self.sonarStore {
                    store.marmot.refreshAfterForeground()
                } else {
                    // Cold-launch tap: the store isn't wired yet. Record intent;
                    // `sonarStore.didSet` consumes it once onAppear wires the store.
                    self.pendingPushRefresh = true
                }
            }
        }

        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let identifier = notification.request.identifier
        let userInfo = notification.request.content.userInfo

        if let conversationId = SonarNotificationHandoff.conversationId(from: userInfo) {
            Task { @MainActor in
                if self.sonarStore?.isConversationOpen(conversationId) == true ||
                    self.chatViewModel?.selectedPrivateChatPeer == PeerID(str: conversationId) {
                    // Already viewing this chat — consume rather than banner.
                    NotificationService.shared.clearNotifications(
                        forConversationIds: [conversationId]
                    )
                    completionHandler([])
                } else {
                    completionHandler([.banner, .sound])
                }
            }
            return
        }
        // Suppress geohash activity notification if we're already in that geohash channel
        if identifier.hasPrefix("geo-activity-"),
           let deep = userInfo["deeplink"] as? String,
           let gh = deep.components(separatedBy: "/").last {
            if case .location(let ch) = LocationChannelManager.shared.selectedChannel, ch.geohash == gh {
                completionHandler([])
                return
            }
        }

        // Show notification in all other cases
        completionHandler([.banner, .sound])
    }
}
