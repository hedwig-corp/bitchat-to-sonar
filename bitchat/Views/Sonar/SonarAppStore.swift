//
// SonarAppStore.swift
// bitchat
//
// Live app store for the Sonar UI. Keeps the published surface the Sonar
// screens consume (channels / DM rows / nearby peers / transcripts /
// identity), but backs every value with the real services:
//   - ChatViewModel (BLE mesh + geohash channels + private chats)
//   - LocationStateManager (location channels for the current position)
//   - NostrRelayManager (online state)
//   - MarmotChatModel (White Noise / MLS secure chats over Nostr)
//
// No demo data: everything rendered comes from the running services.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation
import SwiftUI

// MARK: - Routes (stack entries below home)

enum SonarRoute: Hashable {
    case channel(String)
    case dm(String)
    case nearby
    case settings
    case profile
}

// MARK: - View models consumed by the screens

enum SNVia: String {
    case mesh
    case internet

    /// Plain-language transport name used in delivery-state lines and subs.
    var label: String {
        switch self {
        case .mesh: return "Bluetooth"
        case .internet: return "internet"
        }
    }
}

/// Payment payload of a chat message that decoded as a ⚡PAY sealed coin
/// (docs/SONAR-PAYMENTS.md). State comes from the local SonarPayLedger.
struct SNPayInfo: Equatable {
    let id: String          // payment uuid
    let sats: Int64
    let state: SonarPayEntry.State
}

struct SNMessage: Identifiable, Equatable {
    var id: String = UUID().uuidString
    var mine: Bool = false
    var action: Bool = false
    var author: String?
    var text: String
    var time: String
    var via: SNVia?
    var state: String?
    /// Non-nil = render as a PayBubble instead of a text bubble.
    var pay: SNPayInfo?
}

/// A public channel row: the `#mesh` channel or one geohash level around the
/// current location.
struct SNChannelItem: Identifiable {
    let id: String          // "mesh" or "geo:<geohash>"
    let name: String        // humanized place name (or level + geohash fallback)
    let sub: String         // header subtitle, e.g. "Public · 3 here now"
    let preview: String     // home row second line
    let count: Int
    let channel: ChannelID
}

/// A person: a mesh peer (direct / relayed / unreachable mutual favorite)
/// or a Marmot secure-chat counterpart.
struct SNPeerItem: Identifiable {
    let id: String          // PeerID.id, or "marmot:<groupId>"
    let name: String
    let inRange: Bool       // reachable over Bluetooth right now
    let bars: Int
    let hint: String
    let detail: String
    let angle: Double       // deterministic radar angle (degrees)
    let r: Double           // radar ring radius
    var sonar: Bool = false // announced a Sonar discovery profile (npub)
    /// A Unify Wallet user discovered over Bluetooth (payments-only, no chat).
    /// `id` is the Unify peripheral identifier; tapping offers only "Send sats".
    var unify: Bool = false
    /// Deterministic avatar seed: nil = seed by name. Set to a stable per-peer
    /// id (the Unify peripheral id) so two Unify peers that share a display
    /// name (both "Unify user") still get distinct hue + identicon.
    var avatarSeed: String? = nil
}

/// A peer's Sonar discovery profile (verified announce, type 0x53):
/// their White Noise / Marmot identity plus optional payment address.
struct SonarPeerProfile: Equatable, Codable {
    let npub: String        // bech32 npub1…
    let bip353: String?     // payment address (user@domain)
    let capabilities: UInt8
}

/// A row in the home "Messages" section: a bitchat private chat or a Marmot group.
struct SNDMRow: Identifiable {
    let id: String          // PeerID.id, or "marmot:<groupId>"
    let title: String
    let preview: String
    let time: String
    let unread: Bool
    let presence: Bool      // in Bluetooth range
    let verified: Bool
    let isMarmot: Bool
    let lastDate: Date?
}

/// Real verification data for the verify sheet.
struct SNVerifyInfo {
    let available: Bool
    let safety: [String]    // 12 five-digit groups derived from both parties' keys
    let publicKey: String   // peer key material revealed by "Show public key"
    let note: String?       // shown instead of the grid when unavailable
}

// MARK: - Store

@MainActor
final class SonarAppStore: ObservableObject {
    private enum Keys {
        static let onboarded = "sonar.onboarding.complete"
        static let mode = "sonar.appearance.mode"
        static let marmotVerified = "sonar.verified.marmot"
        static let bip353 = "sonar.bip353"
        /// Thread-safe flag read by the BLE announce provider to gate the
        /// ⚡PAY capability on a configured, receive-capable wallet.
        static let walletConfigured = "sonar.wallet.configured"
        static let legacyDemoState = "sn_proto_v1" // removed prototype persistence
        /// Persisted Sonar profiles ([fingerprint: SonarPeerProfile] JSON) so a
        /// peer's npub↔identity link survives restarts (one folded conversation).
        static let sonarProfiles = "sonar.peerProfiles.v1"
    }

    static let marmotIDPrefix = "marmot:"
    /// SNPeerItem id prefix for a Unify Wallet peer discovered over Bluetooth.
    /// The remainder is the Unify peripheral identifier (UnifyPeer.id).
    static let unifyIDPrefix = "unify:"

    let chatViewModel: ChatViewModel
    let marmot: MarmotChatModel
    let idBridge: NostrIdentityBridge
    /// Ad-hoc Bluetooth discovery of Unify Wallet users (payments-only). Owns
    /// its own CBCentralManager, separate from the mesh BLEService.
    let unify: UnifyNearbyService
    /// The mirror RECEIVER role: advertises Sonar as a Unify payment receiver
    /// (so a Unify user can pay us). Owns its own CBPeripheralManager, separate
    /// from the mesh BLEService and from `unify`'s central. Advertises only
    /// while the wallet is ready AND the app is foreground.
    let unifyReceiver: UnifyReceiverService
    /// Whether the app is in the foreground (set by BitchatApp scenePhase).
    /// Receiver advertising is gated on this AND a ready wallet.
    private var isForeground = true
    /// Lightning wallet behind the payments UI; UnconfiguredWallet until the
    /// real bridge (Services/WalletBridgeService) is injected.
    let wallet: SonarWalletProviding
    /// Local state of every ⚡PAY coin sent/received (docs/SONAR-PAYMENTS.md).
    let payLedger: SonarPayLedger
    private let keychain: KeychainManagerProtocol
    private let locationManager = LocationChannelManager.shared
    private let relayManager = NostrRelayManager.shared
    private let defaults = UserDefaults.standard

    /// Navigation stack below the home root.
    @Published var path: [SonarRoute] = []
    @Published private(set) var onboarded: Bool
    @Published private(set) var mode: String
    @Published private(set) var marmotVerified: [String: Bool]
    /// Sonar discovery profiles received from nearby peers, keyed by PeerID.id.
    /// LIVE only (the short PeerID rotates) — see `sonarProfilesByFingerprint`
    /// for the persisted, restart-surviving copy.
    @Published private(set) var sonarProfiles: [String: SonarPeerProfile] = [:]
    /// Persisted Sonar profiles keyed by the peer's STABLE Noise fingerprint, so
    /// the npub↔peer link survives a restart / BLE-down. This keeps a Sonar
    /// peer's mesh (Noise) and White Noise (Marmot) legs folded into ONE
    /// conversation even when the live 0x53 announce isn't currently arriving.
    private var sonarProfilesByFingerprint: [String: SonarPeerProfile] = [:]
    /// Our optional BIP-353 payment address ("" = unset, TLV omitted).
    @Published private(set) var bip353: String
    /// Mirrors wallet.state for the UI (balance row, PaySheet, claims).
    @Published private(set) var walletState: SonarWalletState
    /// Radar "Send sats" quick-pay: the DM screen opens with the PaySheet up.
    private var pendingPayPeer: String?

    private var cancellables = Set<AnyCancellable>()
    /// Texts queued for a Sonar peer (keyed by npub) while their White
    /// Noise group is being created on first out-of-range send.
    private var pendingMarmotSends: [String: [String]] = [:]
    /// Chat-message ids whose ⚡PAY control lines were already processed.
    private var scannedPayMessageIDs = Set<String>()

    convenience init() {
        let keychain = KeychainManager()
        let idBridge = NostrIdentityBridge()
        self.init(
            chatViewModel: ChatViewModel(
                keychain: keychain,
                idBridge: idBridge,
                identityManager: SecureIdentityStateManager(keychain)
            ),
            marmot: MarmotChatModel(keychain: keychain),
            keychain: keychain,
            idBridge: idBridge,
            wallet: Self.makeWallet()
        )
    }

    private static func makeWallet() -> SonarWalletProviding {
        #if os(iOS)
        return BridgedWallet()
        #else
        return UnconfiguredWallet()
        #endif
    }

