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
    static let groupID = "group.\(bundleID)"

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
        // Warm up georelay directory and refresh if stale (once/day)
        GeoRelayDirectory.shared.prefetchIfNeeded()
    }

    private var chatViewModel: ChatViewModel { sonarStore.chatViewModel }

    var body: some Scene {
        WindowGroup {
            SonarRootView()
                .environmentObject(sonarStore)
                .onAppear {
                    NotificationDelegate.shared.chatViewModel = chatViewModel
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
        if url.scheme == "bitchat" && url.host == "share" {
            checkForSharedContent()
        } else if let token = InviteShare.token(from: url) {
            // Covers both sonar://invite/sinvite1… and https://<host>/join#sinvite1…
            sonarStore.submitInviteLink(token)
        }
    }

    private func checkForSharedContent() {
        // Check app group for shared content from extension
        guard let userDefaults = UserDefaults(suiteName: BitchatApp.groupID) else {
            return
        }

        guard let sharedContent = userDefaults.string(forKey: "sharedContent"),
              let sharedDate = userDefaults.object(forKey: "sharedContentDate") as? Date else {
            return
        }

        // Only process if shared within configured window
        if Date().timeIntervalSince(sharedDate) < TransportConfig.uiShareAcceptWindowSeconds {
            let contentType = userDefaults.string(forKey: "sharedContentType") ?? "text"

            // Clear the shared content
            userDefaults.removeObject(forKey: "sharedContent")
            userDefaults.removeObject(forKey: "sharedContentType")
            userDefaults.removeObject(forKey: "sharedContentDate")
            // No need to force synchronize here

            // Send the shared content immediately on the main queue
            DispatchQueue.main.async {
                // An invite link shared into Sonar means "join", not "send".
                if let token = InviteShare.token(fromText: sharedContent) {
                    self.sonarStore.submitInviteLink(token)
                    return
                }
                if contentType == "url" {
                    // Try to parse as JSON first
                    if let data = sharedContent.data(using: .utf8),
                       let urlData = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                       let url = urlData["url"] {
                        // Send plain URL
                        self.chatViewModel.sendMessage(url)
                    } else {
                        // Fallback to simple URL
                        self.chatViewModel.sendMessage(sharedContent)
                    }
                } else {
                    self.chatViewModel.sendMessage(sharedContent)
                }
            }
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
        Self.pushLog.info("FCM token available from \(source, privacy: .public) (\(fcmToken.prefix(8))...)")
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

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let userInfo = response.notification.request.content.userInfo

        // Check if this is a private message notification
        if identifier.hasPrefix("private-") {
            // Get peer ID from userInfo
            if let peerID = userInfo["peerID"] as? String {
                DispatchQueue.main.async {
                    self.chatViewModel?.startPrivateChat(with: PeerID(str: peerID))
                }
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

        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let identifier = notification.request.identifier
        let userInfo = notification.request.content.userInfo

        // Check if this is a private message notification
        if identifier.hasPrefix("private-") {
            // Get peer ID from userInfo
            if let peerID = userInfo["peerID"] as? String {
                // Don't show notification if the private chat is already open
                // Access main-actor-isolated property via Task
                Task { @MainActor in
                    if self.chatViewModel?.selectedPrivateChatPeer == PeerID(str: peerID) {
                        completionHandler([])
                    } else {
                        completionHandler([.banner, .sound])
                    }
                }
                return
            }
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
