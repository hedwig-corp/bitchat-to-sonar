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
import AVFoundation
import Combine
import CryptoKit
import Foundation
import SonarCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private enum SonarCallAudioRoute {
    static func configure(active: Bool, speakerOn: Bool) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            if active {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
                try session.setActive(true)
                try session.overrideOutputAudioPort(speakerOn ? .speaker : .none)
            } else {
                try? session.overrideOutputAudioPort(.none)
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        } catch {
            SecureLogger.error("call audio route failed: \(error)", category: .session)
        }
        #endif
    }

    static func setSpeaker(_ speakerOn: Bool) {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(speakerOn ? .speaker : .none)
        } catch {
            SecureLogger.error("speaker route failed: \(error)", category: .session)
        }
        #endif
    }
}

// MARK: - Routes (stack entries below home)

enum SonarRoute: Hashable {
    case channel(String)
    case dm(String)
    case nearby
    case settings
    case profile
    /// Call route. Carries the DM peer id + kind.
    case call(String, video: Bool)
    case contactProfile(String, String)
    case groupInfo(String)
    case walletActivity
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

/// Payment payload of a chat message that decoded as a ⚡PAY receipt
/// (docs/SONAR-PAYMENTS.md). State comes from the local SonarPayLedger.
struct SNPayInfo: Equatable {
    let id: String          // payment uuid
    let sats: Int64
    let state: SonarPayEntry.State
    var direct: Bool = false
    var failed: Bool = false
}

/// A call kind (call.jsx `kind`). Drives icons + labels everywhere.
enum SNCallKind: String, Equatable, Codable {
    case voice
    case video
}

/// The descriptor of a finished call, rendered as a CallLog row inside the DM
/// transcript (call.jsx `CallLog`).
struct SNCallInfo: Equatable {
    let kind: SNCallKind
    /// The call never connected (secs == 0) ⇒ shown as a missed call (red).
    let missed: Bool
    /// `fmtCall(secs)` when the call connected, else nil.
    let dur: String?
}

func snCanonicalConversationTitle(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .lowercased()
}

func snInferUniquePeerKeyByTitle(
    groupTitle: String,
    peerTitles: [String: String],
    allGroupTitles: [String]
) -> String? {
    let title = snCanonicalConversationTitle(groupTitle)
    guard !title.isEmpty else { return nil }
    guard allGroupTitles.filter({ snCanonicalConversationTitle($0) == title }).count == 1 else {
        return nil
    }
    let matches = peerTitles.filter { snCanonicalConversationTitle($0.value) == title }
    guard matches.count == 1 else { return nil }
    return matches.first?.key
}

/// A stored call record: its timeline `date` (used to merge it
/// chronologically into the transcript) plus the prebuilt CallLog message.
struct SNCallRecord: Identifiable, Equatable {
    let id: String
    let date: Date
    let message: SNMessage
}

private struct SNStoredCallRecord: Codable {
    let id: String
    let date: Date
    let time: String
    let mine: Bool
    let kind: SNCallKind
    let missed: Bool
    let dur: String?

    init(_ record: SNCallRecord) {
        id = record.id
        date = record.date
        time = record.message.time
        mine = record.message.mine
        kind = record.message.call?.kind ?? .voice
        missed = record.message.call?.missed ?? true
        dur = record.message.call?.dur
    }

    var record: SNCallRecord {
        SNCallRecord(
            id: id,
            date: date,
            message: SNMessage(
                mine: mine,
                text: "",
                time: time,
                call: SNCallInfo(kind: kind, missed: missed, dur: dur)
            )
        )
    }
}

/// The in-flight P2P call the call screen renders. `incoming` ⇒ we are the callee
/// (show Accept/Decline); `phase` tracks the engine state machine.
struct SNActiveCall: Equatable {
    let callId: String
    /// The conversation id the ☎CALL signaling rides (DM peer id or Marmot conv).
    let convId: String
    /// The real-time rail the call was admitted on. Calls must not recalculate this
    /// through the normal chat fallback router while answer/end messages are in flight.
    let signalingVia: SNVia
    let peerName: String
    let video: Bool
    let incoming: Bool
    var phase: CallStateInfo
    var connectedSecs: Int = 0
    var muted: Bool = false
    var speakerOn: Bool = false
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
    /// Non-nil = render a compact CallLog row instead of a bubble (call.jsx).
    var call: SNCallInfo?
    /// Encrypted media attachments (White Noise / Marmot MIP-04). Non-empty ⇒
    /// render a media bubble (image inline, else a file chip).
    var media: [SNMediaItem] = []
    /// Non-nil = render as a sticker bubble instead of text.
    var stickerRef: MarmotService.MarmotStickerRef?
}

/// A media attachment on a Sonar message. `url` is the Blossom URL of the
/// CIPHERTEXT; `groupId` is the Marmot group needed to download + decrypt it.
struct SNMediaItem: Equatable {
    let url: String
    let mime: String
    let filename: String
    let groupId: String
    /// For BLE-mesh media (bitchat file transfer): the local file path on disk.
    /// When set, the bytes are loaded locally instead of downloaded from Blossom.
    var localPath: String? = nil
    var isImage: Bool { mime.hasPrefix("image/") }
    var isGif: Bool {
        mime.caseInsensitiveCompare("image/gif") == .orderedSame ||
        filename.lowercased().hasSuffix(".gif")
    }
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
    /// Short precision-tier label for the "Around you" ladder (design HereCard
    /// `here-scale`): "Mesh" or the geohash level (Block / Area / City / …).
    var tier: String = ""
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
    /// Marmot MLS group backing this row, even when the row id is a folded peer id.
    var marmotGroupId: String? = nil
}

/// A local contact that can be invited into a Marmot group.
struct SNGroupContact: Identifiable, Hashable {
    let id: String          // npub, so duplicates across radar/messages collapse.
    let title: String
    let subtitle: String
    let npub: String
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
        /// Persisted conversation id -> Marmot group id links. This lets a folded
        /// Sonar DM open its encrypted local transcript immediately after restart.
        static let marmotConversationGroups = "sonar.marmotConversationGroups.v1"
        /// Persisted local call-log rows ([conversation id: call records] JSON).
        static let callLogs = "sonar.callLogs.v1"
    }

    private static let maxStoredCallsPerConversation = 100
    private static let capabilitySettleWindow: TimeInterval = 1.5

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
    /// Local wallet payment activity for direct BOLT12 / Unify sends.
    let paymentActivityLedger: SonarPaymentActivityLedger
    private let keychain: KeychainManagerProtocol
    private let locationManager = LocationChannelManager.shared
    private let relayManager = NostrRelayManager.shared
    private let defaults = UserDefaults.standard

    /// Navigation stack below the home root.
    @Published var path: [SonarRoute] = []
    @Published var toast: String? = nil
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
    /// Folded DM id -> Marmot group id. DM rows often use a peer/fingerprint id,
    /// while the encrypted transcript is keyed by the Marmot MLS group id.
    private var marmotGroupIdsByConversationId: [String: String] = [:]
    /// Our optional BIP-353 payment address ("" = unset, TLV omitted).
    @Published private(set) var bip353: String
    /// Mirrors wallet.state for the UI (balance row and PaySheet).
    @Published private(set) var walletState: SonarWalletState
    /// Radar "Send sats" quick-pay: the DM screen opens with the PaySheet up.
    private var pendingPayPeer: String?
    /// Local call records, keyed by DM peer id (the same id the call route +
    /// dmMsgs use). Persisted locally so the transcript keeps completed/missed
    /// call rows across relaunches.
    @Published private(set) var callLogs: [String: [SNCallRecord]] = [:]
    /// Conversations currently checking their bounded local DB transcript. While
    /// this is set, the DM screen must not show a "new empty chat" state yet.
    @Published private(set) var localHydratingDMs: Set<String> = []

    /// The in-flight P2P call the [SonarCallScreen] renders, or nil. Driven by the
    /// real iroh/opus engine via `callWaitEvent`.
    @Published private(set) var activeCall: SNActiveCall?
    private var callStarted = false
    private var callLoopTask: Task<Void, Never>?
    private var callTickerTask: Task<Void, Never>?
    /// Ids of ☎CALL control messages already routed to the engine (dedup).
    private var scannedCallMessageIDs = Set<String>()