    init(
        chatViewModel: ChatViewModel,
        marmot: MarmotChatModel,
        keychain: KeychainManagerProtocol,
        idBridge: NostrIdentityBridge,
        wallet: SonarWalletProviding = UnconfiguredWallet(),
        payLedger: SonarPayLedger = SonarPayLedger(),
        unify: UnifyNearbyService = UnifyNearbyService(),
        unifyReceiver: UnifyReceiverService = UnifyReceiverService()
    ) {
        self.chatViewModel = chatViewModel
        self.marmot = marmot
        self.keychain = keychain
        self.idBridge = idBridge
        self.wallet = wallet
        self.payLedger = payLedger
        self.unify = unify
        self.unifyReceiver = unifyReceiver
        walletState = wallet.state

        // Unify receiver (mirror role): serve an AMOUNTLESS BOLT12 offer behind
        // the user's nickname so a Unify user can pay us. The offer is fetched
        // lazily when advertising starts; the wallet façade is the only source.
        let walletRef = wallet
        unifyReceiver.offerProvider = { try? await walletRef.createOffer() }
        let chatRef = chatViewModel
        unifyReceiver.nameProvider = { [weak chatRef] in
            let nick = chatRef?.nickname.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return nick.isEmpty ? nil : nick
        }
        onboarded = UserDefaults.standard.bool(forKey: Keys.onboarded)
        mode = UserDefaults.standard.string(forKey: Keys.mode) ?? "dark"
        marmotVerified = (UserDefaults.standard.dictionary(forKey: Keys.marmotVerified) as? [String: Bool]) ?? [:]
        bip353 = UserDefaults.standard.string(forKey: Keys.bip353) ?? ""
        // Drop the old prototype demo blob if it is still around.
        defaults.removeObject(forKey: Keys.legacyDemoState)

        // The screens read computed properties off this store; republish
        // whenever any underlying service changes.
        republish(chatViewModel.objectWillChange)
        republish(chatViewModel.unifiedPeerService.objectWillChange)
        republish(marmot.objectWillChange)
        republish(locationManager.objectWillChange)
        republish(relayManager.objectWillChange)
        // Unify nearby payments: republish discovered-peer changes into the radar.
        republish(unify.objectWillChange)
        // Money display: re-render every amount when the mode/currency/rate
        // changes (fiat<->bitcoin toggle, currency picker, live-rate arrival).
        republish(wallet.moneyDisplayChanged)

        // Sonar discovery: collect verified peer profiles announced over the
        // mesh, and start announcing ours once the Marmot npub is known.
        NotificationCenter.default.publisher(for: .sonarPeerProfileUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.handleSonarProfileNotification(note) }
            .store(in: &cancellables)
        marmot.$npub
            .receive(on: DispatchQueue.main)
            .sink { [weak self] npub in
                guard let self else { return }
                self.wireSonarProfileProvider(npub)
                // Publish our kind-0 profile (NIP-01) so peers resolve our
                // nickname instead of our npub. MIP-00 identity == Nostr pubkey.
                if npub != nil { self.marmot.publishProfile(name: self.chatViewModel.nickname) }
                // The wallet derives from the same identity (nsec); once the
                // Marmot identity exists, (re)attempt the deferred wallet setup.
                #if os(iOS)
                if npub != nil { (self.wallet as? BridgedWallet)?.retrySetup() }
                #endif
            }
            .store(in: &cancellables)
        // Messages typed to an out-of-range Sonar peer before their White
        // Noise group exists are queued; flush once the group appears.
        marmot.$groups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.flushPendingMarmotSends() }
            .store(in: &cancellables)

