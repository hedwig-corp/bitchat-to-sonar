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
import ImageIO
import SonarCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private enum SonarCallAudioRoute {
    static func configure(active: Bool, speakerOn: Bool, proximityEnabled: Bool = false) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            if active {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
                try session.setActive(true)
                try session.overrideOutputAudioPort(speakerOn ? .speaker : .none)
                UIDevice.current.isProximityMonitoringEnabled = proximityEnabled
            } else {
                UIDevice.current.isProximityMonitoringEnabled = false
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

enum SonarLocalNotificationKind {
    case message
    case payment
    case call
    case trill
    case invite
    case mention
    case geohash
    case network
}

struct SonarLocalNotificationPrefs {
    var enabled = true
    var showNames = true
    var showPreview = false
    var showPaymentAmount = true
}

struct SonarLocalNotification {
    let title: String
    let body: String
    let identifier: String
    let userInfo: [String: Any]
}

enum SonarLocalNotificationRouter {
    static func make(
        idKey: String,
        kind: SonarLocalNotificationKind? = nil,
        conversationTitle: String?,
        senderName: String? = nil,
        groupName: String? = nil,
        preview: String?,
        prefs: SonarLocalNotificationPrefs,
        unreadCount: UInt64 = 1,
        userInfo: [String: Any] = [:]
    ) -> SonarLocalNotification? {
        let input = SonarNotificationRenderInputInfo(
            enabled: prefs.enabled,
            kindHint: kind?.ffiKind,
            conversationTitle: conversationTitle,
            senderName: senderName,
            groupName: groupName,
            contentPreview: preview,
            unreadCount: max(1, unreadCount),
            showNames: prefs.showNames,
            showPreview: prefs.showPreview,
            showPaymentAmount: prefs.showPaymentAmount
        )
        guard let envelope = sonarRenderNotification(input: input) else { return nil }
        return SonarLocalNotification(
            title: envelope.title,
            body: envelope.body,
            identifier: "sonar-\(identifierSegment(envelope.kind))-\(idKey)",
            userInfo: userInfo
        )
    }

    private static func identifierSegment(_ kind: SonarNotificationKindInfo) -> String {
        switch kind {
        case .message: return "message"
        case .payment: return "payment"
        case .call: return "call"
        case .trill: return "trill"
        case .invite: return "invite"
        case .mention: return "mention"
        case .geohash: return "geohash"
        case .network: return "network"
        }
    }
}

private extension SonarLocalNotificationKind {
    var ffiKind: SonarNotificationKindInfo {
        switch self {
        case .message: return .message
        case .payment: return .payment
        case .call: return .call
        case .trill: return .trill
        case .invite: return .invite
        case .mention: return .mention
        case .geohash: return .geohash
        case .network: return .network
        }
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

/// A folded direct DM keeps the Marmot counterpart's profile title. BLE radar
/// names are transport metadata and must never relabel an encrypted transcript.
func snFoldedDirectMarmotHomeTitle(
    isDirectGroup: Bool,
    marmotProfileTitle: String,
    peerDerivedTitle: String
) -> String {
    isDirectGroup ? marmotProfileTitle : peerDerivedTitle
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

private struct SNPendingMarmotChat {
    let npub: String
    let createdAt: Date
}

private struct SNPendingMarmotGroup {
    let name: String
    let members: [String]
    let createdAt: Date
}

private struct SNPendingMarmotSend {
    let chatId: String
    let text: String
    let messageId: String
}

private struct SNPendingMarmotGroupSend {
    let text: String
    let messageId: String
}

struct SNMarmotRouteReplacement: Equatable {
    let pendingId: String
    let realId: String
}

struct SNMarmotRouteFailure: Equatable {
    let pendingId: String
    let nonce = UUID()
}

enum SNAttachmentRoutePlan: Equatable {
    case ready
    case startSecureChat(npub: String)
    case unavailable
}

enum SNAttachmentRoutePreparationResult: Equatable {
    case ready
    case unavailable
    case failed
}

func snAttachmentRoutePlan(
    hasExistingRoute: Bool,
    pendingNpub: String?,
    resolvedNpub: String?
) -> SNAttachmentRoutePlan {
    if hasExistingRoute { return .ready }
    if let pendingNpub, !pendingNpub.isEmpty {
        return .startSecureChat(npub: pendingNpub)
    }
    if let resolvedNpub, !resolvedNpub.isEmpty {
        return .startSecureChat(npub: resolvedNpub)
    }
    return .unavailable
}

struct SNMessage: Identifiable, Equatable {
    var id: String = UUID().uuidString
    var mine: Bool = false
    var action: Bool = false
    var author: String?
    var text: String
    var time: String
    var sortDate: Date?
    /// Persisted local transcript source used only by the bounded k-way pager.
    /// Optimistic/ephemeral rows intentionally have no source and are always
    /// rebuilt from the authoritative projection.
    var transcriptSourceID: String? = nil
    var via: SNVia?
    var state: String?
    /// 0...1 while a Blossom upload is in flight for this optimistic media row.
    var uploadProgress: Double? = nil
    /// Non-nil = render as a PayBubble instead of a text bubble.
    var pay: SNPayInfo?
    /// Non-nil = render a compact CallLog row instead of a bubble (call.jsx).
    var call: SNCallInfo?
    /// True = ⚡TRILL nudge: render the centered NudgeMsg pill instead of a
    /// bubble. The raw control line must never be shown (`text` stays empty).
    var trill: Bool = false
    /// Encrypted media attachments (White Noise / Marmot MIP-04). Non-empty ⇒
    /// render a media bubble (image inline, else a file chip).
    var media: [SNMediaItem] = []
    /// Non-nil = render as a sticker bubble instead of text.
    var stickerRef: MarmotService.MarmotStickerRef?
}

/// Internet and mesh failures use different resend pipelines. The retry
/// affordance introduced here is backed only by Marmot's durable outbox.
func snCanRetryFailedMessage(_ message: SNMessage) -> Bool {
    message.mine && message.via == .internet && message.state == "Couldn't send"
}

/// Optimistic sticker rows intentionally keep their display text empty. Retry
/// must rebuild the transport marker from the retained sticker reference.
func snRetryContent(_ message: SNMessage) -> String? {
    if let ref = message.stickerRef {
        return meshStickerContent(
            packCoordinate: ref.packCoordinate,
            shortcode: ref.shortcode,
            plaintextSha256: ref.plaintextSha256
        )
    }
    return message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? nil
        : message.text
}

@MainActor
func snIsFailedOptimisticStickerMessage(_ message: SNMessage) -> Bool {
    MarmotChatModel.isFailedOptimisticMessageId(message.id)
        && message.media.isEmpty
        && message.stickerRef != nil
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
    /// Stored attachment dimensions (MIP-04 metadata). Signal pre-sizes media
    /// cells from these so the decoded image never reflows the transcript.
    var width: UInt32? = nil
    var height: UInt32? = nil
    /// Optional duration hint for voice notes (milliseconds). Older records may
    /// be nil; the playback engine probes metadata off the local file then.
    var durationMs: UInt64? = nil
    var isImage: Bool { mime.hasPrefix("image/") }
    var isAudio: Bool { mime.hasPrefix("audio/") }
    var isGif: Bool {
        mime.caseInsensitiveCompare("image/gif") == .orderedSame ||
        filename.lowercased().hasSuffix(".gif")
    }
}

enum SNMediaTransferPhase: Equatable {
    case notDownloaded
    case downloading
    case available
    case failed
}

/// Signal-style attachment state. A remote pointer becomes a local file before
/// any viewer is presented; network activity never owns a fullscreen surface.
struct SNMediaTransferState: Equatable {
    let phase: SNMediaTransferPhase
    let progress: Double?
    let localURL: URL?

    static let notDownloaded = SNMediaTransferState(
        phase: .notDownloaded,
        progress: nil,
        localURL: nil
    )

    static func downloading(_ progress: Double?) -> SNMediaTransferState {
        SNMediaTransferState(phase: .downloading, progress: progress, localURL: nil)
    }

    static func available(_ url: URL) -> SNMediaTransferState {
        SNMediaTransferState(phase: .available, progress: 1, localURL: url)
    }

    static let failed = SNMediaTransferState(phase: .failed, progress: nil, localURL: nil)
}

private final class SNMediaDownloadListener: MediaDownloadListener, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let progressHandler: @Sendable (UInt64, UInt64?) -> Void

    init(progress: @escaping @Sendable (UInt64, UInt64?) -> Void) {
        self.progressHandler = progress
    }

    func onProgress(bytesReceived: UInt64, totalBytes: UInt64?) {
        progressHandler(bytesReceived, totalBytes)
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Live Blossom upload fractions keyed by optimistic message id.
///
/// Collection-host cells only reconfigure when the transcript `heightKey`
/// changes — progress is intentionally excluded from that key (bar height is
/// constant). Bubbles therefore observe this object directly (Compose
/// `mediaUploadFraction` parity) instead of waiting for a cell rebuild.
@MainActor
final class SNMediaUploadProgressSource: ObservableObject {
    @Published private(set) var fractions: [String: Double] = [:]

    func note(id: String, fraction: Double) {
        // Assign a new dictionary — in-place subscript mutation does not
        // reliably fire `@Published` / `objectWillChange`.
        var next = fractions
        next[id] = fraction
        fractions = next
    }

    func clear(id: String) {
        guard fractions[id] != nil else { return }
        var next = fractions
        next.removeValue(forKey: id)
        fractions = next
    }
}

/// Bridges UniFFI upload progress into the optimistic media bubble bar.
final class SNMediaUploadListener: MediaUploadListener, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastEmit = Date.distantPast
    private let progressHandler: @Sendable (String, Double) -> Void

    init(progress: @escaping @Sendable (String, Double) -> Void) {
        self.progressHandler = progress
    }

    func onProgress(clientPendingId: String, bytesSent: UInt64, totalBytes: UInt64) {
        let fraction: Double
        if totalBytes == 0 {
            fraction = 0
        } else {
            fraction = min(1, Double(bytesSent) / Double(totalBytes))
        }
        // ~100ms throttle mirrors download progress paint cadence.
        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(lastEmit) >= 0.1 || fraction >= 1 || fraction <= 0
        if due { lastEmit = now }
        lock.unlock()
        guard due else { return }
        progressHandler(clientPendingId, fraction)
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
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
    /// Muted chat: the row shows a bell-slash instead of the unread dot.
    var muted: Bool = false
}

/// Stable home ordering shared by the live list and the regression smoke
/// suite. A newly received message moves only its cryptographic conversation;
/// equal timestamps retain deterministic title ordering across restarts.
func snSortDMRowsByRecency(_ rows: [SNDMRow]) -> [SNDMRow] {
    rows.sorted {
        let lhs = $0.lastDate ?? .distantPast
        let rhs = $1.lastDate ?? .distantPast
        return lhs == rhs
            ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            : lhs > rhs
    }
}

/// Stable conversation identity for BLE fingerprints that advertise the same
/// Sonar account (parity with Compose `meshConversationIdentityKey`). Unlinked
/// peers stay isolated by their Noise fingerprint / short peer id.
func snMeshConversationIdentityKey(peerId: String, linkedNpubHex: String?) -> String {
    let linked = linkedNpubHex?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    if let linked,
       linked.count == 64,
       linked.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) {
        return "npub:\(linked)"
    }
    return "peer:\(peerId)"
}

func snGroupMeshPeerIdsByIdentity(
    peerIds: [String],
    linkedNpubByPeer: [String: String]
) -> [[String]] {
    Dictionary(grouping: Set(peerIds)) {
        snMeshConversationIdentityKey(peerId: $0, linkedNpubHex: linkedNpubByPeer[$0])
    }
    .values
    .map { $0.sorted() }
    .sorted { ($0.first ?? "") < ($1.first ?? "") }
}

/// Prefer an already-persisted fold target so a row key stays stable; otherwise
/// choose a deterministic fingerprint from the alias set.
func snSelectCanonicalMeshPeerId(
    aliases: [String],
    persistedFoldPeerIds: Set<String>
) -> String? {
    aliases.filter { persistedFoldPeerIds.contains($0) }.min()
        ?? aliases.min()
}

/// Compose-parity filter for reverse-index hits (`peerKeys` / `meshPeerAliases`).
/// Keep only candidates whose *current* linked npub hex matches `targetNpubHex`,
/// so a stale or conflicting favorites claim cannot pull a different person into
/// the alias set (home row, transcript, mute, live send route).
func snFilterPeerKeysMatchingNpubHex(
    candidates: [String],
    linkedNpubHexByPeer: [String: String],
    targetNpubHex: String
) -> [String] {
    let target = targetNpubHex
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard target.count == 64,
          target.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
        return []
    }
    return candidates.filter {
        linkedNpubHexByPeer[$0]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == target
    }.sorted()
}

/// Pick the live BLE route among aliases (Compose `liveMeshRoutePeerId`).
/// Prefer a directly connected peer; optionally fall back to retained reachability
/// for plain bitchat (not Sonar discovery peers).
func snSelectLiveMeshRoutePeerId(
    aliases: [String],
    isConnected: (String) -> Bool,
    isReachable: (String) -> Bool,
    requireDirectConnection: Bool
) -> String? {
    for alias in aliases where isConnected(alias) { return alias }
    if !requireDirectConnection {
        for alias in aliases where isReachable(alias) { return alias }
    }
    return nil
}

/// Collapse mesh home rows that share a linked Sonar npub into one person-row
/// (R-003 / Fix What We Break). Different Noise fingerprints for the same
/// account must not render as two Messages entries.
func snCollapseMeshDMRowsByIdentity(
    rowsByPeer: [String: SNDMRow],
    linkedNpubByPeer: [String: String],
    persistedFoldPeerIds: Set<String>
) -> [String: SNDMRow] {
    var result: [String: SNDMRow] = [:]
    for aliases in snGroupMeshPeerIdsByIdentity(
        peerIds: Array(rowsByPeer.keys),
        linkedNpubByPeer: linkedNpubByPeer
    ) {
        guard let canonical = snSelectCanonicalMeshPeerId(
            aliases: aliases,
            persistedFoldPeerIds: persistedFoldPeerIds
        ) else { continue }
        var best: SNDMRow?
        var unread = false
        var presence = false
        var verified = false
        var muted = false
        for alias in aliases {
            guard let row = rowsByPeer[alias] else { continue }
            unread = unread || row.unread
            presence = presence || row.presence
            verified = verified || row.verified
            muted = muted || row.muted
            if best == nil || (row.lastDate ?? .distantPast) > (best!.lastDate ?? .distantPast) {
                best = row
            }
        }
        guard let chosen = best else { continue }
        result[canonical] = SNDMRow(
            id: canonical,
            title: chosen.title,
            preview: chosen.preview,
            time: chosen.time,
            unread: unread,
            presence: presence,
            verified: verified,
            isMarmot: chosen.isMarmot,
            lastDate: chosen.lastDate,
            marmotGroupId: chosen.marmotGroupId,
            muted: muted
        )
    }
    return result
}

/// Re-key mesh rows onto the same canonical id `sonarPeerKey(forNpub:)` would
/// pick. Collapse only sees fingerprints that currently have a DM row; the
/// Marmot fold path uses the full peerKeys universe (including inactive
/// persisted fingerprints). Without this alignment, a stale fingerprint that
/// sorts first becomes the fold target while the live row stays under another
/// key — `byKey[foldKey]` misses and the person shows twice again.
func snRekeyMeshRowsToCanonicalIds(
    rowsByPeer: [String: SNDMRow],
    canonicalIdForPeer: (String) -> String?
) -> [String: SNDMRow] {
    var result: [String: SNDMRow] = [:]
    for (key, row) in rowsByPeer {
        let canonical = canonicalIdForPeer(key) ?? key
        if let existing = result[canonical] {
            let preferRow = (row.lastDate ?? .distantPast) >= (existing.lastDate ?? .distantPast)
            let chosen = preferRow ? row : existing
            result[canonical] = SNDMRow(
                id: canonical,
                title: chosen.title,
                preview: chosen.preview,
                time: chosen.time,
                unread: existing.unread || row.unread,
                presence: existing.presence || row.presence,
                verified: existing.verified || row.verified,
                isMarmot: chosen.isMarmot,
                lastDate: chosen.lastDate,
                marmotGroupId: chosen.marmotGroupId,
                muted: existing.muted || row.muted
            )
        } else if canonical == row.id {
            result[canonical] = row
        } else {
            result[canonical] = SNDMRow(
                id: canonical,
                title: row.title,
                preview: row.preview,
                time: row.time,
                unread: row.unread,
                presence: row.presence,
                verified: row.verified,
                isMarmot: row.isMarmot,
                lastDate: row.lastDate,
                marmotGroupId: row.marmotGroupId,
                muted: row.muted
            )
        }
    }
    return result
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

enum SonarAccountRestoreError: LocalizedError {
    case walletCleanupFailed
    case accountReplacementFailed

    var errorDescription: String? {
        switch self {
        case .walletCleanupFailed:
            return "Wallet storage couldn't be cleared. Restart Sonar and try again."
        case .accountReplacementFailed:
            return "Account storage couldn't be replaced. Restart Sonar and try again."
        }
    }
}

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
        static let notificationsEnabled = SonarNotificationPreferenceStore.enabledKey
        static let notificationShowNames = SonarNotificationPreferenceStore.showNamesKey
        static let notificationShowPreview = SonarNotificationPreferenceStore.showPreviewKey
        static let discoverNewPeople = "sonar.ble.discoverNewPeople"
        static let bleKnownChatKeys = "sonar.ble.knownChatKeys.v1"
        static let marmotNsecKeychainKey = SonarAccountKeyExport.marmotNsecKey
    }

    #if os(iOS)
    private static let appGroupId = "group.sh.hedwig.sonar"
    #endif

    private static let maxStoredCallsPerConversation = 100
    private static let capabilitySettleWindow: TimeInterval = 1.5
    private static let pendingMarmotDirectSendQueueLimit = 100
    private static let pendingMarmotGroupSendQueueLimit = 100

    static let marmotIDPrefix = "marmot:"
    /// Default domain for unified handles claimed through the app. Core owns
    /// the constant (pure FFI read) — never inline the literal, the
    /// external-vs-claim routing depends on this exact string.
    static let handleDomain = defaultHandleDomain()
    static let pendingMarmotIDPrefix = "marmot-pending:"
    static let pendingMarmotGroupIDPrefix = "marmot-group-pending:"
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
    /// The extra Unify payer scan is useful only while Radar is visible. Keep
    /// this separate from the mesh radio, which remains available for chats.
    private var isNearbyVisible = false
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
    private let networkService = NetworkActivationService.shared
    private let defaults = UserDefaults.standard

    /// Navigation stack below the home root.
    @Published var path: [SonarRoute] = []
    @Published var toast: String? = nil
    /// Invalidates in-flight toast dismissals when a newer toast is shown.
    private var toastSession = SNToastSession()
    /// Replaced on each `showToast` so rapid toasts don't pile sleeping tasks.
    private var toastDismissTask: Task<Void, Never>?
    @Published private(set) var onboarded: Bool
    @Published private(set) var mode: String
    @Published private(set) var discoverNewPeople: Bool
    @Published private(set) var batterySavingEnabled: Bool
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
    /// Lazy reverse index: npub hex → mesh peer keys. Invalidated when live /
    /// persisted profiles change so `peerKeys(linkedToNpub:)` stays O(1) on the
    /// chat-open hot path instead of rescanning every contact.
    private var peerKeysByNpubHex: [String: Set<String>]?
    /// Reverse of `peerKeysByNpubHex`: canonical peer key → stored npub string.
    /// Built with `peerKeysIndex()` so `linkedNpub(forPeerKey:)` stays O(1) on
    /// `dmRows` instead of scanning favorites per row.
    private var npubByPeerKey: [String: String]?
    /// Folded DM id -> Marmot group id. DM rows often use a peer/fingerprint id,
    /// while the encrypted transcript is keyed by the Marmot MLS group id.
    private var marmotGroupIdsByConversationId: [String: String] = [:]
    /// Our optional BIP-353 payment address ("" = unset, TLV omitted).
    @Published private(set) var bip353: String
    /// Lifecycle of the unified handle claim (name@sonarprivacy.xyz). The
    /// registrar POST runs in the core off the main thread; this mirrors it
    /// for the profile screen only.
    enum HandleClaimState: Equatable {
        case idle
        case claiming
        case claimed(String)
        case failed(String)
    }
    @Published private(set) var handleClaimState: HandleClaimState = .idle
    /// The address actually claimed at the Sonar registrar (core sidecar is
    /// the durable record). Distinct from `bip353`, which may also hold an
    /// external payment address from another wallet: only a core-claimed
    /// address gets the claim checkmark and kind-0 `nip05`.
    @Published private(set) var coreClaimedHandle: String?
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

    // ── Media preview (confirmation before send) ──
    struct PendingMediaPreview: Sendable {
        let peerId: String
        let tempURL: URL
        let filename: String
        let mime: String
        let caption: String

        init(peerId: String, tempURL: URL, filename: String, mime: String, caption: String = "") {
            self.peerId = peerId
            self.tempURL = tempURL
            self.filename = filename
            self.mime = mime
            self.caption = caption
        }
    }

    /// Bytes source for one staged attachment. Photos arrive as in-memory
    /// `Data`; videos arrive as picker-owned temp FILES and are moved into the
    /// preview directory without ever buffering the payload through memory.
    enum PendingMediaPayload: Sendable {
        case data(Data)
        case file(URL)
    }

    @Published var pendingMediaPreviews: [PendingMediaPreview] = []
    private var mediaPreviewGeneration: UInt64 = 0

    /// In-memory composer drafts keyed by chat id (DM peer/group, channel id).
    /// Survives leaving a chat and returning within the same process; cleared on send.
    /// Intentionally NOT `@Published`: publishing on every keystroke would invalidate
    /// every `SonarAppStore` observer and re-enter the UIKit transcript host
    /// (`updateUIViewController` → `applySnapshot`) while typing.
    private var composerDrafts: [String: String] = [:]

    /// Boundary-only published mirror of draft non-emptiness per chat. The draft
    /// map above stays unpublished, but the composer's send/mic toggle must
    /// re-render the moment a draft crosses empty <-> non-empty -- otherwise the
    /// mic button lingers after typing starts and a tap on it records and sends
    /// an empty voice note. Publishes only on the boundary (first char / clear),
    /// never per keystroke.
    @Published private(set) var composerDraftHasText: [String: Bool] = [:]

    func composerDraft(for chatId: String) -> String {
        composerDrafts[chatId] ?? ""
    }

    func setComposerDraft(_ text: String, for chatId: String) {
        let nextFlags = snUpdatedComposerDraftHasText(flags: composerDraftHasText, chatId: chatId, text: text)
        if nextFlags != composerDraftHasText { composerDraftHasText = nextFlags }
        let next = snUpdatedComposerDrafts(drafts: composerDrafts, chatId: chatId, text: text)
        guard next != composerDrafts else { return }
        composerDrafts = next
    }

    func composerDraftBinding(for chatId: String) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.composerDraft(for: chatId) ?? "" },
            set: { [weak self] in self?.setComposerDraft($0, for: chatId) }
        )
    }

    private var currentDMId: String? {
        if case .dm(let id)? = path.last { return id }
        return nil
    }

    private func nextMediaPreviewGeneration() -> UInt64 {
        mediaPreviewGeneration += 1
        return mediaPreviewGeneration
    }

    private nonisolated static func writeTempMediaFile(_ data: Data, suffix: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sonar-preview")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + suffix)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private nonisolated static func readTempMediaFile(_ url: URL) -> Data? {
        return try? Data(contentsOf: url)
    }

    /// Move an already-on-disk picked file into the preview directory (same
    /// volume ⇒ a rename, no byte copy). Falls back to copy across volumes.
    private nonisolated static func moveTempMediaFile(_ source: URL, suffix: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sonar-preview")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + suffix)
        do {
            try FileManager.default.moveItem(at: source, to: url)
            return url
        } catch {
            // Consume the source either way — a file we can't stage is a file
            // we must not strand in the picker temp dir.
            defer { try? FileManager.default.removeItem(at: source) }
            do {
                try FileManager.default.copyItem(at: source, to: url)
                return url
            } catch {
                return nil
            }
        }
    }

    private nonisolated static func deleteTempMediaFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private nonisolated static func deletePreviewTempFiles(_ previews: [PendingMediaPreview]) {
        for preview in previews {
            deleteTempMediaFile(preview.tempURL)
        }
    }

    private nonisolated static func reencodeToJpeg(_ data: Data) -> Data? {
        #if canImport(UIKit)
        return UIImage(data: data)?.jpegData(compressionQuality: 0.85)
        #else
        return data
        #endif
    }

    /// Receivers hard-cap media downloads at this plaintext size (core
    /// `MAX_MEDIA_PLAINTEXT_BYTES`, read through the FFI so the sender can
    /// never drift from receiver enforcement) — anything larger publishes a
    /// message no client can fetch.
    private nonisolated static let maxMediaPlaintextBytes = Int(SonarCore.maxMediaPlaintextBytes())

    /// Aggregate plaintext ceiling for one album send (core
    /// `MAX_MEDIA_TOTAL_PLAINTEXT_BYTES`): every attachment is memory-resident
    /// at once during `send_media_multi`.
    private nonisolated static let maxMediaTotalPlaintextBytes = Int(SonarCore.maxMediaTotalPlaintextBytes())

    private nonisolated static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    /// Delete picker/preview temp files older than a day. Normal flows clean
    /// up via `defer`s; this sweep catches files stranded by a crash or kill.
    private nonisolated static func sweepStaleMediaTempFiles() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for name in ["sonar-preview", "sonar-picked"] {
            let dir = fm.temporaryDirectory.appendingPathComponent(name)
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if modified < cutoff {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }

    /// Outcome of finalizing a staged video: distinguishes "cannot fit under
    /// the cap" from an I/O or export failure so the toast never lies.
    private enum VideoFinalizeResult: Sendable {
        case ready(data: Data, filename: String, mime: String)
        case tooLarge
        case failed
    }

    /// Finalize a staged video on send confirmation (Signal-style lazy
    /// finalization): pass the original bytes through when they already fit
    /// under the receiver download cap, otherwise re-encode to a smaller
    /// H.264/AAC MP4 with `AVAssetExportSession` and send that if it fits.
    /// Consumes (deletes) the staged temp file.
    private nonisolated static func finalizeVideoForSend(
        _ url: URL,
        filename: String,
        mime: String
    ) async -> VideoFinalizeResult {
        defer { deleteTempMediaFile(url) }
        if let size = fileSize(url), size <= maxMediaPlaintextBytes {
            guard let data = readTempMediaFile(url) else { return .failed }
            return .ready(data: data, filename: filename, mime: mime)
        }
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset960x540) else {
            return .failed
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonar-preview")
            .appendingPathComponent(UUID().uuidString + ".mp4")
        defer { deleteTempMediaFile(outURL) }
        export.shouldOptimizeForNetworkUse = true
        if #available(iOS 18.0, macOS 15.0, *) {
            do {
                try await export.export(to: outURL, as: .mp4)
            } catch {
                return .failed
            }
        } else {
            export.outputURL = outURL
            export.outputFileType = .mp4
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                export.exportAsynchronously { continuation.resume() }
            }
            guard export.status == .completed else { return .failed }
        }
        guard let outSize = fileSize(outURL) else { return .failed }
        guard outSize <= maxMediaPlaintextBytes else { return .tooLarge }
        guard let data = readTempMediaFile(outURL) else { return .failed }
        let stem = (filename as NSString).deletingPathExtension
        return .ready(data: data, filename: (stem.isEmpty ? "video" : stem) + ".mp4", mime: "video/mp4")
    }

    private func deletePreviewTempFilesAsync(_ previews: [PendingMediaPreview]) {
        guard !previews.isEmpty else { return }
        Task.detached(priority: .utility) {
            Self.deletePreviewTempFiles(previews)
        }
    }

    private func cleanupPreviewTempFiles() {
        _ = nextMediaPreviewGeneration()
        let previews = pendingMediaPreviews
        pendingMediaPreviews = []
        deletePreviewTempFilesAsync(previews)
    }

    func stageMediaPreview(_ peerId: String, data: Data, filename: String, mime: String) {
        stageMediaPreviews(peerId, items: [(payload: .data(data), filename: filename, mime: mime)])
    }

    /// Stage one or more picked photos/videos for the pre-send preview. All
    /// items land as temp files off-main (Signal-style: full-quality until send
    /// confirmation); the batch replaces any previously staged previews. Video
    /// temp files keep their container extension — `AVAsset` needs it to open
    /// the file for the poster frame and the lazy send-time re-encode.
    func stageMediaPreviews(
        _ peerId: String,
        items: [(payload: PendingMediaPayload, filename: String, mime: String)]
    ) {
        guard currentDMId == peerId, !items.isEmpty else {
            // Never staged — drop any picker-owned temp files so a video
            // picked right before navigating away doesn't orphan on disk.
            Task.detached(priority: .utility) {
                for item in items {
                    if case .file(let url) = item.payload { Self.deleteTempMediaFile(url) }
                }
            }
            return
        }
        let generation = nextMediaPreviewGeneration()
        let previous = pendingMediaPreviews
        pendingMediaPreviews = []
        deletePreviewTempFilesAsync(previous)
        Task { @MainActor in
            let written = await Task.detached(priority: .userInitiated, operation: { () -> [(URL, String, String)] in
                items.compactMap { item in
                    let suffix: String
                    if item.mime == "image/gif" {
                        suffix = ".gif"
                    } else if item.mime.hasPrefix("video/") {
                        let ext = (item.filename as NSString).pathExtension
                        suffix = "." + (ext.isEmpty ? "mp4" : ext)
                    } else {
                        suffix = ".img"
                    }
                    switch item.payload {
                    case .data(let data):
                        guard let url = Self.writeTempMediaFile(data, suffix: suffix) else { return nil }
                        return (url, item.filename, item.mime)
                    case .file(let source):
                        guard let url = Self.moveTempMediaFile(source, suffix: suffix) else { return nil }
                        return (url, item.filename, item.mime)
                    }
                }
            }).value
            guard written.count == items.count else {
                Task.detached(priority: .utility) {
                    for (url, _, _) in written { Self.deleteTempMediaFile(url) }
                }
                showToast("Couldn't prepare media.")
                return
            }
            guard mediaPreviewGeneration == generation, currentDMId == peerId else {
                Task.detached(priority: .utility) {
                    for (url, _, _) in written { Self.deleteTempMediaFile(url) }
                }
                return
            }
            pendingMediaPreviews = written.map {
                PendingMediaPreview(peerId: peerId, tempURL: $0.0, filename: $0.1, mime: $0.2)
            }
        }
    }

    func confirmSendPreview(peerId: String? = nil) {
        let items = peerId.map { id in pendingMediaPreviews.filter { $0.peerId == id } } ?? pendingMediaPreviews
        guard !items.isEmpty else { return }
        _ = nextMediaPreviewGeneration()
        if let peerId {
            pendingMediaPreviews.removeAll { $0.peerId == peerId }
        } else {
            pendingMediaPreviews = []
        }
        Task { @MainActor in
            // Finalize every staged item off-main IN ORDER (lazy jpeg re-encode
            // and lazy video re-encode happen here, on send confirmation —
            // Signal-style lazy finalization).
            var prepared: [(peerId: String, data: Data, filename: String, mime: String)] = []
            var encodeFailed = false
            var videoTooLarge = false
            var videoFailed = false
            // Every album item is memory-resident at once through the send —
            // bound the batch's video total like the core aggregate cap does.
            var remainingVideoBudget = Self.maxMediaTotalPlaintextBytes
            for preview in items {
                if preview.mime.hasPrefix("video/") {
                    // Pass through when under the receiver download cap; else
                    // re-encode with AVAssetExportSession to try to fit.
                    let finalized = await Task.detached(priority: .userInitiated, operation: {
                        await Self.finalizeVideoForSend(
                            preview.tempURL,
                            filename: preview.filename,
                            mime: preview.mime
                        )
                    }).value
                    switch finalized {
                    case .ready(let data, let filename, let mime):
                        if data.count > remainingVideoBudget {
                            videoTooLarge = true
                        } else {
                            remainingVideoBudget -= data.count
                            prepared.append((preview.peerId, data, filename, mime))
                        }
                    case .tooLarge:
                        videoTooLarge = true
                    case .failed:
                        videoFailed = true
                    }
                    continue
                }
                guard let raw = await Task.detached(priority: .userInitiated, operation: { () -> Data? in
                    defer { Self.deleteTempMediaFile(preview.tempURL) }
                    return Self.readTempMediaFile(preview.tempURL)
                }).value else { continue }
                if preview.mime == "image/gif" {
                    prepared.append((preview.peerId, raw, preview.filename, preview.mime))
                } else if let bytes = await Task.detached(priority: .userInitiated, operation: {
                    Self.reencodeToJpeg(raw)
                }).value {
                    prepared.append((preview.peerId, bytes, "photo.jpg", "image/jpeg"))
                } else {
                    encodeFailed = true
                }
            }
            if encodeFailed { showToast("Couldn't encode image.") }
            if videoTooLarge { showToast("Video is too large to send (max 25 MB).") }
            if videoFailed { showToast("Couldn't prepare video.") }
            // Group per peer: 2+ items to one peer send as ONE album message;
            // a single item keeps the exact pre-album behavior.
            let peersInOrder = prepared.map(\.peerId).reduce(into: [String]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            for peer in peersInOrder {
                let list = prepared.filter { $0.peerId == peer }
                if list.count > 1 {
                    let numbered = list.enumerated().map { idx, item in
                        (
                            data: item.data,
                            filename: Self.numberedFilename(item.filename, index: idx + 1),
                            mime: item.mime
                        )
                    }
                    sendImageAlbum(peer, items: numbered)
                } else if let only = list.first {
                    if only.mime == "image/gif" || only.mime.hasPrefix("video/") {
                        // The attachment path preserves the source MIME (GIF
                        // animation, video container) instead of forcing JPEG.
                        // A false return means NO route took the payload —
                        // never dismiss the preview into silence.
                        if !sendAttachment(only.peerId, data: only.data, filename: only.filename, mime: only.mime) {
                            showToast(only.mime.hasPrefix("video/")
                                ? "Couldn't send video — start the secure chat first."
                                : "Couldn't send attachment — start the secure chat first.")
                        }
                    } else {
                        sendImage(only.peerId, data: only.data, filename: only.filename, mime: only.mime)
                    }
                }
            }
        }
    }

    /// "photo.jpg" + 2 → "photo-2.jpg". Distinct per-item filenames keep the
    /// pending-upload echo reconciliation (keyed by filename) deterministic
    /// across an album's attachments.
    private static func numberedFilename(_ filename: String, index: Int) -> String {
        let ns = filename as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        return ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
    }

    func cancelPreview(peerId: String? = nil) {
        _ = nextMediaPreviewGeneration()
        let toRemove = peerId.map { id in pendingMediaPreviews.filter { $0.peerId == id } } ?? pendingMediaPreviews
        if let peerId {
            pendingMediaPreviews.removeAll { $0.peerId == peerId }
        } else {
            pendingMediaPreviews = []
        }
        deletePreviewTempFilesAsync(toRemove)
    }

    /// The in-flight P2P call the [SonarCallScreen] renders, or nil. Driven by the
    /// real iroh/opus engine via `callWaitEvent`.
    @Published private(set) var activeCall: SNActiveCall?
    private var callStarted = false
    private var callLoopTask: Task<Void, Never>?
    private var callTickerTask: Task<Void, Never>?
    /// Ids of ☎CALL control messages already routed to the engine (dedup).
    private var scannedCallMessageIDs = Set<String>()

    private var cancellables = Set<AnyCancellable>()
    @Published private var pendingMarmotChats: [String: SNPendingMarmotChat] = [:]
    @Published private var pendingMarmotGroups: [String: SNPendingMarmotGroup] = [:]
    @Published private var pendingMarmotMessagesByChat: [String: [SNMessage]] = [:]
    @Published private(set) var pendingMarmotRouteReplacement: SNMarmotRouteReplacement?
    @Published private(set) var pendingMarmotRouteFailure: SNMarmotRouteFailure?
    private var pendingDirectMarmotSends: [String: [SNPendingMarmotSend]] = [:]
    private var pendingMarmotGroupSends: [String: [SNPendingMarmotGroupSend]] = [:]
    private var startingMarmotChats = Set<String>()
    private var pendingMarmotSetupTasks: [String: Task<Void, Never>] = [:]
    private var pendingMarmotSetupTokens: [String: UUID] = [:]
    private var pendingMarmotGroupSetupTasks: [String: Task<Void, Never>] = [:]
    private var pendingMarmotGroupSetupTokens: [String: UUID] = [:]
    /// Texts queued for a Sonar peer (keyed by npub) while their White
    /// Noise group is being created on first out-of-range send.
    /// Out-of-range mesh→White Noise first sends (npub → queued text + echo id).
    /// Echo lives in `pendingMarmotMessagesByChat` under the open mesh chat id so
    /// the bubble paints before `startChat` finishes (Compose `PendingMeshMarmotSend`).
    private var pendingMarmotSends: [String: [SNPendingMarmotSend]] = [:]
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
    /// ⚡TRILL lines already processed for receive effects (buzz/notification),
    /// separate from the pay scan so replaying transcripts stays idempotent.
    private var scannedTrillMessageIDs = Set<String>()
    /// Sender cooldown (8s per chat, MSN's own guard) — session-local.
    private var trillCooldownUntilByChat: [String: Date] = [:]
    /// Bumped once per foreground buzz; SonarRootView shakes the viewport on
    /// change (skipped under Reduce Motion).
    @Published private(set) var trillShakeTick = 0
    private let localNotificationStartedAt = Date()
    private var seenMarmotNotificationMessageIDs = Set<String>()
    private var seenPrivateChatPaymentNotificationMessageIDs = Set<String>()
    /// Stable mesh peer key -> first sighting time. Conversation rows briefly
    /// hold unresolved peers so 0x53 can fold their transports; Radar always
    /// shows the verified bitchat announce immediately.
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

    private static func recoverOnboardingState(
        storedOnboarded: Bool,
        keychain: KeychainManagerProtocol,
        defaults: UserDefaults
    ) -> Bool {
        if storedOnboarded { return true }
        switch keychain.getIdentityKeyWithResult(forKey: Keys.marmotNsecKeychainKey) {
        case .success(let data):
            let nsec = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard SonarWalletDerivation.secret(fromNsec: nsec) != nil else { return false }
            defaults.set(true, forKey: Keys.onboarded)
            SecureLogger.warning("Recovered onboarding flag from persisted account key", category: .session)
            return true
        case .itemNotFound:
            return false
        case .accessDenied, .deviceLocked, .authenticationFailed, .otherError:
            SecureLogger.warning("Account key not readable while checking onboarding state; leaving onboarding disabled", category: .session)
            return false
        }
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
        onboarded = Self.recoverOnboardingState(
            storedOnboarded: defaults.bool(forKey: Keys.onboarded),
            keychain: keychain,
            defaults: defaults
        )
        mode = UserDefaults.standard.string(forKey: Keys.mode) ?? "dark"
        if UserDefaults.standard.object(forKey: Keys.discoverNewPeople) == nil {
            discoverNewPeople = true
        } else {
            discoverNewPeople = UserDefaults.standard.bool(forKey: Keys.discoverNewPeople)
        }
        #if os(iOS)
        batterySavingEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        #else
        batterySavingEnabled = false
        #endif
        marmotVerified = (UserDefaults.standard.dictionary(forKey: Keys.marmotVerified) as? [String: Bool]) ?? [:]
        bip353 = UserDefaults.standard.string(forKey: Keys.bip353) ?? ""
        // Drop the old prototype demo blob if it is still around.
        defaults.removeObject(forKey: Keys.legacyDemoState)
        callLogs = Self.loadCallLogs(from: defaults)
        syncNotificationPrefsToAppGroup()
        configureVoicePlaybackSession()

        // Internet fallback for private mesh media sends: when the BLE route
        // drops between route selection and send, ChatViewModel hands the
        // packet here so it still goes out over White Noise (Marmot). Must be
        // installed after all stored properties are initialized (captures self).
        chatViewModel.meshMediaSendFallback = { [weak self] packet, peerID, _ in
            self?.sendMeshMediaOverInternet(packet, to: peerID) ?? false
        }

        // The screens read computed properties off this store; republish
        // whenever any underlying service changes.
        republish(chatViewModel.objectWillChange)
        republish(chatViewModel.unifiedPeerService.objectWillChange)
        republish(marmot.objectWillChange)
        republish(locationManager.objectWillChange)
        republish(relayManager.objectWillChange)
        republish(networkService.objectWillChange)
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
        // Favorites Noise↔Nostr links feed the peerKeys reverse index used by
        // same-npub fold / Marmot foldKey — invalidate when favorites change.
        NotificationCenter.default.publisher(for: .favoriteStatusChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.invalidatePeerKeysIndex()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        #if os(iOS)
        NotificationCenter.default.publisher(for: UIDevice.proximityStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleCallProximityChange() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshBatterySavingState() }
            .store(in: &cancellables)
        #endif
        wireBLEDiscoveryPolicy()
        refreshBleKnownContactSnapshot()
        applyBLEDiscoveryPolicy()
        // Let Marmot republish our kind-0 profile on every relay connect (next to
        // the KeyPackage) using the current nickname, so a peer never sees our raw
        // npub because the opportunistic publish below lost the relay/onboarding race.
        marmot.profileNameProvider = { [weak self] in self?.chatViewModel.nickname ?? "" }
        marmot.localBip353Provider = { [weak self] in self?.bip353 ?? "" }
        marmot.handleDomainProvider = { Self.handleDomain }
        marmot.handleOfferProvider = { [weak self] in
            guard let self, case .ready = self.walletState else { return nil }
            return try? await self.wallet.createOffer()
        }
        // Adopt own kind-0 into local Profile state before the connect-path
        // republish (nsec restore clears the device-bound nick/handle).
        marmot.onOwnProfileFetched = { [weak self] profile in
            self?.adoptOwnKind0Profile(profile)
        }
        marmot.onOwnHandleSidecarSeeded = { [weak self] address in
            self?.noteOwnHandleSidecarSeeded(address)
        }
        marmot.$groups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resolvePendingSecureChats() }
            .store(in: &cancellables)
        marmot.$npub
            .receive(on: DispatchQueue.main)
            .sink { [weak self] npub in
                guard let self else { return }
                self.wireSonarProfileProvider(npub)
                self.runPostLocalMarmotStartupIfReady()
            }
            .store(in: &cancellables)
        marmot.$initialLocalHomeReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.runPostLocalMarmotStartupIfReady() }
            .store(in: &cancellables)
        marmot.$relayConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self, connected else { return }
                // Relay-dependent work starts only after the delayed background
                // attach, never as a side effect of publishing the local Home.
                // Kind-0 republish lives only in MarmotChatModel's connect path
                // (hydrate own profile first). Publishing here after nsec restore
                // can emit metadata without `nip05` and replace the durable
                // kind-0 on relays.
                self.adoptClaimedHandleIfNeeded()
                self.ensureCallStarted()
                self.publishPaymentMetadataIfNeeded(force: true)
                self.drainPendingInviteLinks()
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
                self.refreshBleKnownContactSnapshot()
                self.applyBLEDiscoveryPolicy()
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
                #if os(iOS)
                if configured, let bridged = self.wallet as? BridgedWallet {
                    SonarPushRegistration.shared.retryBreezWebhookIfNeeded(wallet: bridged.walletService)
                }
                #endif
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
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.refreshBleKnownContactSnapshot()
                    self?.applyBLEDiscoveryPolicy()
                }
                self.processIncomingPayLines()
                self.processIncomingTrillLines()
                self.processIncomingCallLines()
            }
            .store(in: &cancellables)
        marmot.$messagesByGroup
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.cachePublishedUploadMedia()
                self.processIncomingMarmotNotifications()
                self.processIncomingPayLines()
                self.processIncomingTrillLines()
                self.processIncomingCallLines()
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
        // Push-wake ownership suppresses live banners; when ownership ends the
        // messages sink does not re-fire, so catch up suppressed rows once.
        marmot.$pushWakeLiveCatchUpGeneration
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.processIncomingMarmotNotifications()
                self?.processIncomingTrillLines()
            }
            .store(in: &cancellables)

        // Restore persisted Sonar profiles so a peer's mesh + White Noise legs
        // stay folded into one conversation across restarts (before dmRows runs).
        hydrateSonarProfiles()
        hydrateMarmotConversationGroups()
        refreshBleKnownContactSnapshot()
        applyBLEDiscoveryPolicy()

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

        // A crash or kill mid pick/preview/export bypasses every `defer`, so
        // stale picker/preview temp files (multi-MB for videos) are swept by
        // age on launch.
        Task.detached(priority: .utility) {
            Self.sweepStaleMediaTempFiles()
        }
    }

    /// Identity publication happens before the encrypted DB opens so BLE can
    /// advertise our npub early. Wallet setup is local-only, but still waits for
    /// the coherent Home boundary so it cannot contend with first-paint reads.
    private func runPostLocalMarmotStartupIfReady() {
        guard marmot.initialLocalHomeReady, marmot.npub != nil else { return }
        // The wallet derives from the same identity; retry its deferred setup.
        #if os(iOS) || os(macOS)
        (wallet as? BridgedWallet)?.retrySetup()
        #endif
        // Local sidecar read — recover a claimed handle into prefs without
        // waiting for a relay (Compose parity; the relay-connect sink stays
        // as the online refresh).
        adoptClaimedHandleIfNeeded()
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
        // Coalesce upstream invalidation bursts (BLE announce storms, relay
        // EOSE bursts, presence heartbeats) into at most ~10 store-wide
        // re-renders per second. Every screen reads computed properties off
        // this store, so an unthrottled republish makes one chatty upstream
        // service re-render the entire app at its event rate — measured as
        // visible typing/sending lag in open conversations. Throttle keeps the
        // first event immediate and delays followers by at most 100ms.
        publisher
            .receive(on: DispatchQueue.main)
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: Appearance

    var isDarkMode: Bool { mode == "dark" }

    @MainActor
    func showToast(_ text: String) {
        let epoch = toastSession.show(text)
        toast = toastSession.text
        // Detached so a cancelled Settings `Task { await backupAccountNow() }`
        // (navigation pop / view refresh) cannot cancel the dismiss and leave
        // "Chat backup uploaded" stuck on screen forever. Cancel the previous
        // dismiss task so we don't accumulate sleepers on rapid toasts.
        toastDismissTask?.cancel()
        toastDismissTask = Task.detached { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self, !Task.isCancelled else { return }
            // Epoch owns the session; also require the published toast still
            // matches what we showed so a later showToast/showStickyToast
            // is not wiped ~1.6s later by a stale dismiss.
            guard self.toastSession.epoch == epoch else { return }
            if self.toast == text {
                self.toastSession.clear(ifEpoch: epoch)
                self.toast = nil
            } else {
                self.toastSession.clear(ifEpoch: epoch)
            }
        }
    }

    /// Progress toast that stays until replaced by `showToast` / another sticky.
    @MainActor
    private func showStickyToast(_ text: String) {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        toastSession.showSticky(text)
        toast = toastSession.text
    }

    func toggleMode() {
        mode = mode == "dark" ? "light" : "dark"
        defaults.set(mode, forKey: Keys.mode)
    }

    // MARK: Notifications

    var notificationsEnabled: Bool {
        defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
    }

    var notificationShowNames: Bool {
        defaults.object(forKey: Keys.notificationShowNames) as? Bool ?? true
    }

    var notificationShowPreview: Bool {
        defaults.object(forKey: Keys.notificationShowPreview) as? Bool ?? false
    }

    func toggleNotificationsEnabled() {
        defaults.set(!notificationsEnabled, forKey: Keys.notificationsEnabled)
        syncNotificationPrefsToAppGroup()
        objectWillChange.send()
    }

    func toggleNotificationShowNames() {
        defaults.set(!notificationShowNames, forKey: Keys.notificationShowNames)
        syncNotificationPrefsToAppGroup()
        objectWillChange.send()
    }

    func toggleNotificationShowPreview() {
        defaults.set(!notificationShowPreview, forKey: Keys.notificationShowPreview)
        syncNotificationPrefsToAppGroup()
        objectWillChange.send()
    }

    private func syncNotificationPrefsToAppGroup() {
        #if os(iOS)
        guard let shared = UserDefaults(suiteName: Self.appGroupId) else { return }
        shared.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
        shared.set(notificationShowNames, forKey: Keys.notificationShowNames)
        shared.set(notificationShowPreview, forKey: Keys.notificationShowPreview)
        #endif
    }

    // MARK: Identity

    var nick: String { chatViewModel.nickname }

    func rename(_ nick: String) {
        chatViewModel.nickname = nick
        chatViewModel.validateAndSaveNickname()
        // Re-publish our kind-0 profile so peers see the new name — but never
        // when a local handle pref exists without the core sidecar. That emit
        // would omit `nip05` and replace the durable kind-0 after restore.
        guard marmot.npub != nil else { return }
        let name = chatViewModel.nickname
        let handlePref = bip353
        Task { @MainActor in
            let claimed = await marmot.claimedHandle()
            guard OwnProfileHydration.canPublishOwnProfile(
                localBip353: handlePref,
                coreClaimedHandle: claimed
            ) else { return }
            marmot.publishProfile(name: name)
        }
    }

    func completeOnboarding(nick: String) {
        Task { @MainActor in
            rename(nick)
            guard await marmot.prepareIdentityForOnboarding() else {
                showToast("Couldn't save your account key. Try again.")
                return
            }
            onboarded = true
            defaults.set(true, forKey: Keys.onboarded)
            path = []
        }
    }

    /// `nsec1…` backup of the current identity for the "Export private key"
    /// sheet (self-custody). Prefers the durable keychain copy (Compose
    /// `identityNsec` parity) so the sheet never waits on Marmot sync.
    func exportNsec() async -> String? {
        await SonarAccountKeyExport.exportNsec(keychain: keychain) {
            await marmot.exportNsec()
        }
    }

    // MARK: - Diagnostics (Settings → Diagnostics)

    /// Relay/sync snapshot JSON for the Diagnostics sheet. Nil while the relay
    /// node is still connecting.
    func diagnosticsSnapshotJson() async -> String? {
        await marmot.syncStateSnapshotJson()
    }

    var diagnosticsVerbose: Bool {
        SonarDiagnostics.verboseEnabled
    }

    /// Explicit user opt-in to verbose (debug-level) diagnostics capture.
    func setDiagnosticsVerbose(_ verbose: Bool) {
        SonarDiagnostics.setVerbose(verbose)
        objectWillChange.send()
    }

    /// Assemble the shareable diagnostics zip (logs + sync snapshot).
    func buildDiagnosticsBundle() async -> URL? {
        let snapshot = await marmot.syncStateSnapshotJson()
        return await SonarDiagnostics.buildDebugBundle(snapshotJson: snapshot)
    }

    /// Restore an existing account from a pasted `nsec1…` backup (onboarding
    /// "Restore account" or Settings → Restore account): import the identity,
    /// try Blossom chat restore, wipe any prior wallet on this device, rebuild
    /// the Lightning wallet from the restored nsec, then finish onboarding.
    /// Throws on an invalid key.
    func restoreAccount(nsec: String) async throws {
        let key = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate before any destructive work. An invalid paste must leave the
        // current identity, chats, wallet, and push registrations untouched.
        _ = try SonarIdentity.import(nsec: key)

        #if os(iOS) || os(macOS)
        let bridged = wallet as? BridgedWallet
        #if os(iOS)
        await SonarPushRegistration.shared.prepareForAccountReplacement(wallet: bridged?.walletService)
        #endif
        do {
            if let bridged {
                try await bridged.prepareForIdentityReplacement()
            } else {
                try BridgedWallet.beginWalletStorageMutation()
                try BridgedWallet.wipeWalletStorage()
            }
        } catch {
            throw SonarAccountRestoreError.walletCleanupFailed
        }
        #endif

        // Clear host-owned local-first caches before committing the new nsec. A
        // crash after identity import must never paint the previous account's
        // mesh chats, contacts, payment rows, media, or wallet offer.
        clearAccountBoundLocalStateForRestore()
        let backupOutcome: AccountBackupRestoreOutcome
        do {
            backupOutcome = try await marmot.restoreIdentity(nsec: key)
        } catch {
            #if os(iOS) || os(macOS)
            bridged?.retrySetup()
            #endif
            throw SonarAccountRestoreError.accountReplacementFailed
        }
        #if os(iOS) || os(macOS)
        bridged?.retrySetup()
        #endif
        onboarded = true
        defaults.set(true, forKey: Keys.onboarded)
        path = []
        switch backupOutcome {
        case .restored:
            showToast(String(localized: "Account restored — chats recovered from backup"))
        case .missing:
            showToast(String(localized: "Account restored — chats start empty until you back up"))
        case .failed:
            showToast(String(localized: "Account restored — chat backup restore failed; try again when online"))
        }
    }

    /// Settings → Backup chats: encrypt Marmot DB+key with nsec and upload to
    /// Blossom so delete→reinstall→paste nsec can recover history.
    func backupAccountNow() async {
        // Sticky progress (no auto-dismiss) — a timed dismiss racing the long
        // upload was leaving the completion toast uncleared when the parent
        // Task was cancelled, or colliding with the result toast epoch.
        // Platform gap (Compose): no progress string yet — iOS-only UX; track
        // parity when Compose Settings backup grows a progress toast.
        showStickyToast(String(localized: "Backing up chats…"))
        do {
            try await marmot.backupAccount()
            showToast(String(localized: "Chat backup uploaded"))
        } catch MarmotService.ServiceError.backupAlreadyInProgress {
            // In-flight backup owns sticky/result toasts; do not clobber with failure.
            return
        } catch {
            showToast(String(localized: "Backup failed — try again when online"))
            SecureLogger.warning(
                "⚠️ Account backup failed: \(error.localizedDescription)",
                category: .session
            )
        }
    }

    private func clearAccountBoundLocalStateForRestore() {
        path = []
        unreadCountAtOpenByDM.removeAll()
        jumpMessageIdAtOpenByDM.removeAll()
        pendingJumpMessageIdByDM.removeAll()
        chatViewModel.clearAllConversations()
        openingDMTasks.values.forEach { $0.cancel() }
        openingDMTasks = [:]
        refreshingDMTasks.values.forEach { $0.cancel() }
        refreshingDMTasks = [:]
        pendingMarmotSends = [:]
        pendingMarmotChats = [:]
        pendingMarmotGroups = [:]
        pendingMarmotMessagesByChat = [:]
        pendingMarmotRouteReplacement = nil
        pendingMarmotRouteFailure = nil
        pendingDirectMarmotSends = [:]
        pendingMarmotGroupSends = [:]
        cancelPendingSecureChatSetups()
        cancelPendingMarmotGroupSetups()
        localHydratingDMs = []
        clearMarmotConversationGroups()
        marmot.groups = []
        marmot.messagesByGroup = [:]

        marmotVerified = [:]
        defaults.removeObject(forKey: Keys.marmotVerified)
        defaults.removeObject(forKey: Keys.bleKnownChatKeys)
        sonarProfiles = [:]
        sonarProfilesByFingerprint = [:]
        invalidatePeerKeysIndex()
        meshPeerFirstSeenAt = [:]
        pendingCapabilityRefreshKeys = []
        defaults.removeObject(forKey: Keys.sonarProfiles)
        applyBLEDiscoveryPolicy()

        unify.stop()
        unifyReceiver.stop()
        incomingWalletTask?.cancel()
        incomingWalletTask = nil
        publishedBolt12Offer = nil
        publishedCallDescriptor = false
        publishingPaymentMetadata = false
        needsPaymentMetadataPublish = false
        refreshedKnownDescriptorsForRelaySession = false

        scannedPayMessageIDs = []
        // Message-id dedup state is account-bound: this store outlives a
        // restore, so the incoming account's messages must not be treated as
        // already-notified. Compose fixed the same gap in #288.
        seenMarmotNotificationMessageIDs = []
        scannedTrillMessageIDs = []
        trillCooldownUntilByChat = [:]
        SonarTrillThrottle.shared.reset()
        SonarChatMuteStore.shared.wipe()
        pendingPayPeer = nil
        payLedger.wipe()
        paymentActivityLedger.wipe()
        cancelAllMediaDownloads()
        mediaImageCache = [:]
        pendingUploadMediaCache = [:]
        clearMediaDiskCache()
        clearCallLogs()
        resetCallState()
        bip353 = ""
        defaults.removeObject(forKey: Keys.bip353)
        coreClaimedHandle = nil
        handleClaimState = .idle
        // Previous account's nickname must not survive into the restored
        // identity — kind-0 on relays is authoritative after hydrate.
        chatViewModel.clearNicknameForAccountRestore()
        objectWillChange.send()
    }

    /// Apply a fetched own kind-0 into local nickname / handle prefs.
    /// Mirrors Compose `hydrateOwnProfileFromRelays` adoption.
    /// Does not mark `coreClaimedHandle` — that waits on registrar claim success
    /// via `noteOwnHandleSidecarSeeded`.
    private func adoptOwnKind0Profile(_ profile: MarmotService.Profile) {
        let plan = OwnProfileHydration.plan(
            localNickname: chatViewModel.nickname,
            localBip353: bip353,
            localClaimedHandle: coreClaimedHandle,
            remoteName: profile.bestName,
            remoteNip05: profile.nip05,
            handleDomain: Self.handleDomain
        )
        if let name = plan.nicknameToAdopt, !name.isEmpty {
            chatViewModel.nickname = name
            chatViewModel.saveNickname()
        }
        if let address = plan.nip05ToAdopt, !address.isEmpty {
            setBip353(address)
        }
    }

    /// Core sidecar was re-seeded after restore reclaim — safe to show the
    /// registrar seal and treat the address as claim-backed.
    private func noteOwnHandleSidecarSeeded(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coreClaimedHandle = trimmed
        if bip353.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setBip353(trimmed)
        }
        if handleClaimState == .idle {
            handleClaimState = .claimed(trimmed)
        }
    }

    /// Start Unify scanning while the Nearby/radar screen is visible; stop it
    /// when it goes away. Keeps the extra BLE scan off except when the user is
    /// actually looking for someone nearby to pay.
    func nearbyAppeared() {
        isNearbyVisible = true
        updateNearbyScanning()
    }
    func nearbyDisappeared() {
        isNearbyVisible = false
        updateNearbyScanning()
    }

    // MARK: Unify receiver (mirror role: a Unify user can pay us)

    /// Foreground/background transitions from BitchatApp's scenePhase. iOS
    /// strips the BLE local name and restricts service-UUID advertising in the
    /// background, so we advertise the receiver only while foreground.
    func setForeground(_ foreground: Bool) {
        let changed = isForeground != foreground
        let cameToForeground = foreground && !isForeground
        isForeground = foreground
        #if canImport(UIKit)
        // Tear the Breez node down before suspension so it never holds a SQLite
        // lock while the process is suspended (the 0xdead10cc kill), and rebuild
        // it on foreground. Offline receive is unaffected — it runs in the
        // Notification Service Extension's own process.
        //
        // Drive this on every foreground/background signal, even when our tracked
        // flag didn't change: a silent-push background launch leaves `isForeground`
        // at its `true` default, so the first real foreground would otherwise skip
        // the resume and the node (deferred at launch) would never come up.
        // suspend/resume are idempotent (guarded on node state / `suspendedForBackground`).
        if let walletService = (wallet as? BridgedWallet)?.walletService {
            if foreground {
                walletService.resumeFromBackground()
            } else {
                walletService.suspendForBackground()
            }
        }
        // Mirror Breez: release the Marmot SQLCipher handle + App Group flock so
        // NSE Transponder hydrate is not stuck on `storeBusy` while we are
        // suspended (production APNs has no content-available app wake).
        // Foreground reconnect is driven by refreshAfterForeground / ensureConnected.
        if !foreground {
            marmot.suspendStoreForBackground()
        }
        #endif
        updateNearbyScanning()
        guard changed else { return }
        updateReceiverAdvertising()
        if cameToForeground {
            refreshKnownContactDescriptors()
            publishedCallDescriptor = false
            publishedBolt12Offer = nil
            publishPaymentMetadataIfNeeded(force: true)
            marmot.refreshAfterForeground()
        }
    }

    /// Start advertising as a Unify receiver iff the wallet is ready AND the
    /// app is foreground; stop otherwise. Idempotent — the receiver itself
    /// coalesces repeat starts and only advertises once an offer is fetched.
    private func updateReceiverAdvertising() {
        let ready: Bool
        if case .ready = walletState { ready = true } else { ready = false }
        if ready && isForeground && !isBLEDiscoveryRestricted {
            unifyReceiver.start()
        } else {
            unifyReceiver.stop()
        }
    }

    var isBLEDiscoveryRestricted: Bool {
        batterySavingEnabled || !discoverNewPeople
    }

    var bleDiscoverySettingsDescription: String {
        if batterySavingEnabled {
            return discoverNewPeople
                ? "On, but paused by battery saving; existing chats still reconnect"
                : "Off; existing chats can still reconnect"
        }
        return discoverNewPeople
            ? "Show nearby people you haven't chatted with yet"
            : "Only people from existing chats can appear"
    }

    var radarDiscoveryStatusLine: String {
        let count = nearbyPeers.filter(\.inRange).count
        if batterySavingEnabled {
            return "\(count) in range · battery saving"
        }
        if isBLEDiscoveryRestricted {
            return "\(count) in range · new people off"
        }
        return "\(count) in range · scanning"
    }

    func setDiscoverNewPeople(_ enabled: Bool) {
        guard discoverNewPeople != enabled else { return }
        discoverNewPeople = enabled
        defaults.set(enabled, forKey: Keys.discoverNewPeople)
        applyBLEDiscoveryPolicy()
        updateNearbyScanning()
        updateReceiverAdvertising()
    }

    private var effectiveBLEDiscoveryMode: BLEDiscoveryMode {
        guard isBLEDiscoveryRestricted else { return .normal }
        return hasKnownBleContacts ? .knownOnly : .off
    }

    private var hasKnownBleContacts: Bool {
        !(defaults.stringArray(forKey: Keys.bleKnownChatKeys) ?? []).isEmpty
    }

    private func refreshBatterySavingState() {
        #if os(iOS)
        let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard batterySavingEnabled != enabled else { return }
        batterySavingEnabled = enabled
        applyBLEDiscoveryPolicy()
        updateNearbyScanning()
        updateReceiverAdvertising()
        #endif
    }

    private func updateNearbyScanning() {
        if shouldScanForNearbyPayments(
            isNearbyVisible: isNearbyVisible,
            isForeground: isForeground,
            isDiscoveryRestricted: isBLEDiscoveryRestricted
        ) {
            unify.start()
        } else {
            unify.stop()
        }
    }

    private func wireBLEDiscoveryPolicy() {
        guard let ble = chatViewModel.meshService as? BLEService else { return }
        let knownKey = Keys.bleKnownChatKeys
        ble.knownPeerProvider = { peerID, noisePublicKey in
            let stored = Set((UserDefaults.standard.stringArray(forKey: knownKey) ?? []).map { $0.lowercased() })
            guard !stored.isEmpty else { return false }
            var candidates: Set<String> = [peerID.id.lowercased(), peerID.bare.lowercased()]
            if let noisePublicKey {
                let fingerprint = noisePublicKey.sha256Fingerprint().lowercased()
                candidates.insert(fingerprint)
                candidates.insert(String(fingerprint.prefix(16)))
                candidates.insert(PeerID(publicKey: noisePublicKey).bare.lowercased())
            }
            return !candidates.isDisjoint(with: stored)
        }
    }

    private func applyBLEDiscoveryPolicy() {
        // Decide from the freshly-computed set, NOT from `defaults`: the
        // snapshot mirror is written asynchronously, so reading it back here
        // could see the stale (empty) list and wrongly pick `.off` right after
        // the first known chat is added, leaving BLE disabled until an
        // unrelated refresh.
        let known = refreshBleKnownContactSnapshot()
        guard let ble = chatViewModel.meshService as? BLEService else { return }
        let nextMode: BLEDiscoveryMode = isBLEDiscoveryRestricted
            ? (known.isEmpty ? .off : .knownOnly)
            : .normal
        if ble.discoveryMode == nextMode {
            if isBLEDiscoveryRestricted {
                ble.reapplyDiscoveryModePolicy()
            }
        } else {
            ble.discoveryMode = nextMode
        }
    }

    /// Recompute the set of BLE-known chat keys and mirror it to `defaults`
    /// for cross-launch use + the `knownPeerProvider`. Returns the freshly
    /// computed set so callers can make a decision on it WITHOUT reading the
    /// asynchronously-written `defaults` back (see `applyBLEDiscoveryPolicy`).
    @discardableResult
    private func refreshBleKnownContactSnapshot() -> Set<String> {
        var keys = Set<String>()
        func insert(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { return }
            keys.insert(trimmed)
            let peer = PeerID(str: trimmed)
            keys.insert(peer.bare)
            if let noiseKey = peer.noiseKey {
                let fingerprint = noiseKey.sha256Fingerprint().lowercased()
                keys.insert(fingerprint)
                keys.insert(String(fingerprint.prefix(16)))
                keys.insert(PeerID(publicKey: noiseKey).bare.lowercased())
            }
        }

        for (peerID, messages) in chatViewModel.privateChats where !messages.isEmpty {
            insert(peerID.id)
            insert(canonicalPeerKey(peerID))
        }
        for id in marmotGroupIdsByConversationId.keys {
            insert(id)
        }
        for group in marmot.groups where marmot.isDirectGroup(group) {
            if let other = directOtherNpub(in: group),
               let peerKey = sonarPeerKey(forNpub: other) {
                insert(peerKey)
            }
        }

        // Persist off the main thread: this runs on every `$groups` publish,
        // and CFPreferences writes are an XPC round trip to cfprefsd that can
        // stall the runloop (observed as chat-open microhangs). UserDefaults
        // is thread-safe; last-writer-wins is fine for this mirror.
        let snapshot = Array(keys)
        let defaults = self.defaults
        DispatchQueue.global(qos: .utility).async {
            defaults.set(snapshot, forKey: Keys.bleKnownChatKeys)
        }
        return keys
    }

    func submitInviteLink(_ token: String) {
        guard marmot.npub != nil else {
            pendingInviteLinks.append(token)
            return
        }
        Task {
            do {
                try await marmot.requestJoinViaLink(token: token)
                await MainActor.run { showToast("Join request sent") }
            } catch {
                await MainActor.run { showToast("Couldn't join: \(error.localizedDescription)") }
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
        // The linked account's LIVE kind-0 profile name wins over the BLE
        // nickname (transport metadata): a rename must reach the row both in
        // range and after the peer drops out of range.
        if let profile = resolvedSonarProfile(id),
           let name = marmot.displayName(forNpub: profile.npub) {
            marmot.refreshProfileOnNameMismatch(
                npub: profile.npub,
                liveName: chatViewModel.meshService.peerNickname(peerID: peerID),
            )
            return name
        }
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
            if let known = knownPeerName(id) { return known }
            marmot.ensureProfile(profile.npub)
            return Self.npubDisplay(profile.npub)
        }
        return knownPeerName(id) ?? chatViewModel.nicknameForPeer(peerID)
    }

    /// A human name we already know for this peer from durable local data reachable
    /// by the canonical short id — a favorite nickname or a name recorded in payment
    /// history — so an out-of-range Sonar peer shows their name instead of a raw
    /// pubkey before any Nostr profile (kind-0) has been fetched.
    private func knownPeerName(_ id: String) -> String? {
        let key = canonicalPeerKey(PeerID(str: id))
        if let fav = FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: PeerID(str: key)),
           !fav.peerNickname.isEmpty {
            return fav.peerNickname
        }
        for activity in paymentActivityLedger.activities(peerKey: key)
            .sorted(by: { $0.createdAt > $1.createdAt }) where Self.isHumanName(activity.peerName) {
            return activity.peerName
        }
        return nil
    }

    /// True when a stored peer name is an actual nickname rather than a pubkey
    /// placeholder ("npub1…", a truncated id, or the "External wallet" stand-in).
    private static func isHumanName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "External wallet" else { return false }
        if trimmed.hasPrefix("npub1") || trimmed.contains("\u{2026}") { return false }
        return true
    }

    /// Protocols the chat counterpart speaks — shown ONLY on the verify
    /// sheet's "Speaks" line; everywhere else uses plain-language labels.
    func speaks(_ id: String) -> String {
        if resolvedSonarProfile(id) != nil { return "Sonar mesh + White Noise" }
        if isPendingSecureChat(id) { return "White Noise" }
        return marmotGroupId(id) != nil ? "White Noise" : "bitchat mesh"
    }

    // MARK: Local notification routing

    private var notificationPrefs: SonarLocalNotificationPrefs {
        SonarNotificationPreferenceStore.loadMerged()
    }

    private func localNotificationKind(for content: String) -> SonarLocalNotificationKind {
        switch sonarNotificationClassifyContent(content: content) {
        case .call: return .call
        case .payment: return .payment
        case .trill: return .trill
        default: return .message
        }
    }

    private func sendSonarNotification(
        kind: SonarLocalNotificationKind,
        idKey: String,
        conversationId: String?,
        conversationTitle: String?,
        senderName: String? = nil,
        groupName: String? = nil,
        preview: String? = nil,
        unreadCount: UInt64 = 1,
        messageId: String? = nil,
        sound: SonarNotificationSound = .standard,
        marmotWake: Bool = false
    ) {
        guard !isForeground else { return }
        var userInfo: [String: Any] = [:]
        if marmotWake {
            userInfo[SonarNotificationKeys.marmotWake] = true
        }
        if let conversationId {
            userInfo[SonarNotificationKeys.conversationId] = conversationId
        }
        if let messageId {
            let trimmed = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                userInfo[SonarNotificationKeys.messageId] = trimmed
            }
        }
        guard let notification = SonarLocalNotificationRouter.make(
            idKey: idKey,
            kind: kind,
            conversationTitle: conversationTitle,
            senderName: senderName,
            groupName: groupName,
            preview: preview,
            prefs: notificationPrefs,
            unreadCount: unreadCount,
            userInfo: userInfo
        ) else { return }
        NotificationService.shared.sendLocalNotification(
            title: notification.title,
            body: notification.body,
            identifier: notification.identifier,
            userInfo: notification.userInfo,
            sound: sound
        )
    }

    private func processIncomingMarmotNotifications() {
        // Push-wake owns banners for the current Transponder sync; emitting
        // here as well double-fires (different identifiers) for the same row.
        // Do NOT blanket-mark every in-memory message seen — that drops rows
        // that land via gap recovery after the drain list was returned.
        if marmot.pushWakeOwnsNotifications { return }
        for group in marmot.groups {
            let convId = marmotConvId(forGroup: group.id)
            let title = marmot.title(for: group)
            for message in marmot.messagesByGroup[group.id] ?? [] where !message.isMine {
                if message.createdAt <= localNotificationStartedAt {
                    seenMarmotNotificationMessageIDs.insert(message.id)
                    continue
                }
                // A blocked person must not fire a notification — same rule the
                // mesh inbound path applies via `isNostrBlocked`.
                if isMarmotSenderBlocked(message.senderNpub) {
                    seenMarmotNotificationMessageIDs.insert(message.id)
                    continue
                }
                let groupName = group.memberNpubs.count > 2 ? title : nil
                // Push wake already bannered this message id — mark seen, no second banner.
                if marmot.pushWakeNotifiedMessageIDs.contains(message.id) {
                    seenMarmotNotificationMessageIDs.insert(message.id)
                    continue
                }
                guard seenMarmotNotificationMessageIDs.insert(message.id).inserted else { continue }
                let kind = localNotificationKind(for: message.content)
                // ⚡TRILL alerts (throttle + buzz + trill sound) are owned by
                // processIncomingTrillLines, same split as ⚡PAY on mesh.
                guard kind != .call, kind != .trill else { continue }
                let senderName = marmot.displayName(forNpub: message.senderNpub) ?? snShortNpubLabel(message.senderNpub)
                sendSonarNotification(
                    kind: kind,
                    idKey: message.id,
                    conversationId: convId,
                    conversationTitle: title,
                    senderName: senderName,
                    groupName: groupName,
                    preview: message.content,
                    messageId: message.id
                )
            }
        }
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

    // MARK: Contact profile social actions (favorite / block — Compose parity)

    /// The peer's Noise public key for favorite/block bookkeeping: resolved
    /// from a stable 64-hex chat id, a live mesh peer, or — for an offline
    /// 16-hex short id — a favorites record that carries the key. Nil for
    /// Marmot-only, pending and npub contacts (no mesh leg).
    private func contactNoiseKey(_ id: String) -> Data? {
        guard !id.hasPrefix(Self.marmotIDPrefix), !id.hasPrefix("npub1"),
              !isPendingSecureChat(id)
        else { return nil }
        let peerID = PeerID(str: id)
        if let key = peerID.noiseKey { return key }
        if let peer = chatViewModel.unifiedPeerService.getPeer(by: peerID) {
            return peer.noisePublicKey
        }
        let short = canonicalPeerKey(peerID)
        for (noiseKey, _) in FavoritesPersistenceService.shared.favorites
            where PeerID(publicKey: noiseKey).bare == short {
            return noiseKey
        }
        return nil
    }

    /// Full Noise fingerprint for the mesh leg of this contact, if any — the
    /// key the mesh block list (SecureIdentityStateManager) is indexed by.
    private func contactFingerprint(_ id: String) -> String? {
        guard !id.hasPrefix(Self.marmotIDPrefix), !id.hasPrefix("npub1"),
              !isPendingSecureChat(id)
        else { return nil }
        if let fp = chatViewModel.getFingerprint(for: PeerID(str: id)) { return fp }
        return contactNoiseKey(id)?.sha256Fingerprint()
    }

    /// Lowercased 32-byte hex of an npub, the key the Nostr block list uses.
    private static func nostrBlockKey(_ npub: String) -> String? {
        guard !npub.isEmpty else { return nil }
        return nostrPubkeyData(npub)?.hexEncodedString()
    }

    /// Favorite is a mesh (bitchat) concept: it needs the peer's Noise key.
    /// Mirrors Compose `canFavoriteContact`.
    func canFavoriteContact(_ id: String) -> Bool {
        contactNoiseKey(id) != nil
    }

    func isContactFavorite(_ id: String) -> Bool {
        guard let noiseKey = contactNoiseKey(id) else { return false }
        return FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey)?.isFavorite ?? false
    }

    /// Toggle favorite from the contact profile (Compose `toggleFavoriteContact`).
    /// Persists through FavoritesPersistenceService and sends the hidden
    /// favorite/unfavorite control line over BLE when the peer is connected
    /// (Nostr otherwise) via the existing ChatViewModel/UnifiedPeerService
    /// plumbing. Returns the toast line to show.
    func toggleFavoriteContact(_ id: String, npub: String, name: String) -> String {
        let display = name.isEmpty ? "contact" : name
        guard let noiseKey = contactNoiseKey(id) else {
            return "Favorite works after meeting this contact over Bluetooth."
        }
        if isContactBlocked(id, npub: npub) {
            return "Unblock \(display) before favoriting."
        }
        let wasFavorite = isContactFavorite(id)
        chatViewModel.toggleFavorite(peerID: PeerID(hexData: noiseKey))
        objectWillChange.send()
        return wasFavorite
            ? "Removed \(display) from favorites"
            : "Added \(display) to favorites"
    }

    /// Blocked on either leg of the contact's stable identity: the mesh Noise
    /// fingerprint or the linked npub (Nostr block list). One person, one
    /// block — whichever transport they arrive over.
    func isContactBlocked(_ id: String, npub: String) -> Bool {
        if let fp = contactFingerprint(id),
           chatViewModel.identityManager.isBlocked(fingerprint: fp) {
            return true
        }
        if let hex = Self.nostrBlockKey(npub),
           chatViewModel.identityManager.isNostrBlocked(pubkeyHexLowercased: hex) {
            return true
        }
        return false
    }

    /// True when a Marmot (White Noise) message's sender npub is on the Nostr
    /// block list. Mirrors the mesh inbound filter
    /// (`ChatViewModel+PrivateChat` / `+Nostr`, `isNostrBlocked`): the block
    /// list is keyed by the lowercased 32-byte pubkey hex, so map the sender
    /// npub through `nostrBlockKey`. Used to drop a blocked person's messages
    /// from both the transcript read path and the notification path.
    private func isMarmotSenderBlocked(_ senderNpub: String) -> Bool {
        guard let hex = Self.nostrBlockKey(senderNpub) else { return false }
        return chatViewModel.identityManager.isNostrBlocked(pubkeyHexLowercased: hex)
    }

    /// Block/unblock BOTH identity legs so the person stays blocked whichever
    /// transport discovery arrives over (Compose `setContactBlocked`).
    /// Blocking also drops our favorite — can't be both favorite and blocked,
    /// matching the mesh `/block` command. Returns the toast line to show.
    func setContactBlocked(_ id: String, npub: String, name: String, blocked: Bool) -> String {
        let fingerprint = contactFingerprint(id)
        let nostrKey = Self.nostrBlockKey(npub)
        guard fingerprint != nil || nostrKey != nil else {
            return "No stable identity to block yet."
        }
        if let fingerprint {
            chatViewModel.identityManager.setBlocked(fingerprint, isBlocked: blocked)
        }
        if let nostrKey {
            chatViewModel.identityManager.setNostrBlocked(nostrKey, isBlocked: blocked)
        }
        if blocked, let noiseKey = contactNoiseKey(id) {
            FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: noiseKey)
            invalidatePeerKeysIndex()
        }
        objectWillChange.send()
        let display = name.isEmpty ? "contact" : name
        return blocked ? "Blocked \(display)" : "Unblocked \(display)"
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

    /// Claim a unified handle (`name` → name@sonarprivacy.xyz) at the Sonar
    /// registrar. Best-effort BOLT12 offer: when the wallet is ready the
    /// handle doubles as a BIP-353 payment address; otherwise a chat-only
    /// claim (nil offer) is made — that is a supported path. On success the
    /// claimed address reuses the existing BIP-353 persistence + BLE announce
    /// (`setBip353`) and the kind-0 profile is republished so peers see the
    /// nip05 immediately. All network work runs off the main thread.
    func claimHandle(_ handle: String) {
        let name = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard MarmotService.handleLooksValid(name) else {
            handleClaimState = .failed("That name can't be used.")
            return
        }
        guard handleClaimState != .claiming else { return }
        // A full external address (alice@other-wallet.com) is not claimable at
        // the Sonar registrar — it's a payment address minted elsewhere. Keep
        // the pre-claim behavior: store + announce it as-is, no network.
        if name.contains("@"), !name.hasSuffix("@\(Self.handleDomain)") {
            setBip353(name)
            handleClaimState = .claimed(name)
            return
        }
        handleClaimState = .claiming
        Task { [weak self] in
            guard let self else { return }
            // Offer fetch is tolerated to fail: wallet not ready = chat-only claim.
            var offer: String?
            if case .ready = self.walletState {
                offer = try? await self.wallet.createOffer()
            }
            do {
                let address = try await self.marmot.claimHandle(handle: name, offer: offer)
                self.coreClaimedHandle = address
                if let offer { self.lastClaimedOffer = offer }
                self.setBip353(address)
                self.marmot.publishProfile(name: self.chatViewModel.nickname)
                self.handleClaimState = .claimed(address)
            } catch {
                self.handleClaimState = .failed(Self.describeHandleClaimError(error))
            }
        }
    }

    private static func describeHandleClaimError(_ error: Error) -> String {
        let detail: String
        switch error {
        case MarmotService.ServiceError.notConnected:
            return "Not connected yet — try again in a moment."
        case MarmotService.ServiceError.cancelled:
            return "Claim cancelled — try again."
        case MarmotService.ServiceError.backupAlreadyInProgress:
            return "Backup already in progress."
        case MarmotService.ServiceError.invalidInput(let message),
             MarmotService.ServiceError.core(let message):
            detail = message
        default:
            detail = error.localizedDescription
        }
        if detail.hasPrefix("handle taken:") {
            return "That name is taken — try another."
        }
        return detail
    }

    /// The BOLT12 offer last registered with the handle this session.
    private var lastClaimedOffer: String?

    /// Upgrade a chat-only claim once a wallet offer exists: a claim made
    /// before the wallet was ready has no BIP-353 DNS record, so the handle
    /// looks payable but isn't until re-registered. Re-claims from the same
    /// key are idempotent; once per offer per session keeps this quiet.
    private func refreshHandleOfferIfNeeded(_ offer: String) async {
        guard let claimed = coreClaimedHandle, offer != lastClaimedOffer else { return }
        let name = String(claimed.split(separator: "@").first ?? "")
        guard !name.isEmpty else { return }
        if (try? await marmot.claimHandle(handle: name, offer: offer)) != nil {
            lastClaimedOffer = offer
        }
    }

    /// If lightweight prefs lost the BIP-353 address but the core still holds
    /// a claimed handle, adopt it back (core persistence is the durable copy).
    /// Local DB read only — never blocks or touches the network.
    private func adoptClaimedHandleIfNeeded() {
        Task { [weak self] in
            guard let self else { return }
            guard let address = await self.marmot.claimedHandle(),
                  !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            self.coreClaimedHandle = address
            guard self.bip353.isEmpty else { return }
            self.setBip353(address)
            if self.handleClaimState == .idle {
                self.handleClaimState = .claimed(address)
            }
        }
    }

    /// Resolve a handle (`vincenzo` / `alice@domain`) to an npub for starting
    /// a secure chat. Bounded network lookup in the core; nil on any failure —
    /// callers show a soft miss state and never see an error thrown.
    func resolveHandleForChat(_ input: String) async -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard MarmotService.handleLooksValid(trimmed) else { return nil }
        guard let resolved = try? await marmot.resolveHandle(trimmed), !resolved.npub.isEmpty else { return nil }
        return resolved.npub
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
            invalidatePeerKeysIndex()
        }
        // Persist the npub↔peer link keyed by the canonical 16-hex short id, so
        // the mesh + White Noise legs stay ONE conversation across restarts /
        // BLE-down. The short id is the Noise fingerprint's prefix and is stable
        // whether or not the live 0x53 announce is currently arriving.
        let key = canonicalPeerKey(PeerID(str: peerID))
        if sonarProfilesByFingerprint[key] != profile {
            sonarProfilesByFingerprint[key] = profile
            invalidatePeerKeysIndex()
            persistSonarProfiles()
        }
        if let group = marmotGroup(forNpub: profile.npub) {
            rememberMarmotGroup(group.id, forConversationId: peerID)
            rememberMarmotGroup(group.id, forConversationId: key)
        }
        refreshBleKnownContactSnapshot()
        applyBLEDiscoveryPolicy()
        meshPeerFirstSeenAt[key] = nil
        pendingCapabilityRefreshKeys.remove(key)
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
        // Migrate legacy entries keyed by the full 64-hex Noise fingerprint to
        // the canonical 16-hex short id, so a peer met over BLE still resolves
        // its npub from the offline conversation row (addressed by the short id).
        var migrated: [String: SonarPeerProfile] = [:]
        var changed = false
        for (k, v) in map {
            let short = Self.canonicalStoredKey(k)
            if short != k { changed = true }
            if migrated[short] == nil { migrated[short] = v }
        }
        sonarProfilesByFingerprint = migrated
        invalidatePeerKeysIndex()
        if changed { persistSonarProfiles() }
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

    /// Canonical, restart-stable conversation key for a peer: the 16-hex short
    /// peer ID (the Noise fingerprint's first 16 hex). Returns the SAME value
    /// whether the peer is live over BLE or offline, so the persisted npub /
    /// Marmot links resolve while out of range. Non-peer ids (marmot:, nostr:,
    /// names) are returned unchanged.
    func canonicalPeerKey(_ peerID: PeerID) -> String {
        if let fp = chatViewModel.getFingerprint(for: peerID) { return String(fp.prefix(16)) }
        guard peerID.prefix == .empty else { return peerID.id }
        if peerID.isShort { return peerID.bare }
        if let noiseKey = peerID.noiseKey { return PeerID(publicKey: noiseKey).bare }
        return peerID.id
    }

    /// Canonicalize a PERSISTED key (always a Noise fingerprint or already a
    /// short id) to the 16-hex short form. Used to migrate the on-disk map so a
    /// peer met over BLE still resolves once it is out of range.
    private static func canonicalStoredKey(_ key: String) -> String {
        let peer = PeerID(str: key)
        if peer.prefix == .empty, peer.isHex, peer.bare.count == 64 {
            return String(peer.bare.prefix(16))
        }
        return key
    }

    /// The Sonar profile for a peer id, preferring the live 0x53 announce and
    /// falling back to the persisted (by-canonical-short-id) copy — so a Sonar
    /// peer's White Noise leg is still recognized when it isn't currently
    /// advertising.
    func resolvedSonarProfile(_ id: String) -> SonarPeerProfile? {
        if let live = sonarProfiles[id] { return live }
        // Persisted links are keyed by the canonical 16-hex short id, which is
        // stable whether the peer is in BLE range or not.
        if let persisted = sonarProfilesByFingerprint[canonicalPeerKey(PeerID(str: id))] { return persisted }
        if let persisted = sonarProfilesByFingerprint[id] { return persisted }
        let peer = PeerID(str: id)
        if peer.prefix == .empty, peer.isHex, peer.bare.count == 64,
           let persisted = sonarProfilesByFingerprint[String(peer.bare.prefix(16))] {
            return persisted
        }
        return nil
    }

    /// The canonical 16-hex short key of a persisted/live Sonar peer whose npub
    /// matches `npub`, if any — used to fold a Marmot group into that peer's mesh
    /// conversation even with no live announce. Matches the key `dmRows` builds
    /// its mesh rows under, so the fold lands both in and out of BLE range.
    ///
    /// When several Noise fingerprints advertise the same npub, returns one
    /// stable alias (persisted fold target preferred) so mesh+Marmot collapse
    /// onto a single home row.
    func sonarPeerKey(forNpub npub: String) -> String? {
        let aliases = peerKeys(linkedToNpub: npub)
        guard !aliases.isEmpty else { return nil }
        return snSelectCanonicalMeshPeerId(
            aliases: aliases,
            persistedFoldPeerIds: Set(marmotGroupIdsByConversationId.keys.map(Self.canonicalStoredKey))
        )
    }

    /// Every known 16-hex mesh key linked to `npub` (live 0x53, persisted
    /// fingerprint map, favorites Noise↔Nostr). Used to collapse rotating /
    /// multi-device BLE identities that share one Sonar account.
    private func peerKeys(linkedToNpub npub: String) -> [String] {
        guard let target = Self.nostrPubkeyData(npub) else { return [] }
        let hex = target.hexEncodedString().lowercased()
        let candidates = Array(peerKeysIndex()[hex] ?? [])
        // Re-check each candidate's *current* link (profile preferred over
        // favorites). Compose filters `meshConversationIdentityKey(it, link)`
        // the same way — reverse-index membership alone is not enough.
        var linked: [String: String] = [:]
        for key in candidates {
            if let candidateHex = linkedNpubHex(forPeerKey: key) {
                linked[key] = candidateHex
            }
        }
        return snFilterPeerKeysMatchingNpubHex(
            candidates: candidates,
            linkedNpubHexByPeer: linked,
            targetNpubHex: hex
        )
    }

    private func invalidatePeerKeysIndex() {
        peerKeysByNpubHex = nil
        npubByPeerKey = nil
    }

    private func peerKeysIndex() -> [String: Set<String>] {
        if let cached = peerKeysByNpubHex { return cached }
        var index: [String: Set<String>] = [:]
        var reverse: [String: String] = [:]
        func insert(_ peerKey: String, npub: String) {
            guard !peerKey.isEmpty,
                  let data = Self.nostrPubkeyData(npub) else { return }
            index[data.hexEncodedString().lowercased(), default: []].insert(peerKey)
            reverse[peerKey] = npub
        }
        for (key, profile) in sonarProfiles {
            insert(canonicalPeerKey(PeerID(str: key)), npub: profile.npub)
        }
        for (key, profile) in sonarProfilesByFingerprint {
            insert(Self.canonicalStoredKey(key), npub: profile.npub)
        }
        for (noiseKey, rel) in FavoritesPersistenceService.shared.favorites {
            guard let nostr = rel.peerNostrPublicKey else { continue }
            let bare = PeerID(publicKey: noiseKey).bare
            // Prefer Sonar 0x53 / fingerprint profile over a conflicting favorite
            // claim so the reverse index never indexes the same Noise key under
            // two npubs.
            if let profileNpub = sonarProfilesByFingerprint[bare]?.npub
                ?? sonarProfiles[bare]?.npub,
               let profileData = Self.nostrPubkeyData(profileNpub),
               let favData = Self.nostrPubkeyData(nostr),
               profileData != favData {
                continue
            }
            insert(bare, npub: nostr)
        }
        peerKeysByNpubHex = index
        npubByPeerKey = reverse
        return index
    }

    /// peerKey → stored npub, co-built with `peerKeysIndex()`.
    private func linkedNpubIndex() -> [String: String] {
        _ = peerKeysIndex()
        return npubByPeerKey ?? [:]
    }

    /// Live BLE route for a conversation — may differ from the canonical fold
    /// row id when the same npub has multiple Noise fingerprints (Compose
    /// `liveMeshRoutePeerId`).
    private func liveMeshRoutePeerId(for id: String) -> String? {
        let mesh = chatViewModel.meshService
        let aliases = meshPeerAliases(for: id)
        let isSonar = resolvedSonarProfile(id) != nil
            || aliases.contains { resolvedSonarProfile($0) != nil }
        return snSelectLiveMeshRoutePeerId(
            aliases: aliases,
            isConnected: { mesh.isPeerConnected(PeerID(str: $0)) },
            isReachable: { mesh.isPeerReachable(PeerID(str: $0)) },
            requireDirectConnection: isSonar
        )
    }

    /// Linked Sonar account for a mesh peer — bech32 `npub1…` or hex, as stored
    /// on the profile / favorite. Prefer this over hex-only when calling
    /// `peerKeys(linkedToNpub:)` so the call site matches every other fold path.
    private func linkedNpub(forPeerKey key: String) -> String? {
        if let profile = resolvedSonarProfile(key) {
            return profile.npub
        }
        let short = Self.canonicalStoredKey(key)
        let byPeer = linkedNpubIndex()
        if let npub = byPeer[short] ?? byPeer[key] {
            return npub
        }
        // Index includes favorites; scan only on miss (stale / race).
        for (noiseKey, rel) in FavoritesPersistenceService.shared.favorites {
            guard PeerID(publicKey: noiseKey).bare == short else { continue }
            return rel.peerNostrPublicKey
        }
        return nil
    }

    private func linkedNpubHex(forPeerKey key: String) -> String? {
        linkedNpub(forPeerKey: key).flatMap {
            Self.nostrPubkeyData($0)?.hexEncodedString().lowercased()
        }
    }

    /// All mesh peer keys that represent the same person as `id` (same linked
    /// npub, or the bare peer key when unlinked).
    ///
    /// Linked peers reuse `peerKeys(linkedToNpub:)` (profiles + fingerprints +
    /// favorites) instead of scanning every private chat and calling
    /// `linkedNpubHex` per candidate — that O(N×F) path sat on chat-open and
    /// pagination count.
    private func meshPeerAliases(for id: String) -> [String] {
        let key = canonicalPeerKey(PeerID(str: id))
        if let npub = linkedNpub(forPeerKey: key),
           let hex = Self.nostrPubkeyData(npub)?.hexEncodedString().lowercased() {
            // peerKeys already Compose-filters; still re-check inserted short/id
            // forms so an empty/unlinked alias cannot sneak into the set.
            var candidates = Set(peerKeys(linkedToNpub: npub))
            candidates.insert(key)
            candidates.insert(Self.canonicalStoredKey(id))
            var linked: [String: String] = [:]
            for alias in candidates {
                if let aliasHex = linkedNpubHex(forPeerKey: alias) {
                    linked[alias] = aliasHex
                }
            }
            return snFilterPeerKeysMatchingNpubHex(
                candidates: Array(candidates),
                linkedNpubHexByPeer: linked,
                targetNpubHex: hex
            )
        }
        return Array(Set([key, Self.canonicalStoredKey(id)].filter { !$0.isEmpty })).sorted()
    }

    /// Unique mesh message count across aliases — no sort / no full array alloc.
    /// Single-alias conversations keep the pre-fold O(1) dictionary lookup;
    /// multi-fingerprint (same npub) merges only the alias keys (Compose-shaped).
    private func meshPrivateMessageCount(forConversationId id: String) -> Int {
        let aliases = meshPeerAliases(for: id)
        let aliasSet = Set(aliases)
        if aliasSet.count <= 1 {
            let key = aliases.first ?? id
            return chatViewModel.privateChats[PeerID(str: key)]?.count
                ?? chatViewModel.privateChats[PeerID(str: id)]?.count
                ?? 0
        }
        var seen = Set<String>()
        for alias in aliases {
            guard let msgs = chatViewModel.privateChats[PeerID(str: alias)] else { continue }
            for message in msgs { seen.insert(message.id) }
        }
        return seen.count
    }

    /// Mesh/bitchat private messages across every alias of this conversation.
    /// Single-alias keeps the pre-fold O(1) `privateChats[peer]` return (already
    /// chronological); multi-fingerprint merges only alias keys (Compose-shaped).
    private func meshPrivateMessages(forConversationId id: String) -> [BitchatMessage] {
        let aliases = meshPeerAliases(for: id)
        let aliasSet = Set(aliases)
        if aliasSet.count <= 1 {
            let key = aliases.first ?? id
            return chatViewModel.privateChats[PeerID(str: key)]
                ?? chatViewModel.privateChats[PeerID(str: id)]
                ?? []
        }
        var byId: [String: BitchatMessage] = [:]
        for alias in aliases {
            guard let msgs = chatViewModel.privateChats[PeerID(str: alias)] else { continue }
            for message in msgs { byId[message.id] = message }
        }
        return byId.values.sorted { $0.timestamp < $1.timestamp }
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

    /// Memoization for `nostrPubkeyData`: the same handful of npub/hex strings
    /// get decoded over and over (per chat-list row, per BLE snapshot refresh,
    /// per profile scan in `sonarPeerKey`). A device Time Profiler trace showed
    /// repeated `Bech32.decode` from these paths as the single largest main
    /// thread cost (~35% of all main-thread CPU), arriving in >100ms bursts
    /// that starved the keyboard while typing. Lock-protected because the BLE
    /// profile provider can resolve keys off the main actor; bounded so a
    /// hostile flood of unique strings cannot grow it unbounded.
    private static let pubkeyDataCacheLock = NSLock()
    private static var pubkeyDataCache: [String: Data?] = [:]
    private static let pubkeyDataCacheCap = 4096

    /// Canonical 32-byte Nostr pubkey from a bech32 `npub1…` OR a 64-char hex string.
    private static func nostrPubkeyData(_ s: String) -> Data? {
        pubkeyDataCacheLock.lock()
        if let cached = pubkeyDataCache[s] {
            pubkeyDataCacheLock.unlock()
            return cached
        }
        pubkeyDataCacheLock.unlock()

        let decoded: Data?
        if s.hasPrefix("npub1") {
            if let d = try? Bech32.decode(s), d.hrp == "npub", d.data.count == 32 {
                decoded = d.data
            } else {
                decoded = nil
            }
        } else {
            decoded = Data(hexString: s).flatMap { $0.count == 32 ? $0 : nil }
        }

        pubkeyDataCacheLock.lock()
        if pubkeyDataCache.count >= pubkeyDataCacheCap {
            pubkeyDataCache.removeAll(keepingCapacity: true)
        }
        pubkeyDataCache[s] = decoded
        pubkeyDataCacheLock.unlock()
        return decoded
    }

    private static func sha256Hex(_ value: String) -> String {
        Data(value.utf8).sha256Hex()
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
            // Re-subscribe the Breez NDS webhook as soon as the local receive
            // offer is available. Descriptor publishing can be skipped when the
            // offer is unchanged or the relay is offline, but Boltz webhook
            // state still needs this per-launch unregister -> register self-heal.
            #if os(iOS)
            if let offer, let bridged = self.wallet as? BridgedWallet {
                SonarPushRegistration.shared.ensureBreezWebhook(offer: offer, wallet: bridged.walletService)
            }
            #endif
            if let offer {
                await self.refreshHandleOfferIfNeeded(offer)
            }
            guard self.marmot.npub != nil, self.marmot.relayConnected else { return }
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

    /// Online = a live network path plus at least one relay-backed transport.
    var online: Bool {
        networkService.internetPathSatisfied && (relayManager.isConnected || marmot.relayConnected)
    }

    /// True while a foreground/push-tap catch-up sync is in flight. Drives the
    /// passive "Catching up…" subtitle on the status chip; never gates paint.
    var catchingUp: Bool { marmot.syncingInFlight }

    var connectedRelayCount: Int { relayManager.relays.filter(\.isConnected).count }

    var connectedRelaySummary: String {
        guard networkService.internetPathSatisfied else {
            return "Offline — messages wait or travel over Bluetooth"
        }
        let count = connectedRelayCount
        if count > 0 {
            return "Connected · \(count) Nostr relays"
        }
        if marmot.relayConnected {
            return "Connected · Nostr relays"
        }
        return "Offline — messages wait or travel over Bluetooth"
    }

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
        // The local echo is already in the timeline; repaint this frame
        // instead of waiting on the throttled service republish.
        objectWillChange.send()
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
        openDM(author.routeId)
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
        if let pendingNpub = pendingMarmotNpub(for: id) {
            marmot.ensureProfile(pendingNpub)
            return SNPeerItem(
                id: id,
                name: marmot.displayName(forNpub: pendingNpub) ?? Self.shortNpub(pendingNpub),
                inRange: false, bars: 0,
                hint: "Secure chat", detail: "Setting up White Noise",
                angle: 0, r: 0
            )
        }
        if let pendingGroup = pendingMarmotGroups[id] {
            return SNPeerItem(
                id: id,
                name: pendingGroup.name,
                inRange: false, bars: 0,
                hint: "Secure group", detail: "Setting up White Noise",
                angle: 0, r: 0
            )
        }
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
            marmot.ensureProfile(profile.npub)
            return SNPeerItem(
                id: id,
                name: marmot.displayName(forNpub: profile.npub)
                    ?? knownPeerName(id)
                    ?? marmot.title(for: group),
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
        return preferredDirectMarmotGroup(in: marmotGroups(forNpub: target))
    }

    private func marmotGroups(forNpub npub: String) -> [MarmotService.MarmotGroup] {
        let target = SNMarmotProfileCache.canonicalKey(npub)
        return marmot.groups.filter { directMarmotPeerKey(in: $0) == target }
    }

    private func pendingMarmotChatId(for npub: String) -> String? {
        let clean = SNMarmotProfileCache.canonicalKey(npub)
        guard clean.hasPrefix("npub1") else { return nil }
        return Self.pendingMarmotIDPrefix + clean
    }

    private func pendingMarmotNpub(for id: String) -> String? {
        guard id.hasPrefix(Self.pendingMarmotIDPrefix) else { return nil }
        let npub = String(id.dropFirst(Self.pendingMarmotIDPrefix.count))
        return npub.hasPrefix("npub1") ? npub : nil
    }

    private func pendingMarmotGroupId(seed: String = UUID().uuidString) -> String {
        Self.pendingMarmotGroupIDPrefix + seed
    }

    private func isPendingMarmotGroup(_ id: String) -> Bool {
        id.hasPrefix(Self.pendingMarmotGroupIDPrefix) && pendingMarmotGroups[id] != nil
    }

    func isPendingSecureChat(_ id: String) -> Bool {
        (pendingMarmotNpub(for: id) != nil && marmotGroupId(id) == nil) || isPendingMarmotGroup(id)
    }

    func marmotGroupId(_ id: String) -> String? {
        if isPendingMarmotGroup(id) { return nil }
        if let pendingNpub = pendingMarmotNpub(for: id),
           let group = marmotGroup(forNpub: pendingNpub) {
            return group.id
        }
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

    private func directMarmotPeerKey(in group: MarmotService.MarmotGroup) -> String? {
        snDirectMarmotPeerKey(for: group, ownNpub: marmot.npub)
    }

    private func directMarmotGroups(matching group: MarmotService.MarmotGroup) -> [MarmotService.MarmotGroup] {
        guard let peerKey = directMarmotPeerKey(in: group) else { return [group] }
        let groups = marmot.groups.filter { directMarmotPeerKey(in: $0) == peerKey }
        return groups.isEmpty ? [group] : groups
    }

    private func directMarmotGroups(matchingGroupId groupId: String) -> [MarmotService.MarmotGroup] {
        guard let group = marmotGroup(byId: groupId) else { return [] }
        return directMarmotGroups(matching: group)
    }

    private func latestMarmotMessage(
        in groups: [MarmotService.MarmotGroup]
    ) -> (groupId: String, message: MarmotService.MarmotMessage)? {
        var latest: (groupId: String, message: MarmotService.MarmotMessage)?
        for group in groups {
            guard let message = marmot.homeRowMessage(groupId: group.id) else { continue }
            if latest == nil || message.createdAt > latest!.message.createdAt {
                latest = (group.id, message)
            }
        }
        return latest
    }

    private func preferredDirectMarmotGroup(
        in groups: [MarmotService.MarmotGroup]
    ) -> MarmotService.MarmotGroup? {
        groups.sorted { lhs, rhs in
            let lhsDate = marmot.homeRowMessage(groupId: lhs.id)?.createdAt ?? .distantPast
            let rhsDate = marmot.homeRowMessage(groupId: rhs.id)?.createdAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            let lhsVerified = marmotVerified[lhs.id] ?? false
            let rhsVerified = marmotVerified[rhs.id] ?? false
            if lhsVerified != rhsVerified { return lhsVerified && !rhsVerified }
            return lhs.id < rhs.id
        }.first
    }

    private func hasUnreadMarmotMessage(in groups: [MarmotService.MarmotGroup]) -> Bool {
        groups.contains { (marmot.unreadByGroup[$0.id] ?? 0) > 0 }
    }

    private func hasVerifiedMarmotGroup(in groups: [MarmotService.MarmotGroup]) -> Bool {
        groups.contains { marmotVerified[$0.id] ?? false }
    }

    private func markMarmotGroupsRead(matchingGroupId groupId: String) {
        let groups = directMarmotGroups(matchingGroupId: groupId)
        if groups.isEmpty {
            marmot.markConversationRead(groupId: groupId)
        } else {
            for group in groups { marmot.markConversationRead(groupId: group.id) }
        }
    }

    func marmotGroup(forConversationId id: String) -> MarmotService.MarmotGroup? {
        guard let groupId = marmotGroupId(id) else { return nil }
        return marmotGroup(byId: groupId)
    }

    func isMultiMemberMarmotGroupId(_ id: String) -> Bool {
        if isPendingMarmotGroup(id) { return true }
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
        if let pending = pendingMarmotGroups[id] {
            return pending.members.map { npub in
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
        snShortNpubLabel(value)
    }

    private func directOtherNpub(in group: MarmotService.MarmotGroup) -> String? {
        directMarmotPeerKey(in: group)
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
            let key = canonicalPeerKey(peerID)
            if let existing = byKey[key],
               (existing.lastDate ?? .distantPast) >= (row.lastDate ?? .distantPast) {
                continue
            }
            byKey[key] = row
        }
        // Mutual favorites without a transcript yet are still reachable chats.
        for fav in chatViewModel.unifiedPeerService.mutualFavorites {
            let key = canonicalPeerKey(fav.peerID)
            if (fav.isConnected || fav.isReachable),
               shouldWaitForCapabilities(peerID: fav.peerID, key: key, now: now) {
                continue
            }
            if byKey[key] == nil {
                byKey[key] = meshRow(peerID: fav.peerID, last: nil)
            }
        }
        // Same Sonar npub on multiple Noise fingerprints (rotated BLE id /
        // second device advertising the same account) → one person-row.
        // Without this, Vincenzo Palazzo showed twice with different previews.
        var linkedNpubByPeer: [String: String] = [:]
        for key in byKey.keys {
            if let hex = linkedNpubHex(forPeerKey: key) {
                linkedNpubByPeer[key] = hex
            }
        }
        let persistedFoldPeerIds = Set(
            marmotGroupIdsByConversationId.keys.map(Self.canonicalStoredKey)
        )
        byKey = snCollapseMeshDMRowsByIdentity(
            rowsByPeer: byKey,
            linkedNpubByPeer: linkedNpubByPeer,
            persistedFoldPeerIds: persistedFoldPeerIds
        )
        // Same canonical universe as `sonarPeerKey` / Marmot fold (full peerKeys
        // set), not only fingerprints that currently have a mesh row. Memoize
        // per npub so we don't rebuild peerKeys for every row.
        var canonicalByNpubHex: [String: String] = [:]
        byKey = snRekeyMeshRowsToCanonicalIds(rowsByPeer: byKey) { key in
            guard let npub = linkedNpub(forPeerKey: key),
                  let data = Self.nostrPubkeyData(npub) else { return nil }
            let hex = data.hexEncodedString().lowercased()
            if let cached = canonicalByNpubHex[hex] { return cached }
            let canonical = snSelectCanonicalMeshPeerId(
                aliases: peerKeys(linkedToNpub: npub),
                persistedFoldPeerIds: persistedFoldPeerIds
            )
            if let canonical { canonicalByNpubHex[hex] = canonical }
            return canonical
        }
        // Marmot (White Noise) groups are internet-transport chats. A group
        // whose counterpart is a Sonar-discovered peer is the SAME
        // conversation as that peer's mesh chat: fold it into the peer row
        // (the DM screen renders both transcripts merged) instead of
        // showing a second row.
        var marmotRows: [SNDMRow] = []
        let directGroupsByPeer = snCanonicalDirectMarmotGroups(marmot.groups, ownNpub: marmot.npub)
        var renderedDirectPeerKeys = Set<String>()
        for group in marmot.groups {
            let last = marmot.homeRowMessage(groupId: group.id)
            guard marmot.isDirectGroup(group) else {
                marmotRows.append(SNDMRow(
                    id: Self.marmotIDPrefix + group.id,
                    title: marmot.title(for: group),
                    preview: last.map { Self.previewText($0.content, stickerRef: $0.stickerRef, media: $0.media) } ?? "Secure group · reaches anywhere",
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
            let peerKey = directMarmotPeerKey(in: group)
            let groupSet: [MarmotService.MarmotGroup]
            if let peerKey {
                if renderedDirectPeerKeys.contains(peerKey) { continue }
                renderedDirectPeerKeys.insert(peerKey)
                groupSet = directGroupsByPeer[peerKey] ?? [group]
            } else {
                groupSet = [group]
            }
            let latest = latestMarmotMessage(in: groupSet)
            let rowGroup = preferredDirectMarmotGroup(in: groupSet) ?? group
            let rowGroupId = latest?.groupId ?? rowGroup.id
            let rowLast = latest?.message
            let otherNpub = directOtherNpub(in: rowGroup) ?? peerKey
            // Whole counterpart blocked → suppress this 1:1 chat from the list,
            // the same way a blocked mesh peer never surfaces a row. `peerKey`
            // is already reserved above so no duplicate row can slip through.
            if let otherNpub, isMarmotSenderBlocked(otherNpub) { continue }
            // Live peer id (when currently discovered over 0x53) gives us mesh
            // presence; the persisted fingerprint still lets us build the SAME
            // Sonar row when BLE is down / after restart.
            let liveSonarPeerId = otherNpub.flatMap { np in
                sonarProfiles.first(where: { $0.value.npub == np })?.key
            }
            // Identity is cryptographic: never create a persisted peer↔npub link
            // from a display-title match, even when that title is unique.
            let foldKey = otherNpub.flatMap { sonarPeerKey(forNpub: $0) }
            if let liveSonarPeerId {
                rememberMarmotGroup(rowGroupId, forConversationId: liveSonarPeerId)
            }
            if let foldKey {
                rememberMarmotGroup(rowGroupId, forConversationId: foldKey)
            }
            // Persist the fold under every known Noise alias for this npub so
            // an older fingerprint still opens the same conversation.
            if let otherNpub {
                for alias in peerKeys(linkedToNpub: otherNpub) {
                    rememberMarmotGroup(rowGroupId, forConversationId: alias)
                }
            }
            if let foldKey, let existing = byKey[foldKey] {
                // Same person as a mesh/bitchat chat → merge the White Noise leg
                // into that one row instead of showing a duplicate conversation.
                rememberMarmotGroup(rowGroupId, forConversationId: existing.id)
                let rowTitle = snFoldedDirectMarmotHomeTitle(
                    isDirectGroup: marmot.isDirectGroup(rowGroup),
                    marmotProfileTitle: marmot.title(for: rowGroup),
                    peerDerivedTitle: existing.title
                )
                if let rowLast, rowLast.createdAt > (existing.lastDate ?? .distantPast) {
                    byKey[foldKey] = SNDMRow(
                        id: existing.id,
                        title: rowTitle,
                        preview: Self.previewText(rowLast.content, stickerRef: rowLast.stickerRef, media: rowLast.media),
                        time: Self.listTime(rowLast.createdAt),
                        unread: existing.unread || hasUnreadMarmotMessage(in: groupSet),
                        presence: existing.presence,
                        verified: existing.verified || hasVerifiedMarmotGroup(in: groupSet),
                        isMarmot: false,
                        lastDate: rowLast.createdAt,
                        marmotGroupId: rowGroupId
                    )
                } else if existing.title != rowTitle {
                    byKey[foldKey] = SNDMRow(
                        id: existing.id,
                        title: rowTitle,
                        preview: existing.preview,
                        time: existing.time,
                        unread: existing.unread || hasUnreadMarmotMessage(in: groupSet),
                        presence: existing.presence,
                        verified: existing.verified || hasVerifiedMarmotGroup(in: groupSet),
                        isMarmot: existing.isMarmot,
                        lastDate: existing.lastDate,
                        marmotGroupId: rowGroupId
                    )
                }
                continue
            }
            if let foldKey {
                // Discovered Sonar peer with no mesh transcript yet, or a persisted
                // Sonar peer now out of range → one folded row, not a White Noise
                // duplicate.
                let rowId = liveSonarPeerId ?? foldKey
                rememberMarmotGroup(rowGroupId, forConversationId: rowId)
                let rowTitle = snFoldedDirectMarmotHomeTitle(
                    isDirectGroup: marmot.isDirectGroup(rowGroup),
                    marmotProfileTitle: marmot.title(for: rowGroup),
                    peerDerivedTitle: peerDisplayName(rowId)
                )
                byKey[foldKey] = SNDMRow(
                    id: rowId,
                    title: rowTitle,
                    preview: rowLast.map { Self.previewText($0.content, stickerRef: $0.stickerRef, media: $0.media) } ?? networkLabel(forPeer: rowId),
                    time: rowLast.map { Self.listTime($0.createdAt) } ?? "",
                    unread: hasUnreadMarmotMessage(in: groupSet),
                    presence: liveSonarPeerId != nil && meshReachable(rowId),
                    verified: isVerified(rowId) || hasVerifiedMarmotGroup(in: groupSet),
                    isMarmot: false,
                    lastDate: rowLast?.createdAt,
                    marmotGroupId: rowGroupId
                )
                continue
            }
            if shouldHoldStandaloneMarmotGroup(rowGroup, latestMessage: rowLast, now: now) {
                continue
            }
            marmotRows.append(SNDMRow(
                id: Self.marmotIDPrefix + rowGroupId,
                title: marmot.title(for: rowGroup),
                preview: rowLast.map { Self.previewText($0.content, stickerRef: $0.stickerRef, media: $0.media) } ?? "Secure chat · reaches anywhere",
                time: rowLast.map { Self.listTime($0.createdAt) } ?? "",
                unread: hasUnreadMarmotMessage(in: groupSet),
                presence: false,
                verified: hasVerifiedMarmotGroup(in: groupSet),
                isMarmot: true,
                lastDate: rowLast?.createdAt,
                marmotGroupId: rowGroupId
            ))
        }
        let pendingRows = pendingMarmotChats.compactMap { id, pending -> SNDMRow? in
            guard marmotGroup(forNpub: pending.npub) == nil else { return nil }
            marmot.ensureProfile(pending.npub)
            return SNDMRow(
                id: id,
                title: marmot.displayName(forNpub: pending.npub) ?? Self.shortNpub(pending.npub),
                preview: "Setting up secure chat…",
                time: Self.listTime(pending.createdAt),
                unread: false,
                presence: false,
                verified: false,
                isMarmot: true,
                lastDate: pending.createdAt,
                marmotGroupId: nil
            )
        }
        let pendingGroupRows = pendingMarmotGroups.map { id, pending in
            SNDMRow(
                id: id,
                title: pending.name,
                preview: "Setting up group…",
                time: Self.listTime(pending.createdAt),
                unread: false,
                presence: false,
                verified: false,
                isMarmot: true,
                lastDate: pending.createdAt,
                marmotGroupId: nil
            )
        }
        let rows = Array(byKey.values) + pendingRows + pendingGroupRows + marmotRows
        return snSortDMRowsByRecency(rows).map { row in
            var row = row
            row.muted = isChatMuted(row.id)
            return row
        }
    }

    private func meshRow(peerID: PeerID, last: BitchatMessage?) -> SNDMRow {
        return SNDMRow(
            id: peerID.id,
            title: peerDisplayName(peerID.id),
            preview: last.map { Self.previewText($0.content, stickerRef: meshParseStickerContent(content: $0.content).map { MarmotService.MarmotStickerRef(packCoordinate: $0.packCoordinate, shortcode: $0.shortcode, plaintextSha256: $0.plaintextSha256) }) } ?? networkLabel(forPeer: peerID.id),
            time: last.map { Self.listTime($0.timestamp) } ?? "",
            unread: chatViewModel.unreadPrivateMessages.contains(peerID),
            presence: meshReachable(peerID.id),
            verified: isVerified(peerID.id),
            isMarmot: false,
            lastDate: last?.timestamp
        )
    }

    // MARK: DM transcript + send

    /// Live per-conversation render states, keyed by conversation id. NOT
    /// @Published on purpose: creating one during a SwiftUI body evaluation
    /// must not invalidate the store. Entries are released on `closedDM`.
    private var conversationViewStates: [String: ConversationViewState] = [:]

    /// Drop leave/reopen paint cache when a conversation is deleted or erased.
    private func discardRetainedConversation(_ id: String) {
        conversationViewStates.removeValue(forKey: id)
    }


    /// The precomputed transcript for one conversation. Returns the same
    /// instance across body evaluations so `@ObservedObject` subscriptions
    /// stay stable while the chat is open.
    func conversationViewState(_ id: String) -> ConversationViewState {
        if let existing = conversationViewStates[id] { return existing }
        let state = ConversationViewState(conversationId: id, store: self)
        conversationViewStates[id] = state
        return state
    }

    /// Whether any local Marmot source folded into this visible conversation
    /// still has an older database page. Each source keeps its own cursor.
    func canLoadOlderDM(_ id: String) -> Bool {
        localTranscriptGroups(for: id).contains {
            marmot.hasOlderLocalMessages(groupId: $0.id)
        }
    }

    /// Preserve source identity while the conversation coordinator decides
    /// which cursor must move next. Rows are already render-filtered by
    /// `dmMsgs`, so hidden control lines cannot falsely satisfy a 30-row source
    /// frontier.
    func dmTranscriptSources(
        _ id: String,
        candidates: [SNMessage],
        sourceLimit: Int,
        meshNewestOffset: Int,
        paymentNewestOffset: Int,
        callNewestOffset: Int
    ) -> [SNConversationTranscriptSource] {
        var sources = localTranscriptGroups(for: id).map { group in
            return SNConversationTranscriptSource(
                id: group.id,
                rows: candidates.filter { $0.transcriptSourceID == group.id },
                hasMore: marmot.hasOlderLocalMessages(groupId: group.id)
            )
        }
        if !id.hasPrefix(Self.marmotIDPrefix),
           pendingMarmotNpub(for: id) == nil,
           !isPendingMarmotGroup(id) {
            sources.append(
                SNConversationTranscriptSource(
                    id: SNConversationTranscriptSource.meshID,
                    rows: candidates.filter {
                        $0.transcriptSourceID == SNConversationTranscriptSource.meshID
                    },
                    hasMore: hasCachedMeshOlderDM(
                        id,
                        visibleLimit: sourceLimit,
                        newestOffset: meshNewestOffset
                    )
                )
            )
        }
        let paymentCount = cachedPaymentActivityCount(id)
        if paymentCount > 0 {
            sources.append(
                SNConversationTranscriptSource(
                    id: SNConversationTranscriptSource.paymentActivityID,
                    rows: candidates.filter {
                        $0.transcriptSourceID == SNConversationTranscriptSource.paymentActivityID
                    },
                    hasMore: paymentCount > sourceLimit + paymentNewestOffset
                )
            )
        }
        let callCount = cachedCallRecordCount(id)
        if callCount > 0 {
            sources.append(
                SNConversationTranscriptSource(
                    id: SNConversationTranscriptSource.callLogID,
                    rows: candidates.filter {
                        $0.transcriptSourceID == SNConversationTranscriptSource.callLogID
                    },
                    hasMore: callCount > sourceLimit + callNewestOffset
                )
            )
        }
        return sources
    }

    /// Mesh history is already local and in memory, but it still participates
    /// in the same directional render window as Marmot. Counting it is cheap and
    /// avoids formatting rows merely to discover a lookahead item.
    func hasCachedMeshOlderDM(_ id: String, visibleLimit: Int, newestOffset: Int) -> Bool {
        guard !id.hasPrefix(Self.marmotIDPrefix),
              pendingMarmotNpub(for: id) == nil,
              !isPendingMarmotGroup(id) else { return false }
        return meshPrivateMessageCount(forConversationId: id)
            > visibleLimit + newestOffset
    }

    func cachedMeshMessageCount(_ id: String) -> Int {
        guard !id.hasPrefix(Self.marmotIDPrefix),
              pendingMarmotNpub(for: id) == nil,
              !isPendingMarmotGroup(id) else { return 0 }
        return meshPrivateMessageCount(forConversationId: id)
    }

    func cachedPaymentActivityCount(_ id: String) -> Int {
        paymentActivityLedger.activities(peerKey: id).count
    }

    func cachedCallRecordCount(_ id: String) -> Int {
        callLogs[id]?.count ?? 0
    }

    func hasCachedRenderOnlyOlderDM(
        _ id: String,
        visibleLimit: Int,
        paymentNewestOffset: Int,
        callNewestOffset: Int
    ) -> Bool {
        cachedPaymentActivityCount(id) > visibleLimit + paymentNewestOffset
            || cachedCallRecordCount(id) > visibleLimit + callNewestOffset
    }

    /// Load one older local page for the folded Marmot sources selected by the
    /// global merge frontier, then rebuild the immutable render projection so
    /// the list can restore its pre-prepend anchor deterministically.
    func loadOlderDM(
        _ id: String,
        groupIDs: Set<String>
    ) async -> SNConversationTranscriptLoadResult {
        var result = SNConversationTranscriptLoadResult.none
        for group in localTranscriptGroups(for: id) where groupIDs.contains(group.id) {
            let before = marmot.localTranscriptCanonicalMessageIDs(groupId: group.id)
            if await marmot.loadOlderLocalPageWhenAvailable(groupId: group.id) {
                result.record(
                    before: before,
                    after: marmot.localTranscriptCanonicalMessageIDs(groupId: group.id)
                )
            }
        }
        if result.added {
            conversationViewStates[id]?.rebuildNow()
        }
        return result
    }

    /// Keep every folded local source at the same historical edge as the
    /// conversation-wide render window while background updates continue.
    func preserveHistoricalDM(_ id: String) {
        for group in localTranscriptGroups(for: id) {
            marmot.preserveLocalTranscriptWindow(groupId: group.id)
        }
    }

    /// Move every folded source back to its newest local page. Used when a user
    /// who paged into a bounded historical window scrolls back to its bottom.
    func loadNewestDM(_ id: String) async -> Bool {
        var loaded = true
        for group in localTranscriptGroups(for: id) {
            if !(await marmot.loadNewestLocalPageWhenAvailable(groupId: group.id)) {
                loaded = false
            }
        }
        return loaded
    }

    private func localTranscriptGroups(for id: String) -> [MarmotService.MarmotGroup] {
        let groupId = marmotGroupId(id)
            ?? resolvedSonarProfile(id).flatMap { marmotGroup(forNpub: $0.npub)?.id }
        guard let groupId else { return [] }
        let folded = directMarmotGroups(matchingGroupId: groupId)
        if !folded.isEmpty { return folded }
        return [MarmotService.MarmotGroup(id: groupId, name: "", memberNpubs: [])]
    }

    /// How one chat line renders: regular text, a ⚡PAY receipt bubble,
    /// a ⚡TRILL nudge pill, or hidden (⚡PAYDONE is a protocol control
    /// line). Unknown versions decode to nothing and fall through as text.
    private enum PayMapping {
        case notPay
        case hidden
        case bubble(SNPayInfo, SNVia)
        /// ⚡TRILL|1|<id>: render the centered nudge pill (docs/SONAR-TRILL.md).
        case trill
    }

    private func payMapping(_ content: String, fallbackVia: SNVia) -> PayMapping {
        // ☎CALL signaling lines ride the chat like ⚡PAY but are never shown. The
        // cheap prefix prefilter avoids an FFI call for ordinary chat messages.
        if Self.looksLikeCallControl(content), callParseControl(content: content) != nil {
            return .hidden
        }
        if SonarTrillMessage.isTrillLine(content) { return .trill }
        guard let line = SonarPayMessage.decode(content) else { return .notPay }
        guard case .pay(let pid, let sats) = line else { return .hidden }
        return payBubble(paymentId: pid, wireSats: sats, fallbackVia: fallbackVia)
    }

    /// Marmot messages arrive with a core-computed classification, so the
    /// transcript build does zero content parsing (and zero FFI calls) for
    /// them. Optimistic local echoes default to `.text` and fall back to the
    /// string decode so a just-sent ⚡PAY line still bubbles immediately.
    private func payMapping(
        _ m: MarmotService.MarmotMessage,
        fallbackVia: SNVia
    ) -> PayMapping {
        switch m.classification {
        case .callControl, .payDone:
            return .hidden
        case .payReceipt(let pid, let sats):
            // `sats` is a core u64; the ledger/UI use Int64. `Int64(sats)`
            // TRAPS above Int64.max, so a peer could crash the transcript
            // rebuild with `⚡PAY|1|<id>|9223372036854775808`. Fall back to
            // plain text on overflow — the same outcome the string decoder
            // produced (its `Int64(String)` returned nil).
            guard let wireSats = Int64(exactly: sats) else { return .notPay }
            return payBubble(paymentId: pid, wireSats: wireSats, fallbackVia: fallbackVia)
        case .text:
            // Core MessageClassInfo has no trill variant (yet); ⚡TRILL lines
            // classify as .text and are picked up by the string decode here,
            // exactly like a just-sent optimistic ⚡PAY echo.
            if m.content.hasPrefix("\u{26A1}PAY")
                || m.content.hasPrefix("\u{26A1}TRILL")
                || Self.looksLikeCallControl(m.content) {
                return payMapping(m.content, fallbackVia: fallbackVia)
            }
            return .notPay
        }
    }

    private func payBubble(paymentId pid: String, wireSats: Int64, fallbackVia: SNVia) -> PayMapping {
        let entry = payLedger.entry(for: pid)
        // The coin renders with the transport it traveled over (recorded in
        // the ledger), not the conversation's current reachability.
        let via = entry.flatMap { SNVia(rawValue: $0.via) } ?? fallbackVia
        let isDirect = paymentActivityLedger.entries[pid] != nil
        return .bubble(
            SNPayInfo(id: pid, sats: entry?.sats ?? wireSats, state: entry?.state ?? .sealed, direct: isDirect),
            via
        )
    }

    private func paymentActivityRows(
        for id: String,
        transcriptPayIDs: Set<String>,
        limit: Int? = nil,
        newestOffset: Int = 0
    ) -> [(Date, SNMessage)] {
        let relevant = paymentActivityLedger.activities(peerKey: id).filter { activity in
            payLedger.entry(for: activity.id) == nil || !transcriptPayIDs.contains(activity.id)
        }.sorted { lhs, rhs in
            (lhs.settledAt ?? lhs.createdAt) < (rhs.settledAt ?? rhs.createdAt)
        }
        return Self.transcriptSource(
            relevant,
            limit: limit,
            newestOffset: newestOffset
        ).map { activity in
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
                    transcriptSourceID: SNConversationTranscriptSource.paymentActivityID,
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

    private static func transcriptSource<T>(
        _ rows: [T],
        limit: Int?,
        newestOffset: Int = 0
    ) -> ArraySlice<T> {
        guard let limit else { return rows[...] }
        let end = max(0, rows.count - max(0, newestOffset))
        return rows[..<end].suffix(max(0, limit))
    }

    /// Build the render-ready transcript for one conversation. O(page) with
    /// parsing/sorting — call it from `ConversationViewState` (per data
    /// change), NEVER from a SwiftUI `body` (per render).
    ///
    /// `limit` is applied to every folded local source before expensive
    /// formatting. The caller applies the one conversation-wide render budget
    /// after the chronological merge; keeping the bounded source candidates is
    /// required to page into an older transport when another transport owns the
    /// newer edge.
    func dmMsgs(
        _ id: String,
        limit: Int? = nil,
        meshNewestOffset: Int = 0,
        paymentNewestOffset: Int = 0,
        callNewestOffset: Int = 0
    ) -> [SNMessage] {
        if let groupId = marmotGroupId(id) {
            let groups = directMarmotGroups(matchingGroupId: groupId)
            let sourceGroups = groups.isEmpty
                ? [MarmotService.MarmotGroup(id: groupId, name: "", memberNpubs: [])]
                : groups
            var dated: [(Date, SNMessage)] = []
            for group in sourceGroups {
                dated += Self.transcriptSource(
                    marmot.messagesByGroup[group.id] ?? [],
                    limit: limit
                ).compactMap { m in
                    // Drop a blocked person's messages from the transcript, the
                    // same way the mesh inbound path drops them via `isNostrBlocked`.
                    if !m.isMine, isMarmotSenderBlocked(m.senderNpub) { return nil }
                    switch payMapping(m, fallbackVia: .internet) {
                    case .hidden:
                        return nil
                    case .trill:
                        return (m.createdAt, SNMessage(
                            id: m.id, mine: m.isMine,
                            author: marmot.marmotAuthorName(m),
                            text: "",
                            time: Self.clock(m.createdAt),
                            transcriptSourceID: group.id,
                            via: .internet,
                            trill: true
                        ))
                    case .bubble(let pay, let payVia):
                        return (m.createdAt, SNMessage(
                            id: m.id, mine: m.isMine, text: m.content,
                            time: Self.clock(m.createdAt),
                            transcriptSourceID: group.id,
                            via: payVia,
                            pay: pay
                        ))
                    case .notPay:
                        return (m.createdAt, SNMessage(
                            id: m.id,
                            mine: m.isMine,
                            author: marmot.marmotAuthorName(m),
                            text: m.content,
                            time: Self.clock(m.createdAt),
                            transcriptSourceID: group.id,
                            via: .internet,
                            state: MarmotChatModel.stateText(for: m),
                            uploadProgress: marmot.mediaUploadProgress[m.id],
                            media: Self.mediaItems(m, groupId: group.id),
                            stickerRef: m.stickerRef
                        ))
                    }
                }
            }
            if !id.hasPrefix(Self.marmotIDPrefix), pendingMarmotNpub(for: id) == nil {
                let via: SNVia = .mesh
                let my = chatViewModel.meshService.myPeerID
                dated += Self.transcriptSource(
                    meshPrivateMessages(forConversationId: id),
                    limit: limit,
                    newestOffset: meshNewestOffset
                ).compactMap { m in
                    let mine = m.senderPeerID == my
                    switch payMapping(m.content, fallbackVia: via) {
                    case .hidden:
                        return nil
                    case .trill:
                        return (m.timestamp, SNMessage(
                            id: m.id, mine: mine,
                            author: m.sender,
                            text: "",
                            time: Self.clock(m.timestamp),
                            transcriptSourceID: SNConversationTranscriptSource.meshID,
                            via: via,
                            trill: true
                        ))
                    case .bubble(let pay, let payVia):
                        return (m.timestamp, SNMessage(
                            id: m.id, mine: mine, text: m.content,
                            time: Self.clock(m.timestamp),
                            transcriptSourceID: SNConversationTranscriptSource.meshID,
                            via: payVia,
                            pay: pay
                        ))
                    case .notPay:
                        let mediaItem = meshMediaItem(m.content)
                        let meshSticker = meshParseStickerContent(content: m.content).map {
                            MarmotService.MarmotStickerRef(packCoordinate: $0.packCoordinate, shortcode: $0.shortcode, plaintextSha256: $0.plaintextSha256)
                        }
                        return (m.timestamp, SNMessage(
                            id: m.id,
                            mine: mine,
                            author: m.sender,
                            text: (mediaItem != nil || meshSticker != nil) ? "" : m.content,
                            time: Self.clock(m.timestamp),
                            transcriptSourceID: SNConversationTranscriptSource.meshID,
                            via: via,
                            state: mine ? Self.stateText(m.deliveryStatus) : nil,
                            media: mediaItem.map { [$0] } ?? [],
                            stickerRef: meshSticker
                        ))
                    }
                }
                dated.sort { $0.0 < $1.0 }
            }
            let echoIds = ([id] + sourceGroups.map { Self.marmotIDPrefix + $0.id }).reduce(into: [String]()) { ids, echoId in
                if !ids.contains(echoId) { ids.append(echoId) }
            }
            for echoId in echoIds {
                dated += Self.transcriptSource(
                    pendingMarmotMessagesByChat[echoId] ?? [],
                    limit: limit
                ).map { ($0.sortDate ?? Date(), $0) }
            }
            let transcriptPayIDs = Set(dated.compactMap { $0.1.pay?.id })
            dated += paymentActivityRows(
                for: id,
                transcriptPayIDs: transcriptPayIDs,
                limit: limit,
                newestOffset: paymentNewestOffset
            )
            return mergeCallLogs(
                into: dated,
                id: id,
                limit: limit,
                newestOffset: callNewestOffset
            )
        }
        if pendingMarmotNpub(for: id) != nil {
            let dated = Self.transcriptSource(
                pendingMarmotMessagesByChat[id] ?? [],
                limit: limit
            ).map { ($0.sortDate ?? Date(), $0) }
            return mergeCallLogs(
                into: dated,
                id: id,
                limit: limit,
                newestOffset: callNewestOffset
            )
        }
        if isPendingMarmotGroup(id) {
            let dated = Self.transcriptSource(
                pendingMarmotMessagesByChat[id] ?? [],
                limit: limit
            ).map { ($0.sortDate ?? Date(), $0) }
            return mergeCallLogs(
                into: dated,
                id: id,
                limit: limit,
                newestOffset: callNewestOffset
            )
        }
        let via = dmTransport(id)
        let my = chatViewModel.meshService.myPeerID
        var dated: [(Date, SNMessage)] = Self.transcriptSource(
            meshPrivateMessages(forConversationId: id),
            limit: limit,
            newestOffset: meshNewestOffset
        ).compactMap { m in
            let mine = m.senderPeerID == my
            switch payMapping(m.content, fallbackVia: via) {
            case .hidden:
                return nil
            case .trill:
                return (m.timestamp, SNMessage(
                    id: m.id, mine: mine,
                    author: m.sender,
                    text: "",
                    time: Self.clock(m.timestamp),
                    transcriptSourceID: SNConversationTranscriptSource.meshID,
                    via: via,
                    trill: true
                ))
            case .bubble(let pay, let payVia):
                return (m.timestamp, SNMessage(
                    id: m.id, mine: mine, text: m.content,
                    time: Self.clock(m.timestamp),
                    transcriptSourceID: SNConversationTranscriptSource.meshID,
                    via: payVia,
                    pay: pay
                ))
            case .notPay:
                // BLE-mesh media (bitchat file transfer) arrives as an
                // "[image] <name>" marker with the file already on disk.
                let mediaItem = meshMediaItem(m.content)
                let meshSticker = meshParseStickerContent(content: m.content).map {
                    MarmotService.MarmotStickerRef(packCoordinate: $0.packCoordinate, shortcode: $0.shortcode, plaintextSha256: $0.plaintextSha256)
                }
                return (m.timestamp, SNMessage(
                    id: m.id,
                    mine: mine,
                    author: m.sender,
                    text: (mediaItem != nil || meshSticker != nil) ? "" : m.content,
                    time: Self.clock(m.timestamp),
                    transcriptSourceID: SNConversationTranscriptSource.meshID,
                    via: via,
                    state: mine ? Self.stateText(m.deliveryStatus) : nil,
                    media: mediaItem.map { [$0] } ?? [],
                    stickerRef: meshSticker
                ))
            }
        }
        // Sonar peer: the conversation continues over White Noise while out
        // of Bluetooth range. v1 keeps the two transcripts in separate
        // stores but RENDERS them as one, merged chronologically; the
        // White Noise leg always renders as internet (indigo).
        if let profile = resolvedSonarProfile(id), let group = marmotGroup(forNpub: profile.npub) {
            dated += Self.transcriptSource(
                marmot.messagesByGroup[group.id] ?? [],
                limit: limit
            ).compactMap { m in
                // Drop a blocked person's messages from the transcript, the
                // same way the mesh inbound path drops them via `isNostrBlocked`.
                if !m.isMine, isMarmotSenderBlocked(m.senderNpub) { return nil }
                switch payMapping(m, fallbackVia: .internet) {
                case .hidden:
                    return nil
                case .trill:
                    return (m.createdAt, SNMessage(
                        id: m.id, mine: m.isMine,
                        author: m.isMine ? nil : peerDisplayName(id),
                        text: "",
                        time: Self.clock(m.createdAt),
                        transcriptSourceID: group.id,
                        via: .internet,
                        trill: true
                    ))
                case .bubble(let pay, let payVia):
                    return (m.createdAt, SNMessage(
                        id: m.id, mine: m.isMine, text: m.content,
                        time: Self.clock(m.createdAt),
                        transcriptSourceID: group.id,
                        via: payVia,
                        pay: pay
                    ))
                case .notPay:
                    return (m.createdAt, SNMessage(
                        id: m.id,
                        mine: m.isMine,
                        author: m.isMine ? nil : peerDisplayName(id),
                        text: m.content,
                        time: Self.clock(m.createdAt),
                        transcriptSourceID: group.id,
                        via: .internet,
                        state: MarmotChatModel.stateText(for: m),
                        uploadProgress: marmot.mediaUploadProgress[m.id],
                        media: Self.mediaItems(m, groupId: group.id),
                        stickerRef: m.stickerRef
                    ))
                }
            }
            dated.sort { $0.0 < $1.0 }
        }
        let transcriptPayIDs = Set(dated.compactMap { $0.1.pay?.id })
        dated += paymentActivityRows(
            for: id,
            transcriptPayIDs: transcriptPayIDs,
            limit: limit,
            newestOffset: paymentNewestOffset
        )
        return mergeCallLogs(
            into: dated,
            id: id,
            limit: limit,
            newestOffset: callNewestOffset
        )
    }

    /// Fold local call records for `id` into the transcript chronologically
    /// (stable sort keeps same-instant messages in place). A no-op when this
    /// peer has no recorded calls.
    private func mergeCallLogs(
        into dated: [(Date, SNMessage)],
        id: String,
        limit: Int?,
        newestOffset: Int
    ) -> [SNMessage] {
        let calls = callLogs[id] ?? []
        var combined = dated
        for c in Self.transcriptSource(calls, limit: limit, newestOffset: newestOffset) {
            var message = c.message
            message.transcriptSourceID = SNConversationTranscriptSource.callLogID
            combined.append((c.date, message))
        }
        return combined.enumerated()
            .sorted {
                if $0.element.0 == $1.element.0 { return $0.offset < $1.offset }
                return $0.element.0 < $1.element.0
            }
            .map {
                var message = $0.element.1
                message.sortDate = $0.element.0
                return message
            }
    }

    /// DM routing uses Bluetooth only while a Sonar peer is directly connected;
    /// retained mesh reachability means the direct BLE leg already dropped, so
    /// the conversation continues over White Noise.
    func dmTransport(_ id: String) -> SNVia {
        if meshReachable(id) { return .mesh }
        return .internet
    }

    func sendDm(_ id: String, _ text: String) {
        // Every send route lands a local echo synchronously; repaint this
        // frame instead of waiting on the throttled service republish. One
        // defer covers all early-return branches (mesh route, Marmot,
        // pending) uniformly.
        defer { objectWillChange.send() }
        // Route on the live BLE alias — canonical fold id may be a stale
        // fingerprint while the peer is connected under another Noise key.
        if let route = liveMeshRoutePeerId(for: id) {
            chatViewModel.sendPrivateMessage(text, to: PeerID(str: route))
            return
        }
        if let groupId = marmotGroupId(id) {
            marmot.send(text, to: groupId)
            return
        }
        if let pendingNpub = pendingMarmotNpub(for: id) {
            sendPendingMarmot(text, chatId: id, npub: pendingNpub)
            return
        }
        if isPendingMarmotGroup(id) {
            sendPendingMarmotGroup(text, chatId: id)
            return
        }
        if let profile = resolvedSonarProfile(id) {
            sendOverMarmot(text, npub: profile.npub)
            return
        }
        chatViewModel.sendPrivateMessage(text, to: PeerID(str: id))
    }

    /// Cancel an in-flight Blossom upload for an optimistic media bubble.
    func cancelMediaUpload(_ message: SNMessage) {
        marmot.cancelMediaUpload(pendingId: message.id)
    }

    /// Signal-style retry for one failed outgoing row. Durable Marmot rows
    /// republish the original encrypted event; platform-local setup/media rows
    /// reuse the content already retained for that exact bubble.
    func retryDm(_ id: String, message: SNMessage) {
        guard snCanRetryFailedMessage(message) else { return }
        let groupId = message.media.first?.groupId
            ?? marmotGroupId(id)
            ?? resolvedSonarProfile(id).flatMap { marmotGroup(forNpub: $0.npub)?.id }

        if let groupId,
           MarmotChatModel.isFailedOptimisticMessageId(message.id),
           !message.media.isEmpty {
            retryFailedMedia(message, groupId: groupId)
            return
        }

        if let groupId, snIsFailedOptimisticStickerMessage(message) {
            retryFailedSticker(message, groupId: groupId)
            return
        }

        if message.id.hasPrefix("echo-") {
            retryFailedPendingText(id, message: message, groupId: groupId)
            return
        }

        marmot.retryMessage(messageId: message.id)
    }

    /// Retry one setup-stage text without leaving a gap in the transcript. An
    /// established Marmot chat removes the old failed row only after the new
    /// optimistic echo is visible, then restores it if that replacement fails.
    private func retryFailedPendingText(_ id: String, message: SNMessage, groupId: String?) {
        guard let content = snRetryContent(message) else {
            showToast("This message is no longer available to retry.")
            return
        }
        guard let source = setPendingMarmotMessageState(
            message.id,
            from: "Couldn't send",
            to: "Sending"
        ) else {
            showToast("This message is no longer available to retry.")
            return
        }

        if let groupId {
            let onEchoVisible: () -> Void = { [weak self] in
                self?.removePendingMarmotMessage(message.id)
            }
            let onFailure: () -> Void = { [weak self] in
                self?.restoreFailedPendingMarmotMessage(source.message, preferredKey: source.key)
            }
            if let ref = message.stickerRef {
                marmot.sendSticker(
                    groupId: groupId,
                    packCoordinate: ref.packCoordinate,
                    shortcode: ref.shortcode,
                    plaintextSha256: ref.plaintextSha256,
                    onEchoVisible: onEchoVisible
                )
            } else {
                marmot.send(
                    content,
                    to: groupId,
                    onEchoVisible: onEchoVisible,
                    onFailure: onFailure
                )
            }
            return
        }

        if let npub = pendingMarmotNpub(for: id) {
            let clean = SNMarmotProfileCache.canonicalKey(npub)
            pendingMarmotChats[id] = pendingMarmotChats[id]
                ?? SNPendingMarmotChat(npub: clean, createdAt: source.message.sortDate ?? Date())
            var queue = pendingDirectMarmotSends[clean, default: []]
            queue.removeAll { $0.messageId == message.id }
            queue.append(SNPendingMarmotSend(chatId: id, text: content, messageId: message.id))
            if queue.count > Self.pendingMarmotDirectSendQueueLimit {
                let dropped = queue.removeFirst()
                pendingMarmotMessagesByChat[dropped.chatId] = pendingMarmotMessagesByChat[dropped.chatId]?.map {
                    $0.id == dropped.messageId ? failedPendingMessage($0) : $0
                }
                showToast("Still setting up this chat - wait before retrying more.")
            }
            pendingDirectMarmotSends[clean] = queue
            marmot.connectIfNeeded()
            startSecureChatInBackground(npub: clean, pendingId: id)
            return
        }

        if isPendingMarmotGroup(id) {
            var queue = pendingMarmotGroupSends[id, default: []]
            queue.removeAll { $0.messageId == message.id }
            queue.append(SNPendingMarmotGroupSend(text: content, messageId: message.id))
            if queue.count > Self.pendingMarmotGroupSendQueueLimit {
                let dropped = queue.removeFirst()
                pendingMarmotMessagesByChat[id] = pendingMarmotMessagesByChat[id]?.map {
                    $0.id == dropped.messageId ? failedPendingMessage($0) : $0
                }
                showToast("Still setting up this group - wait before retrying more.")
            }
            pendingMarmotGroupSends[id] = queue
            startPendingMarmotGroupCreation(pendingId: id)
            return
        }

        restoreFailedPendingMarmotMessage(source.message, preferredKey: source.key)
        showToast("This message is no longer available to retry.")
    }

    private func setPendingMarmotMessageState(
        _ messageId: String,
        from expectedState: String? = nil,
        to state: String
    ) -> (key: String, message: SNMessage)? {
        for key in Array(pendingMarmotMessagesByChat.keys) {
            guard let index = pendingMarmotMessagesByChat[key]?.firstIndex(where: { $0.id == messageId }),
                  let original = pendingMarmotMessagesByChat[key]?[index]
            else { continue }
            guard expectedState == nil || original.state == expectedState else { return nil }
            var updated = original
            updated.state = state
            pendingMarmotMessagesByChat[key]?[index] = updated
            return (key, original)
        }
        return nil
    }

    private func removePendingMarmotMessage(_ messageId: String) {
        for key in Array(pendingMarmotMessagesByChat.keys) {
            pendingMarmotMessagesByChat[key]?.removeAll { $0.id == messageId }
            if pendingMarmotMessagesByChat[key]?.isEmpty == true {
                pendingMarmotMessagesByChat[key] = nil
            }
        }
    }

    private func restoreFailedPendingMarmotMessage(_ message: SNMessage, preferredKey: String) {
        if setPendingMarmotMessageState(message.id, to: "Couldn't send") != nil {
            return
        }
        pendingMarmotMessagesByChat[preferredKey, default: []].append(failedPendingMessage(message))
    }

    private func sendPaymentReceiptLines(_ lines: [String], to id: String) async -> Bool {
        guard !lines.isEmpty else { return true }
        if let route = liveMeshRoutePeerId(for: id) {
            let peer = PeerID(str: route)
            for line in lines { chatViewModel.sendPrivateMessage(line, to: peer) }
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
        let content = meshStickerContent(
            packCoordinate: packCoordinate,
            shortcode: sticker.shortcode,
            plaintextSha256: sticker.sha256
        )
        if let route = liveMeshRoutePeerId(for: id) {
            chatViewModel.sendPrivateMessage(content, to: PeerID(str: route))
            return
        }
        if let groupId = marmotGroupId(id) {
            marmot.sendSticker(
                groupId: groupId,
                packCoordinate: packCoordinate,
                shortcode: sticker.shortcode,
                plaintextSha256: sticker.sha256
            )
            return
        }
        if let pendingNpub = pendingMarmotNpub(for: id) {
            sendPendingMarmot(content, chatId: id, npub: pendingNpub)
            return
        }
        if isPendingMarmotGroup(id) {
            sendPendingMarmotGroup(content, chatId: id)
            return
        }
        if let profile = resolvedSonarProfile(id) {
            sendOverMarmotSticker(npub: profile.npub, packCoordinate: packCoordinate, sticker: sticker)
            return
        }
        // Match text routing: let the mesh router queue/fail visibly instead
        // of silently discarding a sticker when contact metadata is incomplete.
        chatViewModel.sendPrivateMessage(content, to: PeerID(str: id))
    }

    private func sendOverMarmotSticker(npub: String, packCoordinate: String, sticker: StickerInfo) {
        if let group = marmotGroup(forNpub: npub) {
            marmot.sendSticker(
                groupId: group.id,
                packCoordinate: packCoordinate,
                shortcode: sticker.shortcode,
                plaintextSha256: sticker.sha256
            )
            return
        }
        let encoded = meshStickerContent(
            packCoordinate: packCoordinate,
            shortcode: sticker.shortcode,
            plaintextSha256: sticker.sha256
        )
        queuePendingMeshMarmotSend(text: encoded, npub: npub)
        startSecureMeshMarmotChat(npub: npub)
    }

    private func sendOverMarmot(_ text: String, npub: String) {
        if let group = marmotGroup(forNpub: npub) {
            marmot.send(text, to: group.id)
            return
        }
        queuePendingMeshMarmotSend(text: text, npub: npub)
        showToast("Out of range — continuing over White Noise…")
        startSecureMeshMarmotChat(npub: npub)
    }

    /// Paint a Sending echo on the open mesh conversation immediately, then
    /// queue the plaintext for [flushPendingMarmotSends] once the WN group lands.
    private func queuePendingMeshMarmotSend(text: String, npub: String) {
        let clean = SNMarmotProfileCache.canonicalKey(npub)
        let chatId = currentDMId ?? sonarPeerKey(forNpub: clean)
        if let chatId {
            let message = pendingMarmotEcho(text: text, createdAt: Date())
            pendingMarmotMessagesByChat[chatId, default: []].append(message)
            objectWillChange.send()
            pendingMarmotSends[clean, default: []].append(
                SNPendingMarmotSend(chatId: chatId, text: text, messageId: message.id)
            )
        } else {
            pendingMarmotSends[clean, default: []].append(
                SNPendingMarmotSend(chatId: "", text: text, messageId: "")
            )
        }
    }

    /// Create the White Noise group for an out-of-range mesh DM. On failure,
    /// mark queued mesh echoes `Couldn't send` (Compose `failPendingMeshMarmotSends`).
    private func startSecureMeshMarmotChat(npub: String) {
        let clean = SNMarmotProfileCache.canonicalKey(npub)
        marmot.connectIfNeeded()
        // Single-flight per npub (Compose `startingMarmotChats`). Extra taps
        // while setup runs stay queued in `pendingMarmotSends` and flush when
        // this starter finishes.
        guard startingMarmotChats.insert(clean).inserted else { return }
        Task { @MainActor in
            defer { startingMarmotChats.remove(clean) }
            let groupId = await marmot.startChatReturningId(with: clean)
            if groupId == nil {
                failPendingMeshMarmotSends(npub: clean)
                if let err = marmot.errorText, !err.isEmpty {
                    showToast(err)
                } else {
                    showToast("couldn't start secure chat")
                }
                return
            }
            // Do not rely solely on `$groups` re-emitting — flush now (Compose
            // calls `flushPendingMarmot` after `startChat`).
            flushPendingMarmotSends()
        }
    }

    private func failPendingMeshMarmotSends(npub: String) {
        let clean = SNMarmotProfileCache.canonicalKey(npub)
        let sends = pendingMarmotSends.removeValue(forKey: clean) ?? []
        guard !sends.isEmpty else { return }
        for send in sends where !send.chatId.isEmpty && !send.messageId.isEmpty {
            guard let idx = pendingMarmotMessagesByChat[send.chatId]?.firstIndex(where: { $0.id == send.messageId }),
                  let original = pendingMarmotMessagesByChat[send.chatId]?[idx]
            else { continue }
            pendingMarmotMessagesByChat[send.chatId]?[idx] = failedPendingMessage(original)
        }
        objectWillChange.send()
    }

    private func sendPendingMarmot(_ text: String, chatId: String, npub: String) {
        let clean = SNMarmotProfileCache.canonicalKey(npub)
        let createdAt = Date()
        if pendingMarmotChats[chatId] == nil, pendingMarmotNpub(for: chatId) == clean {
            pendingMarmotChats[chatId] = SNPendingMarmotChat(npub: clean, createdAt: createdAt)
        }
        let message = pendingMarmotEcho(text: text, createdAt: createdAt)
        pendingMarmotMessagesByChat[chatId, default: []].append(message)
        var queue = pendingDirectMarmotSends[clean, default: []]
        queue.append(SNPendingMarmotSend(chatId: chatId, text: text, messageId: message.id))
        if queue.count > Self.pendingMarmotDirectSendQueueLimit {
            let dropped = queue.removeFirst()
            pendingMarmotMessagesByChat[dropped.chatId] = pendingMarmotMessagesByChat[dropped.chatId]?.map {
                $0.id == dropped.messageId ? failedPendingMessage($0) : $0
            }
            showToast("Still setting up this chat - wait before sending more.")
        }
        pendingDirectMarmotSends[clean] = queue
        startSecureChatInBackground(npub: clean, pendingId: chatId)
    }

    private func sendPendingMarmotGroup(_ text: String, chatId: String) {
        guard isPendingMarmotGroup(chatId) else { return }
        let createdAt = Date()
        let message = pendingMarmotEcho(text: text, createdAt: createdAt)
        pendingMarmotMessagesByChat[chatId, default: []].append(message)
        var queue = pendingMarmotGroupSends[chatId, default: []]
        queue.append(SNPendingMarmotGroupSend(text: text, messageId: message.id))
        if queue.count > Self.pendingMarmotGroupSendQueueLimit {
            let dropped = queue.removeFirst()
            pendingMarmotMessagesByChat[chatId] = pendingMarmotMessagesByChat[chatId]?.map {
                $0.id == dropped.messageId ? failedPendingMessage($0) : $0
            }
            showToast("Still setting up this group - wait before sending more.")
        }
        pendingMarmotGroupSends[chatId] = queue
    }

    private func pendingMarmotEcho(
        text: String,
        id: String = "echo-\(UUID().uuidString)",
        createdAt: Date,
        state: String = "Sending"
    ) -> SNMessage {
        let stickerRef = meshParseStickerContent(content: text).map {
            MarmotService.MarmotStickerRef(
                packCoordinate: $0.packCoordinate,
                shortcode: $0.shortcode,
                plaintextSha256: $0.plaintextSha256
            )
        }
        // A queued ⚡TRILL echo must render as the nudge pill, never as the
        // raw control line (these rows bypass payMapping).
        let isTrill = SonarTrillMessage.isTrillLine(text)
        return SNMessage(
            id: id,
            mine: true,
            text: (stickerRef == nil && !isTrill) ? text : "",
            time: Self.clock(createdAt),
            sortDate: createdAt,
            via: .internet,
            state: state,
            trill: isTrill,
            stickerRef: stickerRef
        )
    }

    private func startSecureChatInBackground(npub: String, pendingId: String) {
        let clean = SNMarmotProfileCache.canonicalKey(npub)
        if let group = marmotGroup(forNpub: clean) {
            finishPendingSecureChat(pendingId: pendingId, npub: clean, groupId: group.id)
            return
        }
        guard startingMarmotChats.insert(clean).inserted else { return }
        let setupToken = UUID()
        pendingMarmotSetupTokens[pendingId] = setupToken
        let setupTask = Task { @MainActor in
            defer { clearPendingSecureChatSetup(pendingId: pendingId, npub: clean, token: setupToken) }
            guard let groupId = await marmot.startChatReturningId(with: clean) else {
                failPendingSecureChat(pendingId: pendingId, npub: clean, setupToken: setupToken)
                return
            }
            finishPendingSecureChat(pendingId: pendingId, npub: clean, groupId: groupId, setupToken: setupToken)
        }
        pendingMarmotSetupTasks[pendingId] = setupTask
    }

    private func finishPendingSecureChat(pendingId: String, npub: String, groupId: String, setupToken: UUID? = nil) {
        guard isActivePendingSecureChatSetup(pendingId: pendingId, npub: npub, token: setupToken) else { return }
        if setupToken == nil {
            cancelPendingSecureChatSetup(pendingId: pendingId, npub: npub)
        }
        pendingMarmotChats[pendingId] = nil
        let realId = Self.marmotIDPrefix + groupId
        pendingMarmotRouteReplacement = SNMarmotRouteReplacement(pendingId: pendingId, realId: realId)
        if currentDMId == pendingId {
            path.removeLast()
            push(.dm(realId))
        }
        if let echoes = pendingMarmotMessagesByChat.removeValue(forKey: pendingId), !echoes.isEmpty {
            pendingMarmotMessagesByChat[realId, default: []].append(contentsOf: echoes)
        }
        flushPendingDirectMarmot(npub: npub, groupId: groupId, realId: realId)
        openedDM(realId, marmotGroupId: groupId)
    }

    private func resolvePendingSecureChats() {
        guard !pendingMarmotChats.isEmpty else { return }
        for (pendingId, pending) in Array(pendingMarmotChats) {
            if let group = marmotGroup(forNpub: pending.npub) {
                finishPendingSecureChat(pendingId: pendingId, npub: pending.npub, groupId: group.id)
            }
        }
    }

    private func failPendingSecureChat(pendingId: String, npub: String, setupToken: UUID? = nil) {
        guard isActivePendingSecureChatSetup(pendingId: pendingId, npub: npub, token: setupToken) else { return }
        pendingMarmotChats[pendingId] = nil
        pendingMarmotRouteFailure = SNMarmotRouteFailure(pendingId: pendingId)
        let queued = pendingDirectMarmotSends.removeValue(forKey: npub) ?? []
        let queuedIds = Set(queued.map(\.messageId))
        var messages = (pendingMarmotMessagesByChat[pendingId] ?? []).map {
            queuedIds.contains($0.id) ? failedPendingMessage($0) : $0
        }
        for item in queued where !messages.contains(where: { $0.id == item.messageId }) {
            let createdAt = Date()
            messages.append(SNMessage(
                id: item.messageId,
                mine: true,
                text: item.text,
                time: Self.clock(createdAt),
                sortDate: createdAt,
                via: .internet,
                state: "Couldn't send"
            ))
        }
        if currentDMId == pendingId && !messages.isEmpty {
            pendingMarmotMessagesByChat[pendingId] = messages
        } else {
            pendingMarmotMessagesByChat[pendingId] = nil
        }
    }

    private func isActivePendingSecureChatSetup(pendingId: String, npub: String, token: UUID?) -> Bool {
        guard pendingMarmotChats[pendingId]?.npub == npub else { return false }
        return token == nil || pendingMarmotSetupTokens[pendingId] == token
    }

    private func clearPendingSecureChatSetup(pendingId: String, npub: String, token: UUID) {
        guard pendingMarmotSetupTokens[pendingId] == token else { return }
        pendingMarmotSetupTokens[pendingId] = nil
        pendingMarmotSetupTasks[pendingId] = nil
        startingMarmotChats.remove(npub)
    }

    private func cancelPendingSecureChatSetup(pendingId: String, npub: String) {
        pendingMarmotSetupTasks[pendingId]?.cancel()
        pendingMarmotSetupTasks[pendingId] = nil
        pendingMarmotSetupTokens[pendingId] = nil
        startingMarmotChats.remove(npub)
    }

    private func cancelPendingSecureChatSetups() {
        pendingMarmotSetupTasks.values.forEach { $0.cancel() }
        pendingMarmotSetupTasks = [:]
        pendingMarmotSetupTokens = [:]
        startingMarmotChats = []
    }

    private func startPendingMarmotGroupCreation(pendingId: String) {
        guard let pending = pendingMarmotGroups[pendingId],
              pendingMarmotGroupSetupTasks[pendingId] == nil
        else { return }
        let setupToken = UUID()
        pendingMarmotGroupSetupTokens[pendingId] = setupToken
        let setupTask = Task { @MainActor in
            defer { clearPendingMarmotGroupSetup(pendingId: pendingId, token: setupToken) }
            do {
                let groupId = try await marmot.startGroup(name: pending.name, members: pending.members)
                finishPendingMarmotGroup(pendingId: pendingId, groupId: groupId, setupToken: setupToken)
            } catch {
                failPendingMarmotGroup(pendingId: pendingId, setupToken: setupToken)
                showToast("Couldn't create group: \(error.localizedDescription)")
            }
        }
        pendingMarmotGroupSetupTasks[pendingId] = setupTask
    }

    private func startPendingMarmotGroupAccept(pendingId: String, invite: MarmotService.GroupInvite) {
        guard pendingMarmotGroupSetupTasks[pendingId] == nil else { return }
        let setupToken = UUID()
        pendingMarmotGroupSetupTokens[pendingId] = setupToken
        let setupTask = Task { @MainActor in
            defer { clearPendingMarmotGroupSetup(pendingId: pendingId, token: setupToken) }
            do {
                let groupId = try await marmot.acceptGroupInvite(invite)
                finishPendingMarmotGroup(pendingId: pendingId, groupId: groupId, setupToken: setupToken)
            } catch {
                failPendingMarmotGroup(pendingId: pendingId, setupToken: setupToken)
                showToast("Couldn't accept invite: \(error.localizedDescription)")
                await marmot.loadLocal()
            }
        }
        pendingMarmotGroupSetupTasks[pendingId] = setupTask
    }

    private func finishPendingMarmotGroup(pendingId: String, groupId: String, setupToken: UUID? = nil) {
        guard isActivePendingMarmotGroupSetup(pendingId: pendingId, token: setupToken) else { return }
        if setupToken == nil {
            cancelPendingMarmotGroupSetup(pendingId: pendingId)
        }
        pendingMarmotGroups[pendingId] = nil
        let realId = Self.marmotIDPrefix + groupId
        pendingMarmotRouteReplacement = SNMarmotRouteReplacement(pendingId: pendingId, realId: realId)
        if currentDMId == pendingId {
            path.removeLast()
            push(.dm(realId))
        }
        if let echoes = pendingMarmotMessagesByChat.removeValue(forKey: pendingId), !echoes.isEmpty {
            pendingMarmotMessagesByChat[realId, default: []].append(contentsOf: echoes)
        }
        flushPendingMarmotGroupSends(pendingId: pendingId, groupId: groupId, realId: realId)
        openedDM(realId, marmotGroupId: groupId)
    }

    private func failPendingMarmotGroup(pendingId: String, setupToken: UUID? = nil) {
        guard isActivePendingMarmotGroupSetup(pendingId: pendingId, token: setupToken) else { return }
        pendingMarmotGroups[pendingId] = nil
        pendingMarmotRouteFailure = SNMarmotRouteFailure(pendingId: pendingId)
        pendingMarmotGroupSends[pendingId] = nil
        pendingMarmotMessagesByChat[pendingId] = nil
        if currentDMId == pendingId {
            pop()
        }
    }

    private func isActivePendingMarmotGroupSetup(pendingId: String, token: UUID?) -> Bool {
        guard pendingMarmotGroups[pendingId] != nil else { return false }
        return token == nil || pendingMarmotGroupSetupTokens[pendingId] == token
    }

    private func clearPendingMarmotGroupSetup(pendingId: String, token: UUID) {
        guard pendingMarmotGroupSetupTokens[pendingId] == token else { return }
        pendingMarmotGroupSetupTokens[pendingId] = nil
        pendingMarmotGroupSetupTasks[pendingId] = nil
    }

    private func cancelPendingMarmotGroupSetup(pendingId: String) {
        pendingMarmotGroupSetupTasks[pendingId]?.cancel()
        pendingMarmotGroupSetupTasks[pendingId] = nil
        pendingMarmotGroupSetupTokens[pendingId] = nil
    }

    private func cancelPendingMarmotGroupSetups() {
        pendingMarmotGroupSetupTasks.values.forEach { $0.cancel() }
        pendingMarmotGroupSetupTasks = [:]
        pendingMarmotGroupSetupTokens = [:]
    }

    private func failedPendingMessage(_ message: SNMessage) -> SNMessage {
        SNMessage(
            id: message.id,
            mine: message.mine,
            action: message.action,
            author: message.author,
            text: message.text,
            time: message.time,
            sortDate: message.sortDate,
            via: message.via,
            state: "Couldn't send",
            pay: message.pay,
            call: message.call,
            media: message.media,
            stickerRef: message.stickerRef
        )
    }

    private func flushPendingDirectMarmot(npub: String, groupId: String, realId: String) {
        let queued = pendingDirectMarmotSends.removeValue(forKey: npub) ?? []
        guard !queued.isEmpty else { return }
        Task { @MainActor in
            for item in queued {
                let fallbackDate = Date()
                let echo = pendingMarmotMessagesByChat[realId]?.first { $0.id == item.messageId } ?? pendingMarmotEcho(
                    text: item.text,
                    id: item.messageId,
                    createdAt: fallbackDate
                )
                let isSticker = meshParseStickerContent(content: item.text) != nil
                if !isSticker {
                    pendingMarmotMessagesByChat[realId]?.removeAll { $0.id == item.messageId }
                }
                let ok = await sendPendingTransferredMarmotContent(item.text, to: groupId)
                if isSticker {
                    pendingMarmotMessagesByChat[realId]?.removeAll { $0.id == item.messageId }
                }
                if !ok {
                    pendingMarmotMessagesByChat[realId, default: []].append(
                        failedPendingMessage(echo)
                    )
                }
            }
        }
    }

    private func flushPendingMarmotGroupSends(pendingId: String, groupId: String, realId: String) {
        let queued = pendingMarmotGroupSends.removeValue(forKey: pendingId) ?? []
        guard !queued.isEmpty else { return }
        Task { @MainActor in
            for item in queued {
                let fallbackDate = Date()
                let echo = pendingMarmotMessagesByChat[realId]?.first { $0.id == item.messageId } ?? pendingMarmotEcho(
                    text: item.text,
                    id: item.messageId,
                    createdAt: fallbackDate
                )
                let isSticker = meshParseStickerContent(content: item.text) != nil
                if !isSticker {
                    pendingMarmotMessagesByChat[realId]?.removeAll { $0.id == item.messageId }
                }
                let ok = await sendPendingTransferredMarmotContent(item.text, to: groupId)
                if isSticker {
                    pendingMarmotMessagesByChat[realId]?.removeAll { $0.id == item.messageId }
                }
                if !ok {
                    pendingMarmotMessagesByChat[realId, default: []].append(
                        failedPendingMessage(echo)
                    )
                }
            }
        }
    }

    /// Mesh→WN flush: no second optimistic (mesh echo already visible).
    private func sendQueuedMarmotContent(_ text: String, to groupId: String) async -> Bool {
        if let ref = meshParseStickerContent(content: text) {
            return await marmot.sendQueuedSticker(
                groupId: groupId,
                packCoordinate: ref.packCoordinate,
                shortcode: ref.shortcode,
                plaintextSha256: ref.plaintextSha256
            )
        }
        return await marmot.sendQueuedText(groupId: groupId, text: text)
    }

    /// Pending-chat / pending-group flush: paint a group optimistic because the
    /// platform echo was already moved off the pending id.
    private func sendPendingTransferredMarmotContent(_ text: String, to groupId: String) async -> Bool {
        if let ref = meshParseStickerContent(content: text) {
            return await marmot.sendQueuedSticker(
                groupId: groupId,
                packCoordinate: ref.packCoordinate,
                shortcode: ref.shortcode,
                plaintextSha256: ref.plaintextSha256
            )
        }
        return await marmot.send([text], to: groupId)
    }

    /// R-011: clear the mesh echo only after a folded durable WN row exists.
    private func meshMarmotCanonicalExists(groupId: String, text: String) -> Bool {
        if let ref = meshParseStickerContent(content: text) {
            return marmot.hasCanonicalOutgoingStickerMatch(
                groupId: groupId,
                packCoordinate: ref.packCoordinate,
                shortcode: ref.shortcode,
                plaintextSha256: ref.plaintextSha256
            )
        }
        return marmot.hasCanonicalOutgoingMatch(groupId: groupId, text: text)
    }

    private func clearMeshMarmotSendEcho(_ send: SNPendingMarmotSend) {
        guard !send.chatId.isEmpty, !send.messageId.isEmpty else { return }
        pendingMarmotMessagesByChat[send.chatId]?.removeAll { $0.id == send.messageId }
        if pendingMarmotMessagesByChat[send.chatId]?.isEmpty == true {
            pendingMarmotMessagesByChat[send.chatId] = nil
        }
    }

    private func failMeshMarmotSendEcho(_ send: SNPendingMarmotSend) {
        guard !send.chatId.isEmpty, !send.messageId.isEmpty else { return }
        guard let idx = pendingMarmotMessagesByChat[send.chatId]?.firstIndex(where: { $0.id == send.messageId }),
              let original = pendingMarmotMessagesByChat[send.chatId]?[idx]
        else { return }
        pendingMarmotMessagesByChat[send.chatId]?[idx] = failedPendingMessage(original)
    }

    /// Keep the mesh Sending bubble until a folded canonical row is visible
    /// (Compose `shouldClearMeshMarmotSendEcho(hasCanonicalRow)`).
    private func clearMeshEchoWhenCanonical(send: SNPendingMarmotSend, groupId: String) async {
        for _ in 0..<10 {
            if meshMarmotCanonicalExists(groupId: groupId, text: send.text) {
                clearMeshMarmotSendEcho(send)
                objectWillChange.send()
                return
            }
            await marmot.loadLocalPage(groupId: groupId, mode: .preserveHistoricalWindow)
            if meshMarmotCanonicalExists(groupId: groupId, text: send.text) {
                clearMeshMarmotSendEcho(send)
                objectWillChange.send()
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // Prefer a sticky Sending echo over a blank gap if hydrate races.
        objectWillChange.send()
    }

    private func flushPendingMarmotSends() {
        guard !pendingMarmotSends.isEmpty else { return }
        for (npub, sends) in pendingMarmotSends {
            guard let group = marmotGroup(forNpub: npub) else { continue }
            pendingMarmotSends[npub] = nil
            Task { @MainActor in
                for send in sends {
                    // Await real send outcome without creating a second optimistic.
                    // Clear the mesh echo only once a folded canonical row exists.
                    let ok = await sendQueuedMarmotContent(send.text, to: group.id)
                    guard !send.chatId.isEmpty, !send.messageId.isEmpty else { continue }
                    if ok {
                        await clearMeshEchoWhenCanonical(send: send, groupId: group.id)
                    } else {
                        failMeshMarmotSendEcho(send)
                        objectWillChange.send()
                    }
                }
            }
        }
    }

    // MARK: Media (White Noise / Marmot MIP-04)

    /// In-memory decrypted-media cache (raw bytes), keyed by the ciphertext's
    /// Blossom URL. Cleared by `wipe()` and `eraseAllChats()`.
    private var mediaImageCache: [String: Data] = [:]
    @Published private var mediaTransferStates: [String: SNMediaTransferState] = [:]
    private var mediaDownloadTasks: [String: Task<Void, Never>] = [:]
    private var mediaDownloadListeners: [String: SNMediaDownloadListener] = [:]
    private var mediaDownloadGenerations: [String: UUID] = [:]

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
    private var retryingFailedOptimisticMessageIDs: Set<String> = []
    private static let pendingMediaURLPrefix = "pending-media-"

    /// Map a Marmot message's attachments into UI items carrying the group id.
    static func mediaItems(_ m: MarmotService.MarmotMessage, groupId: String) -> [SNMediaItem] {
        m.media.map {
            SNMediaItem(
                url: $0.url,
                mime: $0.mimeType,
                filename: $0.filename,
                groupId: groupId,
                width: $0.width,
                height: $0.height
            )
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

    private func retryFailedMedia(_ message: SNMessage, groupId: String) {
        let payloads: [(item: SNMediaItem, data: Data)] = message.media.compactMap { item in
            mediaImageCache[item.url].map { (item, $0) }
        }
        guard payloads.count == message.media.count, !payloads.isEmpty else {
            showToast("This media is no longer available to retry.")
            return
        }
        guard retryingFailedOptimisticMessageIDs.insert(message.id).inserted else { return }

        for payload in payloads {
            rememberPendingUploadMedia(
                groupId: groupId,
                filename: payload.item.filename,
                mime: payload.item.mime,
                caption: message.text,
                localURL: payload.item.url,
                data: payload.data
            )
        }

        if payloads.count == 1, let payload = payloads.first {
            marmot.sendMedia(
                groupId: groupId,
                data: payload.data,
                filename: payload.item.filename,
                mime: payload.item.mime,
                caption: message.text,
                localPreviewURL: payload.item.url,
                onEchoVisible: { [weak self] in
                    self?.marmot.removeFailedOptimisticMessage(
                        groupId: groupId,
                        messageId: message.id
                    )
                },
                onComplete: { [weak self] in
                    self?.retryingFailedOptimisticMessageIDs.remove(message.id)
                    self?.markPendingUploadMediaCompleted(
                        groupId: groupId,
                        filename: payload.item.filename,
                        mime: payload.item.mime,
                        caption: message.text,
                        localURL: payload.item.url
                    )
                },
                onFailure: { [weak self] in
                    self?.retryingFailedOptimisticMessageIDs.remove(message.id)
                    self?.forgetPendingUploadMedia(
                        groupId: groupId,
                        filename: payload.item.filename,
                        mime: payload.item.mime,
                        caption: message.text,
                        localURL: payload.item.url
                    )
                }
            )
            return
        }

        let items = payloads.map {
            MarmotService.MediaAlbumItem(
                data: $0.data,
                filename: $0.item.filename,
                mime: $0.item.mime
            )
        }
        marmot.sendMediaAlbum(
            groupId: groupId,
            items: items,
            caption: message.text,
            localPreviewURLs: payloads.map { $0.item.url },
            onEchoVisible: { [weak self] in
                self?.marmot.removeFailedOptimisticMessage(
                    groupId: groupId,
                    messageId: message.id
                )
            },
            onComplete: { [weak self] in
                self?.retryingFailedOptimisticMessageIDs.remove(message.id)
                for payload in payloads {
                    self?.markPendingUploadMediaCompleted(
                        groupId: groupId,
                        filename: payload.item.filename,
                        mime: payload.item.mime,
                        caption: message.text,
                        localURL: payload.item.url
                    )
                }
            },
            onFailure: { [weak self] in
                self?.retryingFailedOptimisticMessageIDs.remove(message.id)
                for payload in payloads {
                    self?.forgetPendingUploadMedia(
                        groupId: groupId,
                        filename: payload.item.filename,
                        mime: payload.item.mime,
                        caption: message.text,
                        localURL: payload.item.url
                    )
                }
            }
        )
    }

    private func retryFailedSticker(_ message: SNMessage, groupId: String) {
        guard let ref = message.stickerRef else {
            showToast("This sticker is no longer available to retry.")
            return
        }
        guard retryingFailedOptimisticMessageIDs.insert(message.id).inserted else { return }
        marmot.sendSticker(
            groupId: groupId,
            packCoordinate: ref.packCoordinate,
            shortcode: ref.shortcode,
            plaintextSha256: ref.plaintextSha256,
            onEchoVisible: { [weak self] in
                self?.marmot.removeFailedOptimisticMessage(
                    groupId: groupId,
                    messageId: message.id
                )
            },
            onComplete: { [weak self] in
                self?.retryingFailedOptimisticMessageIDs.remove(message.id)
            },
            onFailure: { [weak self] in
                self?.retryingFailedOptimisticMessageIDs.remove(message.id)
            }
        )
    }

    /// True if `id` is a chat that can carry media: an existing Marmot group, a
    /// Sonar peer whose White Noise group exists, OR a bitchat/mesh peer
    /// reachable over Bluetooth right now (sent as a bitchat file transfer).
    func canSendMedia(_ id: String) -> Bool {
        if marmotGroupId(id) != nil { return true }
        if let profile = resolvedSonarProfile(id), marmotGroup(forNpub: profile.npub) != nil { return true }
        return meshReachable(id)
    }

    /// True when media can be sent now or a White Noise route can be created
    /// for this DM. Unlike `canSendMedia`, this includes a newly discovered
    /// Sonar peer whose direct group has not been created yet.
    func canPrepareMedia(_ id: String) -> Bool {
        snAttachmentRoutePlan(
            hasExistingRoute: canSendMedia(id),
            pendingNpub: pendingMarmotNpub(for: id),
            resolvedNpub: resolvedSonarProfile(id)?.npub
        ) != .unavailable
    }

    /// Ensure a route exists before importing desktop-selected media. Text
    /// sends already create a White Noise DM on first use; file sends must do
    /// the same instead of silently rejecting the drop.
    func prepareMediaRoute(_ id: String) async -> SNAttachmentRoutePreparationResult {
        let plan = snAttachmentRoutePlan(
            hasExistingRoute: canSendMedia(id),
            pendingNpub: pendingMarmotNpub(for: id),
            resolvedNpub: resolvedSonarProfile(id)?.npub
        )
        switch plan {
        case .ready:
            return .ready
        case .unavailable:
            return .unavailable
        case .startSecureChat(let npub):
            // A newly opened npub chat starts its setup from `openedDM`. Await
            // that work rather than racing it and creating a duplicate group.
            if let setupTask = pendingMarmotSetupTasks[id] {
                await setupTask.value
                return canSendMedia(id) ? .ready : .failed
            }

            marmot.connectIfNeeded()
            guard let groupId = await marmot.startChatReturningId(with: npub) else {
                return .failed
            }
            rememberMarmotGroup(groupId, forConversationId: id)
            if resolvedSonarProfile(id) != nil {
                rememberMarmotGroup(groupId, forConversationId: canonicalPeerKey(PeerID(str: id)))
            }
            return .ready
        }
    }

    /// True for a non-geo private peer reachable over the BLE mesh right now.
    /// Sonar peers require a direct connection; retained mesh reachability is
    /// still useful for plain bitchat relay but should not hold Sonar on BLE.
    private func meshReachable(_ id: String) -> Bool {
        guard !id.hasPrefix(Self.marmotIDPrefix) else { return false }
        guard !PeerID(str: id).isGeoDM else { return false }
        return liveMeshRoutePeerId(for: id) != nil
    }

    /// Send an image. Over the BLE mesh (bitchat file transfer, type 0x22) when
    /// the peer is reachable over Bluetooth — interops with stock bitchat;
    /// otherwise encrypt + Blossom-upload + publish over White Noise (Marmot).
    func sendImage(_ id: String, data: Data, filename: String, mime: String) {
        if let route = liveMeshRoutePeerId(for: id) {
            sendImageOverMesh(PeerID(str: route), data: data)
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
        guard let gid = groupId else {
            showToast("Couldn't send the image — the secure chat isn't ready yet.")
            return
        }
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

    /// Send N images to one peer as ONE album message (single kind-445 with N
    /// imeta tags) that renders as the swipeable card deck. BLE mesh has no
    /// album packet, so a mesh-reachable peer gets N individual image sends.
    func sendImageAlbum(_ id: String, items: [(data: Data, filename: String, mime: String)]) {
        guard items.count > 1 else {
            if let only = items.first {
                sendImage(id, data: only.data, filename: only.filename, mime: only.mime)
            }
            return
        }
        if let route = liveMeshRoutePeerId(for: id) {
            // Per-item over mesh (no album packet), preserving each MIME:
            // sendImageOverMesh forces JPEG, so route GIFs through the file
            // path to keep the animation instead of flattening it.
            var failed = 0
            let routePeer = PeerID(str: route)
            for item in items {
                if item.mime == "image/gif" || item.mime.hasPrefix("video/") {
                    if !sendAttachment(id, data: item.data, filename: item.filename, mime: item.mime) {
                        failed += 1
                    }
                } else {
                    sendImageOverMesh(routePeer, data: item.data)
                }
            }
            if failed > 0 {
                showToast(failed == 1
                    ? "1 attachment couldn't be sent — start the secure chat first."
                    : "\(failed) attachments couldn't be sent — start the secure chat first.")
            }
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
        // One pending-echo entry per attachment; the canonical album message
        // reconciles each media item against its filename-keyed cache entry.
        var albumItems: [MarmotService.MediaAlbumItem] = []
        var pendingURLs: [String] = []
        for item in items {
            let pendingURL = Self.pendingMediaURL()
            pendingURLs.append(pendingURL)
            rememberPendingUploadMedia(
                groupId: gid,
                filename: item.filename,
                mime: item.mime,
                caption: "",
                localURL: pendingURL,
                data: item.data
            )
            albumItems.append(
                MarmotService.MediaAlbumItem(data: item.data, filename: item.filename, mime: item.mime)
            )
        }
        let pairs = zip(items.map { ($0.filename, $0.mime) }, pendingURLs).map {
            (filename: $0.0, mime: $0.1, url: $1)
        }
        marmot.sendMediaAlbum(
            groupId: gid,
            items: albumItems,
            localPreviewURLs: pendingURLs,
            onComplete: { [weak self] in
                for pair in pairs {
                    self?.markPendingUploadMediaCompleted(
                        groupId: gid,
                        filename: pair.filename,
                        mime: pair.mime,
                        caption: "",
                        localURL: pair.url
                    )
                }
            },
            onFailure: { [weak self] in
                for pair in pairs {
                    self?.forgetPendingUploadMedia(
                        groupId: gid,
                        filename: pair.filename,
                        mime: pair.mime,
                        caption: "",
                        localURL: pair.url
                    )
                }
            }
        )
    }

    /// Send a desktop-selected attachment. White Noise can preserve the source
    /// MIME (including video); BLE mesh uses the existing safe file-packet
    /// allowlist and falls back to a generic file for unsupported types.
    @discardableResult
    func sendAttachment(_ id: String, data: Data, filename: String, mime: String) -> Bool {
        let safeName = snEncryptedAttachmentFilename(filename)
        let safeMime = snEncryptedAttachmentMime(mime)
        if let route = liveMeshRoutePeerId(for: id) {
            if FileTransferLimits.isValidPayload(data.count) {
                chatViewModel.selectedPrivateChatPeer = PeerID(str: route)
                let meshMime = MimeType(safeMime)?.mimeString ?? "application/octet-stream"
                chatViewModel.sendFile(data: data, filename: safeName, mime: meshMime)
                return true
            }
            // Payload exceeds the mesh file-packet limit (videos usually do) —
            // fall through to the White Noise route below instead of silently
            // refusing while a perfectly good encrypted route exists.
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
        if let route = liveMeshRoutePeerId(for: id) {
            chatViewModel.selectedPrivateChatPeer = PeerID(str: route)
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
        guard let gid = groupId else {
            showToast("Couldn't send the voice note — the secure chat isn't ready yet.")
            return
        }
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

    /// Internet fallback for a mesh media send that found no live BLE route
    /// (e.g. the peer went out of range between route selection and send).
    /// Encrypts + Blossom-uploads + publishes over White Noise (Marmot), the
    /// same path as non-mesh `sendImage`/`sendVoiceNote`/`sendAttachment`.
    /// Returns false when no Marmot group exists for the peer — the caller
    /// then marks the message failed instead.
    private func sendMeshMediaOverInternet(_ packet: BitchatFilePacket, to peerID: PeerID) -> Bool {
        let filename = packet.fileName ?? "file"
        let mime = packet.mimeType ?? "application/octet-stream"
        let key = canonicalPeerKey(peerID)
        var groupId = marmotGroupId(key)
        if groupId == nil, let profile = resolvedSonarProfile(key) {
            groupId = marmotGroup(forNpub: profile.npub)?.id
        }
        if groupId == nil {
            for alias in meshPeerAliases(for: key) {
                if let gid = marmotGroupId(alias) { groupId = gid; break }
                if let profile = resolvedSonarProfile(alias),
                   let group = marmotGroup(forNpub: profile.npub) {
                    groupId = group.id
                    break
                }
            }
        }
        guard let gid = groupId else { return false }
        let pendingURL = Self.pendingMediaURL()
        rememberPendingUploadMedia(groupId: gid, filename: filename, mime: mime, caption: "", localURL: pendingURL, data: packet.content)
        marmot.sendMedia(
            groupId: gid,
            data: packet.content,
            filename: filename,
            mime: mime,
            localPreviewURL: pendingURL,
            onComplete: { [weak self] in
                self?.markPendingUploadMediaCompleted(groupId: gid, filename: filename, mime: mime, caption: "", localURL: pendingURL)
            },
            onFailure: { [weak self] in
                self?.forgetPendingUploadMedia(groupId: gid, filename: filename, mime: mime, caption: "", localURL: pendingURL)
            }
        )
        return true
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

    /// Header-only image dimensions for a local file (no pixel decode), cached
    /// by path. Signal derives attachment dimensions at ingestion and sizes
    /// media cells ONLY from stored values (Signal-Android attachments table
    /// width/height → ThumbnailView; Signal-iOS TSAttachmentStream
    /// imageSizePixels → CVMediaAlbumView). Marmot media gets this from MIP-04
    /// metadata; BLE file transfers carry none, so derive it here where the
    /// bytes live — otherwise the bubble reserves the fixed skeleton box and
    /// grows on decode, shifting the transcript.
    private static var meshImageBoundsCache: [String: (UInt32, UInt32)] = [:]

    private func meshImageBounds(atPath path: String) -> (UInt32, UInt32)? {
        if let cached = Self.meshImageBoundsCache[path] { return cached }
        let url = URL(fileURLWithPath: path) as CFURL
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0
        else { return nil }
        let bounds = (UInt32(w), UInt32(h))
        Self.meshImageBoundsCache[path] = bounds
        return bounds
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
                let bounds = k.mime.hasPrefix("image/") ? meshImageBounds(atPath: path) : nil
                return SNMediaItem(
                    url: "",
                    mime: k.mime,
                    filename: safe,
                    groupId: "",
                    localPath: path,
                    width: bounds?.0,
                    height: bounds?.1
                )
            }
        }
        return nil
    }

    private static let reactiveMediaCacheLimit = 1024 * 1024

    private static func mediaKey(_ item: SNMediaItem) -> String {
        item.localPath ?? item.url
    }

    private func existingMediaURL(_ item: SNMediaItem) -> URL? {
        if let path = item.localPath {
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard let disk = Self.mediaCacheURL(for: item.url, createDirectory: false),
              FileManager.default.fileExists(atPath: disk.path)
        else { return nil }
        return disk
    }

    /// Wire the process-wide voice session: fold-aware logical ids + bounded
    /// local queue. Rows only observe; this store owns lifecycle arbitration.
    private func configureVoicePlaybackSession() {
        SNVoicePlaybackIdentity.logicalIdForSource = { [weak self] sourceId in
            guard let self else { return nil }
            if let folded = self.foldedConversationId(forMarmotGroupId: sourceId) {
                return folded
            }
            return sourceId
        }
        VoiceNotePlaybackController.shared.configure(
            queue: SonarVoicePlaybackQueue(store: self),
            onPlaybackStarted: { _ in
                // Listened state is persisted by the controller; receipts reuse
                // existing conversation-read semantics elsewhere.
            }
        )
    }

    func voicePlaybackItem(
        for message: SNMessage,
        media: SNMediaItem,
        mediaIndex: Int,
        logicalConversationId: String
    ) -> VoicePlaybackItem? {
        guard let localURL = existingMediaURL(media) ?? mediaTransferState(media).localURL else {
            return nil
        }
        return VoicePlaybackItem(
            logicalConversationId: logicalConversationId,
            sourceConversationId: media.groupId,
            messageId: message.id,
            attachmentId: snVoiceAttachmentId(
                messageId: message.id,
                mediaIndex: mediaIndex,
                filename: media.filename,
                url: media.url
            ),
            localFile: localURL,
            durationHint: media.durationMs.map { TimeInterval($0) / 1000.0 }
        )
    }

    func mediaTransferState(_ item: SNMediaItem) -> SNMediaTransferState {
        let key = Self.mediaKey(item)
        if let state = mediaTransferStates[key] { return state }
        if let url = existingMediaURL(item) { return .available(url) }
        return .notDownloaded
    }

    /// Hydrate the local state without network work. Visual/audio attachments
    /// may opt into automatic download; generic files remain tap-to-download.
    ///
    /// When the file is already on disk, skip `@Published` writes —
    /// `mediaTransferState` already synthesises `.available` from the
    /// filesystem. Republishing on every bubble appear rebuilds the whole
    /// transcript during chat open (Signal avoids this churn).
    func prepareMedia(_ item: SNMediaItem, autoDownload: Bool) {
        let key = Self.mediaKey(item)
        if let url = existingMediaURL(item) {
            switch mediaTransferStates[key]?.phase {
            case .downloading, .failed:
                mediaTransferStates[key] = .available(url)
            default:
                break // nil / .available: no @Published churn
            }
            return
        }
        if autoDownload || mediaImageCache[key] != nil {
            requestMediaDownload(item)
        }
    }

    func requestMediaDownload(_ item: SNMediaItem) {
        let key = Self.mediaKey(item)
        if let url = existingMediaURL(item) {
            mediaTransferStates[key] = .available(url)
            return
        }
        guard mediaDownloadTasks[key] == nil,
              let finalURL = Self.mediaCacheURL(for: key)
        else { return }

        let generation = UUID()
        let partialURL = finalURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(finalURL.lastPathComponent).\(generation.uuidString).part")
        let cachedData = mediaImageCache[key]
        mediaDownloadGenerations[key] = generation
        mediaTransferStates[key] = .downloading(nil)

        let listener = SNMediaDownloadListener { [weak self] received, total in
            Task { @MainActor [weak self] in
                guard let self,
                      self.mediaDownloadGenerations[key] == generation
                else { return }
                let progress = total.flatMap { total -> Double? in
                    guard total > 0 else { return nil }
                    return min(1, Double(received) / Double(total))
                }
                self.mediaTransferStates[key] = .downloading(progress)
            }
        }
        mediaDownloadListeners[key] = listener

        mediaDownloadTasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                if let cachedData {
                    try await Task.detached(priority: .utility) {
                        #if os(iOS)
                        try cachedData.write(to: partialURL, options: [.atomic, .completeFileProtection])
                        #else
                        try cachedData.write(to: partialURL, options: .atomic)
                        #endif
                    }.value
                } else {
                    guard !item.groupId.isEmpty, !item.url.isEmpty else {
                        throw MarmotService.ServiceError.invalidInput("attachment has no download route")
                    }
                    _ = try await marmot.fetchMediaToFile(
                        groupId: item.groupId,
                        url: item.url,
                        destination: partialURL,
                        listener: listener
                    )
                }
                guard !listener.isCancelled(), !Task.isCancelled else {
                    throw CancellationError()
                }
                let localURL = try await Task.detached(priority: .utility) {
                    try Self.promoteMediaDownload(from: partialURL, to: finalURL)
                }.value
                guard mediaDownloadGenerations[key] == generation else { return }
                mediaTransferStates[key] = .available(localURL)
                if let cachedData, cachedData.count > Self.reactiveMediaCacheLimit {
                    mediaImageCache.removeValue(forKey: key)
                }
            } catch {
                await Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(at: partialURL)
                }.value
                guard mediaDownloadGenerations[key] == generation else { return }
                mediaTransferStates[key] = listener.isCancelled() || error is CancellationError
                    ? .notDownloaded
                    : .failed
            }
            if mediaDownloadGenerations[key] == generation {
                mediaDownloadTasks[key] = nil
                mediaDownloadListeners[key] = nil
                mediaDownloadGenerations[key] = nil
            }
        }
    }

    func cancelMediaDownload(_ item: SNMediaItem) {
        let key = Self.mediaKey(item)
        mediaDownloadListeners[key]?.cancel()
        mediaDownloadTasks[key]?.cancel()
        mediaDownloadTasks[key] = nil
        mediaDownloadListeners[key] = nil
        mediaDownloadGenerations[key] = nil
        mediaTransferStates[key] = .notDownloaded
    }

    private func cancelAllMediaDownloads() {
        mediaDownloadListeners.values.forEach { $0.cancel() }
        mediaDownloadTasks.values.forEach { $0.cancel() }
        mediaDownloadTasks = [:]
        mediaDownloadListeners = [:]
        mediaDownloadGenerations = [:]
        mediaTransferStates = [:]
    }

    nonisolated private static func promoteMediaDownload(from partialURL: URL, to finalURL: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try? FileManager.default.removeItem(at: partialURL)
            return finalURL
        }
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: finalURL.path
        )
        #endif
        return finalURL
    }

    /// Read already-local attachment bytes for image decode or audio playback.
    /// This function deliberately never starts network work.
    func mediaData(_ item: SNMediaItem) async -> Data? {
        let logId = Self.mediaLogId(for: item)
        let key = Self.mediaKey(item)
        if let cached = mediaImageCache[key] {
            SecureLogger.info("SonarMedia[\(logId)]: memory cache hit bytes=\(cached.count) name=\(item.filename) mime=\(item.mime)", category: .session)
            return cached
        }
        if let localURL = existingMediaURL(item) {
            do {
                let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
                SecureLogger.info("SonarMedia[\(logId)]: local file hit bytes=\(data.count) name=\(item.filename) mime=\(item.mime)", category: .session)
                if data.count <= Self.reactiveMediaCacheLimit {
                    mediaImageCache[key] = data
                }
                return data
            } catch {
                SecureLogger.warning("SonarMedia[\(logId)]: local file read failed name=\(item.filename) mime=\(item.mime) error=\(error.localizedDescription)", category: .session)
                return nil
            }
        }
        SecureLogger.info("SonarMedia[\(logId)]: local media miss name=\(item.filename) mime=\(item.mime)", category: .session)
        return nil
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

    func cachedStickerPacks() -> [StickerPackInfo] {
        marmot.cachedStickerPacksSnapshot()
    }

    func stickerImageData(url: String, expectedSha256: String) async -> Data? {
        await marmot.fetchStickerImage(url: url, expectedSha256: expectedSha256)
    }

    func stickerImageData(
        for ref: MarmotService.MarmotStickerRef,
        userInitiated: Bool = false
    ) async -> Data? {
        await marmot.stickerData(for: ref, userInitiated: userInitiated)
    }

    func fetchInstalledPacks() async -> [String]? {
        await marmot.fetchInstalledPacks()
    }

    func isStickerPackInstalled(_ coordinate: String) -> Bool {
        marmot.isStickerPackInstalled(coordinate)
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
    private static func mediaCacheURL(for url: String, createDirectory: Bool = true) -> URL? {
        guard !url.isEmpty, let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectory
        )
        else { return nil }
        let dir = base.appendingPathComponent("media-cache", isDirectory: true)
        if createDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
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

    /// Unread count per DM route captured when navigation pushed the chat.
    /// Consumed by the transcript to anchor at the first unread row with a
    /// divider (Signal-style); cleared when the route pops.
    @Published var unreadCountAtOpenByDM: [String: UInt64] = [:]

    /// Search / deep-link jump for the current DM open (#372). Not `@Published`
    /// — set once at push; host reads it on first apply.
    private(set) var jumpMessageIdAtOpenByDM: [String: String] = [:]
    /// Stashed by `openDM(jumpMessageId:)` and consumed in `captureUnreadAtOpen`.
    private var pendingJumpMessageIdByDM: [String: String] = [:]

    /// Capture the DM's unread count at navigation time — BEFORE `openedDM`
    /// zeroes the core counter — so the transcript can anchor at the first
    /// unread row with a divider (Signal-style) instead of force-pinning the
    /// tail. The published `unreadByGroup` map lags a cold launch, so a map
    /// miss falls back to reading the core conversation index directly; that
    /// read races openedDM's read-marking, but read-marking only runs after
    /// the local hydrate completes, so the summaries read lands first.
    ///
    /// Always publishes a settled value (including `0`). While the key is
    /// absent, `SNMsgList` must not treat the open as fully-read (`?? 0` was
    /// the alpha.11 unread→tail flash race).
    func captureUnreadAtOpen(_ id: String) {
        unreadCountAtOpenByDM[id] = nil
        if let jump = pendingJumpMessageIdByDM.removeValue(forKey: id) {
            jumpMessageIdAtOpenByDM[id] = jump
        } else {
            jumpMessageIdAtOpenByDM[id] = nil
        }
        let groupId = marmotGroupId(id)
            ?? resolvedSonarProfile(id).flatMap { marmotGroup(forNpub: $0.npub)?.id }
        guard let groupId else {
            unreadCountAtOpenByDM[id] = 0
            return
        }
        let groups = directMarmotGroups(matchingGroupId: groupId)
        let ids = groups.isEmpty ? [groupId] : groups.map(\.id)
        let hasCachedEntry = ids.contains { marmot.unreadByGroup[$0] != nil }
        let cached = ids.reduce(UInt64(0)) { $0 + (marmot.unreadByGroup[$1] ?? 0) }
        if hasCachedEntry || cached > 0 {
            unreadCountAtOpenByDM[id] = cached
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let unread = await self.marmot.unreadCount(forGroups: ids)
            self.unreadCountAtOpenByDM[id] = unread
        }
    }

    /// Newest known message date across the DM's folded groups, from the
    /// core conversation index. The transcript must not freeze its unread
    /// divider before the visible rows have caught up to this — hydration can
    /// publish one leg before the folded White Noise groups merge in, and the
    /// rows still missing are exactly the unread ones.
    func expectedNewestMessageDate(_ id: String) -> Date? {
        let groupId = marmotGroupId(id)
            ?? resolvedSonarProfile(id).flatMap { marmotGroup(forNpub: $0.npub)?.id }
        guard let groupId else { return nil }
        let groups = directMarmotGroups(matchingGroupId: groupId)
        let ids = groups.isEmpty ? [groupId] : groups.map(\.id)
        return ids.compactMap { marmot.conversationSummariesByGroup[$0]?.latestAt }.max()
    }

    /// Generations cancel a superseded first-open Task when the user taps another chat.
    private var dmOpenGenerations: [String: UUID] = [:]

    /// True when a local newest page (or retained ConversationViewState) can
    /// paint without awaiting disk — Compose `retainedTranscriptByChat` reopen.
    private func dmHasLocalTranscriptPaint(_ id: String, marmotGroupId knownMarmotGroupId: String?) -> Bool {
        if let retained = conversationViewStates[id], !retained.messages.isEmpty { return true }
        if cachedMeshMessageCount(id) > 0 { return true }
        let groupId = knownMarmotGroupId
            ?? marmotGroupId(id)
            ?? resolvedSonarProfile(id).flatMap { marmotGroup(forNpub: $0.npub)?.id }
        guard let groupId else { return false }
        let groups = directMarmotGroups(matchingGroupId: groupId)
        let ids = groups.isEmpty ? [groupId] : groups.map(\.id)
        return ids.contains { !(marmot.messagesByGroup[$0] ?? []).isEmpty }
    }

    /// Navigate into a DM after the local newest page is ready (Compose
    /// `openChat` parity). First open awaits `loadLocalWhenConnected` before
    /// present; reopen uses retained leave paint and hydrates in the background.
    /// Pass `present` on Mac (selection) instead of the default `push(.dm)`.
    func openDM(
        _ id: String,
        marmotGroupId knownMarmotGroupId: String? = nil,
        jumpMessageId: String? = nil,
        present: (() -> Void)? = nil
    ) {
        if let jumpMessageId {
            pendingJumpMessageIdByDM[id] = jumpMessageId
        } else {
            pendingJumpMessageIdByDM[id] = nil
        }
        let presentDM = present ?? { self.push(.dm(id)) }
        if pendingMarmotNpub(for: id) != nil || isPendingMarmotGroup(id) {
            openedDM(id, marmotGroupId: knownMarmotGroupId)
            presentDM()
            return
        }
        if dmHasLocalTranscriptPaint(id, marmotGroupId: knownMarmotGroupId) {
            openedDM(id, marmotGroupId: knownMarmotGroupId)
            presentDM()
            return
        }
        let generation = UUID()
        dmOpenGenerations[id] = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.openedDM(id, marmotGroupId: knownMarmotGroupId)
            let warmupKey = knownMarmotGroupId
                ?? self.marmotGroupId(id)
                ?? id
            if let task = self.openingDMTasks[warmupKey] {
                await task.value
            }
            guard self.dmOpenGenerations[id] == generation else { return }
            self.dmOpenGenerations[id] = nil
            self.conversationViewState(id).rebuildNow()
            presentDM()
        }
    }

    func openedDM(_ id: String, marmotGroupId knownMarmotGroupId: String? = nil) {
        if let knownMarmotGroupId {
            rememberMarmotGroup(knownMarmotGroupId, forConversationId: id)
            markMarmotGroupsRead(matchingGroupId: knownMarmotGroupId)
        }
        // Bind badge suppression as soon as the DM is considered open — even
        // when navigation used a custom `present` path that skipped `push`.
        syncViewingUnreadGroups()
        if let pendingNpub = pendingMarmotNpub(for: id) {
            marmot.connectIfNeeded()
            marmot.ensureProfile(pendingNpub)
            startSecureChatInBackground(npub: pendingNpub, pendingId: id)
            return
        }
        if isPendingMarmotGroup(id) { return }
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
                let groups = self.directMarmotGroups(matchingGroupId: hydratedGroupId)
                let sourceGroups = groups.isEmpty
                    ? [MarmotService.MarmotGroup(id: hydratedGroupId, name: "", memberNpubs: [])]
                    : groups
                for group in sourceGroups {
                    // `loadLocalWhenConnected(groupId:)` already painted the
                    // known source. Only hydrate additional folded groups here.
                    if groupId == nil || group.id != groupId {
                        await self.marmot.loadLocalPage(groupId: group.id, mode: .newestPage)
                    }
                    self.marmot.markConversationRead(groupId: group.id)
                }
                self.rememberMarmotGroup(hydratedGroupId, forConversationId: id)
                let fp = self.chatViewModel.getFingerprint(for: PeerID(str: id)) ?? id
                self.rememberMarmotGroup(hydratedGroupId, forConversationId: fp)
            }
            // P2: service cold-start catch-up for the conversation the user opened.
            if let hydratedGroupId {
                Task { await self.marmot.preferCatchupGroup(hydratedGroupId) }
            }
            let needsHistoryBackfill = hydratedGroupId.map {
                let groups = self.directMarmotGroups(matchingGroupId: $0)
                let sourceGroups = groups.isEmpty
                    ? [MarmotService.MarmotGroup(id: $0, name: "", memberNpubs: [])]
                    : groups
                return sourceGroups.contains { self.marmot.messagesByGroup[$0.id]?.isEmpty ?? true }
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
        // Keep ConversationViewState for Signal-style reopen paint (Compose
        // retainedTranscriptByChat). Wipe/erase clears the map. Unsubscribe
        // from store invalidation would still rebuild — acceptable for smoke;
        // the leave paint avoids first-frame empty → hydrate flash.
        // NB: do NOT stop the Marmot subscription loop here — it now runs for as
        // long as we're connected (started in performConnect) so welcomes +
        // messages keep arriving live in the background list, not only while a
        // chat is open. It is stopped only on wipe / erase.
        if let pendingNpub = pendingMarmotNpub(for: id) {
            if pendingMarmotChats[id] == nil {
                pendingMarmotMessagesByChat[id] = nil
                pendingDirectMarmotSends[pendingNpub] = nil
                cancelPendingSecureChatSetup(pendingId: id, npub: pendingNpub)
            }
            return
        }
        if isPendingMarmotGroup(id) { return }
        if marmotGroupId(id) == nil {
            if chatViewModel.selectedPrivateChatPeer == PeerID(str: id) {
                chatViewModel.endPrivateChat()
            }
        }
    }

    /// Start a Marmot (White Noise) secure chat by npub and navigate into it.
    @discardableResult
    func startSecureChat(npub: String) -> String? {
        let clean = SNMarmotProfileCache.canonicalKey(npub)
        guard let pendingId = pendingMarmotChatId(for: clean) else { return nil }
        if let group = marmotGroup(forNpub: clean) {
            let id = Self.marmotIDPrefix + group.id
            openDM(id, marmotGroupId: group.id)
            return id
        }
        pendingMarmotChats[pendingId] = pendingMarmotChats[pendingId] ?? SNPendingMarmotChat(npub: clean, createdAt: Date())
        marmot.connectIfNeeded()
        marmot.ensureProfile(clean)
        marmot.ensureSonarDescriptor(clean)
        push(.dm(pendingId))
        startSecureChatInBackground(npub: clean, pendingId: pendingId)
        return pendingId
    }

    @discardableResult
    func startGroup(name: String, members: [String]) -> String? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Group chat"
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        var seenMembers = Set<String>()
        let cleanMembers = members.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenMembers.insert($0).inserted }
        guard cleanMembers.count >= 2 else {
            showToast("Add at least two people")
            return nil
        }
        let pendingId = pendingMarmotGroupId()
        pendingMarmotGroups[pendingId] = SNPendingMarmotGroup(
            name: cleanName,
            members: cleanMembers,
            createdAt: Date()
        )
        marmot.connectIfNeeded()
        startPendingMarmotGroupCreation(pendingId: pendingId)
        return pendingId
    }

    @discardableResult
    func acceptGroupInvite(_ invite: MarmotService.GroupInvite) -> String {
        if marmot.groups.contains(where: { $0.id == invite.groupId }) {
            let id = Self.marmotIDPrefix + invite.groupId
            openedDM(id, marmotGroupId: invite.groupId)
            return id
        }
        let pendingId = pendingMarmotGroupId(seed: "invite:\(invite.id)")
        if pendingMarmotGroups[pendingId] == nil {
            pendingMarmotGroups[pendingId] = SNPendingMarmotGroup(
                name: invite.groupName.isEmpty ? "Group chat" : invite.groupName,
                members: [],
                createdAt: Date()
            )
        }
        marmot.pendingGroupInvites.removeAll { $0.id == invite.id }
        marmot.connectIfNeeded()
        startPendingMarmotGroupAccept(pendingId: pendingId, invite: invite)
        return pendingId
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
        // Store-level block enforcement (Android parity): UI gating alone
        // would let stale UI state or future callers pay a blocked contact.
        if isContactBlocked(id, npub: callNpub(id) ?? "") {
            return "Unblock this contact before paying."
        }
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
                    let via: SNVia = m.receivedViaInternet == true ? .internet : .mesh
                    if m.timestamp <= localNotificationStartedAt {
                        seenPrivateChatPaymentNotificationMessageIDs.insert(m.id)
                    } else if case .pay = line,
                              seenPrivateChatPaymentNotificationMessageIDs.insert(m.id).inserted {
                        sendSonarNotification(
                            kind: .payment,
                            idKey: m.id,
                            conversationId: peerID.id,
                            conversationTitle: peerDisplayName(peerID.id),
                            senderName: peerDisplayName(peerID.id),
                            preview: m.content,
                            messageId: m.id,
                            sound: via == .mesh ? .ble : .standard
                        )
                    }
                    handlePayLine(line, convId: peerID.id, via: via)
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

    // MARK: ⚡TRILL nudges (docs/SONAR-TRILL.md)

    /// True when the nudge action for this chat is currently allowed (outside
    /// the 8-second sender cooldown).
    func canSendTrill(_ id: String) -> Bool {
        SonarTrillPolicy.cooldownRemaining(until: trillCooldownUntilByChat[chatAlertKey(id)]) == nil
    }

    /// Sends an MSN-style nudge through the exact same path a text message
    /// takes (mesh or Marmot, both chat kinds), buzzes locally, and starts
    /// the per-chat sender cooldown.
    func sendTrill(_ id: String) {
        guard canSendTrill(id) else { return }
        trillCooldownUntilByChat[chatAlertKey(id)] =
            Date().addingTimeInterval(SonarTrillPolicy.cooldownSeconds)
        sendDm(id, SonarTrillMessage(id: SonarTrillMessage.makeID()).encoded())
        // The sender's own send triggers the local buzz (MSN behaviour).
        triggerTrillBuzz()
        objectWillChange.send()
    }

    /// Foreground receive effect: viewport shake (via `trillShakeTick`, the
    /// root view skips it under Reduce Motion), the trill bell (ambient —
    /// never overrides the silent switch), and two medium haptic pulses
    /// 100 ms apart (same style as the 🫂 hugs haptic in ChatViewModel).
    private func triggerTrillBuzz() {
        // Never disturb an active call's audio session or UI.
        guard activeCall == nil else { return }
        trillShakeTick &+= 1
        SonarTrillSoundPlayer.shared.play()
        #if os(iOS)
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.prepare()
        impactFeedback.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            impactFeedback.impactOccurred()
        }
        #endif
    }

    /// Scans both transcript stores for incoming ⚡TRILL lines and fires the
    /// receive effect (foreground buzz, or a trill-sound notification), with
    /// the per-chat receiver throttle and mute applied. Mirrors
    /// `processIncomingPayLines`; scanning is idempotent across replays.
    private func processIncomingTrillLines() {
        let my = chatViewModel.meshService.myPeerID
        for (peerID, msgs) in chatViewModel.privateChats {
            for m in msgs where m.senderPeerID != my {
                guard !scannedTrillMessageIDs.contains(m.id),
                      SonarTrillMessage.isTrillLine(m.content)
                else { continue }
                scannedTrillMessageIDs.insert(m.id)
                let name = peerDisplayName(peerID.id)
                handleIncomingTrill(
                    messageId: m.id,
                    convId: peerID.id,
                    arrivedBeforeLaunch: m.timestamp <= localNotificationStartedAt,
                    isBlocked: false, // mesh ingest already drops blocked peers
                    conversationTitle: name,
                    senderName: name,
                    groupName: nil,
                    content: m.content
                )
            }
        }
        // Push-wake owns Marmot banners for the current Transponder sync
        // (`SonarPushProcessor` classifies + throttles trills itself); catch
        // up after ownership ends, same as processIncomingMarmotNotifications.
        if marmot.pushWakeOwnsNotifications { return }
        for group in marmot.groups {
            let convId = marmotConvId(forGroup: group.id)
            let title = marmot.title(for: group)
            for m in marmot.messagesByGroup[group.id] ?? [] where !m.isMine {
                guard !scannedTrillMessageIDs.contains(m.id),
                      SonarTrillMessage.isTrillLine(m.content)
                else { continue }
                if marmot.pushWakeNotifiedMessageIDs.contains(m.id) {
                    scannedTrillMessageIDs.insert(m.id)
                    continue
                }
                scannedTrillMessageIDs.insert(m.id)
                let senderName = marmot.displayName(forNpub: m.senderNpub)
                    ?? snShortNpubLabel(m.senderNpub)
                handleIncomingTrill(
                    messageId: m.id,
                    convId: convId,
                    arrivedBeforeLaunch: m.createdAt <= localNotificationStartedAt,
                    isBlocked: isMarmotSenderBlocked(m.senderNpub),
                    conversationTitle: title,
                    senderName: senderName,
                    groupName: group.memberNpubs.count > 2 ? title : nil,
                    content: m.content
                )
            }
        }
    }

    private func handleIncomingTrill(
        messageId: String,
        convId: String,
        arrivedBeforeLaunch: Bool,
        isBlocked: Bool,
        conversationTitle: String?,
        senderName: String?,
        groupName: String?,
        content: String
    ) {
        let alertKey = chatAlertKey(convId)
        let decision = SonarTrillPolicy.alertDecision(
            arrivedBeforeLaunch: arrivedBeforeLaunch,
            isBlocked: isBlocked,
            isMuted: isChatMuted(convId),
            isForeground: isForeground,
            admitThrottle: { SonarTrillThrottle.shared.admit(chatKey: alertKey) }
        )
        switch decision {
        case .suppress:
            break
        case .buzz:
            triggerTrillBuzz()
        case .notify:
            sendSonarNotification(
                kind: .trill,
                idKey: messageId,
                conversationId: convId,
                conversationTitle: conversationTitle,
                senderName: senderName,
                groupName: groupName,
                preview: content,
                sound: .trill
            )
        }
    }

    // MARK: Per-chat mute (general — suppresses all alert kinds for a chat)

    /// One canonical alert key per conversation, shared by the sender
    /// cooldown, the receiver throttle, and the mute lookup.
    private func chatAlertKey(_ id: String) -> String {
        if id.hasPrefix(Self.marmotIDPrefix) { return id }
        return canonicalPeerKey(PeerID(str: id))
    }

    /// Every key an alerting path may carry for this chat (see
    /// docs/CHAT-TYPES.md — one conversation, five id shapes): the raw chat
    /// id, its canonical peer key, each folded Marmot group id (bare and
    /// `marmot:`-prefixed), and — for direct chats only — the peer's npub
    /// (the push drain path has no group id). Group-chat mutes never store an
    /// npub so muting a group cannot silence the member's direct chat.
    private func muteKeys(forChatId id: String) -> [String] {
        var keys: Set<String> = [id, chatAlertKey(id)]
        for alias in meshPeerAliases(for: id) {
            keys.insert(alias)
        }
        for group in localTranscriptGroups(for: id) where !group.id.isEmpty {
            keys.insert(group.id)
            keys.insert(Self.marmotIDPrefix + group.id)
            keys.insert(chatAlertKey(marmotConvId(forGroup: group.id)))
            if let full = marmot.groups.first(where: { $0.id == group.id }),
               marmot.isDirectGroup(full),
               let other = full.memberNpubs.first(where: { $0 != marmot.npub }) {
                keys.insert(other)
            }
        }
        if let npub = resolvedSonarProfile(id)?.npub ?? pendingMarmotNpub(for: id) {
            keys.insert(npub)
        }
        return keys.filter { !$0.isEmpty }
    }

    func isChatMuted(_ id: String) -> Bool {
        // Match the full folded-id set muteChat stores — not just the raw id /
        // canonical peer key — so a mute keyed by group id / npub still wins
        // when the alert path carries a different shape for the same chat.
        SonarChatMuteStore.shared.isMuted(anyOf: muteKeys(forChatId: id))
    }

    /// Mute end for the chat (`.distantFuture` = until turned back on).
    func chatMuteEnd(_ id: String) -> Date? {
        SonarChatMuteStore.shared.muteEnd(anyOf: muteKeys(forChatId: id))
    }

    /// Mute for `duration` seconds, or indefinitely when nil.
    func muteChat(_ id: String, for duration: TimeInterval?) {
        let until = duration.map { Date().addingTimeInterval($0) } ?? .distantFuture
        SonarChatMuteStore.shared.mute(keys: muteKeys(forChatId: id), until: until)
        objectWillChange.send()
    }

    func unmuteChat(_ id: String) {
        SonarChatMuteStore.shared.unmute(keys: muteKeys(forChatId: id))
        objectWillChange.send()
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
    /// leak into list rows). A caption-less media message previews as its
    /// attachment kind ("Photo", "3 photos", "Voice note", filename) instead
    /// of an empty row.
    static func previewText(
        _ content: String,
        stickerRef: MarmotService.MarmotStickerRef? = nil,
        media: [MarmotService.MarmotMedia] = []
    ) -> String {
        if stickerRef != nil { return "Sticker" }
        if looksLikeCallControl(content), callParseControl(content: content) != nil {
            return "Voice call"
        }
        if SonarTrillMessage.isTrillLine(content) { return "Nudge" }
        if SonarPayMessage.decode(content) != nil { return "\u{20BF} Payment" }
        if content.isEmpty, !media.isEmpty { return Self.mediaPreviewLabel(media) }
        return content
    }

    /// "Photo" / "3 photos" / "Voice note" / filename for a media-only message.
    private static func mediaPreviewLabel(_ media: [MarmotService.MarmotMedia]) -> String {
        if media.count > 1, media.allSatisfy({ $0.isImage }) {
            return "\(media.count) photos"
        }
        guard let first = media.first else { return "" }
        if first.isImage { return "Photo" }
        if first.isAudio { return "Voice note" }
        return first.filename.isEmpty ? "File" : first.filename
    }

    /// Radar "Send sats": open the DM with the PaySheet already up.
    func quickPay(_ id: String) {
        pendingPayPeer = id
        openDM(id)
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
        if isPendingMarmotGroup(id) {
            return SNVerifyInfo(
                available: false, safety: [], publicKey: "",
                note: "Group setup is still finishing."
            )
        }
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
        if let groupId = marmotGroupId(id) {
            let groups = directMarmotGroups(matchingGroupId: groupId)
            if groups.isEmpty { return marmotVerified[groupId] ?? false }
            return hasVerifiedMarmotGroup(in: groups)
        }
        guard let fingerprint = chatViewModel.getFingerprint(for: PeerID(str: id)) else { return false }
        return chatViewModel.verifiedFingerprints.contains(fingerprint)
    }

    func markVerified(_ id: String) {
        if let groupId = marmotGroupId(id) {
            let groups = directMarmotGroups(matchingGroupId: groupId)
            if groups.isEmpty {
                marmotVerified[groupId] = true
            } else {
                for group in groups { marmotVerified[group.id] = true }
            }
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
        if case .dm(let id) = route, currentDMId != id {
            cleanupPreviewTempFiles()
        }
        if case .dm(let id) = route {
            // Capture at navigation time — the screen's own onAppear would
            // lose the race against its child list's onAppear.
            captureUnreadAtOpen(id)
            clearNotificationsForConversation(id)
        }
        #if os(iOS)
        if case .call = route { return }
        #endif
        path.append(route)
        syncViewingUnreadGroups()
    }

    /// Whether the given conversation is the top DM route (used to suppress
    /// banners while that chat is already open). Matches fold / fingerprint
    /// aliases of the same person, not only exact string equality.
    func isConversationOpen(_ conversationId: String) -> Bool {
        guard let openId = currentDMId else { return false }
        return conversationsMatchForNotification(openId, conversationId)
    }

    /// Open a conversation from a notification tap (local or private-message).
    /// Uses the local-first `openDM` path (await newest page before present) and
    /// refuses stale ids that no longer resolve to a live local conversation.
    /// When `jumpMessageId` is set, transcript open-action Jump wins (#372);
    /// missing ids soft-fail to unread/live-edge inside the host.
    func openConversationFromNotification(
        _ conversationId: String,
        jumpMessageId: String? = nil
    ) {
        let id = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let jump: String? = {
            guard let raw = jumpMessageId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return raw
        }()
        if isConversationOpen(id) {
            clearNotificationsForConversation(id)
            // Already on this DM — still apply Jump so a tap while backgrounded
            // on the open chat scrolls to the notified message (#376 GLM Medium).
            if let jump {
                pendingJumpMessageIdByDM[id] = jump
                jumpMessageIdAtOpenByDM[id] = jump
                objectWillChange.send()
            }
            return
        }
        guard let target = resolveNotificationConversation(id) else {
            // Deleted / left / never-hydrated — clear the shade, stay on Home.
            clearNotificationsForConversation(id)
            return
        }
        openDM(target.id, marmotGroupId: target.marmotGroupId, jumpMessageId: jump)
    }

    /// Drop a one-shot Jump target after the host has applied (or soft-failed)
    /// the open action so later transcript updates do not re-jump.
    func clearJumpMessageIdAtOpen(_ id: String) {
        guard jumpMessageIdAtOpenByDM[id] != nil || pendingJumpMessageIdByDM[id] != nil else { return }
        jumpMessageIdAtOpenByDM[id] = nil
        pendingJumpMessageIdByDM[id] = nil
        // Not `@Published` — nudge SwiftUI so the host stops receiving the jump.
        objectWillChange.send()
    }

    /// Map a notification conversation id onto a current local DM row / pending
    /// chat / live Marmot group. Nil means the tap target is gone.
    private func resolveNotificationConversation(
        _ id: String
    ) -> (id: String, marmotGroupId: String?)? {
        if let row = dmRows.first(where: {
            $0.id == id || conversationsMatchForNotification($0.id, id)
        }) {
            return (row.id, row.marmotGroupId)
        }
        if pendingMarmotNpub(for: id) != nil || isPendingMarmotGroup(id) {
            return (id, nil)
        }
        if let groupId = marmotGroupId(id),
           marmot.groups.contains(where: { $0.id == groupId }) {
            if let row = dmRows.first(where: {
                $0.marmotGroupId == groupId || conversationsMatchForNotification($0.id, id)
            }) {
                return (row.id, groupId)
            }
            return (Self.marmotIDPrefix + groupId, groupId)
        }
        // Mesh / bitchat private chat that still has local state.
        if !id.hasPrefix(Self.marmotIDPrefix) {
            let peerID = PeerID(str: id)
            let hasPrivate = chatViewModel.privateChats[peerID] != nil
                || chatViewModel.unifiedPeerService.getPeer(by: peerID) != nil
            if hasPrivate {
                return (id, marmotGroupId(id))
            }
        }
        return nil
    }

    /// True when both ids name the same DM under fold / fingerprint aliases.
    private func conversationsMatchForNotification(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        if let leftGroup = marmotGroupId(left),
           let rightGroup = marmotGroupId(right),
           leftGroup == rightGroup {
            return true
        }
        if let fp = chatViewModel.getFingerprint(for: PeerID(str: left)), fp == right { return true }
        if let fp = chatViewModel.getFingerprint(for: PeerID(str: right)), fp == left { return true }
        let leftKey = canonicalPeerKey(PeerID(str: left))
        let rightKey = canonicalPeerKey(PeerID(str: right))
        if leftKey == rightKey { return true }
        // Same Sonar npub on different Noise fingerprints = one person.
        if let leftHex = linkedNpubHex(forPeerKey: leftKey),
           let rightHex = linkedNpubHex(forPeerKey: rightKey),
           leftHex == rightHex {
            return true
        }
        return false
    }

    /// Dismiss OS notifications that were posted for this conversation (and
    /// any folded / duplicate ids that share its notification userInfo).
    func clearNotificationsForConversation(_ conversationId: String) {
        var ids: Set<String> = [conversationId]
        if let groupId = marmotGroupId(conversationId) {
            ids.insert(groupId)
            ids.insert(Self.marmotIDPrefix + groupId)
            for group in directMarmotGroups(matchingGroupId: groupId) {
                ids.insert(group.id)
                ids.insert(marmotConvId(forGroup: group.id))
            }
        }
        if let mapped = marmotGroupIdsByConversationId[conversationId] {
            ids.insert(mapped)
            ids.insert(Self.marmotIDPrefix + mapped)
        }
        // Mesh fingerprint alias of the same peer (incl. same-npub BLE aliases).
        if let fp = chatViewModel.getFingerprint(for: PeerID(str: conversationId)) {
            ids.insert(fp)
            if let mapped = marmotGroupIdsByConversationId[fp] {
                ids.insert(mapped)
                ids.insert(Self.marmotIDPrefix + mapped)
            }
        }
        for alias in meshPeerAliases(for: conversationId) {
            ids.insert(alias)
            if let mapped = marmotGroupIdsByConversationId[alias] {
                ids.insert(mapped)
                ids.insert(Self.marmotIDPrefix + mapped)
            }
        }
        NotificationService.shared.clearNotifications(forConversationIds: ids)
    }

    func pop() {
        cleanupPreviewTempFiles()
        // The unread divider lives while its chat is on the stack; leaving the
        // chat retires it so a later reopen (already marked read) starts clean.
        if case .dm(let id)? = path.last {
            unreadCountAtOpenByDM[id] = nil
            jumpMessageIdAtOpenByDM[id] = nil
            pendingJumpMessageIdByDM[id] = nil
        }
        if !path.isEmpty { path.removeLast() }
        syncViewingUnreadGroups()
    }

    /// Keep Marmot unread-badge suppression tied to the top DM route so a
    /// summary refresh cannot restore the dot while the chat is open (or while
    /// mark-read is still in flight after leaving).
    private func syncViewingUnreadGroups() {
        guard let id = currentDMId else {
            marmot.setViewingUnreadGroups([])
            return
        }
        let groupId = marmotGroupId(id)
            ?? resolvedSonarProfile(id).flatMap { marmotGroup(forNpub: $0.npub)?.id }
        guard let groupId else {
            marmot.setViewingUnreadGroups([])
            return
        }
        let groups = directMarmotGroups(matchingGroupId: groupId)
        marmot.setViewingUnreadGroups(groups.isEmpty ? [groupId] : groups.map(\.id))
    }

    private func popCallRouteIfNeeded() {
        if case .call? = path.last { pop() }
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
        // Store-level block enforcement (Android parity) — the profile UI
        // already hides the buttons, but the store must not trust the view.
        if isContactBlocked(convId, npub: callNpub(convId) ?? "") {
            SecureLogger.debug("SonarCall: refusing call to blocked contact convId=\(convId.prefix(16))", category: .session)
            return
        }
        guard canCall(convId), let via = callSignalingVia(convId) else {
            SecureLogger.debug("SonarCall: refusing call without BLE or White Noise route convId=\(convId.prefix(16))", category: .session)
            return
        }
        VoiceNotePlaybackController.shared.stop(reason: .call)
        let callId = UUID().uuidString
        let name = callDisplayName(convId)
        // Show the ringing screen IMMEDIATELY so the tap is responsive — the iroh
        // setup (bind/offer) runs in the background. The endpoint is already bound
        // at boot via ensureCallStarted(), so we must NOT call callStart() again
        // here (a second bind blocks — which made the tap "take forever").
        SonarCallAudioRoute.configure(active: true, speakerOn: video, proximityEnabled: !video)
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
                        self.popCallRouteIfNeeded()
                    }
                }
            } catch {
                SecureLogger.error("call place failed: \(error)", category: .session)
                await MainActor.run {
                    guard self.activeCall?.callId == callId else { return }
                    SonarCallAudioRoute.configure(active: false, speakerOn: false)
                    self.activeCall = nil
                    self.popCallRouteIfNeeded()
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
        SonarCallAudioRoute.configure(active: true, speakerOn: c.speakerOn, proximityEnabled: !c.video)
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

    /// Decline the incoming call: send ANSWER|decline, tear down the local slot,
    /// and dismiss the call screen immediately (don't wait for the engine event).
    func declineCall() {
        guard let c = activeCall else { return }
        callTickerTask?.cancel(); callTickerTask = nil
        let line = callEncodeAnswer(callId: c.callId, answer: .decline, nodeAddrB64: "")
        _ = sendCallControl(c.convId, line, via: c.signalingVia)
        SonarCallAudioRoute.configure(active: false, speakerOn: false)
        recordCall(convId: c.convId, video: c.video, mine: false, seconds: 0)
        activeCall = nil
        popCallRouteIfNeeded()
        Task { [weak self] in try? await self?.marmot.callHangup(callId: c.callId) }
    }

    /// Hang up an outgoing/connected call: dismiss immediately (Signal pattern),
    /// then tear down engine + signal END in the background.
    func hangupCall() {
        guard let c = activeCall else { return }
        callTickerTask?.cancel(); callTickerTask = nil
        SonarCallAudioRoute.configure(active: false, speakerOn: false)
        recordCall(convId: c.convId, video: c.video, mine: !c.incoming, seconds: c.connectedSecs)
        activeCall = nil
        popCallRouteIfNeeded()
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
        handleCallProximityChange()
    }

    private func handleCallProximityChange() {
        #if os(iOS)
        guard var c = activeCall, !c.video else { return }
        guard UIDevice.current.proximityState, c.speakerOn else { return }
        c.speakerOn = false
        activeCall = c
        SonarCallAudioRoute.setSpeaker(false)
        #endif
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
        popCallRouteIfNeeded()
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
                let via: SNVia = m.receivedViaInternet == true ? .internet : .mesh
                if handleCallControl(ctrl, convId: peerID.id, via: via, messageId: m.id) {
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
                if handleCallControl(ctrl, convId: Self.marmotIDPrefix + groupId, via: .internet, messageId: m.id) {
                    scannedCallMessageIDs.insert(m.id)
                }
            }
        }
    }

    @discardableResult
    private func sendCallControl(_ convId: String, _ line: String, via: SNVia) -> Bool {
        switch via {
        case .mesh:
            guard let route = liveMeshRoutePeerId(for: convId) else {
                SecureLogger.debug("SonarCall: dropping control without mesh route convId=\(convId.prefix(16))", category: .session)
                return false
            }
            let sent = chatViewModel.meshService.sendPrivateMessageNow(line, to: PeerID(str: route), messageID: UUID().uuidString)
            if !sent {
                SecureLogger.debug("SonarCall: dropping control without established Noise route convId=\(convId.prefix(16)) route=\(route.prefix(16))", category: .session)
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
    private func handleCallControl(_ ctrl: CallControlInfo, convId: String, via: SNVia, messageId: String) -> Bool {
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
            let stale = Date().timeIntervalSince1970 - Double(unixSecs) > 60
            if stale {
                return true
            }
            if activeCall != nil { // busy: auto-decline
                _ = sendCallControl(conversationId, callEncodeAnswer(callId: callId, answer: .busy, nodeAddrB64: ""), via: signalingVia)
                return true
            }
            let name = callDisplayName(conversationId)
            let alreadyStarted = callStarted
            Task { [weak self] in
                guard let self else { return }
                do {
                    if !alreadyStarted {
                        try await self.marmot.callStart()
                        await MainActor.run { self.callStarted = true; self.startCallLoop() }
                    }
                    try await self.marmot.callIncomingOffer(callId: callId, addrB64: nodeAddrB64, video: video)
                    await MainActor.run {
                        VoiceNotePlaybackController.shared.stop(reason: .call)
                        self.activeCall = SNActiveCall(callId: callId, convId: conversationId, signalingVia: signalingVia, peerName: name, video: video, incoming: true, phase: .ringing, speakerOn: video)
                        self.sendSonarNotification(
                            kind: .call,
                            idKey: "call-\(callId)-\(messageId)",
                            conversationId: conversationId,
                            conversationTitle: name,
                            senderName: name,
                            sound: via == .mesh ? .ble : .standard
                        )
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
    ///
    /// Optimistic: hide the row immediately (Compose filters `chats` first), then
    /// await durable MLS purge so a stuck relay cannot keep the chat visible.
    func deleteChat(_ id: String) {
        discardRetainedConversation(id)
        // Stop voice if the active note belongs to this logical conversation
        // (or any folded source mapped under it) before local media is removed.
        VoiceNotePlaybackController.shared.stopIfActiveItem(
            matching: { item in
                item.logicalConversationId == id || item.sourceConversationId == id
            },
            reason: .deleted
        )
        if isPendingSecureChat(id) {
            pendingMarmotChats[id] = nil
            pendingMarmotGroups[id] = nil
            pendingMarmotMessagesByChat[id] = nil
            pendingMarmotGroupSends[id] = nil
            cancelPendingMarmotGroupSetup(pendingId: id)
            if let pendingNpub = pendingMarmotNpub(for: id) {
                pendingDirectMarmotSends[pendingNpub] = nil
                cancelPendingSecureChatSetup(pendingId: id, npub: pendingNpub)
            }
            path.removeAll { route in
                if case .dm(let rid) = route { return rid == id }
                return false
            }
            objectWillChange.send()
            return
        }

        if let groupId = marmotGroupId(id) {
            let shouldLeave = isMultiMemberMarmotGroupId(id)
            // A deduped direct row can represent several duplicate Marmot groups
            // for the same peer; delete the whole set so hidden duplicates don't
            // resurface after the next refresh.
            let matching = shouldLeave ? [] : directMarmotGroups(matchingGroupId: groupId).map(\.id)
            let groupIds = matching.isEmpty ? [groupId] : matching
            for gid in groupIds {
                discardRetainedConversation(gid)
                forgetMarmotGroupMappings(forGroupId: gid)
                marmot.dropGroupFromLocalState(gid)
            }
            path.removeAll { route in
                if case .dm(let rid) = route { return rid == id || groupIds.contains(rid) }
                return false
            }
            objectWillChange.send()
            Task { @MainActor in
                do {
                    if shouldLeave {
                        try await marmot.leaveGroup(groupId)
                    } else {
                        for gid in groupIds { try await marmot.deleteGroup(gid) }
                    }
                } catch {
                    // Optimistic hide already ran — reload from durable state so a
                    // failed purge cannot leave an invisible MLS corpse (R-010).
                    _ = await marmot.loadLocalSummaries(resolveMembers: false)
                    showToast(
                        shouldLeave
                            ? "Couldn't leave group: \(error.localizedDescription)"
                            : "Couldn't delete chat: \(error.localizedDescription)"
                    )
                }
            }
            return
        }

        // Mesh / Sonar peer: erase mesh transcript and every folded WN leg.
        chatViewModel.deleteConversation(with: PeerID(str: id))
        let foldedGroups: [MarmotService.MarmotGroup]
        if let profile = resolvedSonarProfile(id) {
            foldedGroups = marmotGroups(forNpub: profile.npub)
            for g in foldedGroups {
                discardRetainedConversation(g.id)
                forgetMarmotGroupMappings(forGroupId: g.id)
                marmot.dropGroupFromLocalState(g.id)
            }
        } else {
            foldedGroups = []
        }
        path.removeAll { route in
            if case .dm(let rid) = route {
                return rid == id || foldedGroups.contains(where: { $0.id == rid })
            }
            return false
        }
        objectWillChange.send()
        if !foldedGroups.isEmpty {
            Task { @MainActor in
                do {
                    for g in foldedGroups { try await marmot.deleteGroup(g.id) }
                } catch {
                    _ = await marmot.loadLocalSummaries(resolveMembers: false)
                    showToast("Couldn't delete chat: \(error.localizedDescription)")
                }
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
        VoiceNotePlaybackController.shared.clearAll()
        path = []
        unreadCountAtOpenByDM.removeAll()
        jumpMessageIdAtOpenByDM.removeAll()
        pendingJumpMessageIdByDM.removeAll()
        conversationViewStates.removeAll()
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
        pendingMarmotChats = [:]
        pendingMarmotGroups = [:]
        pendingMarmotMessagesByChat = [:]
        pendingMarmotRouteReplacement = nil
        pendingMarmotRouteFailure = nil
        pendingDirectMarmotSends = [:]
        pendingMarmotGroupSends = [:]
        cancelPendingSecureChatSetups()
        cancelPendingMarmotGroupSetups()
        scannedPayMessageIDs = []
        scannedTrillMessageIDs = []
        trillCooldownUntilByChat = [:]
        SonarTrillThrottle.shared.reset()
        SonarChatMuteStore.shared.wipe()
        pendingPayPeer = nil
        localHydratingDMs = []
        clearMarmotConversationGroups()
        marmot.groups = []
        defaults.removeObject(forKey: Keys.bleKnownChatKeys)
        applyBLEDiscoveryPolicy()
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
        cancelAllMediaDownloads()
        mediaImageCache = [:]
        pendingUploadMediaCache = [:]
        clearMediaDiskCache()
        objectWillChange.send()
    }

    // MARK: Emergency wipe (the real panic path)

    func wipe() {
        Task { @MainActor [weak self] in
            await self?.performWipe()
        }
    }

    private func performWipe() async {
        VoiceNotePlaybackController.shared.clearAll()
        path = []
        unreadCountAtOpenByDM.removeAll()
        jumpMessageIdAtOpenByDM.removeAll()
        pendingJumpMessageIdByDM.removeAll()
        // The Breez node must release its SQLite store before wallet files are
        // deleted. Await this before revealing onboarding so a fast re-onboard
        // cannot race a still-running destructive wallet task.
        var walletWipeComplete = true
        #if os(iOS) || os(macOS)
        if let bridged = wallet as? BridgedWallet {
            walletWipeComplete = await bridged.wipeForEmergency()
        } else {
            do {
                try BridgedWallet.beginWalletStorageMutation()
                try BridgedWallet.wipeWalletStorage()
            } catch {
                walletWipeComplete = false
            }
        }
        #endif
        marmot.stopPolling()
        // Wipes Noise/Nostr keys, all keychain data (incl. marmot-nsec),
        // messages, favorites, verified fingerprints and the nickname.
        // panicClearAllData() also erases the on-disk MessageStore; call it
        // here too so the local mesh-DM / channel transcripts are gone even if
        // that ordering ever changes.
        chatViewModel.panicClearAllData()
        MessageStore.shared.wipeAll()
        _ = keychain.deleteIdentityKey(forKey: Keys.marmotNsecKeychainKey)
        // Erase the encrypted Marmot (White Noise) SQLCipher database + its
        // Keychain DB key; also resets in-memory Marmot state.
        marmot.wipeDatabase()
        // Drop diagnostics logs too: at verbose level they can contain peer
        // npubs, so a panic wipe must not leave them on disk.
        SonarDiagnostics.clearLogs()
        marmot.npub = nil
        marmot.groups = []
        marmot.messagesByGroup = [:]
        marmotVerified = [:]
        defaults.removeObject(forKey: Keys.marmotVerified)
        defaults.removeObject(forKey: Keys.bleKnownChatKeys)
        // Stop Sonar discovery announces and forget discovered profiles (live +
        // the persisted npub↔peer link).
        if let ble = chatViewModel.meshService as? BLEService {
            ble.sonarProfileProvider = nil
            ble.discoveryMode = effectiveBLEDiscoveryMode
        }
        sonarProfiles = [:]
        sonarProfilesByFingerprint = [:]
        invalidatePeerKeysIndex()
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
        pendingMarmotChats = [:]
        pendingMarmotGroups = [:]
        pendingMarmotMessagesByChat = [:]
        pendingMarmotRouteReplacement = nil
        pendingMarmotRouteFailure = nil
        pendingDirectMarmotSends = [:]
        pendingMarmotGroupSends = [:]
        cancelPendingSecureChatSetups()
        cancelPendingMarmotGroupSetups()
        // Wallet seed and Breez state were shut down and removed at the start
        // of this async wipe, before any new onboarding can begin.
        payLedger.wipe()
        paymentActivityLedger.wipe()
        cancelAllMediaDownloads()
        mediaImageCache = [:]
        pendingUploadMediaCache = [:]
        clearMediaDiskCache()
        scannedPayMessageIDs = []
        // Message-id dedup state is account-bound: this store outlives a wipe,
        // so a restored account whose ids collide would be silently swallowed.
        seenMarmotNotificationMessageIDs = []
        scannedTrillMessageIDs = []
        trillCooldownUntilByChat = [:]
        SonarTrillThrottle.shared.reset()
        SonarChatMuteStore.shared.wipe()
        pendingPayPeer = nil
        clearCallLogs()
        resetCallState()
        bip353 = ""
        defaults.removeObject(forKey: Keys.bip353)
        onboarded = false
        defaults.set(false, forKey: Keys.onboarded)
        if !walletWipeComplete {
            showToast("Wallet cleanup is incomplete. Restart Sonar before creating or restoring an account.")
        }
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

/// Bounded local voice queue from the already-published transcript projection.
@MainActor
final class SonarVoicePlaybackQueue: VoicePlaybackQueue {
    private weak var store: SonarAppStore?

    init(store: SonarAppStore) {
        self.store = store
    }

    func next(after item: VoicePlaybackItem) -> VoicePlaybackItem? {
        neighbor(of: item, direction: +1)
    }

    func previous(before item: VoicePlaybackItem) -> VoicePlaybackItem? {
        neighbor(of: item, direction: -1)
    }

    private func neighbor(of item: VoicePlaybackItem, direction: Int) -> VoicePlaybackItem? {
        guard let store else { return nil }
        let candidates = store.localVoicePlaybackCandidates(logicalConversationId: item.logicalConversationId)
        guard let idx = candidates.firstIndex(where: { $0.key == item.key }) else { return nil }
        let nextIdx = idx + direction
        guard candidates.indices.contains(nextIdx) else { return nil }
        return candidates[nextIdx]
    }
}

extension SonarAppStore {
    /// Voice notes already present in the local transcript window for one
    /// logical conversation. Never hits relay or scans full history.
    @MainActor
    func localVoicePlaybackCandidates(logicalConversationId: String) -> [VoicePlaybackItem] {
        let rows = conversationViewState(logicalConversationId).messages
        var out: [VoicePlaybackItem] = []
        for message in rows {
            for (index, media) in message.media.enumerated() where media.mime.hasPrefix("audio/") {
                if let item = voicePlaybackItem(
                    for: message,
                    media: media,
                    mediaIndex: index,
                    logicalConversationId: logicalConversationId
                ) {
                    out.append(item)
                }
            }
        }
        return out
    }
}