    private var cancellables = Set<AnyCancellable>()
    /// Texts queued for a Sonar peer (keyed by npub) while their White
    /// Noise group is being created on first out-of-range send.
    private var pendingMarmotSends: [String: [String]] = [:]
    private var pendingInviteLinks: [String] = []
    /// Per-conversation Marmot warm-up work started by openedDM. Home rows and
    /// destination onAppear can both fire; only one local hydrate/sync pass per
    /// chat should run at a time.
    private var openingDMTasks: [String: Task<Void, Never>] = [:]
    /// Per-conversation background relay reconciliation. Kept separate from
    /// `openingDMTasks` so a later open never waits for relay sync/backfill.
    private var refreshingDMTasks: [String: Task<Void, Never>] = [:]
    /// Chat-message ids whose ⚡PAY control lines were already processed.
    private var scannedPayMessageIDs = Set<String>()
    /// Stable mesh peer key -> first sighting time. We briefly hold unresolved
    /// fresh peers so their 0x53 Sonar capabilities can arrive before the UI
    /// commits to a plain Bitchat row.
    private var meshPeerFirstSeenAt: [String: Date] = [:]
    private var pendingCapabilityRefreshKeys = Set<String>()
    private var publishedCallDescriptor = false
    private var publishedBolt12Offer: String?
    private var publishingPaymentMetadata = false
    private var needsPaymentMetadataPublish = false
    private var refreshedKnownDescriptorsForRelaySession = false
    private var incomingWalletTask: Task<Void, Never>?

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
        #if os(iOS) || os(macOS)
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
        paymentActivityLedger: SonarPaymentActivityLedger = SonarPaymentActivityLedger(),
        unify: UnifyNearbyService = UnifyNearbyService(),
        unifyReceiver: UnifyReceiverService = UnifyReceiverService()
    ) {
        self.chatViewModel = chatViewModel
        self.marmot = marmot
        self.keychain = keychain
        self.idBridge = idBridge
        self.wallet = wallet
        self.payLedger = payLedger
        self.paymentActivityLedger = paymentActivityLedger
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
        callLogs = Self.loadCallLogs(from: defaults)

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
                // Bind the iroh call endpoint + start the event loop once we're
                // connected, so an incoming call rings without placing one first.
                if npub != nil { self.ensureCallStarted() }
                // The wallet derives from the same identity (nsec); once the
                // Marmot identity exists, (re)attempt the deferred wallet setup.
                #if os(iOS) || os(macOS)
                if npub != nil { (self.wallet as? BridgedWallet)?.retrySetup() }
                #endif
                if npub != nil { self.publishPaymentMetadataIfNeeded(force: true) }
                if npub != nil { self.drainPendingInviteLinks() }
            }
            .store(in: &cancellables)
        marmot.$relayConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self, connected else { return }
                self.publishPaymentMetadataIfNeeded(force: true)
                guard !self.refreshedKnownDescriptorsForRelaySession else { return }
                self.refreshedKnownDescriptorsForRelaySession = true
                self.refreshKnownContactDescriptors(clearMisses: true)
            }
            .store(in: &cancellables)
        // Messages typed to an out-of-range Sonar peer before their White
        // Noise group exists are queued; flush once the group appears.
        marmot.$groups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                DispatchQueue.main.async { [weak self] in
                    self?.flushPendingMarmotSends()
                }
            }
            .store(in: &cancellables)

        // Payments: mirror the wallet state and watch both transcript
        // stores for incoming ⚡PAY receipt control lines.
        republish(payLedger.objectWillChange)
        republish(paymentActivityLedger.objectWillChange)
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
                self.publishPaymentMetadataIfNeeded()
                self.updateWalletPaymentObservation()
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
        publishPaymentMetadataIfNeeded()
        updateWalletPaymentObservation()
        chatViewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.processIncomingPayLines(); self?.processIncomingCallLines() }
            .store(in: &cancellables)
        marmot.$messagesByGroup
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.cachePublishedUploadMedia()
                self.processIncomingPayLines()
                self.processIncomingCallLines()
                self.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Restore persisted Sonar profiles so a peer's mesh + White Noise legs
        // stay folded into one conversation across restarts (before dmRows runs).
        hydrateSonarProfiles()
        hydrateMarmotConversationGroups()

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
        // `-sonar.debug.sendMeshImage 1`: send a generated test JPEG to the first
        // connected/reachable mesh peer ~12s after launch over the bitchat file
        // transfer path (type 0x22). Verifies Sonar→stock-bitchat BLE media interop
        // without UI automation (the phone must be unlocked + Sonar foreground).
        if onboarded, let flag = defaults.string(forKey: "sonar.debug.sendMeshImage"), !flag.isEmpty {
            scheduleDebugMeshImage()
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

    private func scheduleDebugMeshImage(attempt: Int = 0) {
        let delay: Double = attempt == 0 ? 12 : 6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let my = self.chatViewModel.meshService.myPeerID
            let target = self.chatViewModel.allPeers.first {
                $0.peerID != my && ($0.isConnected || $0.isReachable)
            }
            guard let peer = target else {
                if attempt < 8 {
                    self.scheduleDebugMeshImage(attempt: attempt + 1)
                } else {
                    SecureLogger.warning("🧪 debug.sendMeshImage: no connected peer to send to", category: .session)
                    self.writeDebugReport("sendMeshImage gave up — no connected/reachable peer")
                }
                return
            }
            guard let jpeg = Self.debugTestJPEG() else {
                self.writeDebugReport("sendMeshImage: failed to render test JPEG")
                return
            }
            SecureLogger.warning("🧪 debug.sendMeshImage: sending \(jpeg.count)B JPEG to peer \(peer.peerID.id) (\(peer.displayName))", category: .session)
            self.writeDebugReport("sendMeshImage: \(jpeg.count)B → \(peer.peerID.id) (\(peer.displayName))")
            self.sendImageOverMesh(peer.peerID, data: jpeg)
        }
    }

    /// A small, valid JPEG generated in-process (cyan field + label) for the
    /// mesh-image smoke test. Returns nil on platforms without UIKit.
    private static func debugTestJPEG() -> Data? {
        #if canImport(UIKit)
        let size = CGSize(width: 240, height: 240)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor(red: 0.12, green: 0.74, blue: 0.89, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = "SONAR → bitchat"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 20),
                .foregroundColor: UIColor.white,
            ]
            let s = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2), withAttributes: attrs)
        }
        return image.jpegData(compressionQuality: 0.8)
        #else
        return nil
        #endif
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

    @MainActor
    func showToast(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toast == text { toast = nil }
        }
    }

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

    /// `nsec1…` backup of the current identity for the "Export private key"
    /// sheet (self-custody). Nil until the secure-chat identity has loaded.
    func exportNsec() async -> String? {
        await marmot.exportNsec()
    }

    /// Restore an existing account from a pasted `nsec1…` backup on the
    /// "I already have a key" onboarding path: import the identity, then finish
    /// onboarding. Throws on an invalid key.
    func restoreAccount(nsec: String) async throws {
        try await marmot.restoreIdentity(nsec: nsec)
        onboarded = true
        defaults.set(true, forKey: Keys.onboarded)
        path = []
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
        let cameToForeground = foreground && !isForeground
        isForeground = foreground
        updateReceiverAdvertising()
        if cameToForeground {
            refreshKnownContactDescriptors()
            publishedCallDescriptor = false
            publishedBolt12Offer = nil
            publishPaymentMetadataIfNeeded(force: true)
        }
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

    func submitInviteLink(_ token: String) {
        guard marmot.npub != nil else {
            pendingInviteLinks.append(token)
            return
        }
        Task {
            do {
                try await marmot.requestJoinViaLink(token: token)
                await MainActor.run { toast = "Join request sent" }
            } catch {
                await MainActor.run { toast = "Couldn't join: \(error.localizedDescription)" }
            }
        }
    }

    private func drainPendingInviteLinks() {
        let queued = pendingInviteLinks
        pendingInviteLinks.removeAll()
        for token in queued { submitInviteLink(token) }
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

    /// Known Sonar profile for a peer (live 0x53 when available, otherwise the
    /// persisted fingerprint link). Nil means a plain bitchat peer.
    func sonarProfile(_ id: String) -> SonarPeerProfile? { resolvedSonarProfile(id) }

    /// Plain-language network line for peer-row subtitles: which network the
    /// chat runs on and how far it can reach.
    func networkLabel(sonar: Bool, mutualFavorite: Bool) -> String {
        if sonar { return "Sonar · reaches anywhere" }
        return mutualFavorite ? "bitchat · reaches anywhere" : "bitchat · nearby only"
    }

    func networkLabel(forPeer id: String) -> String {
        networkLabel(sonar: resolvedSonarProfile(id) != nil, mutualFavorite: isMutualFavorite(id))
    }

    private static func npubDisplay(_ npub: String) -> String {
        guard npub.count > 24 else { return npub }
        return String(npub.prefix(14)) + "..." + String(npub.suffix(6))
    }

    private func peerDisplayName(_ id: String) -> String {
        let peerID = PeerID(str: id)
        if let live = chatViewModel.meshService.peerNickname(peerID: peerID),
           !live.isEmpty {
            return live
        }
        if let favorite = FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: peerID),
           !favorite.peerNickname.isEmpty {
            return favorite.peerNickname
        }
        if let noiseKey = peerID.noiseKey ?? Data(hexString: peerID.id),
           let favorite = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
           !favorite.peerNickname.isEmpty {
            return favorite.peerNickname
        }
        if let profile = resolvedSonarProfile(id) {
            if let name = marmot.displayName(forNpub: profile.npub) {
                return name
            }
            marmot.ensureProfile(profile.npub)
            return Self.npubDisplay(profile.npub)
        }
        return chatViewModel.nicknameForPeer(peerID)
    }

    /// Protocols the chat counterpart speaks — shown ONLY on the verify
    /// sheet's "Speaks" line; everywhere else uses plain-language labels.
    func speaks(_ id: String) -> String {
        if resolvedSonarProfile(id) != nil { return "Sonar mesh + White Noise" }
        return marmotGroupId(id) != nil ? "White Noise" : "bitchat mesh"
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
        if let group = marmotGroup(forNpub: profile.npub) {
            rememberMarmotGroup(group.id, forConversationId: peerID)
            rememberMarmotGroup(group.id, forConversationId: fp)
        }
        meshPeerFirstSeenAt[fp] = nil
        pendingCapabilityRefreshKeys.remove(fp)
        // Proactively fetch the Nostr descriptor so the BOLT12 offer is ready
        // by the time the user opens the payment sheet. Without this, the
        // descriptor loads lazily and the payment button appears only after a
        // second visit to the action sheet.
        if profile.capabilities & SonarCapability.payments != 0 {
            marmot.ensureSonarDescriptor(npub)
        }
    }

    /// Refresh Sonar descriptors for every persisted fingerprint↔npub link so
    /// payment and call capabilities stay current for contacts discovered over
    /// BLE even when they're out of range. Called at boot and on foreground
    /// return; `ensureSonarDescriptor`'s 15-minute TTL avoids redundant fetches.
    private func refreshKnownContactDescriptors(clearMisses: Bool = false) {
        let npubs = sonarProfilesByFingerprint.values.map(\.npub)
        guard !npubs.isEmpty else { return }
        marmot.refreshDescriptors(forKnownNpubs: npubs, clearMisses: clearMisses)
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

    private func persistMarmotConversationGroups() {
        guard let data = try? JSONEncoder().encode(marmotGroupIdsByConversationId) else { return }
        defaults.set(data, forKey: Keys.marmotConversationGroups)
    }

    private func hydrateMarmotConversationGroups() {
        guard let data = defaults.data(forKey: Keys.marmotConversationGroups),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        marmotGroupIdsByConversationId = map.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }

    private func rememberMarmotGroup(_ groupId: String, forConversationId id: String) {
        guard !groupId.isEmpty, !id.isEmpty else { return }
        if marmotGroupIdsByConversationId[id] == groupId { return }
        marmotGroupIdsByConversationId[id] = groupId
        persistMarmotConversationGroups()
    }

    private func forgetMarmotGroupMappings(forGroupId groupId: String) {
        let oldCount = marmotGroupIdsByConversationId.count
        marmotGroupIdsByConversationId = marmotGroupIdsByConversationId.filter { $0.value != groupId }
        if marmotGroupIdsByConversationId.count != oldCount {
            persistMarmotConversationGroups()
        }
    }

    private func clearMarmotConversationGroups() {
        marmotGroupIdsByConversationId = [:]
        defaults.removeObject(forKey: Keys.marmotConversationGroups)
    }

    private static func loadCallLogs(from defaults: UserDefaults) -> [String: [SNCallRecord]] {
        guard let data = defaults.data(forKey: Keys.callLogs),
              let stored = try? JSONDecoder().decode([String: [SNStoredCallRecord]].self, from: data)
        else { return [:] }
        return stored.mapValues { records in
            records
                .sorted { $0.date < $1.date }
                .suffix(maxStoredCallsPerConversation)
                .map(\.record)
        }
    }

    private func persistCallLogs() {
        let stored = callLogs.mapValues { records in
            records
                .sorted { $0.date < $1.date }
                .suffix(Self.maxStoredCallsPerConversation)
                .map(SNStoredCallRecord.init)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Keys.callLogs)
    }

    private func clearCallLogs() {
        callLogs = [:]
        defaults.removeObject(forKey: Keys.callLogs)
    }

    /// The Sonar profile for a peer id, preferring the live 0x53 announce and
    /// falling back to the persisted (by-fingerprint) copy — so a Sonar peer's
    /// White Noise leg is still recognized when it isn't currently advertising.
    func resolvedSonarProfile(_ id: String) -> SonarPeerProfile? {
        if let live = sonarProfiles[id] { return live }
        if let persisted = sonarProfilesByFingerprint[id] { return persisted }
        let fp = chatViewModel.getFingerprint(for: PeerID(str: id)) ?? id
        if let persisted = sonarProfilesByFingerprint[fp] { return persisted }
        if let noiseKey = PeerID(str: id).noiseKey {
            return sonarProfilesByFingerprint[noiseKey.sha256Fingerprint()]
        }
        return nil
    }

    /// The peer key (stable fingerprint) of a persisted/live Sonar peer whose
    /// npub matches `npub`, if any — used to fold a Marmot group into that peer's
    /// mesh conversation even with no live announce.
    func sonarPeerKey(forNpub npub: String) -> String? {
        guard let target = Self.nostrPubkeyData(npub) else { return nil }
        if let live = sonarProfiles.first(where: { Self.nostrPubkeyData($0.value.npub) == target })?.key {
            return chatViewModel.getFingerprint(for: PeerID(str: live)) ?? live
        }
        if let persisted = sonarProfilesByFingerprint.first(where: { Self.nostrPubkeyData($0.value.npub) == target })?.key {
            return persisted
        }
        // Fallback: a favorite we've met over BLE carries the noise↔nostr link, so a
        // White Noise chat with that npub is the SAME person as the mesh chat — fold
        // it even when we never captured a 0x53 announce from them (the gap that made
        // one person show as two chats). Compare canonically so a hex-vs-npub format
        // mismatch never blocks the fold.
        for (noiseKey, rel) in FavoritesPersistenceService.shared.favorites {
            if let nostr = rel.peerNostrPublicKey, Self.nostrPubkeyData(nostr) == target {
                return noiseKey.sha256Fingerprint()
            }
        }
        return nil
    }

    @discardableResult
    private func markMeshPeerSeen(_ peerID: PeerID, now: Date = Date()) -> String {
        let key = chatViewModel.getFingerprint(for: peerID) ?? peerID.id
        if meshPeerFirstSeenAt[key] == nil {
            meshPeerFirstSeenAt[key] = now
        }
        return key
    }

    private func hasMeshMessages(peerID: PeerID, key: String) -> Bool {
        if chatViewModel.privateChats[peerID]?.isEmpty == false { return true }
        if key != peerID.id, chatViewModel.privateChats[PeerID(str: key)]?.isEmpty == false { return true }
        return false
    }

    private func shouldWaitForCapabilities(
        peerID: PeerID,
        key: String,
        now: Date,
        hasMessages: Bool = false
    ) -> Bool {
        if hasMessages { return false }
        if resolvedSonarProfile(peerID.id) != nil || resolvedSonarProfile(key) != nil { return false }
        guard let firstSeen = meshPeerFirstSeenAt[key] else { return false }
        let remaining = Self.capabilitySettleWindow - now.timeIntervalSince(firstSeen)
        if remaining <= 0 { return false }
        scheduleCapabilitySettleRefresh(for: key, after: remaining)
        return true
    }

    private func hasRecentMarmotActivityForCapabilitySettle(
        _ latestMessage: MarmotService.MarmotMessage?,
        now: Date
    ) -> Bool {
        guard let latestMessage else { return false }
        let age = now.timeIntervalSince(latestMessage.createdAt)
        return age > -Self.capabilitySettleWindow && age < Self.capabilitySettleWindow
    }

    private func scheduleCapabilitySettleRefresh(for key: String, after remaining: TimeInterval) {
        guard pendingCapabilityRefreshKeys.insert(key).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 0.05) { [weak self] in
            guard let self else { return }
            self.pendingCapabilityRefreshKeys.remove(key)
            self.objectWillChange.send()
        }
    }

    private func shouldHoldStandaloneMarmotGroup(
        _ group: MarmotService.MarmotGroup,
        latestMessage: MarmotService.MarmotMessage?,
        now: Date
    ) -> Bool {
        guard marmot.isDirectGroup(group) else { return false }
        let title = snCanonicalConversationTitle(marmot.title(for: group))
        guard !title.isEmpty else { return false }
        let my = chatViewModel.meshService.myPeerID
        // Hold if a name-matched peer is still settling capabilities.
        for peer in chatViewModel.allPeers where peer.peerID != my && (peer.isConnected || peer.isReachable) {
            let key = markMeshPeerSeen(peer.peerID, now: now)
            guard snCanonicalConversationTitle(peerDisplayName(peer.peerID.id)) == title else { continue }
            if shouldWaitForCapabilities(peerID: peer.peerID, key: key, now: now) {
                return true
            }
        }
        guard hasRecentMarmotActivityForCapabilitySettle(latestMessage, now: now) else { return false }
        // Also hold if ANY mesh peer is still within its settle window and
        // hasn't resolved capabilities yet — the pending 0x53 announce may be
        // the one that provides the name we need to fold by.  This broad fallback
        // is limited to fresh Marmot activity so old standalone rows do not blink.
        for peer in chatViewModel.allPeers where peer.peerID != my && (peer.isConnected || peer.isReachable) {
            let key = chatViewModel.getFingerprint(for: peer.peerID) ?? peer.peerID.id
            let hasMessages = hasMeshMessages(peerID: peer.peerID, key: key)
            if shouldWaitForCapabilities(peerID: peer.peerID, key: key, now: now, hasMessages: hasMessages) {
                return true
            }
        }
        return false
    }

    /// Canonical 32-byte Nostr pubkey from a bech32 `npub1…` OR a 64-char hex string.
    private static func nostrPubkeyData(_ s: String) -> Data? {
        if s.hasPrefix("npub1") {
            guard let d = try? Bech32.decode(s), d.hrp == "npub", d.data.count == 32 else { return nil }
            return d.data
        }
        return Data(hexString: s).flatMap { $0.count == 32 ? $0 : nil }
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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

    private func publishPaymentMetadataIfNeeded(force: Bool = false) {
        guard marmot.npub != nil, marmot.relayConnected else { return }
        guard !publishingPaymentMetadata else {
            needsPaymentMetadataPublish = true
            return
        }
        publishingPaymentMetadata = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.publishingPaymentMetadata = false
                if self.needsPaymentMetadataPublish {
                    self.needsPaymentMetadataPublish = false
                    self.publishPaymentMetadataIfNeeded(force: true)
                }
            }
            let offer: String?
            switch self.walletState {
            case .ready:
                do {
                    offer = try await self.wallet.createOffer()
                    guard case .ready = self.walletState else { return }
                } catch {
                    SecureLogger.error("Sonar descriptor payment metadata publish failed: \(error)", category: .session)
                    return
                }
            case .settingUp:
                return
            case .notConfigured:
                // Keep call signaling discoverable for users without a ready
                // wallet, but do not overwrite a known offer with nil.
                guard self.publishedBolt12Offer == nil else { return }
                offer = nil
            }
            guard force || !self.publishedCallDescriptor || self.publishedBolt12Offer != offer else { return }
            do {
                try await self.marmot.publishSonarDescriptor(bolt12Offer: offer)
                if offer != nil {
                    guard case .ready = self.walletState else { return }
                }
                self.publishedCallDescriptor = true
                self.publishedBolt12Offer = offer
            } catch {
                SecureLogger.error("Sonar descriptor payment metadata publish failed: \(error)", category: .session)
            }
        }
    }

    private func updateWalletPaymentObservation() {
        guard case .ready = walletState else {
            incomingWalletTask?.cancel()
            incomingWalletTask = nil
            return
        }
        guard incomingWalletTask == nil else { return }
        let stream = wallet.incomingPayments()
        incomingWalletTask = Task { [weak self] in
            for await payment in stream {
                guard !Task.isCancelled else { return }
                self?.recordIncomingWalletPayment(payment)
            }
        }
    }

    private func recordIncomingWalletPayment(_ payment: SonarWalletPayment) {
        guard payment.isIncoming else { return }
        let activityId = "wallet-\(payment.id)"
        paymentActivityLedger.recordPending(SonarPaymentActivity(
            id: activityId,
            kind: .walletIncoming,
            peerKey: "wallet",
            peerName: "External wallet",
            direction: .incoming,
            sats: payment.amountSats,
            via: SNVia.internet.rawValue,
            createdAt: payment.timestamp,
            destinationHash: nil,
            status: .paid,
            walletPaymentId: payment.id,
            feesSats: payment.feesSats,
            settledAt: payment.timestamp
        ))
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

    /// Explicitly saved/bookmarked geohash channels (design home "Saved
    /// channels"), one row each. Raw geohashes from GeohashBookmarksStore become
    /// humanized SNChannelItems with a live "N here now" count; the friendly
    /// place name resolves asynchronously (until then, the precision-tier label
    /// — NEVER the raw geohash, per the design rule). Mesh is always present so
    /// it is never bookmarked.
    var savedChannels: [SNChannelItem] {
        locationManager.bookmarks.map { gh in
            let count = chatViewModel.geohashParticipantCount(for: gh)
            let level = Self.level(forLength: gh.count)
            let name = locationManager.bookmarkNames[gh] ?? level.displayName
            return SNChannelItem(
                id: "geo:" + gh,
                name: name,
                sub: "Public · \(count) here now",
                preview: count > 0 ? "\(count) here now" : "Saved channel",
                count: count,
                channel: .location(GeohashChannel(level: level, geohash: gh)),
                tier: level.displayName
            )
        }
    }

    /// Kick off friendly place-name resolution for all saved channels (the
    /// design shows place names, never raw geohashes). Idempotent — safe to call
    /// on appear; mirrors LocationChannelsSheet's per-row `resolveBookmarkNameIfNeeded`.
    func resolveSavedChannelNames() {
        for gh in locationManager.bookmarks {
            locationManager.resolveBookmarkNameIfNeeded(for: gh)
        }
    }

    private func meshChannelItem() -> SNChannelItem {
        let n = meshCount
        return SNChannelItem(
            id: "mesh",
            name: "Mesh",
            sub: "Public · \(n) in range",
            preview: n > 0 ? "\(n) people in Bluetooth range" : "Bluetooth · works without internet",
            count: n,
            channel: .mesh,
            tier: "Mesh"
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
            channel: .location(ch),
            tier: ch.level.displayName
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

    func sendStickerToChannel(_ chId: String, sticker: StickerInfo, packCoordinate: String) -> Bool {
        guard let groupId = marmotGroupId(chId) else { return false }
        marmot.sendSticker(
            groupId: groupId,
            packCoordinate: packCoordinate,
            shortcode: sticker.shortcode,
            plaintextSha256: sticker.sha256
        )
        return true
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
        let now = Date()
        var items: [SNPeerItem] = []
        for peer in chatViewModel.allPeers where peer.peerID != my {
            let peerKey = markMeshPeerSeen(peer.peerID, now: now)
            let sonar = resolvedSonarProfile(peer.peerID.id) != nil || resolvedSonarProfile(peerKey) != nil
            let hasMessages = hasMeshMessages(peerID: peer.peerID, key: peerKey)
            if (peer.isConnected || peer.isReachable),
               shouldWaitForCapabilities(peerID: peer.peerID, key: peerKey, now: now, hasMessages: hasMessages) {
                continue
            }
            let h = snHash(peer.peerID.id)
            let angle = Double(h % 360)
            let jitter = Double((h >> 9) % 11) - 5
            // Sonar discovery peers carry their npub (and optionally a
            // payment address); subtitles end with the plain-language
            // network line ("Sonar · reaches anywhere" etc.).
            let network = networkLabel(sonar: sonar, mutualFavorite: peer.isMutualFavorite)
            let displayName = peerDisplayName(peer.peerID.id)
            if peer.isConnected {
                items.append(SNPeerItem(
                    id: peer.peerID.id, name: displayName, inRange: true, bars: 3,
                    hint: "Right here", detail: "Direct connection · " + network,
                    angle: angle, r: 66 + jitter, sonar: sonar
                ))
            } else if peer.isReachable {
                items.append(SNPeerItem(
                    id: peer.peerID.id, name: displayName, inRange: true, bars: 2,
                    hint: "Nearby", detail: "Relayed through the mesh · " + network,
                    angle: angle, r: 118 + jitter, sonar: sonar
                ))
            } else if peer.isMutualFavorite || sonar {
                items.append(SNPeerItem(
                    id: peer.peerID.id, name: displayName, inRange: false, bars: 0,
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
        if let item = nearbyPeerItem(forConversationId: id) { return item }
        if id.hasPrefix(Self.marmotIDPrefix), let groupId = marmotGroupId(id) {
            let group = marmot.groups.first { $0.id == groupId }
            return SNPeerItem(
                id: id,
                name: group.map { marmot.title(for: $0) } ?? "Secure chat",
                inRange: false, bars: 0,
                hint: "Secure chat", detail: "Encrypted chat · reaches anywhere",
                angle: 0, r: 0
            )
        }
        if let unifyId = unifyPeerId(id) {
            let name = unify.peers.first { $0.id == unifyId }?.name
                ?? UnifyNearbyContract.advertisedNamePrefix
            return SNPeerItem(
                id: id, name: name, inRange: true, bars: 1,
                hint: "Unify", detail: "Unify \u{00B7} pay only",
                angle: 0, r: 0, unify: true, avatarSeed: unifyId
            )
        }
        if let profile = resolvedSonarProfile(id),
           let group = marmotGroup(forNpub: profile.npub) {
            return SNPeerItem(
                id: id,
                name: marmot.title(for: group),
                inRange: false, bars: 0,
                hint: "Out of range", detail: networkLabel(forPeer: id),
                angle: 0, r: 0, sonar: true
            )
        }
        return SNPeerItem(
            id: id,
            name: peerDisplayName(id),
            inRange: false, bars: 0,
            hint: "Out of range", detail: networkLabel(forPeer: id),
            angle: 0, r: 0, sonar: resolvedSonarProfile(id) != nil
        )
    }

    private func nearbyPeerItem(forConversationId id: String) -> SNPeerItem? {
        let peers = nearbyPeers
        if let exact = peers.first(where: { $0.id == id }) { return exact }
        guard !id.hasPrefix(Self.marmotIDPrefix),
              let targetFingerprint = chatViewModel.getFingerprint(for: PeerID(str: id)),
              let live = peers.first(where: { item in
                  guard !item.unify,
                        let fingerprint = chatViewModel.getFingerprint(for: PeerID(str: item.id))
                  else { return false }
                  return fingerprint == targetFingerprint
              })
        else { return nil }
        return SNPeerItem(
            id: id,
            name: live.name,
            inRange: live.inRange,
            bars: live.bars,
            hint: live.hint,
            detail: live.detail,
            angle: live.angle,
            r: live.r,
            sonar: live.sonar,
            unify: live.unify,
            avatarSeed: live.avatarSeed
        )
    }

    /// The White Noise (Marmot) 1:1 group whose counterpart is `npub`.
    func marmotGroup(forNpub npub: String) -> MarmotService.MarmotGroup? {
        let target = SNMarmotProfileCache.canonicalKey(npub)
        return marmot.groups.first {
            marmot.isDirectGroup($0) &&
                $0.memberNpubs.map(SNMarmotProfileCache.canonicalKey).contains(target)
        }
    }

    func marmotGroupId(_ id: String) -> String? {
        if id.hasPrefix(Self.marmotIDPrefix) {
            return String(id.dropFirst(Self.marmotIDPrefix.count))
        }
        if let mapped = marmotGroupIdsByConversationId[id] {
            return mapped
        }
        if let fp = chatViewModel.getFingerprint(for: PeerID(str: id)),
           let mapped = marmotGroupIdsByConversationId[fp] {
            rememberMarmotGroup(mapped, forConversationId: id)
            return mapped
        }
        guard let profile = resolvedSonarProfile(id),
              let group = marmotGroup(forNpub: profile.npub)
        else { return nil }
        rememberMarmotGroup(group.id, forConversationId: id)
        let fp = chatViewModel.getFingerprint(for: PeerID(str: id)) ?? id
        rememberMarmotGroup(group.id, forConversationId: fp)
        return group.id
    }

    private func marmotGroup(byId groupId: String) -> MarmotService.MarmotGroup? {
        marmot.groups.first { $0.id == groupId }
    }

    func marmotGroup(forConversationId id: String) -> MarmotService.MarmotGroup? {
        guard let groupId = marmotGroupId(id) else { return nil }
        return marmotGroup(byId: groupId)
    }

    func isMultiMemberMarmotGroupId(_ id: String) -> Bool {
        guard let groupId = marmotGroupId(id),
              let group = marmotGroup(byId: groupId)
        else { return false }
        return !marmot.isDirectGroup(group)
    }

    func groupInviteContacts(excluding excluded: Set<String> = []) -> [SNGroupContact] {
        let excluded = Set(excluded.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var byNpub: [String: SNGroupContact] = [:]

        func insert(title: String, subtitle: String, npub: String) {
            let clean = npub.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.hasPrefix("npub1"), !excluded.contains(clean) else { return }
            if let mine = marmot.npub, clean == mine { return }
            guard byNpub[clean] == nil else { return }
            byNpub[clean] = SNGroupContact(
                id: clean,
                title: title.isEmpty ? Self.shortNpub(clean) : title,
                subtitle: subtitle,
                npub: clean
            )
        }

        for peer in nearbyPeers where !peer.unify {
            guard let profile = resolvedSonarProfile(peer.id) else { continue }
            insert(
                title: peer.name,
                subtitle: peer.inRange ? "Nearby · Bluetooth" : "Known Sonar contact",
                npub: profile.npub
            )
        }
        for row in dmRows {
            if let groupId = marmotGroupId(row.id),
               let group = marmotGroup(byId: groupId),
               let other = directOtherNpub(in: group) {
                insert(title: row.title, subtitle: "White Noise chat", npub: other)
            } else if let profile = resolvedSonarProfile(row.id) {
                insert(title: row.title, subtitle: row.presence ? "Nearby · Bluetooth" : "Known Sonar contact", npub: profile.npub)
            }
        }
        for group in marmot.groups where marmot.isDirectGroup(group) {
            guard let other = directOtherNpub(in: group) else { continue }
            insert(title: marmot.title(for: group), subtitle: "White Noise chat", npub: other)
        }

        return byNpub.values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func groupMemberContacts(forConversationId id: String) -> [SNGroupContact] {
        guard let group = marmotGroup(forConversationId: id) else { return [] }
        return marmot.otherMembers(in: group).map { npub in
            marmot.ensureProfile(npub)
            let title = marmot.displayName(forNpub: npub) ?? Self.shortNpub(npub)
            return SNGroupContact(
                id: npub,
                title: title,
                subtitle: Self.shortNpub(npub),
                npub: npub
            )
        }
    }

    static func shortNpub(_ value: String) -> String {
        value.count > 16 ? "\(value.prefix(10))…\(value.suffix(4))" : value
    }

    private func directOtherNpub(in group: MarmotService.MarmotGroup) -> String? {
        guard marmot.isDirectGroup(group) else { return nil }
        return marmot.otherMembers(in: group).first
    }

    private func callMarmotGroupId(_ id: String) -> String? {
        if let groupId = marmotGroupId(id) { return groupId }
        guard let profile = resolvedSonarProfile(id) else { return nil }
        return marmotGroup(forNpub: profile.npub)?.id
    }

    private func callProfile(_ id: String) -> SonarPeerProfile? {
        if let profile = resolvedSonarProfile(id) { return profile }
        guard let groupId = marmotGroupId(id),
              let group = marmotGroup(byId: groupId),
              let otherNpub = directOtherNpub(in: group)
        else { return nil }
        if let peerKey = sonarPeerKey(forNpub: otherNpub) {
            return resolvedSonarProfile(peerKey)
        }
        return sonarProfiles.first(where: { $0.value.npub == otherNpub })?.value
            ?? sonarProfilesByFingerprint.first(where: { $0.value.npub == otherNpub })?.value
    }

    private func callNpub(_ id: String) -> String? {
        if let profile = callProfile(id) { return profile.npub }
        guard let groupId = marmotGroupId(id),
              let group = marmotGroup(byId: groupId)
        else { return nil }
        return directOtherNpub(in: group)
    }

    private func callDescriptor(_ id: String) -> MarmotService.SonarDescriptor? {
        guard let npub = callNpub(id) else { return nil }
        marmot.ensureSonarDescriptor(npub)
        return marmot.sonarDescriptorsByNpub[npub]
    }

    private func paymentDescriptor(_ id: String) -> MarmotService.SonarDescriptor? {
        guard let npub = callNpub(id) else { return nil }
        marmot.ensureSonarDescriptor(npub)
        return marmot.sonarDescriptorsByNpub[npub]
    }

    private func directPaymentOffer(_ id: String) -> String? {
        guard let descriptor = paymentDescriptor(id),
              descriptor.supportsDirectPayments,
              let offer = descriptor.bolt12Offer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !offer.isEmpty
        else { return nil }
        return offer
    }

    private func callSignalingVia(_ id: String) -> SNVia? {
        if meshReachable(id) { return .mesh }
        if callMarmotGroupId(id) != nil { return .internet }
        if resolvedSonarProfile(id) != nil { return .internet }
        return nil
    }

    private func foldedConversationId(forMarmotGroupId groupId: String) -> String? {
        guard let group = marmotGroup(byId: groupId),
              let otherNpub = directOtherNpub(in: group)
        else { return nil }
        return sonarPeerKey(forNpub: otherNpub)
    }

    private func inferFoldKeyByUniqueTitle(
        for group: MarmotService.MarmotGroup,
        otherNpub: String,
        rowsByKey: [String: SNDMRow]
    ) -> String? {
        guard let targetNpub = Self.nostrPubkeyData(otherNpub) else { return nil }
        let peerTitles = rowsByKey.mapValues(\.title)
        let groupTitles = marmot.groups.map { marmot.title(for: $0) }
        guard let peerKey = snInferUniquePeerKeyByTitle(
            groupTitle: marmot.title(for: group),
            peerTitles: peerTitles,
            allGroupTitles: groupTitles
        ) else { return nil }
        if let existing = sonarProfilesByFingerprint[peerKey],
           Self.nostrPubkeyData(existing.npub) != targetNpub {
            return nil
        }
        sonarProfilesByFingerprint[peerKey] = SonarPeerProfile(
            npub: otherNpub,
            bip353: sonarProfilesByFingerprint[peerKey]?.bip353,
            capabilities: sonarProfilesByFingerprint[peerKey]?.capabilities ?? SonarCapability.marmotDM
        )
        persistSonarProfiles()
        return peerKey
    }

    private func callConversationId(_ id: String) -> String {
        if let groupId = marmotGroupId(id),
           let folded = foldedConversationId(forMarmotGroupId: groupId) {
            return folded
        }
        return id
    }

    private func callDisplayName(_ id: String) -> String {
        if !meshReachable(id),
           let groupId = callMarmotGroupId(id),
           let group = marmot.groups.first(where: { $0.id == groupId }) {
            return marmot.title(for: group)
        }
        return peerItem(id).name
    }

    // MARK: Messages (home rows)

    var dmRows: [SNDMRow] {
        // Mesh/bitchat chats, deduplicated by fingerprint (the same peer can
        // appear under a short mesh ID and its stable Noise key).
        let now = Date()
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
            if (fav.isConnected || fav.isReachable),
               shouldWaitForCapabilities(peerID: fav.peerID, key: key, now: now) {
                continue
            }
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
            guard marmot.isDirectGroup(group) else {
                marmotRows.append(SNDMRow(
                    id: Self.marmotIDPrefix + group.id,
                    title: marmot.title(for: group),
                    preview: last.map { Self.previewText($0.content) } ?? "Secure group · reaches anywhere",
                    time: last.map { Self.listTime($0.createdAt) } ?? "",
                    unread: (marmot.unreadByGroup[group.id] ?? 0) > 0,
                    presence: false,
                    verified: false,
                    isMarmot: true,
                    lastDate: last?.createdAt,
                    marmotGroupId: group.id
                ))
                continue
            }
            let otherNpub = directOtherNpub(in: group)
            // Live peer id (when currently discovered over 0x53) gives us mesh
            // presence; the persisted fingerprint still lets us build the SAME
            // Sonar row when BLE is down / after restart.
            let liveSonarPeerId = otherNpub.flatMap { np in
                sonarProfiles.first(where: { $0.value.npub == np })?.key
            }
            let foldKey = otherNpub.flatMap { npub in
                sonarPeerKey(forNpub: npub)
                    ?? inferFoldKeyByUniqueTitle(for: group, otherNpub: npub, rowsByKey: byKey)
            }
            if let liveSonarPeerId {
                rememberMarmotGroup(group.id, forConversationId: liveSonarPeerId)
            }
            if let foldKey {
                rememberMarmotGroup(group.id, forConversationId: foldKey)
            }
            if let foldKey, let existing = byKey[foldKey] {
                // Same person as a mesh/bitchat chat → merge the White Noise leg
                // into that one row instead of showing a duplicate conversation.
                rememberMarmotGroup(group.id, forConversationId: existing.id)
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
                        lastDate: last.createdAt,
                        marmotGroupId: group.id
                    )
                }
                continue
            }
            if let foldKey {
                // Discovered Sonar peer with no mesh transcript yet, or a persisted
                // Sonar peer now out of range → one folded row, not a White Noise
                // duplicate.
                let rowId = liveSonarPeerId ?? foldKey
                rememberMarmotGroup(group.id, forConversationId: rowId)
                byKey[foldKey] = SNDMRow(
                    id: rowId,
                    title: liveSonarPeerId == nil ? marmot.title(for: group) : peerDisplayName(rowId),
                    preview: last.map { Self.previewText($0.content) } ?? networkLabel(forPeer: rowId),
                    time: last.map { Self.listTime($0.createdAt) } ?? "",
                    unread: (marmot.unreadByGroup[group.id] ?? 0) > 0,
                    presence: liveSonarPeerId != nil && meshReachable(rowId),
                    verified: isVerified(rowId) || (marmotVerified[group.id] ?? false),
                    isMarmot: false,
                    lastDate: last?.createdAt,
                    marmotGroupId: group.id
                )
                continue
            }
            if shouldHoldStandaloneMarmotGroup(group, latestMessage: last, now: now) {
                continue
            }
            marmotRows.append(SNDMRow(
                id: Self.marmotIDPrefix + group.id,
                title: marmot.title(for: group),
                preview: last.map { Self.previewText($0.content) } ?? "Secure chat · reaches anywhere",
                time: last.map { Self.listTime($0.createdAt) } ?? "",
                unread: (marmot.unreadByGroup[group.id] ?? 0) > 0,
                presence: false,
                verified: marmotVerified[group.id] ?? false,
                isMarmot: true,
                lastDate: last?.createdAt,
                marmotGroupId: group.id
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
        return SNDMRow(
            id: peerID.id,
            title: peerDisplayName(peerID.id),
            preview: last.map { Self.previewText($0.content) } ?? networkLabel(forPeer: peerID.id),
            time: last.map { Self.listTime($0.timestamp) } ?? "",
            unread: chatViewModel.unreadPrivateMessages.contains(peerID),
            presence: meshReachable(peerID.id),
            verified: isVerified(peerID.id),
            isMarmot: false,
            lastDate: last?.timestamp
        )
    }

    // MARK: DM transcript + send

    /// How one chat line renders: regular text, a ⚡PAY receipt bubble,
    /// or hidden (⚡PAYDONE is a protocol control line). Unknown
    /// ⚡PAY versions decode to nothing and fall through as plain text.
    private enum PayMapping {
        case notPay
        case hidden
        case bubble(SNPayInfo, SNVia)
    }

    private func payMapping(_ content: String, fallbackVia: SNVia) -> PayMapping {
        // ☎CALL signaling lines ride the chat like ⚡PAY but are never shown. The
        // cheap prefix prefilter avoids an FFI call for ordinary chat messages.
        if Self.looksLikeCallControl(content), callParseControl(content: content) != nil {
            return .hidden
        }
        guard let line = SonarPayMessage.decode(content) else { return .notPay }
        guard case .pay(let pid, let sats) = line else { return .hidden }
        let entry = payLedger.entry(for: pid)
        // The coin renders with the transport it traveled over (recorded in
        // the ledger), not the conversation's current reachability.
        let via = entry.flatMap { SNVia(rawValue: $0.via) } ?? fallbackVia
        let isDirect = paymentActivityLedger.entries[pid] != nil
        return .bubble(
            SNPayInfo(id: pid, sats: entry?.sats ?? sats, state: entry?.state ?? .sealed, direct: isDirect),
            via
        )
    }

    private func paymentActivityRows(for id: String, transcriptPayIDs: Set<String>) -> [(Date, SNMessage)] {
        paymentActivityLedger.activities(peerKey: id).filter { activity in
            payLedger.entry(for: activity.id) == nil || !transcriptPayIDs.contains(activity.id)
        }.map { activity in
            let displayDate = activity.settledAt ?? activity.createdAt
            let state: SonarPayEntry.State = activity.status == .paid ? .claimed : .settling
            let via = SNVia(rawValue: activity.via) ?? .internet
            return (
                displayDate,
                SNMessage(
                    id: "payment-activity-\(activity.id)",
                    mine: activity.direction == .outgoing,
                    text: "",
                    time: Self.clock(displayDate),
                    via: via,
                    pay: SNPayInfo(
                        id: activity.id,
                        sats: activity.sats,
                        state: state,
                        direct: true,
                        failed: activity.status == .failed
                    )
                )
            )
        }
    }

    func dmMsgs(_ id: String) -> [SNMessage] {
        if let groupId = marmotGroupId(id) {
            var dated: [(Date, SNMessage)] = (marmot.messagesByGroup[groupId] ?? []).compactMap { m in
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
                        author: String(m.senderNpub.prefix(12)),
                        text: m.content,
                        time: Self.clock(m.createdAt),
                        via: .internet,
                        state: MarmotChatModel.stateText(for: m),
                        media: Self.mediaItems(m, groupId: groupId),
                        stickerRef: m.stickerRef
                    ))
                }
            }
            if !id.hasPrefix(Self.marmotIDPrefix) {
                let peerID = PeerID(str: id)
                let via: SNVia = .mesh
                let my = chatViewModel.meshService.myPeerID
                dated += (chatViewModel.privateChats[peerID] ?? []).compactMap { m in
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
                        let mediaItem = meshMediaItem(m.content)
                        return (m.timestamp, SNMessage(
                            id: m.id,
                            mine: mine,
                            author: m.sender,
                            text: mediaItem != nil ? "" : m.content,
                            time: Self.clock(m.timestamp),
                            via: via,
                            state: mine ? Self.stateText(m.deliveryStatus) : nil,
                            media: mediaItem.map { [$0] } ?? []
                        ))
                    }
                }
                dated.sort { $0.0 < $1.0 }
            }
            let transcriptPayIDs = Set(dated.compactMap { $0.1.pay?.id })
            dated += paymentActivityRows(for: id, transcriptPayIDs: transcriptPayIDs)
            return mergeCallLogs(into: dated, id: id)
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
                // BLE-mesh media (bitchat file transfer) arrives as an
                // "[image] <name>" marker with the file already on disk.
                let mediaItem = meshMediaItem(m.content)
                return (m.timestamp, SNMessage(
                    id: m.id,
                    mine: mine,
                    author: m.sender,
                    text: mediaItem != nil ? "" : m.content,
                    time: Self.clock(m.timestamp),
                    via: via,
                    state: mine ? Self.stateText(m.deliveryStatus) : nil,
                    media: mediaItem.map { [$0] } ?? []
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
                        author: m.isMine ? nil : peerDisplayName(id),
                        text: m.content,
                        time: Self.clock(m.createdAt),
                        via: .internet,
                        state: MarmotChatModel.stateText(for: m),
                        media: Self.mediaItems(m, groupId: group.id)
                    ))
                }
            }
            dated.sort { $0.0 < $1.0 }
        }
        let transcriptPayIDs = Set(dated.compactMap { $0.1.pay?.id })
        dated += paymentActivityRows(for: id, transcriptPayIDs: transcriptPayIDs)
        return mergeCallLogs(into: dated, id: id)
    }

    /// Fold local call records for `id` into the transcript chronologically
    /// (stable sort keeps same-instant messages in place). A no-op when this
    /// peer has no recorded calls.
    private func mergeCallLogs(into dated: [(Date, SNMessage)], id: String) -> [SNMessage] {
        let calls = callLogs[id] ?? []
        var combined = dated
        for c in calls { combined.append((c.date, c.message)) }
        return combined.enumerated()
            .sorted {
                if $0.element.0 == $1.element.0 { return $0.offset < $1.offset }
                return $0.element.0 < $1.element.0
            }
            .map { $0.element.1 }
    }

    /// DM routing uses Bluetooth only while a Sonar peer is directly connected;
    /// retained mesh reachability means the direct BLE leg already dropped, so
    /// the conversation continues over White Noise.
    func dmTransport(_ id: String) -> SNVia {
        if meshReachable(id) { return .mesh }
        return .internet
    }

    func sendDm(_ id: String, _ text: String) {
        if meshReachable(id) {
            chatViewModel.sendPrivateMessage(text, to: PeerID(str: id))
            return
        }
        if let groupId = marmotGroupId(id) {
            marmot.send(text, to: groupId)
            return
        }
        if let profile = resolvedSonarProfile(id) {
            sendOverMarmot(text, npub: profile.npub)
            return
        }
        chatViewModel.sendPrivateMessage(text, to: PeerID(str: id))
    }

    private func sendPaymentReceiptLines(_ lines: [String], to id: String) async -> Bool {
        guard !lines.isEmpty else { return true }
        if meshReachable(id) {
            for line in lines { chatViewModel.sendPrivateMessage(line, to: PeerID(str: id)) }
            return true
        }
        if let groupId = marmotGroupId(id) {
            return await marmot.send(lines, to: groupId)
        }
        if let profile = resolvedSonarProfile(id) {
            if let group = marmotGroup(forNpub: profile.npub) {
                return await marmot.send(lines, to: group.id)
            }
            marmot.connectIfNeeded()
            guard let groupId = await marmot.startChatReturningId(with: profile.npub) else { return false }
            return await marmot.send(lines, to: groupId)
        }
        for line in lines { chatViewModel.sendPrivateMessage(line, to: PeerID(str: id)) }
        return true
    }

    func sendSticker(_ id: String, sticker: StickerInfo, packCoordinate: String) {
        guard let groupId = marmotGroupId(id) else { return }
        marmot.sendSticker(
            groupId: groupId,
            packCoordinate: packCoordinate,
            shortcode: sticker.shortcode,
            plaintextSha256: sticker.sha256
        )
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

    // MARK: Media (White Noise / Marmot MIP-04)

    /// In-memory decrypted-media cache (raw bytes), keyed by the ciphertext's
    /// Blossom URL. Cleared by `wipe()` and `eraseAllChats()`.
    private var mediaImageCache: [String: Data] = [:]

    private struct PendingUploadMedia {
        let localURL: String
        let data: Data
        let startedAt: Date
        let existingMediaURLs: Set<String>
        var completedOrder: Int?
    }

    /// Bytes for uploads we just started, keyed by group/filename/mime/caption.
    /// When the canonical Marmot message appears, these bytes are copied under
    /// the real Blossom URL so the sent bubble does not briefly fall back to a
    /// download spinner.
    private var pendingUploadMediaCache: [String: [PendingUploadMedia]] = [:]
    private static let pendingMediaURLPrefix = "pending-media-"

    /// Map a Marmot message's attachments into UI items carrying the group id.
    static func mediaItems(_ m: MarmotService.MarmotMessage, groupId: String) -> [SNMediaItem] {
        m.media.map {
            SNMediaItem(url: $0.url, mime: $0.mimeType, filename: $0.filename, groupId: groupId)
        }
    }

    private static func pendingMediaURL() -> String {
        pendingMediaURLPrefix + UUID().uuidString
    }

    private static func pendingUploadMediaKey(
        groupId: String,
        filename: String,
        mime: String,
        caption: String
    ) -> String {
        [groupId, filename, mime, caption].joined(separator: "\u{1f}")
    }

    private func rememberPendingUploadMedia(
        groupId: String,
        filename: String,
        mime: String,
        caption: String,
        localURL: String,
        data: Data
    ) {
        let key = Self.pendingUploadMediaKey(groupId: groupId, filename: filename, mime: mime, caption: caption)
        let existingMediaURLs = Set(
            marmot.messagesByGroup[groupId, default: []]
                .flatMap { $0.media.map(\.url) }
                .filter { !$0.hasPrefix(Self.pendingMediaURLPrefix) }
        )
        pendingUploadMediaCache[key, default: []].append(
            PendingUploadMedia(
                localURL: localURL,
                data: data,
                startedAt: Date(),
                existingMediaURLs: existingMediaURLs,
                completedOrder: nil
            )
        )
        mediaImageCache[localURL] = data
    }

    private var pendingUploadCompletionOrder = 0

    private func markPendingUploadMediaCompleted(
        groupId: String,
        filename: String,
        mime: String,
        caption: String,
        localURL: String
    ) {
        let key = Self.pendingUploadMediaKey(groupId: groupId, filename: filename, mime: mime, caption: caption)
        guard var pending = pendingUploadMediaCache[key],
              let index = pending.firstIndex(where: { $0.localURL == localURL }),
              pending[index].completedOrder == nil else { return }
        pendingUploadCompletionOrder += 1
        pending[index].completedOrder = pendingUploadCompletionOrder
        pendingUploadMediaCache[key] = pending
    }

    private func forgetPendingUploadMedia(
        groupId: String,
        filename: String,
        mime: String,
        caption: String,
        localURL: String
    ) {
        let key = Self.pendingUploadMediaKey(groupId: groupId, filename: filename, mime: mime, caption: caption)
        guard var pending = pendingUploadMediaCache[key] else { return }
        pending.removeAll { $0.localURL == localURL }
        if pending.isEmpty {
            pendingUploadMediaCache.removeValue(forKey: key)
        } else {
            pendingUploadMediaCache[key] = pending
        }
    }

    private func cachePublishedUploadMedia() {
        guard !pendingUploadMediaCache.isEmpty else { return }
        for (groupId, messages) in marmot.messagesByGroup {
            for message in messages where message.isMine {
                for media in message.media
                    where !media.url.hasPrefix(Self.pendingMediaURLPrefix) && mediaImageCache[media.url] == nil {
                    let key = Self.pendingUploadMediaKey(
                        groupId: groupId,
                        filename: media.filename,
                        mime: media.mimeType,
                        caption: message.content
                    )
                    guard var pending = pendingUploadMediaCache[key], !pending.isEmpty else { continue }
                    let match = pending.enumerated()
                        .filter {
                            guard $0.element.completedOrder != nil else { return false }
                            return message.createdAt.timeIntervalSince1970 >= floor($0.element.startedAt.timeIntervalSince1970)
                                && !$0.element.existingMediaURLs.contains(media.url)
                        }
                        .min {
                            ($0.element.completedOrder ?? Int.max) < ($1.element.completedOrder ?? Int.max)
                        }
                    guard let match else { continue }
                    let upload = pending.remove(at: match.offset)
                    mediaImageCache[media.url] = upload.data
                    mediaImageCache.removeValue(forKey: upload.localURL)
                    if let disk = Self.mediaCacheURL(for: media.url) {
                        try? upload.data.write(to: disk, options: [.atomic, .completeFileProtection])
                    }
                    if pending.isEmpty {
                        pendingUploadMediaCache.removeValue(forKey: key)
                    } else {
                        pendingUploadMediaCache[key] = pending
                    }
                }
            }
        }
    }

    /// True if `id` is a chat that can carry media: an existing Marmot group, a
    /// Sonar peer whose White Noise group exists, OR a bitchat/mesh peer
    /// reachable over Bluetooth right now (sent as a bitchat file transfer).
    func canSendMedia(_ id: String) -> Bool {
        if marmotGroupId(id) != nil { return true }
        if let profile = resolvedSonarProfile(id), marmotGroup(forNpub: profile.npub) != nil { return true }
        return meshReachable(id)
    }

    /// True for a non-geo private peer reachable over the BLE mesh right now.
    /// Sonar peers require a direct connection; retained mesh reachability is
    /// still useful for plain bitchat relay but should not hold Sonar on BLE.
    private func meshReachable(_ id: String) -> Bool {
        guard !id.hasPrefix(Self.marmotIDPrefix) else { return false }
        let peerID = PeerID(str: id)
        guard !peerID.isGeoDM else { return false }
        let mesh = chatViewModel.meshService
        if resolvedSonarProfile(id) != nil {
            return mesh.isPeerConnected(peerID)
        }
        return mesh.isPeerConnected(peerID) || mesh.isPeerReachable(peerID)
    }

    /// Send an image. Over the BLE mesh (bitchat file transfer, type 0x22) when
    /// the peer is reachable over Bluetooth — interops with stock bitchat;
    /// otherwise encrypt + Blossom-upload + publish over White Noise (Marmot).
    func sendImage(_ id: String, data: Data, filename: String, mime: String) {
        if meshReachable(id) {
            sendImageOverMesh(PeerID(str: id), data: data)
            return
        }
        let groupId: String?
        if let gid = marmotGroupId(id) {
            groupId = gid
        } else if let profile = resolvedSonarProfile(id) {
            groupId = marmotGroup(forNpub: profile.npub)?.id
        } else {
            groupId = nil
        }
        guard let gid = groupId else { return }
        let pendingURL = Self.pendingMediaURL()
        rememberPendingUploadMedia(
            groupId: gid,
            filename: filename,
            mime: mime,
            caption: "",
            localURL: pendingURL,
            data: data
        )
        marmot.sendMedia(
            groupId: gid,
            data: data,
            filename: filename,
            mime: mime,
            localPreviewURL: pendingURL,
            onComplete: { [weak self] in
                self?.markPendingUploadMediaCompleted(
                    groupId: gid,
                    filename: filename,
                    mime: mime,
                    caption: "",
                    localURL: pendingURL
                )
            },
            onFailure: { [weak self] in
                self?.forgetPendingUploadMedia(
                    groupId: gid,
                    filename: filename,
                    mime: mime,
                    caption: "",
                    localURL: pendingURL
                )
            }
        )
    }

    /// Send a desktop-selected attachment. White Noise can preserve the source
    /// MIME (including video); BLE mesh uses the existing safe file-packet
    /// allowlist and falls back to a generic file for unsupported types.
    @discardableResult
    func sendAttachment(_ id: String, data: Data, filename: String, mime: String) -> Bool {
        if meshReachable(id) {
            guard FileTransferLimits.isValidPayload(data.count) else { return false }
            chatViewModel.selectedPrivateChatPeer = PeerID(str: id)
            let meshMime = MimeType(mime)?.mimeString ?? "application/octet-stream"
            chatViewModel.sendFile(data: data, filename: filename, mime: meshMime)
            return true
        }

        let groupId: String?
        if let gid = marmotGroupId(id) {
            groupId = gid
        } else if let profile = resolvedSonarProfile(id) {
            groupId = marmotGroup(forNpub: profile.npub)?.id
        } else {
            groupId = nil
        }
        guard let gid = groupId else { return false }

        let finalName = (filename as NSString).lastPathComponent
        let safeName = finalName.isEmpty ? "attachment" : finalName
        let safeMime = mime.isEmpty ? "application/octet-stream" : mime
        let pendingURL = Self.pendingMediaURL()
        rememberPendingUploadMedia(
            groupId: gid,
            filename: safeName,
            mime: safeMime,
            caption: "",
            localURL: pendingURL,
            data: data
        )
        marmot.sendMedia(
            groupId: gid,
            data: data,
            filename: safeName,
            mime: safeMime,
            localPreviewURL: pendingURL,
            onComplete: { [weak self] in
                self?.markPendingUploadMediaCompleted(
                    groupId: gid,
                    filename: safeName,
                    mime: safeMime,
                    caption: "",
                    localURL: pendingURL
                )
            },
            onFailure: { [weak self] in
                self?.forgetPendingUploadMedia(
                    groupId: gid,
                    filename: safeName,
                    mime: safeMime,
                    caption: "",
                    localURL: pendingURL
                )
            }
        )
        return true
    }

    /// Send a recorded voice note (AAC .m4a at `url`). Over the BLE mesh it rides
    /// bitchat's file transfer as a `[voice]` note (interops with stock bitchat);
    /// otherwise it's encrypted + uploaded over White Noise (Marmot) like any
    /// media. Same routing as `sendImage`, audio mime. Cleans up the temp file.
    func sendVoiceNote(_ id: String, url: URL) {
        defer { try? FileManager.default.removeItem(at: url) }
        if meshReachable(id) {
            chatViewModel.selectedPrivateChatPeer = PeerID(str: id)
            chatViewModel.sendVoiceNote(at: url)
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        let groupId: String?
        if let gid = marmotGroupId(id) {
            groupId = gid
        } else if let profile = resolvedSonarProfile(id) {
            groupId = marmotGroup(forNpub: profile.npub)?.id
        } else {
            groupId = nil
        }
        guard let gid = groupId else { return }
        let pendingURL = Self.pendingMediaURL()
        rememberPendingUploadMedia(
            groupId: gid,
            filename: url.lastPathComponent,
            mime: "audio/mp4",
            caption: "",
            localURL: pendingURL,
            data: data
        )
        marmot.sendMedia(
            groupId: gid,
            data: data,
            filename: url.lastPathComponent,
            mime: "audio/mp4",
            localPreviewURL: pendingURL,
            onComplete: { [weak self] in
                self?.markPendingUploadMediaCompleted(
                    groupId: gid,
                    filename: url.lastPathComponent,
                    mime: "audio/mp4",
                    caption: "",
                    localURL: pendingURL
                )
            },
            onFailure: { [weak self] in
                self?.forgetPendingUploadMedia(
                    groupId: gid,
                    filename: url.lastPathComponent,
                    mime: "audio/mp4",
                    caption: "",
                    localURL: pendingURL
                )
            }
        )
    }

    /// Send an image over the BLE mesh by reusing ChatViewModel's bitchat file
    /// path (saves outgoing, echoes "[image] <name>", sends `sendFilePrivate`).
    private func sendImageOverMesh(_ peerID: PeerID, data: Data) {
        chatViewModel.selectedPrivateChatPeer = peerID // target + enable media context
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonar-\(UUID().uuidString).jpg")
        guard (try? data.write(to: tmp)) != nil else { return }
        chatViewModel.sendImage(from: tmp) { try? FileManager.default.removeItem(at: tmp) }
    }

    /// Resolve a bitchat file marker ("[image]/[file]/[voice] <name>") to a media
    /// item with the local on-disk path, if the file exists.
    private func meshMediaItem(_ content: String) -> SNMediaItem? {
        let kinds: [(prefix: String, mime: String, dirs: [String])] = [
            ("[image] ", "image/jpeg", ["images/incoming", "images/outgoing"]),
            ("[voice] ", "audio/mp4", ["voicenotes/incoming", "voicenotes/outgoing"]),
            ("[file] ", "application/octet-stream", ["files/incoming", "files/outgoing"]),
        ]
        guard let k = kinds.first(where: { content.hasPrefix($0.prefix) }) else { return nil }
        let name = String(content.dropFirst(k.prefix.count)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              let base = try? FileManager.default.url(
                  for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        else { return nil }
        let safe = (name as NSString).lastPathComponent
        let filesDir = base.appendingPathComponent("files", isDirectory: true)
        for dir in k.dirs {
            let path = filesDir.appendingPathComponent(dir).appendingPathComponent(safe).path
            if FileManager.default.fileExists(atPath: path) {
                return SNMediaItem(url: "", mime: k.mime, filename: safe, groupId: "", localPath: path)
            }
        }
        return nil
    }

    /// Bytes for a media attachment: a local file (BLE-mesh) or download+decrypt
    /// from Blossom (Marmot), cached by URL.
    func mediaData(_ item: SNMediaItem) async -> Data? {
        let logId = Self.mediaLogId(for: item)
        if let path = item.localPath {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                SecureLogger.info("SonarMedia[\(logId)]: local file hit bytes=\(data.count) name=\(item.filename) mime=\(item.mime)", category: .session)
                return data
            } catch {
                SecureLogger.warning("SonarMedia[\(logId)]: local file read failed name=\(item.filename) mime=\(item.mime) error=\(error.localizedDescription)", category: .session)
                return nil
            }
        }
        if let cached = mediaImageCache[item.url] {
            SecureLogger.info("SonarMedia[\(logId)]: memory cache hit bytes=\(cached.count) name=\(item.filename) mime=\(item.mime)", category: .session)
            return cached
        }
        // Persistent on-disk cache: a decrypted blob survives relaunch and, on a
        // hit, returns WITHOUT touching the serialized Marmot FFI queue — so it
        // can never queue behind an in-flight sync (the cause of slow media).
        if let disk = Self.mediaCacheURL(for: item.url),
           FileManager.default.fileExists(atPath: disk.path) {
            do {
                let data = try Data(contentsOf: disk)
                mediaImageCache[item.url] = data
                SecureLogger.info("SonarMedia[\(logId)]: disk cache hit bytes=\(data.count) name=\(item.filename) mime=\(item.mime)", category: .session)
                return data
            } catch {
                SecureLogger.warning("SonarMedia[\(logId)]: disk cache read failed name=\(item.filename) mime=\(item.mime) error=\(error.localizedDescription)", category: .session)
            }
        }
        SecureLogger.info("SonarMedia[\(logId)]: remote fetch start name=\(item.filename) mime=\(item.mime)", category: .session)
        guard let data = await marmot.fetchMedia(groupId: item.groupId, url: item.url) else {
            SecureLogger.warning("SonarMedia[\(logId)]: remote fetch returned no data name=\(item.filename) mime=\(item.mime)", category: .session)
            return nil
        }
        mediaImageCache[item.url] = data
        SecureLogger.info("SonarMedia[\(logId)]: remote fetch hit bytes=\(data.count) name=\(item.filename) mime=\(item.mime)", category: .session)
        // Write-through to disk, protected at rest like MessageStore plaintext.
        if let disk = Self.mediaCacheURL(for: item.url) {
            do {
                try data.write(to: disk, options: [.atomic, .completeFileProtection])
            } catch {
                SecureLogger.warning("SonarMedia[\(logId)]: disk cache write failed name=\(item.filename) mime=\(item.mime) error=\(error.localizedDescription)", category: .session)
            }
        }
        return data
    }

    func stickerPack(
        authorPubkeyHex: String,
        identifier: String,
        relayUrls: [String]
    ) async -> StickerPackInfo? {
        await marmot.fetchStickerPack(
            authorPubkeyHex: authorPubkeyHex,
            identifier: identifier,
            relayUrls: relayUrls
        )
    }

    func stickerImageData(url: String, expectedSha256: String) async -> Data? {
        await marmot.fetchStickerImage(url: url, expectedSha256: expectedSha256)
    }

    func stickerImageData(for ref: MarmotService.MarmotStickerRef) async -> Data? {
        await marmot.stickerData(for: ref)
    }

    func fetchInstalledPacks() async -> [String] {
        await marmot.fetchInstalledPacks()
    }

    func installStickerPack(coordinate: String) async -> Bool {
        await marmot.installStickerPack(coordinate: coordinate)
    }

    func uninstallStickerPack(coordinate: String) async -> Bool {
        await marmot.uninstallStickerPack(coordinate: coordinate)
    }

    private static func mediaLogId(for item: SNMediaItem) -> String {
        let key = item.localPath ?? item.url
        guard !key.isEmpty else { return "empty" }
        return SHA256.hash(data: Data(key.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// `<AppSupport>/media-cache/<sha256(url)>` — content-addressed by the
    /// ciphertext's Blossom URL (a stable per-blob key). Creates the dir lazily.
    private static func mediaCacheURL(for url: String) -> URL? {
        guard !url.isEmpty, let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let dir = base.appendingPathComponent("media-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name)
    }

    /// Erase the on-disk media cache. Called by both wipe paths.
    private func clearMediaDiskCache() {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        else { return }
        try? FileManager.default.removeItem(at: base.appendingPathComponent("media-cache", isDirectory: true))
    }

    func openedDM(_ id: String, marmotGroupId knownMarmotGroupId: String? = nil) {
        if let knownMarmotGroupId {
            rememberMarmotGroup(knownMarmotGroupId, forConversationId: id)
            marmot.markConversationRead(groupId: knownMarmotGroupId)
        }
        let sonarProfile = resolvedSonarProfile(id)
        let groupId = knownMarmotGroupId
            ?? marmotGroupId(id)
            ?? sonarProfile.flatMap { marmotGroup(forNpub: $0.npub)?.id }
        let hasMarmotGroup = groupId != nil
        if !hasMarmotGroup {
            chatViewModel.startPrivateChat(with: PeerID(str: id))
        }
        // Sonar peers may carry a White Noise leg of the conversation. Opening
        // hydrates local DB state first, then reconciles relays in the
        // background; duplicate open notifications for the same id join the
        // in-flight work instead of starting another sync.
        guard hasMarmotGroup || sonarProfile != nil else { return }
        marmot.connectIfNeeded()
        let warmupKey = groupId ?? id
        if let task = openingDMTasks[warmupKey], !task.isCancelled {
            localHydratingDMs.insert(id)
            Task { [weak self] in
                await task.value
                self?.localHydratingDMs.remove(id)
            }
            return
        }
        localHydratingDMs.insert(id)
        openingDMTasks[warmupKey] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.openingDMTasks[warmupKey] = nil
            }
            guard await self.marmot.loadLocalWhenConnected(groupId: groupId) else {
                self.localHydratingDMs.remove(id)
                return
            }
            guard !Task.isCancelled else {
                self.localHydratingDMs.remove(id)
                return
            }
            let hydratedGroupId = groupId
                ?? sonarProfile.flatMap { self.marmotGroup(forNpub: $0.npub)?.id }
            if let hydratedGroupId {
                await self.marmot.loadLocalPage(groupId: hydratedGroupId)
                self.rememberMarmotGroup(hydratedGroupId, forConversationId: id)
                let fp = self.chatViewModel.getFingerprint(for: PeerID(str: id)) ?? id
                self.rememberMarmotGroup(hydratedGroupId, forConversationId: fp)
            }
            let needsHistoryBackfill = hydratedGroupId.map {
                self.marmot.messagesByGroup[$0]?.isEmpty ?? true
            } ?? false
            if !needsHistoryBackfill {
                self.localHydratingDMs.remove(id)
            }
            guard !Task.isCancelled else {
                self.localHydratingDMs.remove(id)
                return
            }
            self.refreshMarmotDMInBackground(
                warmupKey: warmupKey,
                conversationId: id,
                groupId: hydratedGroupId,
                keepLoadingUntilComplete: needsHistoryBackfill
            )
        }
    }

    func isLocallyHydratingDM(_ id: String) -> Bool {
        localHydratingDMs.contains(id)
    }

    private func refreshMarmotDMInBackground(
        warmupKey: String,
        conversationId id: String,
        groupId: String?,
        keepLoadingUntilComplete: Bool
    ) {
        if let task = refreshingDMTasks[warmupKey], !task.isCancelled {
            if keepLoadingUntilComplete {
                localHydratingDMs.insert(id)
                Task { [weak self] in
                    await task.value
                    self?.localHydratingDMs.remove(id)
                }
            }
            return
        }
        if keepLoadingUntilComplete {
            localHydratingDMs.insert(id)
        }
        refreshingDMTasks[warmupKey] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.refreshingDMTasks[warmupKey] = nil
                if keepLoadingUntilComplete {
                    self.localHydratingDMs.remove(id)
                }
            }
            await self.marmot.refreshWhenConnected(groupId: groupId, hydrateBeforeSync: false)
        }
    }

    func closedDM(_ id: String) {
        // NB: do NOT stop the Marmot subscription loop here — it now runs for as
        // long as we're connected (started in performConnect) so welcomes +
        // messages keep arriving live in the background list, not only while a
        // chat is open. It is stopped only on wipe / erase.
        if marmotGroupId(id) == nil {
            if chatViewModel.selectedPrivateChatPeer == PeerID(str: id) {
                chatViewModel.endPrivateChat()
            }
        }
    }

    /// Start a Marmot (White Noise) secure chat by npub and navigate into it.
    func startSecureChat(npub: String) {
        marmot.connectIfNeeded()
        marmot.ensureSonarDescriptor(npub)
        Task { @MainActor in
            if let groupId = await marmot.startChatReturningId(with: npub) {
                push(.dm("\(Self.marmotIDPrefix)\(groupId)"))
            }
        }
    }

    // MARK: Payments (⚡PAY receipts — docs/SONAR-PAYMENTS.md)

    /// Spendable balance once the wallet is ready; nil otherwise.
    var balanceSats: Int64? {
        if case .ready(let balance) = walletState { return balance }
        return nil
    }

    /// Wallet payment activity, newest first. Includes direct Sonar BOLT12
    /// sends and Unify nearby sends.
    var paymentActivities: [SonarPaymentActivity] {
        paymentActivityLedger.sorted
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

    /// Payment-capable when the peer has a BOLT12 offer from their Nostr
    /// descriptor, OR when the peer announced the payments capability (over
    /// BLE or from a persisted profile). Lightning payments go through BOLT12
    /// regardless of transport, so BLE proximity is not required.
    func paymentCapable(_ id: String) -> Bool {
        if directPaymentOffer(id) != nil { return true }
        if let profile = resolvedSonarProfile(id),
           profile.capabilities & SonarCapability.payments != 0 {
            return true
        }
        return false
    }

    func paymentDetailsUnavailableMessage(_ id: String) async -> String? {
        guard let npub = callNpub(id) else {
            return "Fetching payment details — try again in a moment."
        }
        let cached = marmot.sonarDescriptorsByNpub[npub]
        let hasBolt12 = cached?.bolt12Offer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if hasBolt12 {
            marmot.ensureSonarDescriptor(npub)
            return nil
        }
        await marmot.fetchSonarDescriptorSync(npub)
        let offer = marmot.sonarDescriptorsByNpub[npub]?.bolt12Offer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !offer.isEmpty { return nil }
        return "Fetching payment details — try again in a moment."
    }

    /// Voice/video calls are a Sonar-only feature. Prefer live BLE signaling, but
    /// keep the same call affordance after either BLE discovery or signed Nostr
    /// descriptor discovery when White Noise signaling exists.
    func canCall(_ id: String) -> Bool {
        guard callSignalingVia(id) != nil else { return false }
        if let profile = callProfile(id),
           profile.capabilities & SonarCapability.calls != 0 {
            return true
        }
        return callDescriptor(id)?.supportsMarmotCallSignaling == true
    }

    /// Sends money directly to the receiver's BOLT12 offer from their
    /// `sonar.meta.v1` descriptor. Fetches the descriptor synchronously if
    /// missing; returns a user-facing message only when the offer is truly
    /// unavailable after the fetch.
    @discardableResult
    func sendPay(_ id: String, sats: Int64) async -> String? {
        guard sats > 0, case .ready = walletState else { return nil }
        var offer: String?
        if let npub = callNpub(id) {
            let cached = marmot.sonarDescriptorsByNpub[npub]
            let hasBolt12 = cached?.bolt12Offer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            if !hasBolt12 {
                await marmot.fetchSonarDescriptorSync(npub)
            }
        }
        offer = directPaymentOffer(id)
        guard let offer else {
            return "Fetching payment details — try again in a moment."
        }
        let activityId = UUID().uuidString.lowercased()
        let via = dmTransport(id)
        paymentActivityLedger.recordPending(SonarPaymentActivity(
            id: activityId,
            kind: .sonarDirect,
            peerKey: id,
            peerName: peerItem(id).name,
            direction: .outgoing,
            sats: sats,
            via: via.rawValue,
            createdAt: Date(),
            destinationHash: Self.sha256Hex(offer),
            status: .pending
        ))
        let payment: SonarWalletPayment
        do {
            payment = try await wallet.send(
                destination: offer,
                amountSats: sats,
                note: "Sonar payment \(activityId)"
            )
        } catch {
            paymentActivityLedger.markFailed(activityId, message: error.localizedDescription)
            SecureLogger.error("Sonar direct payment failed: \(error)", category: .session)
            return "Payment failed: \(error.localizedDescription)"
        }
        // Wallet settled — record locally before sending receipts so the
        // ledger is consistent even if the chat send path ever fails.
        paymentActivityLedger.markPaid(activityId, payment: payment)
        payLedger.record(SonarPayEntry(
            id: activityId, peerKey: id, sats: sats,
            direction: .outgoing, state: .claimed, via: via.rawValue
        ))
        let receiptOk = await sendPaymentReceiptLines(
            [
                SonarPayMessage.pay(id: activityId, sats: sats).encoded(),
                SonarPayMessage.done(id: activityId, preimage: payment.preimage).encoded()
            ],
            to: id
        )
        if !receiptOk {
            SecureLogger.error("Sonar direct payment receipt delivery failed", category: .session)
            return "Payment sent but receipt delivery failed"
        }
        return nil
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
            payLedger.record(SonarPayEntry(
                id: id, peerKey: convId, sats: sats,
                direction: .incoming, state: .sealed, via: via.rawValue
            ))

        case .done(let id, let preimage):
            payLedger.markIncomingClaimedOrPending(id, preimage: preimage)
        }
    }

    /// Maps a raw last-message content to the home-row preview ("₿ Payment"
    /// for any ⚡PAY line, "Voice call" for ☎CALL signaling, so codecs never
    /// leak into list rows).
    static func previewText(_ content: String) -> String {
        if looksLikeCallControl(content), callParseControl(content: content) != nil {
            return "Voice call"
        }
        return SonarPayMessage.decode(content) != nil ? "\u{20BF} Payment" : content
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
        let activityId = UUID().uuidString.lowercased()
        paymentActivityLedger.recordPending(SonarPaymentActivity(
            id: activityId,
            kind: .unifyNearby,
            peerKey: id,
            peerName: peerItem(id).name,
            direction: .outgoing,
            sats: sats,
            via: SNVia.internet.rawValue,
            createdAt: Date(),
            destinationHash: Self.sha256Hex(destination),
            status: .pending
        ))
        unifyPay = (id, .paying(destination: destination, sats: sats))
        Task { [weak self] in
            guard let self else { return }
            do {
                let payment = try await self.wallet.send(
                    destination: destination,
                    amountSats: sats,
                    note: "Unify nearby payment \(activityId)"
                )
                self.paymentActivityLedger.markPaid(activityId, payment: payment)
                self.unifyPay = (id, .sent(sats: sats))
            } catch {
                self.paymentActivityLedger.markFailed(activityId, message: error.localizedDescription)
                self.unifyPay = (id, .failed(error.localizedDescription))
            }
        }
    }

    /// Dismiss the Unify pay sheet.
    func dismissUnifyPay() { unifyPay = nil }

    // MARK: Verification (real fingerprints)

    func verifyInfo(for id: String) -> SNVerifyInfo {
        if let groupId = marmotGroupId(id) {
            guard let group = marmotGroup(byId: groupId), marmot.isDirectGroup(group) else {
                return SNVerifyInfo(
                    available: false, safety: [], publicKey: "",
                    note: "Safety numbers are available for 1:1 chats."
                )
            }
            let other = directOtherNpub(in: group)
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

    // MARK: Calls

    /// mm:ss formatter (call.jsx `fmtCall`): minutes unpadded, seconds padded.
    static func fmtCall(_ sec: Int) -> String {
        "\(sec / 60):" + String(format: "%02d", sec % 60)
    }

    // MARK: - Real P2P calls (iroh transport; ☎CALL over the chat)

    /// Bind the iroh endpoint once + start the call event loop (idempotent).
    func ensureCallStarted() {
        guard !callStarted else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.marmot.callStart()
                await MainActor.run { self.callStarted = true; self.startCallLoop() }
            } catch {
                SecureLogger.error("call start failed: \(error)", category: .session)
            }
        }
    }

    /// Place an outgoing call from `convId`: register it, push the call screen,
    /// and send the ☎CALL OFFER (with our dialable address) over the chat.
    func placeCall(_ convId: String, video: Bool) {
        guard activeCall == nil else { return }
        guard canCall(convId), let via = callSignalingVia(convId) else {
            SecureLogger.debug("SonarCall: refusing call without BLE or White Noise route convId=\(convId.prefix(16))", category: .session)
            return
        }
        let callId = UUID().uuidString
        let name = callDisplayName(convId)
        // Show the ringing screen IMMEDIATELY so the tap is responsive — the iroh
        // setup (bind/offer) runs in the background. The endpoint is already bound
        // at boot via ensureCallStarted(), so we must NOT call callStart() again
        // here (a second bind blocks — which made the tap "take forever").
        SonarCallAudioRoute.configure(active: true, speakerOn: video)
        activeCall = SNActiveCall(callId: callId, convId: convId, signalingVia: via, peerName: name, video: video, incoming: false, phase: .ringing, speakerOn: video)
        push(.call(convId, video: video))
        let alreadyStarted = callStarted
        Task { [weak self] in
            guard let self else { return }
            do {
                if !alreadyStarted {
                    try await self.marmot.callStart()
                    await MainActor.run { self.callStarted = true; self.startCallLoop() }
                }
                let addr = try await self.marmot.callLocalAddress()
                try await self.marmot.callPlace(callId: callId, video: video)
                if await MainActor.run(body: { self.activeCall?.callId == callId && self.activeCall?.muted == true }) {
                    try? await self.marmot.callSetMuted(callId: callId, muted: true)
                }
                let line = callEncodeOffer(callId: callId, video: video, nodeAddrB64: addr, unixSecs: UInt64(Date().timeIntervalSince1970))
                await MainActor.run {
                    guard self.activeCall?.callId == callId else { return } // user already ended
                    if !self.sendCallControl(convId, line, via: via) {
                        Task { [weak self] in try? await self?.marmot.callHangup(callId: callId) }
                        SonarCallAudioRoute.configure(active: false, speakerOn: false)
                        self.activeCall = nil
                        self.pop()
                    }
                }
            } catch {
                SecureLogger.error("call place failed: \(error)", category: .session)
                await MainActor.run {
                    guard self.activeCall?.callId == callId else { return }
                    SonarCallAudioRoute.configure(active: false, speakerOn: false)
                    self.activeCall = nil
                    self.pop()
                }
            }
        }
    }

    /// Accept the incoming call: send ANSWER|accept (with our address), then dial.
    func acceptCall() {
        guard let c = activeCall else { return }
        var next = c
        next.phase = .connecting
        activeCall = next
        SonarCallAudioRoute.configure(active: true, speakerOn: c.speakerOn)
        let alreadyStarted = callStarted
        Task { [weak self] in
            guard let self else { return }
            do {
                // The endpoint is normally bound at boot; ensure it before dialing
                // in case ensureCallStarted() failed (e.g. no network at launch).
                if !alreadyStarted {
                    try await self.marmot.callStart()
                    await MainActor.run { self.callStarted = true; self.startCallLoop() }
                }
                let addr = try await self.marmot.callLocalAddress()
                let line = callEncodeAnswer(callId: c.callId, answer: .accept, nodeAddrB64: addr)
                let sent = await MainActor.run { self.sendCallControl(c.convId, line, via: c.signalingVia) }
                guard sent else {
                    try? await self.marmot.callHangup(callId: c.callId)
                    await MainActor.run { SonarCallAudioRoute.configure(active: false, speakerOn: false) }
                    return
                }
                if await MainActor.run(body: { self.activeCall?.callId == c.callId && self.activeCall?.muted == true }) {
                    try? await self.marmot.callSetMuted(callId: c.callId, muted: true)
                }
                try await self.marmot.callAccept(callId: c.callId)
            } catch {
                SecureLogger.error("call accept failed: \(error)", category: .session)
            }
        }
    }

    /// Decline the incoming call: send ANSWER|decline + tear down the local slot.
    func declineCall() {
        guard let c = activeCall else { return }
        let line = callEncodeAnswer(callId: c.callId, answer: .decline, nodeAddrB64: "")
        _ = sendCallControl(c.convId, line, via: c.signalingVia)
        Task { [weak self] in try? await self?.marmot.callHangup(callId: c.callId) }
    }

    /// Hang up an outgoing/connected call: tear down media + signal END. The
    /// engine's Ended event records the call-log entry and pops the screen.
    func hangupCall() {
        guard let c = activeCall else { return }
        SonarCallAudioRoute.configure(active: false, speakerOn: false)
        let line = callEncodeEnd(callId: c.callId, reason: "hangup")
        _ = sendCallControl(c.convId, line, via: c.signalingVia)
        Task { [weak self] in try? await self?.marmot.callHangup(callId: c.callId) }
    }

    func toggleCallMute() {
        guard var c = activeCall else { return }
        c.muted.toggle()
        activeCall = c
        Task { [weak self] in try? await self?.marmot.callSetMuted(callId: c.callId, muted: c.muted) }
    }

    func toggleCallSpeaker() {
        guard var c = activeCall else { return }
        c.speakerOn.toggle()
        activeCall = c
        SonarCallAudioRoute.setSpeaker(c.speakerOn)
    }

    private func startCallLoop() {
        guard callLoopTask == nil else { return }
        // Detached: the parking loop must NOT be MainActor-isolated. The blocking
        // wait already parks off-main (MarmotService.callWaitQueue); keeping the
        // loop body off the main actor too means even a degenerate fast-return
        // can't starve the UI. State mutation hops back via MainActor.run below.
        callLoopTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ev = await self.marmot.callWaitEvent(timeoutSeconds: 20)
                if Task.isCancelled { return }
                if let ev { await MainActor.run { self.onCallEvent(ev) } }
            }
        }
    }

    private func onCallEvent(_ ev: CallEventInfo) {
        guard var c = activeCall, ev.callId == c.callId else { return }
        switch ev.state {
        case .ringing: break
        case .connecting: c.phase = .connecting; activeCall = c
        case .connected: c.phase = .connected; c.connectedSecs = 0; activeCall = c; startCallTicker()
        case .ended, .failed, .declined, .busy, .missed: finalizeCall(c, ev)
        }
    }

    private func startCallTicker() {
        callTickerTask?.cancel()
        callTickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                await MainActor.run {
                    if var c = self.activeCall { c.connectedSecs += 1; self.activeCall = c }
                }
            }
        }
    }

    /// Record the call-log entry, clear state, and pop the call screen.
    private func finalizeCall(_ c: SNActiveCall, _ ev: CallEventInfo) {
        callTickerTask?.cancel(); callTickerTask = nil
        SonarCallAudioRoute.configure(active: false, speakerOn: false)
        let secs = Int(ev.durationSecs)
        recordCall(convId: c.convId, video: c.video, mine: !c.incoming, seconds: secs)
        activeCall = nil
        if case .call? = path.last { pop() }
    }

    /// Tear down call state on wipe/erase so calling rebinds cleanly after the
    /// node is recreated (the iroh endpoint must be re-bound).
    private func resetCallState() {
        callTickerTask?.cancel(); callTickerTask = nil
        callLoopTask?.cancel(); callLoopTask = nil
        SonarCallAudioRoute.configure(active: false, speakerOn: false)
        activeCall = nil
        callStarted = false
        scannedCallMessageIDs = []
    }

    private func recordCall(convId: String, video: Bool, mine: Bool, seconds: Int) {
        let connected = seconds > 0
        let now = Date()
        let record = SNCallRecord(
            id: UUID().uuidString,
            date: now,
            message: SNMessage(
                mine: mine,
                text: "",
                time: Self.clock(now),
                call: SNCallInfo(
                    kind: video ? .video : .voice,
                    missed: !connected,
                    dur: connected ? Self.fmtCall(seconds) : nil
                )
            )
        )
        var records = callLogs[convId, default: []]
        records.append(record)
        callLogs[convId] = Array(records.suffix(Self.maxStoredCallsPerConversation))
        persistCallLogs()
    }

    /// Scan inbound mesh + Marmot messages for ☎CALL control lines (deduped) and
    /// route them to the engine — never rendered as chat. Mirrors the ⚡PAY scan.
    /// Wire prefix of a ☎CALL control line (mirrors Rust `CALL_PREFIX`). Used as a
    /// pure-Swift prefilter so plain chat never crosses the FFI boundary.
    private static let callPrefix = "☎CALL"

    /// Cheap allocation-light check matching Rust `CallControl::is_control`
    /// (`content.trim_start().starts_with(CALL_PREFIX)`). No FFI.
    private static func looksLikeCallControl(_ content: String) -> Bool {
        content.drop(while: { $0.isWhitespace }).hasPrefix(callPrefix)
    }

    private func processIncomingCallLines() {
        let my = chatViewModel.meshService.myPeerID
        for (peerID, msgs) in chatViewModel.privateChats {
            for m in msgs where m.senderPeerID != my {
                guard !scannedCallMessageIDs.contains(m.id) else { continue }
                // Pure-Swift prefilter: skip the FFI for every non-☎CALL message
                // (i.e. essentially all chat) so this main-queue sink never
                // marshals ordinary messages into the core just to get back nil.
                guard Self.looksLikeCallControl(m.content) else {
                    scannedCallMessageIDs.insert(m.id)
                    continue
                }
                guard let ctrl = callParseControl(content: m.content) else {
                    scannedCallMessageIDs.insert(m.id)
                    continue
                }
                if handleCallControl(ctrl, convId: peerID.id, via: .mesh) {
                    scannedCallMessageIDs.insert(m.id)
                }
            }
        }
        for (groupId, msgs) in marmot.messagesByGroup {
            for m in msgs where !m.isMine {
                guard !scannedCallMessageIDs.contains(m.id) else { continue }
                guard Self.looksLikeCallControl(m.content) else {
                    scannedCallMessageIDs.insert(m.id)
                    continue
                }
                guard let ctrl = callParseControl(content: m.content) else {
                    scannedCallMessageIDs.insert(m.id)
                    continue
                }
                if handleCallControl(ctrl, convId: Self.marmotIDPrefix + groupId, via: .internet) {
                    scannedCallMessageIDs.insert(m.id)
                }
            }
        }
    }

    @discardableResult
    private func sendCallControl(_ convId: String, _ line: String, via: SNVia) -> Bool {
        switch via {
        case .mesh:
            guard meshReachable(convId) else {
                SecureLogger.debug("SonarCall: dropping control without mesh route convId=\(convId.prefix(16))", category: .session)
                return false
            }
            let sent = chatViewModel.meshService.sendPrivateMessageNow(line, to: PeerID(str: convId), messageID: UUID().uuidString)
            if !sent {
                SecureLogger.debug("SonarCall: dropping control without established Noise route convId=\(convId.prefix(16))", category: .session)
            }
            return sent
        case .internet:
            if let groupId = callMarmotGroupId(convId) {
                marmot.send(line, to: groupId)
                return true
            }
            guard let profile = resolvedSonarProfile(convId) else {
                SecureLogger.debug("SonarCall: internet signaling requires Marmot group convId=\(convId.prefix(16))", category: .session)
                return false
            }
            sendOverMarmot(line, npub: profile.npub)
            return true
        }
    }

    @discardableResult
    private func handleCallControl(_ ctrl: CallControlInfo, convId: String, via: SNVia) -> Bool {
        let conversationId = callConversationId(convId)
        if case let .offer(callId, _, _, _) = ctrl, !canCall(conversationId) {
            if shouldDeferOfferForSonarDescriptor(conversationId) {
                SecureLogger.debug("SonarCall: deferring offer until Sonar descriptor lookup completes convId=\(convId.prefix(16)) folded=\(conversationId.prefix(16))", category: .session)
                return false
            }
            SecureLogger.debug("SonarCall: ignoring offer without Sonar call route convId=\(convId.prefix(16)) folded=\(conversationId.prefix(16)) via=\(via)", category: .session)
            _ = sendCallControl(convId, callEncodeAnswer(callId: callId, answer: .decline, nodeAddrB64: ""), via: via)
            return true
        }
        let signalingVia = callSignalingVia(conversationId) ?? via

        switch ctrl {
        case let .offer(callId, video, nodeAddrB64, unixSecs):
            if activeCall != nil { // busy: auto-decline
                _ = sendCallControl(conversationId, callEncodeAnswer(callId: callId, answer: .busy, nodeAddrB64: ""), via: signalingVia)
                return true
            }
            let stale = Date().timeIntervalSince1970 - Double(unixSecs) > 60
            let name = callDisplayName(conversationId)
            let alreadyStarted = callStarted
            Task { [weak self] in
                guard let self else { return }
                do {
                    // The endpoint is already bound at boot — do NOT call callStart()
                    // again (a second bind blocks, so the incoming OFFER would never
                    // ring). Only bind if boot's ensureCallStarted actually failed.
                    if !alreadyStarted {
                        try await self.marmot.callStart()
                        await MainActor.run { self.callStarted = true; self.startCallLoop() }
                    }
                    try await self.marmot.callIncomingOffer(callId: callId, addrB64: nodeAddrB64, video: video)
                    if stale {
                        try? await self.marmot.callHangup(callId: callId)
                        await MainActor.run { self.recordCall(convId: conversationId, video: video, mine: false, seconds: 0) }
                        return
                    }
                    await MainActor.run {
                        self.activeCall = SNActiveCall(callId: callId, convId: conversationId, signalingVia: signalingVia, peerName: name, video: video, incoming: true, phase: .ringing, speakerOn: video)
                        self.push(.call(conversationId, video: video))
                    }
                } catch {
                    SecureLogger.error("incoming offer failed: \(error)", category: .session)
                }
            }
        case let .answer(callId, answer, nodeAddrB64):
            if activeCall?.callId == callId {
                Task { [weak self] in try? await self?.marmot.callAnswer(callId: callId, answer: answer, addrB64: nodeAddrB64) }
            }
        case let .cancel(callId):
            if activeCall?.callId == callId { Task { [weak self] in try? await self?.marmot.callHangup(callId: callId) } }
        case let .end(callId, _):
            if activeCall?.callId == callId { Task { [weak self] in try? await self?.marmot.callHangup(callId: callId) } }
        }
        return true
    }

    private func shouldDeferOfferForSonarDescriptor(_ conversationId: String) -> Bool {
        // BLE discovery is authoritative when present; only defer for npub-only
        // Marmot contacts whose public Sonar descriptor is still unknown.
        guard callProfile(conversationId) == nil,
              let npub = callNpub(conversationId),
              marmot.sonarDescriptorsByNpub[npub] == nil
        else { return false }
        if let miss = marmot.sonarDescriptorMissesByNpub[npub],
           Date().timeIntervalSince(miss) < 60 {
            return false
        }
        marmot.ensureSonarDescriptor(npub)
        return true
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

    // MARK: Delete a single chat (per-row)

    /// Delete or leave ONE conversation. Handles all three Messages-row
    /// kinds: a pure White Noise/Marmot group (`marmot:<id>`), a mesh/bitchat
    /// peer, or a Sonar peer whose conversation spans BOTH a mesh leg and a White
    /// Noise leg (delete both). Multi-member Marmot groups publish a leave
    /// proposal; other deletes are local-only.
    func deleteChat(_ id: String) {
        if let groupId = marmotGroupId(id) {
            forgetMarmotGroupMappings(forGroupId: groupId)
            let shouldLeave = isMultiMemberMarmotGroupId(id)
            Task {
                if shouldLeave {
                    await marmot.leaveGroup(groupId)
                } else {
                    await marmot.deleteGroup(groupId)
                }
            }
        } else {
            // Mesh / Sonar peer: delete the mesh transcript...
            chatViewModel.deleteConversation(with: PeerID(str: id))
            // ...and the folded White Noise leg, if this peer has one.
            if let profile = resolvedSonarProfile(id), let g = marmotGroup(forNpub: profile.npub) {
                forgetMarmotGroupMappings(forGroupId: g.id)
                Task { await marmot.deleteGroup(g.id) }
            }
        }
        // If we're currently viewing this chat, return to the Messages list.
        path.removeAll { route in
            if case .dm(let rid) = route { return rid == id }
            return false
        }
        objectWillChange.send()
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
        openingDMTasks.values.forEach { $0.cancel() }
        openingDMTasks = [:]
        refreshingDMTasks.values.forEach { $0.cancel() }
        refreshingDMTasks = [:]
        pendingMarmotSends = [:]
        scannedPayMessageIDs = []
        pendingPayPeer = nil
        localHydratingDMs = []
        clearMarmotConversationGroups()
        publishedBolt12Offer = nil
        publishedCallDescriptor = false
        publishingPaymentMetadata = false
        needsPaymentMetadataPublish = false
        refreshedKnownDescriptorsForRelaySession = false
        clearCallLogs()
        // The node is recreated by eraseChatsKeepIdentity → reset call state so
        // the iroh endpoint rebinds (the marmot.$npub sink calls ensureCallStarted).
        resetCallState()
        // Payment rows render inside conversations — clear local ledgers too.
        // The Lightning wallet seed/balance is separate and is NOT touched.
        payLedger.wipe()
        paymentActivityLedger.wipe()
        mediaImageCache = [:]
        pendingUploadMediaCache = [:]
        clearMediaDiskCache()
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
        meshPeerFirstSeenAt = [:]
        pendingCapabilityRefreshKeys = []
        defaults.removeObject(forKey: Keys.sonarProfiles)
        openingDMTasks.values.forEach { $0.cancel() }
        openingDMTasks = [:]
        refreshingDMTasks.values.forEach { $0.cancel() }
        refreshingDMTasks = [:]
        localHydratingDMs = []
        clearMarmotConversationGroups()
        // Stop scanning for Unify peers and clear the discovered list (no
        // secrets are stored, but the list must not survive a panic wipe).
        unify.stop()
        // Stop advertising as a Unify receiver (the served offer is derived
        // from the wallet seed being wiped below).
        unifyReceiver.stop()
        incomingWalletTask?.cancel()
        incomingWalletTask = nil
        publishedBolt12Offer = nil
        publishedCallDescriptor = false
        publishingPaymentMetadata = false
        needsPaymentMetadataPublish = false
        refreshedKnownDescriptorsForRelaySession = false
        pendingMarmotSends = [:]
        // Forget every ⚡PAY coin and the Lightning wallet seed (separate
        // keychain service owned by SonarWalletKit).
        #if os(iOS) || os(macOS)
        BridgedWallet.wipeWalletStorage()
        #endif
        payLedger.wipe()
        paymentActivityLedger.wipe()
        mediaImageCache = [:]
        pendingUploadMediaCache = [:]
        clearMediaDiskCache()
        scannedPayMessageIDs = []
        pendingPayPeer = nil
        clearCallLogs()
        resetCallState()
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