        // Payments: mirror the wallet state and watch both transcript
        // stores for incoming ⚡PAY control lines (claim/settle/reveal).
        republish(payLedger.objectWillChange)
        wallet.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.walletState = state
                // Gate the advertised ⚡PAY capability on a receive-capable wallet.
                let configured: Bool
                if case .ready = state { configured = true } else { configured = false }
                UserDefaults.standard.set(configured, forKey: Keys.walletConfigured)
                // Start/stop the Unify receiver as the wallet becomes (un)ready.
                self.updateReceiverAdvertising()
            }
            .store(in: &cancellables)
        // Seed the flag from the current state so the first announce is correct.
        if case .ready = wallet.state {
            UserDefaults.standard.set(true, forKey: Keys.walletConfigured)
        } else {
            UserDefaults.standard.set(false, forKey: Keys.walletConfigured)
        }
        // Seed receiver advertising from the current state (foreground at launch).
        updateReceiverAdvertising()
        chatViewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.processIncomingPayLines() }
            .store(in: &cancellables)
        marmot.$messagesByGroup
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.processIncomingPayLines() }
            .store(in: &cancellables)

        // Restore persisted Sonar profiles so a peer's mesh + White Noise legs
        // stay folded into one conversation across restarts (before dmRows runs).
        hydrateSonarProfiles()

        if onboarded {
            marmot.connectIfNeeded()
            if locationManager.permissionState == .authorized {
                locationManager.refreshChannels()
            }
            // Unify scanning is started on demand while the radar is visible
            // (see nearbyAppeared/Disappeared) to avoid a continuous high-power
            // BLE scan on top of the mesh.
        }

        #if DEBUG
        // Init probe (only when a debug launch arg is present): pull
        // <AppSupport>/sonar-debug.txt to confirm the store init ran and that the
        // launch args reached UserDefaults. NB: pass app args after a `--` so
        // devicectl doesn't swallow `-sonar.debug.*` as its own options, e.g.
        // `devicectl … process launch --terminate-existing --device <id> -- \
        //   <bundle> -sonar.debug.sendMarmot "<npub>|<text>"`.
        if ["sonar.debug.sendMarmot", "sonar.debug.sendMeshDM", "sonar.debug.route"]
            .contains(where: { defaults.string(forKey: $0) != nil }) {
            writeDebugReport("init onboarded=\(onboarded) sendMarmot=\(defaults.string(forKey: "sonar.debug.sendMarmot") ?? "nil") sendMeshDM=\(defaults.string(forKey: "sonar.debug.sendMeshDM") ?? "nil")")
        }
        // Smoke-test hook: `simctl launch <sim> <bundle> -sonar.debug.route
        // settings` lands in the argument domain (volatile, this launch
        // only) and deep-opens a screen for screenshot verification.
        if onboarded, let route = defaults.string(forKey: "sonar.debug.route") {
            switch route {
            case "settings": path = [.settings]
            case "nearby": path = [.nearby]
            default: break
            }
        }
        // Smoke-test hook (on-device, USB): launch with
        // `-sonar.debug.sendMeshDM "<text>"` to send a private mesh DM to the
        // first connected/reachable peer ~12s after launch (once BLE has had
        // time to connect + handshake). Logs the target peerID + text so the
        // send/receive can be confirmed from device logs without UI automation.
        if onboarded, let text = defaults.string(forKey: "sonar.debug.sendMeshDM"), !text.isEmpty {
            scheduleDebugMeshDM(text)
        }
        // `-sonar.debug.sendMarmot "<text>"`: force the White Noise (Marmot) path
        // to the first discovered Sonar peer ~25s after launch (after 0x53
        // discovery has populated its npub). This exercises the BLE→White Noise
        // fallback transport directly, independent of BLE reachability.
        if onboarded, let raw = defaults.string(forKey: "sonar.debug.sendMarmot"), !raw.isEmpty {
            // Single launch arg (two devicectl `-key value` pairs parse
            // unreliably). Format "<npub1…>|<text>" → DIRECT White Noise send to
            // that npub (bypasses BLE 0x53 discovery, verifies the Marmot/relay
            // transport device-to-device). Plain "<text>" → send to the first
            // discovered Sonar peer.
            if raw.hasPrefix("npub1"), let sep = raw.firstIndex(of: "|") {
                let npub = String(raw[raw.startIndex..<sep])
                let text = String(raw[raw.index(after: sep)...])
                scheduleDebugMarmotDirect(text, npub: npub)
            } else {
                scheduleDebugMarmot(raw)
            }
        }
        #endif
    }

    #if DEBUG
    /// Append a line to <AppSupport>/sonar-debug.txt — reliably pullable with
    /// `devicectl device copy from` when os_log streaming is unavailable.
    private func writeDebugReport(_ line: String) {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return }
        let url = base.appendingPathComponent("sonar-debug.txt")
        let stamped = line + "\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Direct White Noise send to an explicit npub (bypasses BLE 0x53 discovery).
    /// Retries the send and writes the Marmot connect/group state to a file each
    /// attempt so the relay round-trip can be diagnosed without iOS log streaming.
    private func scheduleDebugMarmotDirect(_ text: String, npub: String, attempt: Int = 0, sent: Bool = false) {
        let delay: Double = attempt == 0 ? 14 : 8
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let grp = self.marmotGroup(forNpub: npub)
            let connected = self.marmot.npub != nil
            self.writeDebugReport("marmotDirect attempt=\(attempt) connected=\(connected) err=\(self.marmot.errorText ?? "nil") groups=\(self.marmot.groups.count) groupForNpub=\(grp?.id ?? "none") sent=\(sent)")
            var didSend = sent
            if !sent && connected {
                self.sendOverMarmot(text, npub: npub)
                didSend = true
            }
            if attempt < 6 { self.scheduleDebugMarmotDirect(text, npub: npub, attempt: attempt + 1, sent: didSend) }
        }
    }

    private func scheduleDebugMarmot(_ text: String, attempt: Int = 0) {
        // Retry until 0x53 discovery has populated a Sonar peer's npub (after a
        // --terminate-existing relaunch the mesh re-handshake + announce can take
        // longer than a single fixed delay), then force the White Noise path.
        let delay: Double = attempt == 0 ? 18 : 5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if let (peerID, profile) = self.sonarProfiles.first {
                SecureLogger.warning("🧪 debug.sendMarmot: White Noise send '\(text)' to npub \(profile.npub) (peer \(peerID))", category: .session)
                self.sendOverMarmot(text, npub: profile.npub)
            } else if attempt < 10 {
                self.scheduleDebugMarmot(text, attempt: attempt + 1)
            } else {
                SecureLogger.warning("🧪 debug.sendMarmot: gave up — no Sonar peer discovered (no npub)", category: .session)
            }
        }
    }
    #endif

    #if DEBUG
    private func scheduleDebugMeshDM(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self else { return }
            let my = self.chatViewModel.meshService.myPeerID
            let target = self.chatViewModel.allPeers.first {
                $0.peerID != my && ($0.isConnected || $0.isReachable)
            }
            guard let peer = target else {
                SecureLogger.warning("🧪 debug.sendMeshDM: no connected peer to send to", category: .session)
                return
            }
            SecureLogger.warning("🧪 debug.sendMeshDM: sending '\(text)' to peer \(peer.peerID.id) (\(peer.displayName))", category: .session)
            self.chatViewModel.startPrivateChat(with: peer.peerID)
            self.chatViewModel.sendPrivateMessage(text, to: peer.peerID)
        }
    }
    #endif

    private func republish<P: Publisher>(_ publisher: P) where P.Output == Void, P.Failure == Never {
        publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: Appearance

    var isDarkMode: Bool { mode == "dark" }

    func toggleMode() {
        mode = mode == "dark" ? "light" : "dark"
        defaults.set(mode, forKey: Keys.mode)
    }

    // MARK: Identity

    var nick: String { chatViewModel.nickname }

    func rename(_ nick: String) {
        chatViewModel.nickname = nick
        chatViewModel.validateAndSaveNickname()
        // Re-publish our kind-0 profile so peers see the new name.
        if marmot.npub != nil { marmot.publishProfile(name: chatViewModel.nickname) }
    }

    func completeOnboarding(nick: String) {
        rename(nick)
        onboarded = true
        defaults.set(true, forKey: Keys.onboarded)
        path = []
        marmot.connectIfNeeded()
    }

    /// Start Unify scanning while the Nearby/radar screen is visible; stop it
    /// when it goes away. Keeps the extra BLE scan off except when the user is
    /// actually looking for someone nearby to pay.
    func nearbyAppeared() { unify.start() }
    func nearbyDisappeared() { unify.stop() }

    // MARK: Unify receiver (mirror role: a Unify user can pay us)

    /// Foreground/background transitions from BitchatApp's scenePhase. iOS
    /// strips the BLE local name and restricts service-UUID advertising in the
    /// background, so we advertise the receiver only while foreground.
    func setForeground(_ foreground: Bool) {
        guard isForeground != foreground else { return }
        isForeground = foreground
        updateReceiverAdvertising()
    }

    /// Start advertising as a Unify receiver iff the wallet is ready AND the
    /// app is foreground; stop otherwise. Idempotent — the receiver itself
    /// coalesces repeat starts and only advertises once an offer is fetched.
    private func updateReceiverAdvertising() {
        let ready: Bool
        if case .ready = walletState { ready = true } else { ready = false }
        if ready && isForeground {
            unifyReceiver.start()
        } else {
            unifyReceiver.stop()
        }
    }

    /// Marmot (White Noise) npub once the secure-chat service connected.
    var npub: String? { marmot.npub }

    /// Truncated key shown by the settings profile card / profile screen:
    /// first 14 chars + "…" + last 6 chars; placeholder until connected.
    var shortKey: String {
        guard let npub = marmot.npub else { return "npub · connecting…" }
        return String(npub.prefix(14)) + "\u{2026}" + String(npub.suffix(6))
    }

    /// Noise identity fingerprint formatted like "a3f9 2c41 770e 5b2d".
    var myFingerprintDisplay: String {
        Self.fingerprintDisplay(chatViewModel.getMyFingerprint())
    }

    static func fingerprintDisplay(_ fingerprint: String) -> String {
        let head = String(fingerprint.lowercased().prefix(16))
        guard !head.isEmpty else { return "\u{2014}" }
        var groups: [String] = []
        var rest = Substring(head)
        while !rest.isEmpty {
            groups.append(String(rest.prefix(4)))
            rest = rest.dropFirst(4)
        }
        return groups.joined(separator: " ")
    }

    // MARK: Sonar discovery (mesh announce of npub + payment address)

    /// Discovered Sonar profile for a nearby peer (nil = plain bitchat peer).
    func sonarProfile(_ id: String) -> SonarPeerProfile? { sonarProfiles[id] }

    /// Plain-language network line for peer-row subtitles: which network the
    /// chat runs on and how far it can reach.
    func networkLabel(sonar: Bool, mutualFavorite: Bool) -> String {
        if sonar { return "Sonar · reaches anywhere" }
        return mutualFavorite ? "bitchat · reaches anywhere" : "bitchat · nearby only"
    }

    func networkLabel(forPeer id: String) -> String {
        networkLabel(sonar: sonarProfiles[id] != nil, mutualFavorite: isMutualFavorite(id))
    }

    /// Protocols the chat counterpart speaks — shown ONLY on the verify
    /// sheet's "Speaks" line; everywhere else uses plain-language labels.
    func speaks(_ id: String) -> String {
        (marmotGroupId(id) != nil || sonarProfiles[id] != nil)
            ? "bitchat mesh + White Noise"
            : "bitchat mesh"
    }

    // MARK: Favorites (out-of-range internet delivery for bitchat peers)

    func isFavorite(_ id: String) -> Bool {
        chatViewModel.isFavorite(peerID: PeerID(str: id))
    }

    func isMutualFavorite(_ id: String) -> Bool {
        let peerID = PeerID(str: id)
        if let noiseKey = peerID.noiseKey {
            return FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey)?.isMutual ?? false
        }
        return chatViewModel.unifiedPeerService.getPeer(by: peerID)?.isMutualFavorite ?? false
    }

    func toggleFavorite(_ id: String) {
        chatViewModel.toggleFavorite(peerID: PeerID(str: id))
    }

    /// Start a Marmot (White Noise) secure chat with a Sonar-discovered peer
    /// using the npub from their verified discovery announce.
    func startSecureChat(withSonarPeer id: String) {
        guard let profile = sonarProfiles[id] else { return }
        startSecureChat(npub: profile.npub)
    }

    /// Update our BIP-353 payment address (empty = stop sharing one).
    /// A leading ₿ is stripped per BIP-353 display convention.
    func setBip353(_ address: String) {
        var trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("₿") { trimmed = String(trimmed.dropFirst()) }
        guard trimmed != bip353 else { return }
        bip353 = trimmed
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Keys.bip353)
        } else {
            defaults.set(trimmed, forKey: Keys.bip353)
        }
    }

    private func handleSonarProfileNotification(_ note: Notification) {
        guard let peerID = note.userInfo?[SonarDiscoveryUserInfoKey.peerID] as? String,
              let announce = note.userInfo?[SonarDiscoveryUserInfoKey.profile] as? SonarAnnouncePacket,
              let npub = try? Bech32.encode(hrp: "npub", data: announce.npub)
        else { return }
        let profile = SonarPeerProfile(
            npub: npub,
            bip353: announce.bip353,
            capabilities: announce.capabilities
        )
        if sonarProfiles[peerID] != profile {
            sonarProfiles[peerID] = profile
        }
        // Persist the npub↔peer link keyed by the STABLE Noise fingerprint, so the
        // mesh + White Noise legs stay one conversation across restarts / BLE-down.
        let fp = chatViewModel.getFingerprint(for: PeerID(str: peerID)) ?? peerID
        if sonarProfilesByFingerprint[fp] != profile {
            sonarProfilesByFingerprint[fp] = profile
            persistSonarProfiles()
        }
    }

    private func persistSonarProfiles() {
        guard let data = try? JSONEncoder().encode(sonarProfilesByFingerprint) else { return }
        defaults.set(data, forKey: Keys.sonarProfiles)
    }

    private func hydrateSonarProfiles() {
        guard let data = defaults.data(forKey: Keys.sonarProfiles),
              let map = try? JSONDecoder().decode([String: SonarPeerProfile].self, from: data)
        else { return }
        sonarProfilesByFingerprint = map
    }

    /// The Sonar profile for a peer id, preferring the live 0x53 announce and
    /// falling back to the persisted (by-fingerprint) copy — so a Sonar peer's
    /// White Noise leg is still recognized when it isn't currently advertising.
    func resolvedSonarProfile(_ id: String) -> SonarPeerProfile? {
        if let live = sonarProfiles[id] { return live }
        let fp = chatViewModel.getFingerprint(for: PeerID(str: id)) ?? id
        return sonarProfilesByFingerprint[fp]
    }

    /// The peer key (stable fingerprint) of a persisted/live Sonar peer whose
    /// npub matches `npub`, if any — used to fold a Marmot group into that peer's
    /// mesh conversation even with no live announce.
    func sonarPeerKey(forNpub npub: String) -> String? {
        if let live = sonarProfiles.first(where: { $0.value.npub == npub })?.key {
            return chatViewModel.getFingerprint(for: PeerID(str: live)) ?? live
        }
        return sonarProfilesByFingerprint.first(where: { $0.value.npub == npub })?.key
    }

    /// Inject our Sonar profile into BLEService once the Marmot identity is
    /// known. The provider runs on BLE's message queue, so it only captures
    /// plain values and reads UserDefaults (thread-safe) — never this store.
    private func wireSonarProfileProvider(_ npub: String?) {
        guard let ble = chatViewModel.meshService as? BLEService else { return }
        guard let npub,
              let decoded = try? Bech32.decode(npub),
              decoded.hrp == "npub", decoded.data.count == 32
        else {
            ble.sonarProfileProvider = nil
            return
        }
        let npubRaw = decoded.data
        let bip353Key = Keys.bip353
        let walletConfiguredKey = Keys.walletConfigured
        ble.sonarProfileProvider = {
            let stored = UserDefaults.standard.string(forKey: bip353Key)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return SonarLocalProfile(
                npub: npubRaw,
                bip353: (stored?.isEmpty == false) ? stored : nil,
                // Advertise ⚡PAY only when our wallet can actually receive.
                paymentsEnabled: UserDefaults.standard.bool(forKey: walletConfiguredKey)
            )
        }
    }

    // MARK: Connectivity (status chip + connection sheet)

    /// Online = Nostr relay sockets are up (internet reach), independent of mesh.
    var online: Bool { relayManager.isConnected }

    var connectedRelayCount: Int { relayManager.relays.filter(\.isConnected).count }

    /// Peers currently reachable over the Bluetooth mesh (direct or relayed).
    var meshCount: Int {
        let my = chatViewModel.meshService.myPeerID
        return chatViewModel.allPeers.filter { $0.peerID != my && ($0.isConnected || $0.isReachable) }.count
    }

    // MARK: Channels (home "Nearby channels")

    var locationPermissionDenied: Bool {
        locationManager.permissionState == .denied || locationManager.permissionState == .restricted
    }

    /// Location channels are ready once permission is granted and levels resolved.
    var locationReady: Bool {
        locationManager.permissionState == .authorized && !locationManager.availableChannels.isEmpty
    }

    func enableLocation() {
        locationManager.enableLocationChannels()
    }

    var channels: [SNChannelItem] {
        var items = [meshChannelItem()]
        for ch in locationManager.availableChannels {
            items.append(item(for: ch))
        }
        return items
    }

    func channelItem(_ chId: String) -> SNChannelItem {
        guard chId.hasPrefix("geo:") else { return meshChannelItem() }
        let geohash = String(chId.dropFirst(4))
        let ch = locationManager.availableChannels.first { $0.geohash == geohash }
            ?? GeohashChannel(level: Self.level(forLength: geohash.count), geohash: geohash)
        return item(for: ch)
    }

    private func meshChannelItem() -> SNChannelItem {
        let n = meshCount
        return SNChannelItem(
            id: "mesh",
            name: "Mesh",
            sub: "Public · \(n) in range",
            preview: n > 0 ? "\(n) people in Bluetooth range" : "Bluetooth · works without internet",
            count: n,
            channel: .mesh
        )
    }

    private func item(for ch: GeohashChannel) -> SNChannelItem {
        let count = chatViewModel.geohashParticipantCount(for: ch.geohash)
        let name = locationManager.locationNames[ch.level] ?? ch.displayName
        return SNChannelItem(
            id: "geo:" + ch.geohash,
            name: name,
            sub: "Public · \(count) here now",
            preview: "\(ch.level.displayName) · \(count) here now",
            count: count,
            channel: .location(ch)
        )
    }

    private static func level(forLength length: Int) -> GeohashChannelLevel {
        switch length {
        case 8...: return .building
        case 7: return .block
        case 6: return .neighborhood
        case 5: return .city
        case 4: return .province
        default: return .region
        }
    }

    func openChannel(_ item: SNChannelItem) {
        locationManager.select(item.channel)
        push(.channel(item.id))
    }

    /// Re-select on deep navigation so the timeline matches the screen.
    func ensureChannelSelected(_ chId: String) {
        let target = channelItem(chId).channel
        if locationManager.selectedChannel != target {
            locationManager.select(target)
        }
    }

    // MARK: Channel timeline + send

    func chMsgs(_ chId: String) -> [SNMessage] {
        let via: SNVia = chId == "mesh" ? .mesh : .internet
        return chatViewModel.messages.map { mapPublic($0, via: via) }
    }

    func sendCh(_ chId: String, _ text: String) {
        // sendMessage() routes to the private chat while one is selected.
        if chatViewModel.selectedPrivateChatPeer != nil {
            chatViewModel.endPrivateChat()
        }
        ensureChannelSelected(chId)
        chatViewModel.sendMessage(text)
    }

    private func mapPublic(_ m: BitchatMessage, via: SNVia) -> SNMessage {
        let time = Self.clock(m.timestamp)
        if m.sender == "system" || m.content.hasPrefix("* ") {
            return SNMessage(id: m.id, action: true, text: m.content, time: time)
        }
        // Identity-based self-detection (NOT nickname): for geohash channels
        // this compares senderPeerID against our per-geohash derived Nostr
        // identity (HMAC of the device seed), so own messages stay "mine"
        // after a nickname change. The old nick-equality check broke exactly
        // there — rename from "Vincenzo" to "Jimmy" and past messages stopped
        // being recognized as ours.
        let mine = chatViewModel.isSelfMessage(m)
        return SNMessage(
            id: m.id,
            mine: mine,
            author: m.sender,
            text: m.content,
            time: time,
            via: via,
            state: mine ? Self.stateText(m.deliveryStatus) : nil
        )
    }

    // MARK: Geohash channel → private DM (tap an author in the transcript)

    /// A geohash-channel participant resolved to a DM-able identity.
    struct SNChannelAuthor: Identifiable, Equatable {
        /// The DM route id ("nostr_<16hex>") passed to `.dm(...)`.
        let routeId: String
        /// The participant's full 64-char Nostr pubkey hex (needed for block).
        let pubkeyHex: String
        /// Display name, e.g. "alice#c3d4" (or "anon#7f21" when anonymous).
        let name: String
        var id: String { routeId }
    }

    /// Resolve the author of a geohash-channel message to a private-DM target.
    /// Returns nil when the message is ours, isn't a geohash message, or the
    /// author is no longer an active participant — in which case we can't
    /// recover their full pubkey (their per-location identity has left the
    /// channel), and the UI surfaces an "no longer here" toast instead.
    func channelAuthor(forMessage messageId: String) -> SNChannelAuthor? {
        guard let m = chatViewModel.messages.first(where: { $0.id == messageId }),
              let spid = m.senderPeerID, spid.isGeoChat,
              !chatViewModel.isSelfMessage(m) else { return nil }
        // The public message carries only the short id (first 8 hex chars);
        // recover the full pubkey from the live participant roster.
        let short = spid.bare.lowercased()
        guard let person = chatViewModel.visibleGeohashPeople()
            .first(where: { $0.id.lowercased().hasPrefix(short) }) else { return nil }
        let convKey = PeerID(nostr_: person.id)
        return SNChannelAuthor(routeId: convKey.id, pubkeyHex: person.id.lowercased(), name: person.displayName)
    }

    /// Open a private DM with a resolved geohash participant. Registers the
    /// recipient mapping (`startGeohashDM` — required before `sendGeohashDM`
    /// can resolve the recipient) and navigates to the DM screen.
    func openChannelDM(_ author: SNChannelAuthor) {
        chatViewModel.startGeohashDM(withPubkeyHex: author.pubkeyHex)
        push(.dm(author.routeId))
    }

    /// Block a geohash participant (persists across launches; their messages
    /// disappear from the channel).
    func blockChannelAuthor(_ author: SNChannelAuthor) {
        chatViewModel.blockGeohashUser(pubkeyHexLowercased: author.pubkeyHex, displayName: author.name)
    }

    // MARK: People (radar / compose)

    /// Real peers: connected (inner ring), mesh-relayed (middle ring) and
    /// mutual favorites currently unreachable over mesh (outer ring "ghosts",
    /// reachable over Nostr). Angles are deterministic from the peer id hash.
    var nearbyPeers: [SNPeerItem] {
        let my = chatViewModel.meshService.myPeerID
        var items: [SNPeerItem] = []
        for peer in chatViewModel.allPeers where peer.peerID != my {
            let h = snHash(peer.peerID.id)
            let angle = Double(h % 360)
            let jitter = Double((h >> 9) % 11) - 5
            // Sonar discovery peers carry their npub (and optionally a
            // payment address); subtitles end with the plain-language
            // network line ("Sonar · reaches anywhere" etc.).
            let sonar = sonarProfiles[peer.peerID.id] != nil
            let network = networkLabel(sonar: sonar, mutualFavorite: peer.isMutualFavorite)
            if peer.isConnected {
                items.append(SNPeerItem(
                    id: peer.peerID.id, name: peer.displayName, inRange: true, bars: 3,
                    hint: "Right here", detail: "Direct connection · " + network,
                    angle: angle, r: 66 + jitter, sonar: sonar
                ))
            } else if peer.isReachable {
                items.append(SNPeerItem(
                    id: peer.peerID.id, name: peer.displayName, inRange: true, bars: 2,
                    hint: "Nearby", detail: "Relayed through the mesh · " + network,
                    angle: angle, r: 118 + jitter, sonar: sonar
                ))
            } else if peer.isMutualFavorite {
                items.append(SNPeerItem(
                    id: peer.peerID.id, name: peer.displayName, inRange: false, bars: 0,
                    hint: "Out of range", detail: network,
                    angle: angle, r: 162 + jitter, sonar: sonar
                ))
            }
        }
        // Unify Wallet users discovered over Bluetooth (payments-only). They
        // are NOT mesh peers, so they sit on the outer ring with a plain-
        // language "pay only" label and a distinct badge. Tapping one offers
        // only "Send sats" — never a DM.
        for peer in unify.peers {
            let id = Self.unifyIDPrefix + peer.id
            let h = snHash(peer.id)
            let angle = Double(h % 360)
            let jitter = Double((h >> 9) % 11) - 5
            items.append(SNPeerItem(
                id: id, name: peer.name, inRange: true, bars: unifyBars(peer.rssi),
                hint: "Unify", detail: "Unify \u{00B7} pay only",
                angle: angle, r: 150 + jitter, unify: true,
                // Seed the avatar by the stable peripheral id so two Unify users
                // are visually distinct even with the same "Unify user" name.
                avatarSeed: peer.id
            ))
        }
        return items
    }

    /// Map a Unify peer RSSI (dBm) onto the 0–3 radar signal bars.
    private func unifyBars(_ rssi: Int) -> Int {
        switch rssi {
        case (-60)...: return 3
        case (-75)..<(-60): return 2
        default: return 1
        }
    }

    func peerItem(_ id: String) -> SNPeerItem {
        if let groupId = marmotGroupId(id) {
            let group = marmot.groups.first { $0.id == groupId }
            return SNPeerItem(
                id: id,
                name: group.map { marmot.title(for: $0) } ?? "Secure chat",
                inRange: false, bars: 0,
                hint: "Secure chat", detail: "Encrypted chat · reaches anywhere",
                angle: 0, r: 0
            )
        }
        if let item = nearbyPeers.first(where: { $0.id == id }) { return item }
        if let unifyId = unifyPeerId(id) {
            let name = unify.peers.first { $0.id == unifyId }?.name
                ?? UnifyNearbyContract.advertisedNamePrefix
            return SNPeerItem(
                id: id, name: name, inRange: true, bars: 1,
                hint: "Unify", detail: "Unify \u{00B7} pay only",
                angle: 0, r: 0, unify: true, avatarSeed: unifyId
            )
        }
        let peerID = PeerID(str: id)
        return SNPeerItem(
            id: id,
            name: chatViewModel.nicknameForPeer(peerID),
            inRange: false, bars: 0,
            hint: "Out of range", detail: networkLabel(forPeer: id),
            angle: 0, r: 0, sonar: sonarProfiles[id] != nil
        )
    }

    /// The White Noise (Marmot) 1:1 group whose counterpart is `npub`.
    func marmotGroup(forNpub npub: String) -> MarmotService.MarmotGroup? {
        marmot.groups.first { $0.memberNpubs.contains(npub) }
    }

    func marmotGroupId(_ id: String) -> String? {
        id.hasPrefix(Self.marmotIDPrefix) ? String(id.dropFirst(Self.marmotIDPrefix.count)) : nil
    }

    // MARK: Messages (home rows)

    var dmRows: [SNDMRow] {
        // Mesh/bitchat chats, deduplicated by fingerprint (the same peer can
        // appear under a short mesh ID and its stable Noise key).
        var byKey: [String: SNDMRow] = [:]
        for (peerID, msgs) in chatViewModel.privateChats where !msgs.isEmpty {
            let row = meshRow(peerID: peerID, last: msgs.last)
            let key = chatViewModel.getFingerprint(for: peerID) ?? peerID.id
            if let existing = byKey[key],
               (existing.lastDate ?? .distantPast) >= (row.lastDate ?? .distantPast) {
                continue
            }
            byKey[key] = row
        }
        // Mutual favorites without a transcript yet are still reachable chats.
        for fav in chatViewModel.unifiedPeerService.mutualFavorites {
            let key = chatViewModel.getFingerprint(for: fav.peerID) ?? fav.peerID.id
            if byKey[key] == nil {
                byKey[key] = meshRow(peerID: fav.peerID, last: nil)
            }
        }
        // Marmot (White Noise) groups are internet-transport chats. A group
        // whose counterpart is a Sonar-discovered peer is the SAME
        // conversation as that peer's mesh chat: fold it into the peer row
        // (the DM screen renders both transcripts merged) instead of
        // showing a second row.
        var marmotRows: [SNDMRow] = []
        for group in marmot.groups {
            let msgs = marmot.messagesByGroup[group.id] ?? []
            let last = msgs.last
            let otherNpub = group.memberNpubs.first(where: { $0 != marmot.npub })
            // Live peer id (only when currently discovered over 0x53) lets us build
            // a fresh row; the persisted fingerprint still folds into an EXISTING
            // mesh row when the peer isn't advertising (BLE down / after restart).
            let liveSonarPeerId = otherNpub.flatMap { np in
                sonarProfiles.first(where: { $0.value.npub == np })?.key
            }
            let foldKey = otherNpub.flatMap { sonarPeerKey(forNpub: $0) }
            if let foldKey, let existing = byKey[foldKey] {
                // Same person as a mesh/bitchat chat → merge the White Noise leg
                // into that one row instead of showing a duplicate conversation.
                if let last, last.createdAt > (existing.lastDate ?? .distantPast) {
                    byKey[foldKey] = SNDMRow(
                        id: existing.id,
                        title: existing.title,
                        preview: Self.previewText(last.content),
                        time: Self.listTime(last.createdAt),
                        unread: existing.unread,
                        presence: existing.presence,
                        verified: existing.verified,
                        isMarmot: false,
                        lastDate: last.createdAt
                    )
                }
                continue
            }
            if let liveSonarPeerId, let foldKey {
                // Discovered Sonar peer with no mesh transcript yet → one row.
                let peerID = PeerID(str: liveSonarPeerId)
                let mesh = chatViewModel.meshService
                byKey[foldKey] = SNDMRow(
                    id: liveSonarPeerId,
                    title: chatViewModel.nicknameForPeer(peerID),
                    preview: last.map { Self.previewText($0.content) } ?? networkLabel(forPeer: liveSonarPeerId),
                    time: last.map { Self.listTime($0.createdAt) } ?? "",
                    unread: false,
                    presence: mesh.isPeerConnected(peerID) || mesh.isPeerReachable(peerID),
                    verified: isVerified(liveSonarPeerId),
                    isMarmot: false,
                    lastDate: last?.createdAt
                )
                continue
            }
            marmotRows.append(SNDMRow(
                id: Self.marmotIDPrefix + group.id,
                title: marmot.title(for: group),
                preview: last.map { Self.previewText($0.content) } ?? "Secure chat · reaches anywhere",
                time: last.map { Self.listTime($0.createdAt) } ?? "",
                unread: false,
                presence: false,
                verified: marmotVerified[group.id] ?? false,
                isMarmot: true,
                lastDate: last?.createdAt
            ))
        }
        let rows = Array(byKey.values) + marmotRows
        return rows.sorted {
            let l = $0.lastDate ?? .distantPast
            let r = $1.lastDate ?? .distantPast
            return l == r ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending : l > r
        }
    }

    private func meshRow(peerID: PeerID, last: BitchatMessage?) -> SNDMRow {
        let mesh = chatViewModel.meshService
        return SNDMRow(
            id: peerID.id,
            title: chatViewModel.nicknameForPeer(peerID),
            preview: last.map { Self.previewText($0.content) } ?? networkLabel(forPeer: peerID.id),
            time: last.map { Self.listTime($0.timestamp) } ?? "",
            unread: chatViewModel.unreadPrivateMessages.contains(peerID),
            presence: mesh.isPeerConnected(peerID) || mesh.isPeerReachable(peerID),
            verified: isVerified(peerID.id),
            isMarmot: false,
            lastDate: last?.timestamp
        )
    }

    // MARK: DM transcript + send

    /// How one chat line renders: regular text, a ⚡PAY sealed-coin bubble,
    /// or hidden (⚡PAYCLAIM/⚡PAYDONE are protocol control lines). Unknown
    /// ⚡PAY versions decode to nothing and fall through as plain text.
    private enum PayMapping {
        case notPay
        case hidden
        case bubble(SNPayInfo, SNVia)
    }

    private func payMapping(_ content: String, fallbackVia: SNVia) -> PayMapping {
        guard let line = SonarPayMessage.decode(content) else { return .notPay }
        guard case .pay(let pid, let sats) = line else { return .hidden }
        let entry = payLedger.entry(for: pid)
        // The coin renders with the transport it traveled over (recorded in
        // the ledger), not the conversation's current reachability.
        let via = entry.flatMap { SNVia(rawValue: $0.via) } ?? fallbackVia
        return .bubble(
            SNPayInfo(id: pid, sats: entry?.sats ?? sats, state: entry?.state ?? .sealed),
            via
        )
    }

    func dmMsgs(_ id: String) -> [SNMessage] {
        if let groupId = marmotGroupId(id) {
            return (marmot.messagesByGroup[groupId] ?? []).compactMap { m in
                switch payMapping(m.content, fallbackVia: .internet) {
                case .hidden:
                    return nil
                case .bubble(let pay, let payVia):
                    return SNMessage(
                        id: m.id, mine: m.isMine, text: m.content,
                        time: Self.clock(m.createdAt), via: payVia, pay: pay
                    )
                case .notPay:
                    return SNMessage(
                        id: m.id,
                        mine: m.isMine,
                        author: String(m.senderNpub.prefix(12)),
                        text: m.content,
                        time: Self.clock(m.createdAt),
                        via: .internet
                    )
                }
            }
        }
        let peerID = PeerID(str: id)
        let via = dmTransport(id)
        let my = chatViewModel.meshService.myPeerID
        var dated: [(Date, SNMessage)] = (chatViewModel.privateChats[peerID] ?? []).compactMap { m in
            let mine = m.senderPeerID == my
            switch payMapping(m.content, fallbackVia: via) {
            case .hidden:
                return nil
            case .bubble(let pay, let payVia):
                return (m.timestamp, SNMessage(
                    id: m.id, mine: mine, text: m.content,
                    time: Self.clock(m.timestamp), via: payVia, pay: pay
                ))
            case .notPay:
                return (m.timestamp, SNMessage(
                    id: m.id,
                    mine: mine,
                    author: m.sender,
                    text: m.content,
                    time: Self.clock(m.timestamp),
                    via: via,
                    state: mine ? Self.stateText(m.deliveryStatus) : nil
                ))
            }
        }
        // Sonar peer: the conversation continues over White Noise while out
        // of Bluetooth range. v1 keeps the two transcripts in separate
        // stores but RENDERS them as one, merged chronologically; the
        // White Noise leg always renders as internet (indigo).
        if let profile = resolvedSonarProfile(id), let group = marmotGroup(forNpub: profile.npub) {
            dated += (marmot.messagesByGroup[group.id] ?? []).compactMap { m in
                switch payMapping(m.content, fallbackVia: .internet) {
                case .hidden:
                    return nil
                case .bubble(let pay, let payVia):
                    return (m.createdAt, SNMessage(
                        id: m.id, mine: m.isMine, text: m.content,
                        time: Self.clock(m.createdAt), via: payVia, pay: pay
                    ))
                case .notPay:
                    return (m.createdAt, SNMessage(
                        id: m.id,
                        mine: m.isMine,
                        author: m.isMine ? nil : chatViewModel.nicknameForPeer(peerID),
                        text: m.content,
                        time: Self.clock(m.createdAt),
                        via: .internet
                    ))
                }
            }
            dated.sort { $0.0 < $1.0 }
        }
        return dated.map(\.1)
    }

    /// DM routing mirrors MessageRouter: Bluetooth when the peer is reachable
    /// over the mesh, otherwise NIP-17 over Nostr (internet).
    func dmTransport(_ id: String) -> SNVia {
        if marmotGroupId(id) != nil { return .internet }
        let peerID = PeerID(str: id)
        if peerID.isGeoDM { return .internet }
        let mesh = chatViewModel.meshService
        return (mesh.isPeerConnected(peerID) || mesh.isPeerReachable(peerID)) ? .mesh : .internet
    }

    func sendDm(_ id: String, _ text: String) {
        if let groupId = marmotGroupId(id) {
            marmot.send(text, to: groupId)
            return
        }
        // Sonar peer out of Bluetooth range: continue over White Noise,
        // creating the Marmot group on first send if it doesn't exist yet.
        if let profile = resolvedSonarProfile(id), dmTransport(id) == .internet {
            sendOverMarmot(text, npub: profile.npub)
            return
        }
        chatViewModel.sendPrivateMessage(text, to: PeerID(str: id))
    }

    private func sendOverMarmot(_ text: String, npub: String) {
        if let group = marmotGroup(forNpub: npub) {
            marmot.send(text, to: group.id)
            return
        }
        pendingMarmotSends[npub, default: []].append(text)
        marmot.connectIfNeeded()
        marmot.startChat(with: npub)
    }

    private func flushPendingMarmotSends() {
        guard !pendingMarmotSends.isEmpty else { return }
        for (npub, texts) in pendingMarmotSends {
            guard let group = marmotGroup(forNpub: npub) else { continue }
            pendingMarmotSends[npub] = nil
            for text in texts { marmot.send(text, to: group.id) }
        }
    }

    func openedDM(_ id: String) {
        if marmotGroupId(id) != nil {
            marmot.startPolling()
            Task { await marmot.refresh() }
        } else {
            chatViewModel.startPrivateChat(with: PeerID(str: id))
            // Sonar peers may carry a White Noise leg of the conversation:
            // keep that transcript fresh while the screen is open (resolved =
            // live OR persisted, so it works even when not currently in range).
            if resolvedSonarProfile(id) != nil {
                marmot.connectIfNeeded()
                marmot.startPolling()
                if marmot.npub != nil {
                    Task { await marmot.refresh() }
                }
            }
        }
    }

    func closedDM(_ id: String) {
        if marmotGroupId(id) != nil {
            marmot.stopPolling()
        } else {
            if resolvedSonarProfile(id) != nil {
                marmot.stopPolling()
            }
            if chatViewModel.selectedPrivateChatPeer == PeerID(str: id) {
                chatViewModel.endPrivateChat()
            }
        }
    }

    /// Start a Marmot (White Noise) secure chat by npub. The new group shows
    /// up in the Messages list once the welcome round-trips.
    func startSecureChat(npub: String) {
        marmot.connectIfNeeded()
        marmot.startChat(with: npub)
    }

    // MARK: Payments (⚡PAY sealed coins — docs/SONAR-PAYMENTS.md)

    /// Spendable balance once the wallet is ready; nil otherwise.
    var balanceSats: Int64? {
        if case .ready(let balance) = walletState { return balance }
        return nil
    }

    // MARK: Money display

    /// The EFFECTIVE money string for an amount (fiat when the user picked fiat
    /// AND a live rate exists, otherwise grouped sats). The single rendering
    /// path for every amount in the UI.
    func money(_ sats: Int64) -> String { wallet.format(sats: sats) }

    /// Secondary "≈ N sats" detail, shown only when the primary line is fiat
    /// (so the user can still see the bitcoin amount). nil otherwise.
    func moneySatsLine(_ sats: Int64) -> String? {
        wallet.effectiveShowsFiat ? sonarFormatSats(sats) : nil
    }

    /// Live fiat line for an amount; nil unless fiat is effectively shown.
    /// (Kept for call sites that want an optional secondary fiat line.)
    func fiatText(_ sats: Int64) -> String? {
        wallet.effectiveShowsFiat ? wallet.format(sats: sats) : nil
    }

    var displayMode: String { wallet.displayMode }
    var displayCurrency: String { wallet.displayCurrency }
    var canEnterFiat: Bool { wallet.hasLiveRate }
    func supportedCurrencies() -> [SonarCurrency] { wallet.supportedCurrencies() }

    /// Symbol for the selected currency (falls back to the code).
    var currencySymbol: String {
        supportedCurrencies().first { $0.code == displayCurrency }?.symbol ?? displayCurrency
    }

    func setDisplayMode(_ mode: String) { Task { await wallet.setDisplayMode(mode) } }
    func setDisplayCurrency(_ code: String) { Task { await wallet.setDisplayCurrency(code) } }

    /// Typed fiat text → sats at the live rate (only call when canEnterFiat).
    func parseFiat(_ text: String) -> Int64 {
        wallet.parseFiatInput(text, currencyCode: displayCurrency)
    }

    /// ⚡PAY lines may only travel to counterparts that speak them: Marmot
    /// (White Noise) chats and Sonar peers announcing the payments
    /// capability (discovery bit 1). Never bitchat-only peers.
    func paymentCapable(_ id: String) -> Bool {
        if marmotGroupId(id) != nil { return true }
        if let profile = sonarProfiles[id] {
            return profile.capabilities & SonarCapability.payments != 0
        }
        return false
    }

    /// Sends a sealed coin over the conversation's current rail. The balance
    /// is NOT deducted here — real sats only move at claim time, when the
    /// wallet pays the receiver's offer (honest deviation from the demo).
    func sendPay(_ id: String, sats: Int64) {
        guard sats > 0, paymentCapable(id) else { return }
        let uuid = UUID().uuidString.lowercased()
        let via = dmTransport(id)
        payLedger.record(SonarPayEntry(
            id: uuid, peerKey: id, sats: sats,
            direction: .outgoing, state: .sealed, via: via.rawValue
        ))
        sendDm(id, SonarPayMessage.pay(id: uuid, sats: sats).encoded())
    }

    /// Receiver tapped a sealed coin: create a BOLT12 offer and send the
    /// claim. Requires a ready wallet (the screen shows the setup sheet
    /// otherwise). sealed → claiming; reverts to sealed if the offer fails.
    func claimPay(_ convId: String, payId: String) {
        guard let entry = payLedger.entry(for: payId),
              entry.direction == .incoming, entry.state == .sealed,
              case .ready = walletState
        else { return }
        payLedger.transition(payId, to: .claiming)
        Task { [weak self] in
            guard let self else { return }
            do {
                let offer = try await self.wallet.createOffer()
                self.sendDm(convId, SonarPayMessage.claim(id: payId, offer: offer).encoded())
            } catch {
                self.payLedger.transition(payId, to: .sealed)
                SecureLogger.error("⚡PAY claim failed (createOffer): \(error)", category: .session)
            }
        }
    }

    /// Scans both transcript stores for ⚡PAY control lines from the
    /// counterpart. Ledger transitions are idempotent, so replaying
    /// transcripts after a relaunch cannot double-settle.
    private func processIncomingPayLines() {
        let my = chatViewModel.meshService.myPeerID
        for (peerID, msgs) in chatViewModel.privateChats {
            for m in msgs where m.senderPeerID != my {
                guard !scannedPayMessageIDs.contains(m.id) else { continue }
                scannedPayMessageIDs.insert(m.id)
                if let line = SonarPayMessage.decode(m.content) {
                    handlePayLine(line, convId: peerID.id, via: dmTransport(peerID.id))
                }
            }
        }
        for (groupId, msgs) in marmot.messagesByGroup {
            for m in msgs where !m.isMine {
                guard !scannedPayMessageIDs.contains(m.id) else { continue }
                scannedPayMessageIDs.insert(m.id)
                if let line = SonarPayMessage.decode(m.content) {
                    handlePayLine(line, convId: marmotConvId(forGroup: groupId), via: .internet)
                }
            }
        }
    }

    /// A Marmot group folded into a Sonar peer's conversation replies on
    /// that conversation id, so sendDm routes by current reachability.
    private func marmotConvId(forGroup groupId: String) -> String {
        if let group = marmot.groups.first(where: { $0.id == groupId }),
           let otherNpub = group.memberNpubs.first(where: { $0 != marmot.npub }),
           let sonarPeerId = sonarProfiles.first(where: { $0.value.npub == otherNpub })?.key {
            return sonarPeerId
        }
        return Self.marmotIDPrefix + groupId
    }

    private func handlePayLine(_ line: SonarPayMessage, convId: String, via: SNVia) {
        switch line {
        case .pay(let id, let sats):
            // Sealed coin arrived: remember it so it survives transcript loss.
            payLedger.record(SonarPayEntry(
                id: id, peerKey: convId, sats: sats,
                direction: .incoming, state: .sealed, via: via.rawValue
            ))

        case .claim(let id, let offer):
            // Counterpart claimed our coin: settle over Lightning, then
            // confirm. sealed → settling → claimed; failure reverts.
            guard let entry = payLedger.entry(for: id),
                  entry.direction == .outgoing, entry.state == .sealed
            else { return }
            payLedger.transition(id, to: .settling)
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.wallet.send(
                        destination: offer,
                        amountSats: entry.sats,
                        note: "Sonar payment \(id)"
                    )
                    self.payLedger.transition(id, to: .claimed)
                    self.sendDm(convId, SonarPayMessage.done(id: id).encoded())
                } catch {
                    self.payLedger.transition(id, to: .sealed)
                    SecureLogger.error("⚡PAY settle failed (wallet.send): \(error)", category: .session)
                }
            }

        case .done(let id):
            // Our claim settled: reveal the coin ("Added to your balance").
            guard let entry = payLedger.entry(for: id), entry.direction == .incoming else { return }
            payLedger.transition(id, to: .claimed)
        }
    }

    /// Maps a raw last-message content to the home-row preview ("₿ Payment"
    /// for any ⚡PAY line so the codec never leaks into list rows).
    static func previewText(_ content: String) -> String {
        SonarPayMessage.decode(content) != nil ? "\u{20BF} Payment" : content
    }

    /// Radar "Send sats": open the DM with the PaySheet already up.
    func quickPay(_ id: String) {
        pendingPayPeer = id
        openedDM(id)
        push(.dm(id))
    }

    /// Consumed by the DM screen on appear (one-shot).
    func consumePayRequest(_ id: String) -> Bool {
        guard pendingPayPeer == id else { return false }
        pendingPayPeer = nil
        return true
    }

    // MARK: Unify nearby payments (payments-only, no chat)

    /// True if `id` is a Unify peer id (prefix `unify:`).
    func isUnify(_ id: String) -> Bool { id.hasPrefix(Self.unifyIDPrefix) }

    /// The Unify peripheral identifier behind a `unify:` SNPeerItem id.
    func unifyPeerId(_ id: String) -> String? {
        id.hasPrefix(Self.unifyIDPrefix) ? String(id.dropFirst(Self.unifyIDPrefix.count)) : nil
    }

    /// Drives the "Send sats" sheet for a tapped Unify peer.
    enum UnifyPayPhase: Equatable {
        /// Fetching the served BIP321 URI over Bluetooth.
        case fetching
        /// Offer fetched; show the amount keypad (URI carried no amount).
        case amount(destination: String)
        /// Paying `sats` to `destination` over Lightning.
        case paying(destination: String, sats: Int64)
        /// Done.
        case sent(sats: Int64)
        /// Failed with a human message.
        case failed(String)
    }

    /// Sheet state for the Unify "Send sats" flow (nil = no sheet). The peer
    /// id stays alongside so the sheet can label itself.
    @Published var unifyPay: (peerId: String, phase: UnifyPayPhase)?

    /// Radar/list tap on a Unify peer chose "Send sats". Fetch the served
    /// BIP321 URI, parse the Lightning destination, then either pay directly
    /// (URI carried an amount) or prompt for an amount.
    func sendSatsToUnify(_ id: String) {
        guard let unifyId = unifyPeerId(id) else { return }
        // Honest gate: a Unify peer still shows, but paying needs a wallet.
        guard case .ready = walletState else {
            unifyPay = (id, .failed("Set up your wallet first to send money."))
            return
        }
        unifyPay = (id, .fetching)
        Task { [weak self] in
            guard let self else { return }
            do {
                let uri = try await self.unify.fetchPaymentURI(unifyId)
                guard let parsed = UnifyBIP321.parse(uri) else {
                    self.unifyPay = (id, .failed(UnifyNearbyError.noPayment.localizedDescription))
                    return
                }
                if let sats = parsed.amountSats {
                    self.payUnify(id, destination: parsed.lightning, sats: sats)
                } else {
                    self.unifyPay = (id, .amount(destination: parsed.lightning))
                }
            } catch {
                let msg = (error as? UnifyNearbyError)?.errorDescription ?? error.localizedDescription
                self.unifyPay = (id, .failed(msg))
            }
        }
    }

    /// User entered an amount on the Unify pay keypad.
    func confirmUnifyAmount(_ id: String, destination: String, sats: Int64) {
        guard sats > 0 else { return }
        payUnify(id, destination: destination, sats: sats)
    }

    /// Direct Lightning send to the Unify receiver's served offer/invoice. This
    /// is NOT the ⚡PAY sealed-coin chat path — Unify peers don't chat.
    private func payUnify(_ id: String, destination: String, sats: Int64) {
        unifyPay = (id, .paying(destination: destination, sats: sats))
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.wallet.send(destination: destination, amountSats: sats, note: "Unify nearby payment")
                self.unifyPay = (id, .sent(sats: sats))
            } catch {
                self.unifyPay = (id, .failed(error.localizedDescription))
            }
        }
    }

    /// Dismiss the Unify pay sheet.
    func dismissUnifyPay() { unifyPay = nil }

    // MARK: Verification (real fingerprints)

    func verifyInfo(for id: String) -> SNVerifyInfo {
        if let groupId = marmotGroupId(id) {
            let other = marmot.groups.first { $0.id == groupId }?
                .memberNpubs.first { $0 != marmot.npub }
            if let mine = marmot.npub, let other {
                return SNVerifyInfo(
                    available: true,
                    safety: Self.safetyNumbers(mine, other),
                    publicKey: other,
                    note: nil
                )
            }
            return SNVerifyInfo(
                available: false, safety: [], publicKey: "",
                note: "Connecting to the secure chat service — try again in a moment."
            )
        }
        let peerID = PeerID(str: id)
        if let peerFingerprint = chatViewModel.getFingerprint(for: peerID) {
            return SNVerifyInfo(
                available: true,
                safety: Self.safetyNumbers(chatViewModel.getMyFingerprint(), peerFingerprint),
                publicKey: peerFingerprint,
                note: nil
            )
        }
        return SNVerifyInfo(
            available: false, safety: [], publicKey: "",
            note: "Connect over Bluetooth at least once to compare safety numbers."
        )
    }

    /// 12 five-digit groups derived deterministically from both parties' key
    /// material (order-independent), so both phones show the same numbers.
    static func safetyNumbers(_ a: String, _ b: String) -> [String] {
        let combined = [a.lowercased(), b.lowercased()].sorted().joined(separator: "|")
        return (0..<12).map { String(format: "%05d", snHash(combined + ":" + String($0)) % 100_000) }
    }

    func isVerified(_ id: String) -> Bool {
        if let groupId = marmotGroupId(id) { return marmotVerified[groupId] ?? false }
        guard let fingerprint = chatViewModel.getFingerprint(for: PeerID(str: id)) else { return false }
        return chatViewModel.verifiedFingerprints.contains(fingerprint)
    }

    func markVerified(_ id: String) {
        if let groupId = marmotGroupId(id) {
            marmotVerified[groupId] = true
            defaults.set(marmotVerified, forKey: Keys.marmotVerified)
        } else {
            chatViewModel.verifyFingerprint(for: PeerID(str: id))
        }
    }

    var verifiedCount: Int {
        chatViewModel.verifiedFingerprints.count + marmotVerified.values.filter { $0 }.count
    }

    // MARK: Navigation

    func push(_ route: SonarRoute) {
        path.append(route)
    }

    func pop() {
        if !path.isEmpty { path.removeLast() }
    }

    // MARK: Commands (composer "/" layer)

    struct CommandContext {
        enum Kind { case ch, dm }
        let type: Kind
        let id: String
        let target: String
    }

    func onCommand(_ ctx: CommandContext, _ cmd: String) {
        if cmd == "who" || cmd == "msg" {
            push(.nearby)
            return
        }
        if cmd == "slap" {
            let who = nick.isEmpty ? "you" : nick
            let text = "* " + who + " slaps " + ctx.target + " around a bit with a large trout"
            // Posted through the real send path; "* " lines render as actions.
            if ctx.type == .ch {
                sendCh(ctx.id, text)
            } else {
                sendDm(ctx.id, text)
            }
        }
    }

    // MARK: Erase all chats (keep identity)

    /// Delete every conversation — mesh DMs, public/channel transcripts and
    /// White Noise (Marmot) secure chats — WITHOUT logging the user out. The
    /// Noise/Nostr/Marmot identities, nickname, favorites, onboarding and the
    /// Lightning wallet are preserved; only message history is erased. Use this
    /// to start fresh (e.g. to drop a broken Marmot group) without re-running
    /// onboarding. Contrast with `wipe()`, which destroys everything.
    func eraseAllChats() {
        path = []
        // Mesh DMs + public/channel transcripts (in-memory + on-disk store).
        chatViewModel.clearAllConversations()
        // White Noise / Marmot groups: wipe the encrypted DB then reconnect
        // with the SAME identity so new secure chats still work.
        Task { await marmot.eraseChatsKeepIdentity() }
        // Drop queued sends + pay-scan state that referenced the erased chats.
        pendingMarmotSends = [:]
        scannedPayMessageIDs = []
        pendingPayPeer = nil
        // ⚡PAY coins live inside the erased chats — clear the ledger too. The
        // Lightning wallet seed/balance is separate and is NOT touched.
        payLedger.wipe()
        objectWillChange.send()
    }

    // MARK: Emergency wipe (the real panic path)

    func wipe() {
        path = []
        marmot.stopPolling()
        // Wipes Noise/Nostr keys, all keychain data (incl. marmot-nsec),
        // messages, favorites, verified fingerprints and the nickname.
        // panicClearAllData() also erases the on-disk MessageStore; call it
        // here too so the local mesh-DM / channel transcripts are gone even if
        // that ordering ever changes.
        chatViewModel.panicClearAllData()
        MessageStore.shared.wipeAll()
        _ = keychain.deleteIdentityKey(forKey: "marmot-nsec")
        // Erase the encrypted Marmot (White Noise) SQLCipher database + its
        // Keychain DB key; also resets in-memory Marmot state.
        marmot.wipeDatabase()
        marmot.npub = nil
        marmot.groups = []
        marmot.messagesByGroup = [:]
        marmotVerified = [:]
        defaults.removeObject(forKey: Keys.marmotVerified)
        // Stop Sonar discovery announces and forget discovered profiles (live +
        // the persisted npub↔peer link).
        (chatViewModel.meshService as? BLEService)?.sonarProfileProvider = nil
        sonarProfiles = [:]
        sonarProfilesByFingerprint = [:]
        defaults.removeObject(forKey: Keys.sonarProfiles)
        // Stop scanning for Unify peers and clear the discovered list (no
        // secrets are stored, but the list must not survive a panic wipe).
        unify.stop()
        // Stop advertising as a Unify receiver (the served offer is derived
        // from the wallet seed being wiped below).
        unifyReceiver.stop()
        pendingMarmotSends = [:]
        // Forget every ⚡PAY coin and the Lightning wallet seed (separate
        // keychain service owned by SonarWalletKit).
        #if os(iOS)
        BridgedWallet.wipeWalletStorage()
        #endif
        payLedger.wipe()
        scannedPayMessageIDs = []
        pendingPayPeer = nil
        bip353 = ""
        defaults.removeObject(forKey: Keys.bip353)
        onboarded = false
        defaults.set(false, forKey: Keys.onboarded)
    }

    // MARK: Time formatting

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    static func listTime(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return clock(date) }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day,
           days < 7 {
            return weekdayFormatter.string(from: date)
        }
        return dayFormatter.string(from: date)
    }

    static func stateText(_ status: DeliveryStatus?) -> String? {
        switch status {
        case .sending: return "Sending"
        case .sent: return "Sent"
        case .delivered: return "Delivered"
        case .read: return "Read"
        case .failed: return "Couldn't send"
        case .partiallyDelivered(let reached, let total): return "Delivered to \(reached) of \(total)"
        case nil: return nil
        }
    }
}
