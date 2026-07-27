//
// MarmotChatView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import Combine
import BitLogger
import CryptoKit
import SonarCore
#if os(iOS)
import UIKit
#endif

func snNormalizeStickerPackCoordinate(_ coordinate: String) -> String {
    let parts = coordinate.split(
        separator: ":",
        maxSplits: 2,
        omittingEmptySubsequences: false
    )
    guard parts.count == 3 else { return coordinate }
    return "\(parts[0]):\(parts[1].lowercased()):\(parts[2])"
}

enum SNMarmotProfileCache {
    static let defaultsKey = "marmot.profilesByNpub.v1"
    private static let cacheLimit = 4_096
    private static let canonicalLock = NSLock()
    private static var canonicalCache: [String: String] = [:]

    static func canonicalKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        canonicalLock.lock()
        if let cached = canonicalCache[trimmed] {
            canonicalLock.unlock()
            return cached
        }
        canonicalLock.unlock()

        let canonical = computeCanonicalKey(trimmed)

        canonicalLock.lock()
        if canonicalCache.count >= cacheLimit {
            canonicalCache.removeAll(keepingCapacity: true)
        }
        canonicalCache[trimmed] = canonical
        canonicalLock.unlock()

        return canonical
    }

    private static func computeCanonicalKey(_ trimmed: String) -> String {
        if trimmed.hasPrefix("npub1"),
           let decoded = try? Bech32.decode(trimmed),
           decoded.hrp == "npub",
           decoded.data.count == 32,
           let encoded = try? Bech32.encode(hrp: "npub", data: decoded.data) {
            return encoded
        }
        if let data = Data(hexString: trimmed), data.count == 32,
           let encoded = try? Bech32.encode(hrp: "npub", data: data) {
            return encoded
        }
        return trimmed
    }

    static func load(from defaults: UserDefaults) -> [String: MarmotService.Profile] {
        guard let data = defaults.data(forKey: defaultsKey),
              let profiles = try? JSONDecoder().decode([String: MarmotService.Profile].self, from: data)
        else { return [:] }
        let loaded = normalized(profiles)
        // Keep the NSE App Group name mirror warm even when nothing new was
        // fetched this session (kill-state Transponder banners need aliases).
        syncSharedProfileNames(loaded)
        return loaded
    }

    static func save(_ profiles: [String: MarmotService.Profile], to defaults: UserDefaults) {
        guard let payload = encoded(profiles) else { return }
        commit(payload, to: defaults)
    }

    /// The expensive half: normalize + JSON-encode the whole map. `nonisolated`
    /// and pure so callers can run it off the main actor and commit the result
    /// later — see `MarmotChatModel.scheduleProfileCacheWrite`.
    nonisolated static func encoded(
        _ profiles: [String: MarmotService.Profile]
    ) -> (data: Data, normalized: [String: MarmotService.Profile])? {
        let normalizedProfiles = normalized(profiles)
        guard let data = try? JSONEncoder().encode(normalizedProfiles) else { return nil }
        return (data, normalizedProfiles)
    }

    /// The cheap half: hand the encoded bytes to UserDefaults (in-memory, the
    /// disk flush is the OS's problem) and mirror the App Group name map.
    static func commit(
        _ payload: (data: Data, normalized: [String: MarmotService.Profile]),
        to defaults: UserDefaults
    ) {
        defaults.set(payload.data, forKey: defaultsKey)
        syncSharedProfileNames(payload.normalized)
    }

    static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
        SonarSharedProfileNames.clear()
    }

    private static func normalized(_ profiles: [String: MarmotService.Profile]) -> [String: MarmotService.Profile] {
        profiles.reduce(into: [:]) { result, entry in
            let key = canonicalKey(entry.key)
            if result[key]?.bestName == nil || entry.value.bestName != nil {
                result[key] = entry.value
            }
        }
    }

    /// Mirror bestName under both npub and hex so NSE drain senders (often hex)
    /// resolve without Bech32 / relay fetch inside the appex.
    private static func syncSharedProfileNames(_ profiles: [String: MarmotService.Profile]) {
        var names: [String: String] = [:]
        for (key, profile) in profiles {
            guard let best = profile.bestName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !best.isEmpty else { continue }
            names[key] = best
            names[key.lowercased()] = best
            if let hex = pubkeyHex(for: key) {
                names[hex] = best
                names[hex.lowercased()] = best
            }
            if let npub = npub(for: key) {
                names[npub] = best
            }
        }
        SonarSharedProfileNames.save(names)
    }

    private static func pubkeyHex(for key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 64, trimmed.allSatisfy(\.isHexDigit) {
            return trimmed.lowercased()
        }
        guard trimmed.hasPrefix("npub1"),
              let decoded = try? Bech32.decode(trimmed),
              decoded.hrp == "npub",
              decoded.data.count == 32 else { return nil }
        return decoded.data.map { String(format: "%02x", $0) }.joined()
    }

    private static func npub(for key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("npub1") { return canonicalKey(trimmed) }
        guard let data = Data(hexString: trimmed), data.count == 32,
              let encoded = try? Bech32.encode(hrp: "npub", data: data) else { return nil }
        return encoded
    }
}

/// Durable cache of resolved public Sonar descriptors, keyed by npub.
///
/// The descriptor carries the peer's BOLT12 offer, which is what unlocks
/// "Send money" in a chat. Holding it only in memory meant every cold start
/// hid the payment affordance until a relay round-trip landed (and hid it for
/// a further 60 s whenever that first fetch missed). Persisting it lets the
/// payment row paint from local state first — the same local-first shape the
/// profile cache already uses.
enum SNMarmotDescriptorCache {
    static let defaultsKey = "marmot.sonarDescriptorsByNpub.v1"
    /// Descriptors are small and bounded by how many contacts exist, but cap
    /// the persisted set so a long-lived install cannot grow it without limit.
    private static let entryLimit = 1_024

    static func load(from defaults: UserDefaults) -> [String: MarmotService.SonarDescriptor] {
        guard let data = defaults.data(forKey: defaultsKey),
              let descriptors = try? JSONDecoder().decode(
                  [String: MarmotService.SonarDescriptor].self, from: data
              )
        else { return [:] }
        // A blob written before the cap existed can be over the limit; bound it
        // here so the live map starts bounded without needing a write.
        return capped(descriptors)
    }

    static func save(
        _ descriptors: [String: MarmotService.SonarDescriptor],
        to defaults: UserDefaults
    ) {
        guard let data = encoded(descriptors) else { return }
        commit(data, to: defaults)
    }

    /// The expensive half: cap + JSON-encode the whole map. `nonisolated` and
    /// pure so callers can run it off the main actor and commit the result
    /// later — see `MarmotChatModel.scheduleDescriptorCacheWrite`.
    nonisolated static func encoded(
        _ descriptors: [String: MarmotService.SonarDescriptor]
    ) -> Data? {
        try? JSONEncoder().encode(capped(descriptors))
    }

    /// The cheap half: hand the encoded bytes to UserDefaults.
    static func commit(_ data: Data, to defaults: UserDefaults) {
        defaults.set(data, forKey: defaultsKey)
    }

    static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Keep the freshest descriptors when over the cap (newest `publishedAt`).
    /// Applied to the LIVE model map as well as to `save`, so the in-memory
    /// dictionary cannot grow without bound and make every fetch re-encode more.
    static func capped(
        _ descriptors: [String: MarmotService.SonarDescriptor]
    ) -> [String: MarmotService.SonarDescriptor] {
        guard descriptors.count > entryLimit else { return descriptors }
        let kept = descriptors
            .sorted {
                $0.value.publishedAt == $1.value.publishedAt
                    ? $0.key < $1.key
                    : $0.value.publishedAt > $1.value.publishedAt
            }
            .prefix(entryLimit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}

func snShortNpubLabel(_ value: String) -> String {
    value.count > 16 ? "\(value.prefix(10))…\(value.suffix(4))" : value
}

func snDirectMarmotPeerKey(for group: MarmotService.MarmotGroup, ownNpub: String?) -> String? {
    let ownKey = ownNpub.map(SNMarmotProfileCache.canonicalKey)
    let others = Array(Set(group.memberNpubs.map(SNMarmotProfileCache.canonicalKey).filter {
        guard !$0.isEmpty else { return false }
        guard let ownKey else { return true }
        return $0 != ownKey
    })).sorted()
    return others.count == 1 ? others.first : nil
}

func snCanonicalDirectMarmotGroups(
    _ groups: [MarmotService.MarmotGroup],
    ownNpub: String?
) -> [String: [MarmotService.MarmotGroup]] {
    groups.reduce(into: [:]) { result, group in
        guard let key = snDirectMarmotPeerKey(for: group, ownNpub: ownNpub) else { return }
        result[key, default: []].append(group)
    }
}

func snResolvedMarmotAuthorName(
    _ message: MarmotService.MarmotMessage,
    profilesByNpub: [String: MarmotService.Profile],
    fetchMissingProfile: (String) -> Void,
    shortNpub: (String) -> String
) -> String? {
    guard !message.isMine, !message.senderNpub.isEmpty else { return nil }
    let canonical = SNMarmotProfileCache.canonicalKey(message.senderNpub)
    if let name = profilesByNpub[canonical]?.bestName ?? profilesByNpub[message.senderNpub]?.bestName {
        return name
    }
    fetchMissingProfile(message.senderNpub)
    return shortNpub(message.senderNpub)
}

/// Home-only projection of the core conversation index. Transcript pages stay
/// bounded and authoritative; a synthetic row is used only when the summary is
/// newer than the loaded page (or that group is outside the page window).
func snMarmotHomeRowMessage(
    loaded: MarmotService.MarmotMessage?,
    summary: MarmotService.ConversationSummary?
) -> MarmotService.MarmotMessage? {
    guard let summary, summary.messageCount > 0 else { return loaded }
    if let loaded {
        if loaded.createdAt > summary.latestAt { return loaded }
        if loaded.createdAt == summary.latestAt,
           loaded.senderNpub == summary.latestSenderNpub,
           loaded.content == summary.latestContent,
           loaded.isMine == summary.latestMine {
            return loaded
        }
    }
    return MarmotService.MarmotMessage(
        id: "summary:\(summary.groupIdHex):\(summary.messageCount)",
        senderNpub: summary.latestSenderNpub,
        content: summary.latestContent,
        createdAt: summary.latestAt,
        isMine: summary.latestMine,
        media: []
    )
}

enum SNMarmotChatSnapshotCache {
    private static let defaultsKey = "marmot.chatSnapshot.v1"

    private struct Snapshot: Codable {
        let groups: [MarmotService.MarmotGroup]
    }

    static func load(from defaults: UserDefaults) -> ([MarmotService.MarmotGroup], [String: [MarmotService.MarmotMessage]]) {
        guard let data = defaults.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return ([], [:]) }
        // Rewrite older snapshots that included message bodies/media outside the
        // encrypted chat database. The startup cache is row metadata only.
        save(groups: snapshot.groups, messagesByGroup: [:], to: defaults)
        return (snapshot.groups, [:])
    }

    static func save(
        groups: [MarmotService.MarmotGroup],
        messagesByGroup: [String: [MarmotService.MarmotMessage]],
        to defaults: UserDefaults
    ) {
        _ = messagesByGroup
        let snapshot = Snapshot(groups: groups)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// UI state for Marmot (MLS-over-Nostr) secure chats — the White Noise
/// interop path. Owns a `MarmotService` and persists the generated Nostr
/// identity in the keychain (wiped by emergency wipe like everything else).
@MainActor
final class MarmotChatModel: ObservableObject {
    enum LocalTranscriptLoadMode {
        case newestPage
        case preserveHistoricalWindow
    }

    enum StickerCacheLookupState: Equatable {
        case hit
        case miss
        case invalidated
    }

    private static let nsecKeychainKey = SonarAccountKeyExport.marmotNsecKey
    /// Raw encoded sticker bytes stay bounded independently from the 100 MiB
    /// disk cache. Decoded SwiftUI images have their own framework caches, so
    /// retaining hundreds of multi-megabyte Data values here only adds memory
    /// pressure without improving transcript paint.
    private static let stickerImageMemoryBudgetBytes = 25 * 1024 * 1024
    private static let stickerImageMemoryEntryLimit = 100
    /// Cap on remembered unresolvable refs. A peer can mint refs freely, so the
    /// negative cache that protects the relay must itself be bounded.
    private static let unresolvableStickerRefLimit = 256
    private static let sonarDescriptorRefreshInterval: TimeInterval = 15 * 60
    private static let sonarDescriptorMissRetryInterval: TimeInterval = 60
    /// Re-fetch kind-0 profiles older than this so alias/name updates are
    /// noticed during long sessions (mirrors Android PROFILE_REFRESH_TTL_SECS).
    private static let profileRefreshTTL: TimeInterval = 30 * 60
    private static let localTranscriptPageLimit = TransportConfig.sonarTranscriptPageCount
    private static let localTranscriptRetainedLimit = TransportConfig.sonarTranscriptRetainedCount
    /// A summary invalidation may briefly own the same per-group loader as an
    /// edge gesture. Retry only that coalescing case for up to one second.
    private static let localTranscriptBusyRetryLimit = 21
    private static let localSummaryPageLimit: UInt32 = 20
    private static let localSummaryGroupLimit: UInt32 = 50
    private static let relayReconnectRetryDelaySeconds: Double = 10

    @Published var npub: String?
    /// Supplies the local user's current nickname so the kind-0 profile can be
    /// (re)published on every relay connect, alongside the KeyPackage. Set by
    /// SonarAppStore. Without this the profile only published opportunistically
    /// (on the npub signal / explicit rename) and could be lost to relay or
    /// onboarding timing — leaving peers to see a raw npub instead of the name.
    var profileNameProvider: (() -> String)?
    /// Host bip353 / handle pref for hydration planning. Set by SonarAppStore.
    var localBip353Provider: (() -> String)?
    /// Default Sonar handle domain (registrar). Set by SonarAppStore.
    var handleDomainProvider: (() -> String)?
    /// Best-effort BOLT12 offer for restore reclaim. Set by SonarAppStore.
    var handleOfferProvider: (() async -> String?)?
    /// Called on the main actor after our own kind-0 is fetched on relay
    /// connect, so the host can adopt name / NIP-05 into local profile state
    /// before any republish. Set by SonarAppStore.
    var onOwnProfileFetched: ((MarmotService.Profile) -> Void)?
    /// Called on the main actor after a restore reclaim seeds the core sidecar.
    /// Set by SonarAppStore — do not mark `coreClaimedHandle` before this.
    var onOwnHandleSidecarSeeded: ((String) -> Void)?
    /// After the first own-kind-0 fetch this process, handle-less accounts can
    /// skip the RTT on later reconnects. Sonar-domain prefs without a sidecar
    /// still re-enter so reclaim can retry.
    private var didFetchOwnProfileThisSession = false
    @Published var groups: [MarmotService.MarmotGroup] = []
    @Published var pendingGroupInvites: [MarmotService.GroupInvite] = []
    @Published var pendingDirectChats: [String: Date] = [:]
    private var directChatSetupTasks: [String: (token: UUID, task: Task<String?, Never>)] = [:]
    @Published var messagesByGroup: [String: [MarmotService.MarmotMessage]] = [:]
    /// Core-owned row metadata for every conversation. Kept separate from
    /// transcript pages so summary placeholders never render as chat bubbles.
    @Published private(set) var conversationSummariesByGroup: [String: MarmotService.ConversationSummary] = [:]
    @Published var busy = false
    /// Serializes Settings → Backup chats so a second tap cannot seal while the
    /// first has already reopened SQLCipher (Compose joins jobs before FFI).
    private var accountBackupInFlight = false
    @Published var errorText: String?
    /// Resolved kind-0 profiles, keyed by npub — fills in human names/avatars
    /// for Marmot members instead of raw npubs.
    @Published var profilesByNpub: [String: MarmotService.Profile] = [:]
    /// Resolved public Sonar descriptors, keyed by npub. Presence here confirms
    /// the npub is Sonar-capable; absence is only "unknown / not fetched".
    @Published var sonarDescriptorsByNpub: [String: MarmotService.SonarDescriptor] = [:]
    /// Recent relay misses, keyed by npub. A miss is NOT proof the user is White
    /// Noise-only; it only lets call-offer handling stop deferring forever.
    @Published private(set) var sonarDescriptorMissesByNpub: [String: Date] = [:]
    /// True when the current node is relay-backed, not just the local DB node.
    @Published private(set) var relayConnected = false
    /// True while a foreground/push-tap catch-up sync is running. Passive UI
    /// signal only: it must never gate paint, sending, or scrolling.
    @Published private(set) var syncingInFlight = false
    /// The single in-flight foreground/push-tap catch-up refresh. Coalesces the
    /// scenePhase-driven and notification-tap-driven refresh paths so they don't
    /// both enqueue `syncForce()` on the serial engine queue (shared with sends)
    /// and so `syncingInFlight` is owned by exactly one run. @MainActor-isolated.
    private var refreshTask: Task<Void, Never>?
    /// True after the first local encrypted-DB hydration attempt finishes.
    /// Home uses this as its atomic reveal boundary; relay state is irrelevant.
    @Published private(set) var initialLocalHomeReady = false
    /// Unread message counts per Marmot group, keyed by group ID hex.
    @Published var unreadByGroup: [String: UInt64] = [:]
    /// Groups marked read whose core `unread_count` may still be nonzero while
    /// `markConversationRead` is in flight. Summary refresh must not restore
    /// their badges (Compose `unreadSuppressGroupIds` parity).
    private var unreadSuppressGroupIds = Set<String>()
    /// Groups belonging to the DM currently on screen. Suppressed for the
    /// whole viewing session so arrivals while reading never flash a badge.
    private var viewingUnreadGroupIds = Set<String>()
    /// While true, SonarAppStore must not emit process-alive Marmot banners —
    /// `SonarPushProcessor` owns lock-screen copy for the current push wake.
    /// Backed by a refcount so overlapping wakes cannot clear ownership early.
    private(set) var pushWakeOwnsNotifications = false
    private var pushWakeOwnershipCount = 0
    /// Bumps when ownership drops to zero so SonarAppStore can catch up live
    /// banners that were suppressed while push owned the lock screen.
    @Published private(set) var pushWakeLiveCatchUpGeneration: UInt64 = 0
    /// Message IDs the push wake already bannered. Live path marks these seen
    /// after ownership ends — stable IDs, not display labels / truncated previews.
    private(set) var pushWakeNotifiedMessageIDs = Set<String>()
    /// Group IDs already covered by a push-wake banner (drain or unread-delta).
    private(set) var pushWakeNotifiedGroupIds = Set<String>()
    /// Blossom upload progress (0...1) keyed by optimistic message id.
    /// Prefer reading [`mediaUploadProgressSource`] from bubbles — collection
    /// host cells do not rebuild on progress-only changes.
    @Published private(set) var mediaUploadProgress: [String: Double] = [:]
    /// Observable progress map for live upload bars (Compose-style).
    let mediaUploadProgressSource = SNMediaUploadProgressSource()
    /// In-flight upload listeners keyed by optimistic message id (tap-to-cancel).
    private var mediaUploadListeners: [String: SNMediaUploadListener] = [:]

    private let service: MarmotService
    private let keychain: KeychainManagerProtocol
    private let defaults: UserDefaults
    private var syncTask: Task<Void, Never>?
    private var relayConnectTask: Task<Void, Never>?
    /// Single-flight durable media resume. Core also claims per entry id; this
    /// stops stacking overlapping resume Tasks on flaky relay reconnects.
    private var mediaResumeTask: Task<Void, Never>?
    /// Single-flight forced gap recovery (`syncForce` + drain). Push/foreground
    /// paths share one in-flight task so rapid wakes cannot stack FETCH_TIMEOUT
    /// parks. The drained notifications are returned to awaiters (push titled
    /// local notifications) — do not drain again after join or they are lost.
    private var gapRecoveryTask: Task<[DrainNotificationInfo], Never>?
    /// Generation for `gapRecoveryTask` so a finishing older task cannot clear
    /// a newer in-flight recovery.
    private var gapRecoveryGeneration: UInt64 = 0
    /// While a push `refresh()` awaits gap recovery, polling drains that win
    /// the `drainQueue` race park their notification metadata here so
    /// `SonarPushProcessor` still gets titled local notifications (destructive
    /// drain is single-consume). Cleared when the waiter collects them.
    private var pushWakeDrainActive = false
    private var pushWakeDrainBuffer: [DrainNotificationInfo] = []
    /// Nested `refresh()` waiters share one capture window (refcount).
    private var pushWakeDrainWaiters = 0
    /// Gap-recovery drain handed to at most one `refresh()` awaiter so overlapping
    /// push wakes cannot double-post the same recovered notifications.
    private var gapRecoveryUnclaimedDrain: [DrainNotificationInfo]?
    private var relayBusy = false
    #if DEBUG
    /// SONAR_BENCH: one-shot guards for the post-connect "first wake" (T3b) and
    /// "first drain" (T4) markers. DEBUG-only (benchmark harness).
    private var benchFirstWakeLogged = false
    private var benchFirstDrainLogged = false
    /// Explicitly opt-in physical-device text-send benchmark task. The trigger
    /// is compiled out of Release builds and requires all benchmark env vars.
    private var benchSendTask: Task<Void, Never>?
    /// Explicitly opt-in physical-device sticker cache benchmark task.
    private var benchStickerTask: Task<Void, Never>?
    /// Prevent ordinary Debug picker hits from polluting benchmark captures.
    private var stickerBenchmarkRecording = false
    #endif
    /// Last locally-authoritative installed set. Generic pack metadata also
    /// contains previews/transcript packs and must never grant picker access.
    private var installedPackCoordinates: Set<String> = []
    /// npubs whose profile fetch is in flight or done. Entries older than
    /// `profileRefreshTTL` are cleared by `refreshStaleProfiles()` so updated
    /// aliases/names get re-fetched during long sessions.
    private var profileFetches: Set<String> = []
    /// Last successful kind-0 profile fetch time per npub.
    private var profileFetchedAt: [String: Date] = [:]
    /// npubs whose Sonar descriptor fetch is currently in flight.
    private var descriptorFetches: Set<String> = []
    /// Last successful relay lookup time per npub. A successful nil response is
    /// tracked via `sonarDescriptorMissesByNpub`.
    private var sonarDescriptorFetchedAtByNpub: [String: Date] = [:]
    /// Bumped on identity teardown so a descriptor fetch started under the old
    /// account cannot land — and persist — after the wipe.
    private var descriptorCacheGeneration = 0
    /// Bumped by every teardown that clears a contact cache. A deferred write
    /// that encoded before the clear is dropped instead of resurrecting erased
    /// contact data (an Account Key Durability-class failure).
    private var contactCacheWriteGeneration = 0
    /// Per-cache schedule order. Detached encodes finish out of order, so
    /// without this an older snapshot could commit after a newer one and lose
    /// the freshest profile / BOLT12 offer from disk until the next fetch.
    private var profileCacheScheduledSeq = 0
    private var profileCacheCommittedSeq = 0
    private var descriptorCacheScheduledSeq = 0
    private var descriptorCacheCommittedSeq = 0
    /// Optimistically-echoed outgoing messages per group, kept visible until
    /// the relay round-trip brings the real copy back (then reconciled away).
    private var pendingOptimistic: [String: [MarmotService.MarmotMessage]] = [:]
    /// Canonical rows that predate each optimistic echo in the local transcript.
    /// They must not be mistaken for the relay copy of a later identical send.
    private var preexistingCanonicalMessageIDsByOptimisticID: [String: Set<String>] = [:]
    private var stickerPacksByCoordinate: [String: StickerPackInfo] = [:]
    private var stickerPackLRU: [String] = []
    private var stickerImagesBySHA256: [String: Data] = [:]
    private var stickerImageLRU: [String] = []
    /// Refs the latest relay-refreshed pack does not contain. Bounded; entries
    /// stop a removed/bogus ref from re-driving eviction + relay refetch on
    /// every bubble mount, retry tick, and tap.
    private var unresolvableStickerRefKeys: [String] = []
    private var unresolvableStickerRefKeySet: Set<String> = []
    private var stickerImageMemoryBytes = 0
    private var stickerCacheGeneration: UInt64 = 0
    /// Last desired payment offer metadata for our public descriptor. Reused
    /// when other descriptor refreshes publish capabilities without changing
    /// payment state.
    private var descriptorBolt12Offer: String?
    private var conversationChangeSub: AnyCancellable?
    /// Coalesce core invalidations by group so rapid pending/ACK transitions
    /// refresh one bounded transcript page instead of rescanning every chat.
    private var pendingConversationRefreshGroups: Set<String> = []
    private var conversationRefreshTask: Task<Void, Never>?
    /// Per-group database cursor state. Folded conversations may contain more
    /// than one Marmot group, so a visible chat must never share one cursor.
    private struct LocalTranscriptCursor: Equatable {
        let beforeSecs: UInt64
        let beforeId: String
    }
    private var localTranscriptCursorByGroup: [String: LocalTranscriptCursor] = [:]
    private var localTranscriptHasOlderByGroup: [String: Bool] = [:]
    private var localTranscriptLoadingGroups: Set<String> = []
    /// Groups whose bounded cache has moved away from the newest edge. Summary
    /// refreshes must preserve their older edge or they can create a gap behind
    /// the cursor while an older-page read is suspended.
    private var localTranscriptPreservesOlderEdgeGroups: Set<String> = []
    /// Serializes outgoing sends so rapid-fire messages arrive in order.
    private var sendChain: Task<Void, Never>?
    /** Deletion increments this generation and awaits the tail task. Tasks
     * still queued behind an in-flight core call then retire without sending. */
    private var sendGeneration: UInt64 = 0
    private var sendsSuspendedForAccountMutation = false
    /// Media uploads and retries intentionally run independently from the text
    /// ordering chain, but deletion still owns and joins their lifetimes.
    private var independentAccountTasks: [UUID: Task<Void, Never>] = [:]
    /// Shared with the render window (`SNConversationTranscriptWindow`) so a
    /// reconciled echo can be recognized and dropped at that layer too.
    nonisolated static let optimisticIDPrefix = "optimistic-"
    nonisolated static let failedOptimisticIDPrefix = "failed-"

    static func stateText(for message: MarmotService.MarmotMessage) -> String? {
        guard message.isMine else { return nil }
        if message.id.hasPrefix(failedOptimisticIDPrefix) { return "Couldn't send" }
        if message.id.hasPrefix(optimisticIDPrefix) {
            return pendingOutboundStateText(hasMedia: !message.media.isEmpty, media: message.media)
        }
        if message.deliveryState == "failed" { return "Couldn't send" }
        if message.deliveryState == "pending" {
            return pendingOutboundStateText(hasMedia: !message.media.isEmpty, media: message.media)
        }
        return "Sent"
    }

    /// Image/album Blossom uploads use "Uploading" (horizontal bar). Voice notes
    /// and other non-image attachments match Signal: "Sending" + status spinner.
    private static func pendingOutboundStateText(
        hasMedia: Bool,
        media: [MarmotService.MarmotMedia]
    ) -> String {
        guard hasMedia else { return "Sending" }
        let imageUpload = media.contains(where: \.isImage)
        return imageUpload ? "Uploading" : "Sending"
    }

    static func shouldExposeCachedStickerPack(
        coordinate: String,
        installedCoordinates: Set<String>
    ) -> Bool {
        installedCoordinates.contains(snNormalizeStickerPackCoordinate(coordinate))
    }

    static func stickerCacheLookupState(
        hasData: Bool,
        startedGeneration: UInt64,
        currentGeneration: UInt64
    ) -> StickerCacheLookupState {
        guard startedGeneration == currentGeneration else { return .invalidated }
        return hasData ? .hit : .miss
    }

    /// Session key under which a sticker reference was authorized against the
    /// validated pack. Memory-first lookups are gated on this so the sha-keyed
    /// byte LRU never serves a ref that was not verified this session.
    static func stickerRefMemoryKey(
        packCoordinate: String,
        shortcode: String,
        plaintextSha256: String
    ) -> String {
        "\(snNormalizeStickerPackCoordinate(packCoordinate))|\(shortcode)|\(plaintextSha256.lowercased())"
    }

    /// Delay before retry `attempt` (0-based) of a failed transcript sticker
    /// load, or nil when attempts are exhausted. Mirrors the Compose schedule.
    static func stickerLoadRetryDelaySeconds(attempt: Int) -> Double? {
        switch attempt {
        case 0: return 2
        case 1: return 8
        default: return nil
        }
    }

    private enum CachedStickerImageResult {
        case hit(Data)
        case miss
        case invalidated
    }

    static func isFailedOptimisticMessageId(_ id: String) -> Bool {
        id.hasPrefix(failedOptimisticIDPrefix)
    }

    init(
        service: MarmotService = MarmotService(),
        keychain: KeychainManagerProtocol = KeychainManager(),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.keychain = keychain
        self.defaults = defaults
        self.profilesByNpub = SNMarmotProfileCache.load(from: defaults)
        self.sonarDescriptorsByNpub = SNMarmotDescriptorCache.load(from: defaults)
        let cached = SNMarmotChatSnapshotCache.load(from: defaults)
        self.groups = cached.0
        self.messagesByGroup = cached.1
        self.conversationChangeSub = service.conversationChanged
            .receive(on: DispatchQueue.main)
            .collect(.byTimeOrCount(DispatchQueue.main, .milliseconds(50), 128))
            .sink { [weak self] groupIds in
                Task { @MainActor [weak self] in
                    self?.scheduleConversationRefresh(groupIds: groupIds)
                }
            }
    }

    /// Connect (or reconnect after background store release): reuse the keychain
    /// identity if present. A fresh identity may be created only by explicit
    /// onboarding completion. Publishes our KeyPackage so White Noise users can
    /// start chats with us. Idempotent while connected or while a connect is
    /// already in flight (`busy`).
    func connectIfNeeded(allowCreateIdentity: Bool = false) {
        if service.isConnected() { return }
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            _ = await performConnect(allowCreateIdentity: allowCreateIdentity)
        }
    }

    /// Box + lock so an expiration handler and a closeNode completion cannot both
    /// end the same `UIBackgroundTaskIdentifier` (value-type capture race). Shared
    /// by `suspendStoreForBackground()` and `closeStoreAfterBackgroundWake()`.
    #if os(iOS)
    final class SNBackgroundTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var id = UIBackgroundTaskIdentifier.invalid
        func set(_ newId: UIBackgroundTaskIdentifier) {
            lock.lock(); id = newId; lock.unlock()
        }
        func endOnce() {
            lock.lock()
            let current = id
            id = .invalid
            lock.unlock()
            if current != .invalid {
                UIApplication.shared.endBackgroundTask(current)
            }
        }
    }
    #endif

    /// Drop the live Marmot node + App Group store lock before suspension so the
    /// NSE can acquire exclusive hydrate on Transponder push. Tor/Nostr are already
    /// dormant in background; keeping the flock would leave banners stuck on the
    /// generic NSE placeholder (no `content-available` app wake on production APNs).
    ///
    /// Uses a background task so iOS does not freeze the process mid-closeNode —
    /// a fire-and-forget Task alone often loses the race with Transponder NSE.
    func suspendStoreForBackground() {
        #if os(iOS)
        let box = SNBackgroundTaskBox()
        box.set(
            UIApplication.shared.beginBackgroundTask(withName: "sonar.marmot.storeSuspend") {
                box.endOnce()
            }
        )
        // userInitiated: flock release must beat Transponder NSE acquire
        // (default Task priority often loses the race → storeBusy generic banner).
        Task(priority: .userInitiated) { [weak self] in
            await self?.service.closeNode()
            box.endOnce()
        }
        #else
        Task { [weak self] in
            await self?.service.closeNode()
        }
        #endif
    }

    /// Awaitable sibling of `suspendStoreForBackground()` for background-wake
    /// completion (silent push): guarantees the SQLCipher handle + App Group
    /// flock are released BEFORE the caller invokes the fetch completion
    /// handler, so iOS never suspends the process holding locked files
    /// (RunningBoard 0xdead10cc). `closeNode()` is idempotent and clears its
    /// own fence, so a later foreground resume reconnects normally.
    func closeStoreAfterBackgroundWake() async {
        #if os(iOS)
        // Quiesce the drain/polling + relay-reconnect machinery BEFORE the
        // close: the wake's ensureConnected() ran performConnect →
        // startPolling(), and after closeNode() the polling loop's
        // ensureSubscriptions error path schedules scheduleRelayConnect(),
        // which would reopen the SQLCipher store while still backgrounded —
        // re-exposing the 0xdead10cc kill this close exists to prevent.
        // Foreground resume restarts polling via view onAppear/performConnect.
        // refreshTask is deliberately left running: it may be a legitimate
        // foreground resume that reconnectIfForegroundAfterWakeClose settles.
        syncTask?.cancel()
        syncTask = nil
        relayConnectTask?.cancel()
        relayConnectTask = nil
        // Hold a background task across the close, exactly like
        // `suspendStoreForBackground()`. The push wake abandons its wait on this
        // call once its deadline expires so it can return the fetch completion
        // handler on time; without this, that early return would let iOS suspend
        // the process with the SQLCipher store still open and the flock held —
        // the 0xdead10cc kill. With it, iOS keeps us alive until the close lands.
        //
        // The flock is deliberately NOT released ahead of `closeNode()`. The NSE
        // opens its own `SonarNode` on this same store the moment it wins the
        // flock (`NotificationService.collectMarmotNotificationsAfterWake`), and
        // that path drains MLS events — two processes committing against one
        // store can fork group state. `NotificationService` states the contract
        // directly: never unlock under an open handle. Releasing early would
        // trade a background kill for a corrupted MLS store, which is worse.
        let box = SNBackgroundTaskBox()
        box.set(
            UIApplication.shared.beginBackgroundTask(withName: "sonar.marmot.wakeClose") {
                box.endOnce()
            }
        )
        await service.closeNode()
        box.endOnce()
        #endif
    }

    /// Post-close recheck for the push-wake path. If the user foregrounded
    /// WHILE `closeNode()` was draining, the scene-phase resume already
    /// started a refresh whose connect attempt was rejected behind the
    /// `nodeClosing` fence — and `refreshAfterForeground()`'s single-flight
    /// latch would discard a plain re-kick while that doomed task is still
    /// polling toward its timeout. Settle the in-flight refresh first, then
    /// re-kick only when the app is foreground AND still disconnected.
    func reconnectIfForegroundAfterWakeClose() async {
        #if os(iOS)
        if let existing = refreshTask {
            _ = await existing.value
        }
        guard UIApplication.shared.applicationState != .background else { return }
        guard !service.isConnected() else { return }
        refreshAfterForeground()
        #endif
    }

    func prepareIdentityForOnboarding() async -> Bool {
        if npub != nil || service.isConnected() { return true }
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        return await performConnect(allowCreateIdentity: true)
    }

    /// The actual connect sequence (awaitable, NOT guarded). Reuse the keychain
    /// identity, open the encrypted DB, hydrate the bounded local Home window,
    /// then schedule relay setup behind that first-paint boundary. Used by the lazy
    /// `connectIfNeeded()` and the erase-and-reconnect path —
    /// the latter must NOT be blocked by the `busy`/`npub` guard, which would
    /// silently leave the node disconnected ("not connected yet" until restart).
    private func performConnect(allowCreateIdentity: Bool = false) async -> Bool {
        // A keychain/DB failure must reveal the cached fallback instead of
        // leaving the app's launch surface visible forever.
        defer { initialLocalHomeReady = true }
        // Read the persisted nsec SAFELY: transient read failures (e.g. device
        // LOCKED during a background BLE wake) must never generate a replacement
        // key. Even a genuine miss only creates a key during explicit onboarding.
        // Otherwise setup retries once the existing key is accessible (#13).
        var storedNsec: String?
        #if DEBUG
        let benchNsec = ProcessInfo.processInfo.environment["SONAR_BENCH_NSEC"]
        #else
        let benchNsec: String? = nil
        #endif
        if let benchNsec, !benchNsec.isEmpty {
            // SONAR_BENCH: deterministic provisioning for the cold-start benchmark.
            // Adopt the env identity WITHOUT depending on Keychain — unsigned
            // simulator builds get errSecMissingEntitlement (-34018), which would
            // otherwise early-return below and the relay-sync path would never run.
            // Simulator only / throwaway data — never set this env in production.
            storedNsec = benchNsec
            _ = keychain.saveIdentityKey(Data(benchNsec.utf8), forKey: Self.nsecKeychainKey)
            SecureLogger.info("SONAR_BENCH identity from env (keychain-independent)", category: .session)
        } else {
            switch keychain.getIdentityKeyWithResult(forKey: Self.nsecKeychainKey) {
            case .success(let data):
                storedNsec = String(data: data, encoding: .utf8)
                // Refresh data through the non-destructive save path. Existing
                // Keychain accessibility is immutable via SecItemUpdate; new
                // items use AfterFirstUnlockThisDeviceOnly.
                if let s = storedNsec { _ = keychain.saveIdentityKey(Data(s.utf8), forKey: Self.nsecKeychainKey) }
            case .itemNotFound:
                guard allowCreateIdentity else {
                    SecureLogger.warning("⚠️ marmot-nsec missing after onboarding — refusing to create a replacement identity", category: .session)
                    self.errorText = "Account key missing. Restore from your backup key."
                    return false
                }
                storedNsec = nil
            case .accessDenied, .deviceLocked, .authenticationFailed, .otherError:
                SecureLogger.warning("⚠️ marmot-nsec not readable yet (device locked?) — deferring identity", category: .session)
                return false
            }
        }
        // 1) Publish our npub IMMEDIATELY — the identity pubkey is offline-
        //    derivable, so Sonar discovery (0x53) can advertise it without
        //    waiting on (or being blocked by) the relay connect. Persist a
        //    freshly-generated nsec so `connect` below reuses the same identity.
        do {
            let np = try await service.loadIdentityNpub(nsec: storedNsec)
            if storedNsec == nil {
                guard let fresh = await service.exportNsec() else {
                    self.errorText = "Couldn't create account key. Try again."
                    SecureLogger.error("Generated identity could not export marmot-nsec", category: .keychain)
                    self.npub = nil
                    return false
                }
                guard keychain.saveIdentityKey(Data(fresh.utf8), forKey: Self.nsecKeychainKey) else {
                    self.errorText = "Couldn't save account key. Try again."
                    SecureLogger.error("Failed to persist newly generated marmot-nsec", category: .keychain)
                    self.npub = nil
                    return false
                }
                storedNsec = fresh
            }
            self.npub = np
        } catch {
            let desc = Self.describe(error)
            SecureLogger.warning("⚠️ Marmot identity load failed: \(desc)", category: .session)
            self.errorText = desc
            return false
        }
        // 2) Open the encrypted DB with no relays first → load LOCAL chats right
        //    away → then attach real relays in the background. A relay publish
        //    failure must NOT hide already-persisted chats.
        do {
            _ = try await service.connectLocal(nsec: storedNsec)
            relayConnected = false
            // Publish one coherent, bounded local Home model before the root
            // view becomes visible. This reads no relay and performs no sync.
            await loadLocalSummaries(resolveMembers: false)
            #if DEBUG
            // SONAR_BENCH: local-first paint ready — row previews/order hydrated
            // from the encrypted DB before any relay attach (T1).
            SecureLogger.info("SONAR_BENCH t1_local_paint groups=\(groups.count)", category: .session)
            #endif
            self.errorText = nil
            scheduleRelayConnect(delaySeconds: 0.25)
            return true
        } catch {
            let desc = Self.describe(error)
            SecureLogger.warning("⚠️ Marmot local open failed: \(desc)", category: .session)
            self.errorText = desc
            return false
        }
    }

    /// `nsec1…` backup of the connected identity, for the "Export private key"
    /// self-custody escape hatch. Prefers keychain (Compose secrets parity)
    /// so callers never wait on Marmot `workQueue` sync/connect.
    func exportNsec() async -> String? {
        await SonarAccountKeyExport.exportNsec(keychain: keychain) {
            await service.exportNsec()
        }
    }

    /// Relay/sync diagnostics snapshot JSON for the Diagnostics screen and
    /// debug bundle. Nil before the relay node is connected.
    func syncStateSnapshotJson() async -> String? {
        await service.syncStateSnapshotJson()
    }

    /// Restore an existing identity from a pasted `nsec1…` backup (onboarding
    /// "I already have a key"): validate it, persist it as THE identity, then
    /// connect as it. Throws on an invalid key so the caller can surface it.
    /// When a Blossom account backup exists for this nsec, Marmot chats are
    /// restored before reconnect; otherwise chats start empty.
    @discardableResult
    func restoreIdentity(nsec raw: String) async throws -> AccountBackupRestoreOutcome {
        let nsec = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate without mutating the live service. A failed import must leave
        // the currently connected identity and its local database untouched.
        _ = try SonarIdentity.import(nsec: nsec)
        // Retain the previous account key only in memory until the replacement
        // local database is open. If that final commit step fails, restore the
        // old identity instead of returning an error with a half-switched account.
        let previousNsec = await service.exportNsec()
            ?? keychain.getIdentityKey(forKey: Self.nsecKeychainKey)
                .flatMap { String(data: $0, encoding: .utf8) }
        // Block connectIfNeeded while the old node, database, and identity-bound
        // caches are invalidated and the replacement identity is connected.
        busy = true
        defer { busy = false }
        // Identity restore is an account replacement, not a reconnect. Match
        // the Compose import path: invalidate memory first, then wipe the old
        // core database (including its sticker caches) before opening the new
        // account. The generation bump prevents an in-flight image read from
        // repopulating old bytes while the disk wipe is awaiting completion.
        let service = self.service
        do {
            try await prepareForIdentityReplacement {
                try await service.wipeDatabase()
            }
        } catch {
            _ = await performConnect()
            throw error
        }
        // Commit the replacement identity only after the old account's durable
        // state has been removed successfully.
        guard keychain.saveIdentityKey(Data(nsec.utf8), forKey: Self.nsecKeychainKey) else {
            _ = await performConnect()
            throw MarmotService.ServiceError.core("failed to persist restored identity")
        }
        let backupOutcome = await service.tryRestoreAccountFromBlossom(nsec: nsec)
        // Drive the full local-first connect sequence directly; performConnect
        // reads the nsec persisted above and opens the restored or fresh DB.
        guard await performConnect() else {
            let replacementError = errorText ?? "failed to connect restored identity"
            // A committed Blossom restore already wrote live ciphertext under the
            // new nsec. Wiping / deleting that nsec would permanently lose chats
            // (and violate Account Key Durability on first-time import).
            if backupOutcome == .restored {
                throw MarmotService.ServiceError.core(replacementError)
            }
            // A failed local open may have installed the replacement identity in
            // memory or left a partial SQLite store. Tear it down before restoring
            // the prior key so callers never observe an account/key mismatch.
            do {
                try await prepareForIdentityReplacement {
                    try await service.wipeDatabase()
                }
            } catch {
                throw MarmotService.ServiceError.core(
                    "\(replacementError); failed to roll back replacement storage"
                )
            }
            let keyRestored: Bool
            if let previousNsec {
                keyRestored = keychain.saveIdentityKey(
                    Data(previousNsec.utf8),
                    forKey: Self.nsecKeychainKey
                )
            } else {
                // Never delete a freshly persisted nsec on first-time restore —
                // surface the connect error and keep the account key durable.
                keyRestored = true
            }
            guard keyRestored else {
                throw MarmotService.ServiceError.core(
                    "\(replacementError); failed to restore the previous account key"
                )
            }
            if previousNsec != nil {
                _ = await performConnect()
            }
            throw MarmotService.ServiceError.core(replacementError)
        }
        return backupOutcome
    }

    /// Upload an encrypted Marmot account backup to Blossom, then reconnect.
    ///
    /// Always reconnects after the upload attempt — Compose `backupAccountNow`
    /// always `boot()`s so a failed Blossom call cannot leave the node closed
    /// (Settings tap would look dead and chats stay offline until restart).
    func backupAccount() async throws {
        // `@MainActor` serializes check-then-set; Settings taps share this actor.
        guard !accountBackupInFlight else {
            throw MarmotService.ServiceError.backupAlreadyInProgress
        }
        accountBackupInFlight = true
        defer { accountBackupInFlight = false }

        let wasPolling = syncTask != nil
        // Raise `busy` before stopping poll/relay so an in-flight
        // `connectRelaysIfNeeded` body sees the fence and bails before reopen.
        busy = true
        defer { busy = false }
        stopPolling()
        if !(await awaitRelayIdleForBackup()) {
            SecureLogger.warning(
                "⚠️ Account backup proceeding while relay still busy after drain timeout",
                category: .session
            )
        }

        var uploadError: Error?
        do {
            _ = try await service.uploadAccountBackup()
        } catch {
            uploadError = error
        }
        let reconnected = await performConnect()
        // Clear busy before relay attach: `performConnect` schedules
        // `connectRelaysIfNeeded` with a short delay that no-ops while `busy`,
        // which would leave a local-only node after Settings backup.
        // (`defer` also clears if we're cancelled mid-`performConnect`.)
        busy = false
        if reconnected {
            connectRelaysIfNeeded()
        }
        if wasPolling { startPolling() }
        let outcome = MarmotAccountBackupFlow.outcome(
            uploadSucceeded: uploadError == nil,
            reconnected: reconnected
        )
        if outcome.shouldSurfaceUploadFailure, let uploadError {
            throw uploadError
        }
        if outcome.shouldSurfaceReconnectFailure {
            throw MarmotService.ServiceError.core(errorText ?? "failed to reconnect after backup")
        }
    }

    /// Best-effort drain of an in-flight relay attach before `closeNode` +
    /// WAL checkpoint (Compose cancels and joins relay jobs before FFI).
    /// Returns `false` when the timeout elapsed while `relayBusy` stayed true
    /// (caller still proceeds — closeNode fences new attach — but logs).
    @discardableResult
    private func awaitRelayIdleForBackup(timeoutSeconds: Double = 3) async -> Bool {
        let start = Date()
        while relayBusy && Date().timeIntervalSince(start) < timeoutSeconds {
            if Task.isCancelled { return !relayBusy }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !relayBusy
    }

    /// Await until the Marmot node is connected (or a short timeout), kicking
    /// off a connect if none is in flight. Lets start/send wait through the
    /// reconnect window (e.g. right after "erase all chats" or a cold launch)
    /// instead of immediately surfacing "not connected yet".
    func ensureConnected(timeoutSeconds: Double = 10) async -> Bool {
        if service.isConnected() { return true }
        if !busy { connectIfNeeded() }
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            // Honor cancellation: the push-wake rerun deadline relies on it
            // (withTimeout's group waits for the child after cancelAll()).
            if Task.isCancelled { return false }
            if service.isConnected() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return service.isConnected()
    }

    private func scheduleRelayConnect(delaySeconds: Double = 2) {
        guard relayConnectTask == nil else { return }
        relayConnectTask = Task { [weak self] in
            let nanos = UInt64(max(0, delaySeconds) * 1_000_000_000)
            if nanos > 0 {
                try? await Task.sleep(nanoseconds: nanos)
            }
            guard !Task.isCancelled else { return }
            self?.connectRelaysIfNeeded()
            self?.relayConnectTask = nil
        }
    }

    private func scheduleResumePendingMediaUploads() {
        guard mediaResumeTask == nil else { return }
        mediaResumeTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    self?.mediaResumeTask = nil
                }
            }
            guard let self else { return }
            try? await self.service.resumePendingMediaUploads()
        }
    }

    private func registerMediaUploadListener(_ id: String, _ listener: SNMediaUploadListener) {
        mediaUploadListeners[id]?.cancel()
        mediaUploadListeners[id] = listener
    }

    private func clearMediaUploadListener(_ id: String) {
        mediaUploadListeners.removeValue(forKey: id)
        noteMediaUploadProgress(id, nil)
    }

    private func noteMediaUploadProgress(_ id: String, _ fraction: Double?) {
        if let fraction {
            #if DEBUG
            // Milestone logs for device upload timing (pair with media_upload_begin/end).
            if fraction <= 0.001 {
                SecureLogger.info(
                    "SONAR_BENCH media_upload_progress id=\(id) fraction=0",
                    category: .session
                )
            } else if fraction >= 0.999 {
                SecureLogger.info(
                    "SONAR_BENCH media_upload_progress id=\(id) fraction=1",
                    category: .session
                )
            }
            #endif
            mediaUploadProgressSource.note(id: id, fraction: fraction)
            var next = mediaUploadProgress
            next[id] = fraction
            mediaUploadProgress = next
        } else {
            mediaUploadProgressSource.clear(id: id)
            var next = mediaUploadProgress
            next.removeValue(forKey: id)
            mediaUploadProgress = next
        }
    }

    /// Cancel an in-flight Blossom upload for the optimistic bubble [pendingId].
    /// Drops the optimistic row immediately; core abandons Blossom + staging.
    func cancelMediaUpload(pendingId: String) {
        mediaUploadListeners[pendingId]?.cancel()
        noteMediaUploadProgress(pendingId, nil)
        for (groupId, pending) in pendingOptimistic {
            guard pending.contains(where: { $0.id == pendingId }) else { continue }
            discardOptimistic(id: pendingId, from: groupId)
            break
        }
    }

    private static func isMediaUploadCancelled(_ error: Error) -> Bool {
        let detail: String
        if let service = error as? MarmotService.ServiceError {
            switch service {
            case .core(let message), .invalidInput(let message):
                detail = message
            case .cancelled:
                return true
            case .notConnected, .backupAlreadyInProgress:
                return false
            }
        } else {
            detail = error.localizedDescription
        }
        return detail.localizedCaseInsensitiveContains("upload cancelled")
    }

    /// Core returned `MediaUploadInFlight` — another worker owns this optimistic id.
    private static func isMediaUploadInFlight(_ error: Error) -> Bool {
        let detail: String
        if let service = error as? MarmotService.ServiceError {
            switch service {
            case .core(let message), .invalidInput(let message):
                detail = message
            default:
                return false
            }
        } else {
            detail = error.localizedDescription
        }
        return detail.localizedCaseInsensitiveContains("already in flight")
    }

    /// Core aborted this call because the node is being closed for background
    /// suspension (R-016), not because the relay failed. Must never reach
    /// `errorText`: the app is on its way to the background, the sync watermark
    /// was not advanced, and the next foreground resume or push wake re-runs it.
    /// Matches the message because `SonarFfiError` is a flat error — the marker
    /// is `SUSPEND_INTERRUPT_MARKER` in `core/sonar-ffi/src/lib.rs`.
    private static func isSuspendInterrupted(_ error: Error) -> Bool {
        let detail: String
        if let service = error as? MarmotService.ServiceError {
            switch service {
            case .core(let message), .invalidInput(let message):
                detail = message
            default:
                return false
            }
        } else {
            detail = error.localizedDescription
        }
        return detail.localizedCaseInsensitiveContains("interrupted for suspend")
    }

    private func connectRelaysIfNeeded() {
        // Identity backup/restore holds `busy` with the node closed — do not
        // reopen the DB underneath a staged restore or in-flight upload.
        guard !busy, !relayBusy else { return }
        relayConnectTask?.cancel()
        relayConnectTask = nil
        relayBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.relayBusy = false }
            guard !self.busy else { return }
            do {
                self.relayConnected = false
                #if DEBUG
                // SONAR_BENCH: relay attach begins (T2). connect() returns once
                // relays are quorum-connected (not after sync).
                SecureLogger.info("SONAR_BENCH t2_relay_connect_begin", category: .session)
                #endif
                _ = try await self.service.connect(nsec: nil)
                #if DEBUG
                // SONAR_BENCH: relays quorum-connected (T3). Marmot events now
                // flow into the background buffer and are applied by the drain loop.
                SecureLogger.info("SONAR_BENCH t3_relay_connected", category: .session)
                #endif
                self.errorText = nil
                // Mirror the service latch rather than assuming true: a
                // background invalidate landing mid-attach leaves it down (see
                // RelayConnectionPolicy.latchAfterAttach), and this published
                // flag gates reachability + the online chip in SonarAppStore.
                self.relayConnected = self.service.isRelayConnected()
                // Start the drain loop BEFORE any publish: message receive must
                // never wait on identity publishes. The publishes below used to
                // hold the serial engine queue for their per-relay OK waits and
                // delayed the first drain by ~50s on device (t3→t3a).
                self.startPolling()
                // Resume durable pre-Blossom media staging (mid-upload kill /
                // disconnect). Does not block cold start; Blossom itself does
                // not need the relay, but publish still uses the outbox.
                self.scheduleResumePendingMediaUploads()
                try? await self.service.publishKeyPackageBackground()
                // After nsec restore the local nick/handle sidecars are empty.
                // Fetch our own kind-0 first so the host can adopt name + nip05
                // before any republish — publishing blank/stale metadata would
                // replace the durable relay profile.
                let safeToPublish = await self.hydrateOwnProfileFromRelays()
                // Republish our kind-0 profile here too (not just on the npub
                // signal / rename): the KeyPackage lands reliably on every relay
                // connect, but the profile previously did not, so peers saw our
                // raw npub when the opportunistic publish lost the relay /
                // onboarding race. Keep them in lockstep. Never publish a blank
                // name or before the handle sidecar is seeded (would wipe
                // relay metadata / nip05).
                if safeToPublish,
                   let name = self.profileNameProvider?()
                    .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    try? await self.service.publishProfileBackground(name: name)
                }
                #if DEBUG
                // SONAR_BENCH: KeyPackage + profile publish ENQUEUED (T3a). The
                // relay sends complete in the background inside the core; this
                // marker now measures event creation, not relay OK acks (see
                // docs/PERFORMANCE.md).
                SecureLogger.info("SONAR_BENCH t3a_published", category: .session)
                self.startSendBenchmarkIfRequested()
                self.startStickerBenchmarkIfRequested()
                #endif
            } catch MarmotService.ServiceError.cancelled {
                self.relayConnected = false
                return
            } catch {
                self.relayConnected = false
                // Same terminal rule as the polling loop: `connect()` finishes
                // with a (suspendable) `retryOutbox()`, so a background
                // transition mid-connect surfaces the marker here. Retrying
                // would reopen the SQLCipher store after `closeNode()` clears
                // `nodeClosing`, while still backgrounded.
                if Self.isSuspendInterrupted(error) { return }
                let desc = Self.describe(error)
                SecureLogger.warning("⚠️ Marmot relay connect failed: \(desc)", category: .session)
                self.errorText = desc
                self.scheduleRelayConnect(delaySeconds: Self.relayReconnectRetryDelaySeconds)
            }
        }
    }

    func ensureRelayConnected(timeoutSeconds: Double = 10) async -> Bool {
        if service.isRelayConnected() { return true }
        connectRelaysIfNeeded()
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            // Honor cancellation: see ensureConnected — the wake rerun
            // deadline propagates through withTimeout's cancelAll().
            if Task.isCancelled { return false }
            if service.isRelayConnected() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return service.isRelayConnected()
    }

    /// Drop the host-side relay latch (see `MarmotService.invalidateRelayConnection`).
    func invalidateRelayConnection() {
        service.invalidateRelayConnection()
        relayConnected = false
    }

    #if DEBUG
    /// Run an explicitly requested text-send benchmark through the same model
    /// path as the composer. CoreDevice can supply these variables with
    /// `devicectl device process launch --environment-variables`; Release
    /// builds contain neither the trigger nor its message loop.
    private func startSendBenchmarkIfRequested() {
        guard benchSendTask == nil else { return }
        let environment = ProcessInfo.processInfo.environment
        guard
            let rawCount = environment["SONAR_BENCH_SEND_COUNT"],
            let count = Int(rawCount),
            (1...500).contains(count),
            let rawTarget = environment["SONAR_BENCH_SEND_TARGET"]
        else { return }

        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        let prefix = environment["SONAR_BENCH_SEND_PREFIX"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safePrefix = prefix.flatMap { $0.isEmpty ? nil : $0 } ?? "SONAR_BENCH_SEND"

        benchSendTask = Task { [weak self] in
            guard let self else { return }
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            #endif
            // Let KeyPackage/profile background publishes leave the fast relay
            // path before measuring user messages.
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            let deadline = Date().addingTimeInterval(30)
            var destination: MarmotService.MarmotGroup?
            while destination == nil, Date() < deadline, !Task.isCancelled {
                await self.loadLocalSummaries(resolveMembers: true)
                let matches = self.groups.filter { group in
                    group.name.localizedCaseInsensitiveCompare(target) == .orderedSame
                        || self.title(for: group)
                            .localizedCaseInsensitiveCompare(target) == .orderedSame
                }
                guard matches.count < 2 else {
                    SecureLogger.warning(
                        "SONAR_BENCH send_batch_target_ambiguous",
                        category: .session
                    )
                    return
                }
                destination = matches.first
                if destination == nil {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }

            guard let destination else {
                SecureLogger.warning(
                    "SONAR_BENCH send_batch_target_not_found",
                    category: .session
                )
                return
            }

            let runID = String(UUID().uuidString.prefix(8))
            var dispatched = 0
            for sample in 1...count where !Task.isCancelled {
                let label = String(
                    format: "%@ %@ %02d/%02d",
                    safePrefix,
                    runID,
                    sample,
                    count
                )
                // Match the composer path exactly. Completion is determined from
                // the core local-persist + first-ACK markers, not the model's
                // shared errorText (which can also be changed by background sync).
                self.send(label, to: destination.id)
                dispatched += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if let finalSend = self.sendChain {
                _ = await finalSend.result
            }
            SecureLogger.info(
                "SONAR_BENCH send_batch_finished requested=\(count) dispatched=\(dispatched)",
                category: .session
            )
        }
    }

    /// Exercise the production host/core cache ladder without installing a
    /// pack or erasing account data. The exact pack address must be supplied by
    /// the Debug launcher so this cannot become a user-visible fallback pack.
    private func startStickerBenchmarkIfRequested() {
        guard benchStickerTask == nil else { return }
        let environment = ProcessInfo.processInfo.environment
        guard
            environment["SONAR_BENCH_STICKERS"] == "1",
            let rawAuthor = environment["SONAR_BENCH_STICKER_AUTHOR"],
            let rawIdentifier = environment["SONAR_BENCH_STICKER_IDENTIFIER"]
        else { return }
        let author = rawAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty, !identifier.isEmpty else { return }
        let imageLimit = min(
            max(Int(environment["SONAR_BENCH_STICKER_IMAGE_LIMIT"] ?? "8") ?? 8, 1),
            20
        )
        let imageOffset = max(
            Int(environment["SONAR_BENCH_STICKER_IMAGE_OFFSET"] ?? "0") ?? 0,
            0
        )
        let relayUrls = environment["SONAR_BENCH_STICKER_RELAYS"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        let restoreCoreVerbose = SonarDiagnostics.verboseEnabled
        SonarDiagnostics.setCoreBenchmarkVerbose(true)
        benchStickerTask = Task { [weak self] in
            defer { SonarDiagnostics.setCoreBenchmarkVerbose(restoreCoreVerbose) }
            guard let self else { return }
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            #endif
            let totalStarted = DispatchTime.now().uptimeNanoseconds
            SecureLogger.info(
                "SONAR_BENCH device_sticker_batch_begin image_limit=\(imageLimit) " +
                    "image_offset=\(imageOffset)",
                category: .session
            )

            let cacheKey = "30031:\(author.lowercased()):\(identifier)"
            self.stickerPacksByCoordinate.removeValue(forKey: cacheKey)
            self.stickerPackLRU.removeAll { $0 == cacheKey }
            self.clearStickerImageMemoryCache()
            let pack: StickerPackInfo
            do {
                pack = try await self.service.fetchStickerPack(
                    authorPubkeyHex: author,
                    identifier: identifier,
                    relayUrls: relayUrls
                )
                self.rememberStickerPack(pack, cacheKey: cacheKey)
            } catch {
                SecureLogger.warning(
                    "SONAR_BENCH device_sticker_batch_failed phase=pack_fetch " +
                        "error=\(String(describing: type(of: error)))",
                    category: .session
                )
                return
            }
            let stickers = Array(pack.stickers.dropFirst(imageOffset).prefix(imageLimit))
            guard !stickers.isEmpty else {
                SecureLogger.warning(
                    "SONAR_BENCH device_sticker_batch_failed phase=empty_pack",
                    category: .session
                )
                return
            }

            func fetchPass() async -> Int {
                var loaded = 0
                for sticker in stickers {
                    if await self.fetchStickerImage(
                        url: sticker.url,
                        expectedSha256: sticker.sha256
                    ) != nil {
                        loaded += 1
                    }
                }
                return loaded
            }

            self.stickerBenchmarkRecording = true
            defer { self.stickerBenchmarkRecording = false }
            let initial = await fetchPass() // network on cold cache, disk otherwise
            let memory = await fetchPass()  // host LRU
            self.clearStickerImageMemoryCache()
            let disk = await fetchPass()    // verified Rust disk cache
            self.clearStickerImageMemoryCache()
            var refs = 0
            for sticker in stickers {
                let ref = MarmotService.MarmotStickerRef(
                    packCoordinate: pack.packCoordinate,
                    shortcode: sticker.shortcode,
                    plaintextSha256: sticker.sha256
                )
                if await self.stickerData(for: ref) != nil { refs += 1 }
            }
            let totalMicroseconds = (DispatchTime.now().uptimeNanoseconds - totalStarted) / 1_000
            SecureLogger.info(
                "SONAR_BENCH device_sticker_batch_finished stickers=\(stickers.count) " +
                    "image_offset=\(imageOffset) " +
                    "initial=\(initial) memory=\(memory) disk=\(disk) refs=\(refs) " +
                    "total_us=\(totalMicroseconds)",
                category: .session
            )
        }
    }
    #endif

    /// Re-establish relay subscriptions and catch up on missed events after the
    /// app returns to foreground. iOS tears down TCP connections in background;
    /// nostr-sdk may auto-reconnect the sockets, but the Marmot subscription
    /// filters can be stale.
    ///
    /// Android parity: paint from the live drain lane immediately; never gate
    /// the chat list / transcript on `syncForce` (FETCH_TIMEOUT). Gap recovery
    /// is single-flight in the background; `conversationChanged` + the polling
    /// drain loop repaint as rows land in local storage.
    func refreshAfterForeground() {
        // Single-flight: if a foreground/push-tap catch-up is already running,
        // let it finish instead of starting a second one. Both the scenePhase
        // transition and a notification tap can call this; without coalescing
        // they double-enqueue syncForce() on the serial engine queue and the
        // first completion clears syncingInFlight while the other still runs.
        if let existing = refreshTask, !existing.isCancelled {
            return
        }
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.refreshTask = nil }
            guard await self.ensureConnected() else { return }
            self.syncingInFlight = true
            defer { self.syncingInFlight = false }
            guard await self.ensureRelayConnected() else {
                await self.loadLocalSummaries()
                return
            }
            try? await self.service.ensureSubscriptions()
            try? await self.service.drainPending()
            await self.loadLocalSummaries()
            // Route the actual gap-recovery sync through the shared
            // single-flight gate so a concurrent push-wake `refresh()` cannot
            // double-enqueue `syncForce()` on the serial engine queue. Awaiting
            // here keeps the passive indicator active through the real work;
            // local paint remains independent and already completed above.
            _ = await self.ensureGapRecovery().value
        }
    }

    /// Prefer cold-start historical catch-up for the open chat (MLS group id).
    /// Local-first: never blocks paint/send. Empty/nil clears preference.
    func preferCatchupGroup(_ groupId: String?) async {
        await service.preferCatchupGroup(groupId)
    }

    func beginPushWakeNotificationOwnership() {
        pushWakeOwnershipCount += 1
        pushWakeOwnsNotifications = true
        if pushWakeOwnershipCount == 1 {
            pushWakeNotifiedMessageIDs = []
            pushWakeNotifiedGroupIds = []
        }
    }

    func endPushWakeNotificationOwnership() {
        pushWakeOwnershipCount = max(0, pushWakeOwnershipCount - 1)
        let stillOwned = pushWakeOwnershipCount > 0
        pushWakeOwnsNotifications = stillOwned
        if !stillOwned {
            // Live `$messagesByGroup` sink early-returns while owned; bump so
            // SonarAppStore re-runs the processor for any unsuppressed rows.
            pushWakeLiveCatchUpGeneration &+= 1
        }
    }

    /// Record that push wake already bannered the local rows matching a drain
    /// notification (preview may be core-truncated with `…`).
    func notePushWakeNotified(drain notif: DrainNotificationInfo) {
        // Prefer exact message id from core (R-004) — no preview scan needed.
        if !notif.messageIdHex.isEmpty {
            pushWakeNotifiedMessageIDs.insert(notif.messageIdHex)
            if !notif.groupIdHex.isEmpty {
                pushWakeNotifiedGroupIds.insert(notif.groupIdHex)
            }
            return
        }

        let preview = notif.contentPreview
        let hasGroupName = !notif.groupName.isEmpty
        let hasSender = !notif.senderNpub.isEmpty
        // DMs often ship empty groupName from core (`unwrap_or("")`). Without a
        // sender or name anchor, refuse to scan every chat for preview match.
        guard hasGroupName || hasSender else { return }

        for (groupId, messages) in messagesByGroup {
            if hasGroupName {
                let title = groups.first(where: { $0.id == groupId }).map { self.title(for: $0) } ?? ""
                let summaryName = conversationSummariesByGroup[groupId]?.name ?? ""
                if title != notif.groupName && summaryName != notif.groupName {
                    continue
                }
            }
            var matched = false
            for message in messages where !message.isMine {
                if hasSender && message.senderNpub != notif.senderNpub {
                    continue
                }
                if SonarPushWakeDedup.matchesPreview(fullContent: message.content, preview: preview) {
                    pushWakeNotifiedMessageIDs.insert(message.id)
                    matched = true
                }
            }
            if matched {
                pushWakeNotifiedGroupIds.insert(groupId)
            }
        }
    }

    /// Record that push wake bannered the latest unread advance for a group.
    func notePushWakeNotified(groupIdHex: String, content: String) {
        pushWakeNotifiedGroupIds.insert(groupIdHex)
        guard let messages = messagesByGroup[groupIdHex] else { return }
        if let match = messages.last(where: {
            !$0.isMine && SonarPushWakeDedup.matchesPreview(fullContent: $0.content, preview: content)
        }) {
            pushWakeNotifiedMessageIDs.insert(match.id)
            return
        }
        if let latest = messages.last(where: { !$0.isMine }) {
            pushWakeNotifiedMessageIDs.insert(latest.id)
        }
    }

    /// True when push wake already bannered the current unread tip for this group.
    func pushWakeAlreadyNotifiedLatest(groupIdHex: String, content: String) -> Bool {
        guard let messages = messagesByGroup[groupIdHex] else { return false }
        if let match = messages.last(where: {
            !$0.isMine && SonarPushWakeDedup.matchesPreview(fullContent: $0.content, preview: content)
        }) {
            return pushWakeNotifiedMessageIDs.contains(match.id)
        }
        if let latest = messages.last(where: { !$0.isMine }) {
            return pushWakeNotifiedMessageIDs.contains(latest.id)
        }
        return false
    }

    /// Best-effort local hydration for screen open paths. This never waits for
    /// relay connect/sync; if the encrypted DB is not open yet, connectIfNeeded()
    /// continues opening it in the background.
    func loadLocalIfConnected(groupId: String? = nil) async {
        guard service.isConnected() else {
            connectIfNeeded()
            return
        }
        await loadLocalWindow(groupId: groupId, mode: .newestPage)
    }

    /// Wait only for the local Marmot node/DB to open, then hydrate local state.
    /// This deliberately performs no relay sync.
    @discardableResult
    func loadLocalWhenConnected(groupId: String? = nil, timeoutSeconds: Double = 10) async -> Bool {
        guard await ensureConnected(timeoutSeconds: timeoutSeconds) else { return false }
        await loadLocalWindow(groupId: groupId, mode: .newestPage)
        return true
    }

    /// Background reconciliation for open chats. Kept separate from local
    /// hydration so relay sync cannot gate first paint.
    func refreshWhenConnected(groupId: String? = nil, hydrateBeforeSync: Bool = true) async {
        guard await ensureConnected() else { return }
        if hydrateBeforeSync {
            await loadLocalWindow(groupId: groupId, mode: .newestPage)
        }
        if await ensureRelayConnected() {
            do {
                try await service.syncOnce()
                self.errorText = nil
            } catch {
                // A suspend abort is not a relay failure — leave the banner alone.
                if !Self.isSuspendInterrupted(error) {
                    self.errorText = Self.describe(error)
                }
            }
            let notifications = (try? await service.drainPending()) ?? []
            if !notifications.isEmpty {
                await loadLocalWindow(groupId: groupId, mode: .preserveHistoricalWindow)
                return
            }
        }
        await loadLocalWindow(groupId: groupId, mode: .preserveHistoricalWindow)
    }

    private func loadLocalWindow(
        groupId: String?,
        mode: LocalTranscriptLoadMode
    ) async {
        if let groupId {
            await loadLocalPage(groupId: groupId, mode: mode)
        } else {
            await loadLocalSummaries()
        }
    }

    /// Load groups + messages from the LOCAL encrypted DB only (no relay I/O),
    /// so the chat list paints instantly on launch regardless of relay health.
    func loadLocal() async {
        await loadLocalSummaries()
    }

    private func scheduleConversationRefresh(groupIds: [String]) {
        pendingConversationRefreshGroups.formUnion(groupIds)
        guard conversationRefreshTask == nil else { return }
        conversationRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !self.pendingConversationRefreshGroups.isEmpty, !Task.isCancelled {
                let groups = self.pendingConversationRefreshGroups
                self.pendingConversationRefreshGroups.removeAll(keepingCapacity: true)
                var deferredBusyGroup = false
                for changedGroupId in groups {
                    if self.localTranscriptLoadingGroups.contains(changedGroupId) {
                        self.pendingConversationRefreshGroups.insert(changedGroupId)
                        deferredBusyGroup = true
                        continue
                    }
                    if self.groups.contains(where: { $0.id == changedGroupId })
                        || self.messagesByGroup[changedGroupId] != nil {
                        _ = await self.loadLocalPage(
                            groupId: changedGroupId,
                            mode: .preserveHistoricalWindow
                        )
                    } else {
                        // A newly-created/received group is not in the host cache
                        // yet, so only that case needs the wider summary hydrate.
                        await self.loadLocalSummaries(resolveMembers: false)
                    }
                    // Viewing this chat: zero unread so the badge cannot stick
                    // after the user already read the new arrival.
                    if self.viewingUnreadGroupIds.contains(changedGroupId) {
                        self.markConversationRead(groupId: changedGroupId)
                    }
                }
                if deferredBusyGroup {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            self.conversationRefreshTask = nil
        }
    }

    /// Load the latest local transcript window for one group. Used by chat open
    /// so existing conversations paint from the encrypted DB without scanning
    /// all groups or all messages.
    @discardableResult
    func loadLocalPage(
        groupId: String,
        mode: LocalTranscriptLoadMode
    ) async -> Bool {
        guard localTranscriptLoadingGroups.insert(groupId).inserted else { return false }
        defer { localTranscriptLoadingGroups.remove(groupId) }
        var transcriptLoaded = false
        do {
            // Transcript first: group metadata and invites are unrelated to the
            // first visible frame and must not sit ahead of the selected page.
            let rawPage = try await service.messagesCursorPage(
                groupId: groupId,
                limit: UInt32(Self.localTranscriptPageLimit + 1)
            )
            let page = Array(rawPage.prefix(Self.localTranscriptPageLimit))
            let existing = messagesByGroup[groupId] ?? []
            let existingCanonical = existing.filter { !Self.isLocalTranscriptEcho($0) }
            let echoes = existing.filter(Self.isLocalTranscriptEcho)
            let shouldPreserveHistoricalWindow = mode == .preserveHistoricalWindow
                && !existingCanonical.isEmpty
            let canonical: [MarmotService.MarmotMessage]
            if shouldPreserveHistoricalWindow {
                let pinnedToOlderEdge = localTranscriptPreservesOlderEdgeGroups.contains(groupId)
                let merged = Self.mergeMessages(existing: existingCanonical, incoming: page)
                // Match Signal's same-location reload: keep every local page
                // already loaded. Before the retained cap, merge in live rows;
                // once the conversation pins this source, update membership in
                // place so an unseen tail cannot move its historical cursor.
                canonical = Self.refreshLocalMessages(
                    existing: existingCanonical,
                    newest: page,
                    retainedLimit: Self.localTranscriptRetainedLimit,
                    preservingOlderEdge: pinnedToOlderEdge
                )
                localTranscriptCursorByGroup[groupId] = Self.oldestCursor(in: canonical)
                localTranscriptHasOlderByGroup[groupId] =
                    localTranscriptHasOlderByGroup[groupId] == true
                    || rawPage.count > Self.localTranscriptPageLimit
                    || merged.count > Self.localTranscriptRetainedLimit
            } else {
                let oldestPageDate = page.map(\.createdAt).min()
                // Returning from a historical cache window must replace it with a
                // contiguous newest page. Preserve only rows at/after this page's
                // boundary in case a local summary landed after the database read.
                let concurrentNewest = existingCanonical.filter { message in
                    guard let oldestPageDate else { return false }
                    return message.createdAt >= oldestPageDate
                }
                canonical = Array(
                    Self.mergeMessages(existing: concurrentNewest, incoming: page)
                        .suffix(Self.localTranscriptRetainedLimit)
                )
                localTranscriptCursorByGroup[groupId] = Self.oldestCursor(in: canonical)
                localTranscriptHasOlderByGroup[groupId] = rawPage.count > Self.localTranscriptPageLimit
                localTranscriptPreservesOlderEdgeGroups.remove(groupId)
            }
            var byGroup = messagesByGroup
            byGroup[groupId] = Self.mergeMessages(existing: canonical, incoming: echoes)
            self.messagesByGroup = reconcileOptimistic(
                into: byGroup,
                freshRowsByGroup: [groupId: page]
            )
            transcriptLoaded = true
            let groups = try await service.groups()
            let invites = try await service.pendingGroupInvites()
            let summaries = await service.conversationSummaries()
            let activeGroupIds = Set(groups.map(\.id))
            self.conversationSummariesByGroup = Dictionary(
                uniqueKeysWithValues: summaries
                    .filter { activeGroupIds.contains($0.groupIdHex) }
                    .map { ($0.groupIdHex, $0) }
            )
            self.publishUnread(from: summaries)
            self.groups = groups
            dropResolvedPendingDirectChats()
            self.pendingGroupInvites = invites
            SNMarmotChatSnapshotCache.save(
                groups: groups,
                messagesByGroup: self.messagesByGroup,
                to: defaults
            )
            if let group = groups.first(where: { $0.id == groupId }) {
                let relayReady = service.isRelayConnected()
                for member in group.memberNpubs where member != npub {
                    ensureProfile(member)
                    if relayReady {
                        ensureSonarDescriptor(member)
                    }
                }
            }
            return true
        } catch {
            self.errorText = Self.describe(error)
            // The transcript is the operation this method promises. Metadata
            // hydration follows it but must not make a successful newest-page
            // reset look coalesced/failed to the edge loader.
            return transcriptLoaded
        }
    }

    /// Page the next local database window before the oldest retained canonical
    /// row. Returns true only when at least one new row was prepended.
    func loadOlderLocalPage(groupId: String) async -> Bool {
        guard localTranscriptHasOlderByGroup[groupId] == true,
              let cursor = localTranscriptCursorByGroup[groupId],
              localTranscriptLoadingGroups.insert(groupId).inserted else {
            return false
        }
        defer { localTranscriptLoadingGroups.remove(groupId) }

        let existing = messagesByGroup[groupId] ?? []
        let preservedOlderEdgeBeforeLoad = localTranscriptPreservesOlderEdgeGroups.contains(groupId)
        if existing.lazy.filter({ !Self.isLocalTranscriptEcho($0) }).count
            >= Self.localTranscriptRetainedLimit {
            // Close the race before the database await: a concurrent summary
            // refresh must not evict the cursor row while this page is in
            // flight, otherwise the two retained ranges would have a gap.
            localTranscriptPreservesOlderEdgeGroups.insert(groupId)
        }
        let pageCount = Self.localTranscriptPageLimit

        do {
            let rawPage = try await service.messagesCursorPage(
                groupId: groupId,
                beforeSecs: cursor.beforeSecs,
                beforeIdHex: cursor.beforeId,
                limit: UInt32(pageCount + 1)
            )
            let page = Array(rawPage.prefix(pageCount))
            // A summary/new-message invalidation may have landed while the DB
            // read was suspended. Merge into the latest group snapshot so the
            // prepend cannot overwrite a newer row or optimistic echo.
            let latestExisting = messagesByGroup[groupId] ?? existing
            let latestCanonical = latestExisting.filter { !Self.isLocalTranscriptEcho($0) }
            let latestIDs = Set(latestCanonical.map(\.id))
            // Keep the edge that the user is paging toward. Once the retained
            // cache is full, prepending another page evicts rows from the newer
            // edge instead of turning the 500-row memory bound into a permanent
            // history ceiling.
            let mergedCanonical = Self.mergeMessages(existing: latestCanonical, incoming: page)
            let canonical = Array(mergedCanonical.prefix(Self.localTranscriptRetainedLimit))
            if mergedCanonical.count > Self.localTranscriptRetainedLimit {
                localTranscriptPreservesOlderEdgeGroups.insert(groupId)
            }
            let retainedIDs = Set(canonical.map(\.id))
            let added = page.contains {
                !latestIDs.contains($0.id) && retainedIDs.contains($0.id)
            }
            localTranscriptCursorByGroup[groupId] = Self.oldestCursor(in: canonical)
            localTranscriptHasOlderByGroup[groupId] = rawPage.count > pageCount

            let echoes = latestExisting.filter(Self.isLocalTranscriptEcho)
            var byGroup = messagesByGroup
            byGroup[groupId] = Self.mergeMessages(existing: canonical, incoming: echoes)
            messagesByGroup = reconcileOptimistic(
                into: byGroup,
                freshRowsByGroup: [groupId: page]
            )
            return added
        } catch {
            if !preservedOlderEdgeBeforeLoad {
                localTranscriptPreservesOlderEdgeGroups.remove(groupId)
            }
            self.errorText = Self.describe(error)
            return false
        }
    }

    func loadOlderLocalPageWhenAvailable(groupId: String) async -> Bool {
        for attempt in 0..<Self.localTranscriptBusyRetryLimit {
            if await loadOlderLocalPage(groupId: groupId) { return true }
            guard localTranscriptLoadingGroups.contains(groupId),
                  attempt + 1 < Self.localTranscriptBusyRetryLimit else { return false }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return false
            }
        }
        return false
    }

    func loadNewestLocalPageWhenAvailable(groupId: String) async -> Bool {
        for attempt in 0..<Self.localTranscriptBusyRetryLimit {
            if await loadLocalPage(groupId: groupId, mode: .newestPage) { return true }
            guard localTranscriptLoadingGroups.contains(groupId),
                  attempt + 1 < Self.localTranscriptBusyRetryLimit else { return false }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return false
            }
        }
        return false
    }

    func hasOlderLocalMessages(groupId: String) -> Bool {
        localTranscriptHasOlderByGroup[groupId] == true
    }

    func localTranscriptCanonicalMessageIDs(groupId: String) -> Set<String> {
        Set(
            (messagesByGroup[groupId] ?? [])
                .lazy
                .filter { !Self.isLocalTranscriptEcho($0) }
                .map(\.id)
        )
    }

    /// Load row metadata plus the newest local message per group. This keeps the
    /// chat list fresh without scanning full transcripts on cold start, polling,
    /// or idle reconciliation. Already-loaded active transcripts are preserved
    /// and merged with the newest row.
    /// Sum of unread counts for [groupIds] read straight from the core
    /// conversation index. The published `unreadByGroup` map lags a cold
    /// launch (it fills on the next summaries refresh), so open-time captures
    /// must not depend on it.
    func unreadCount(forGroups groupIds: [String]) async -> UInt64 {
        let wanted = Set(groupIds)
        let summaries = await service.conversationSummaries()
        return summaries
            .filter { wanted.contains($0.groupIdHex) }
            .reduce(UInt64(0)) { $0 + $1.unreadCount }
    }

    /// Load conversation summaries from the local Marmot DB.
    /// Returns `true` only when the read path succeeded — callers that use
    /// the result as an unread-delta baseline must not treat a failed load
    /// (empty in-memory cache) as a hydrated empty inbox.
    @discardableResult
    func loadLocalSummaries(resolveMembers: Bool = true) async -> Bool {
        do {
            let groups = try await service.groups()
            let invites = try await service.pendingGroupInvites()
            let pages = try await service.recentMessagePages(
                groupLimit: Self.localSummaryGroupLimit,
                pageLimit: Self.localSummaryPageLimit
            )
            let summaries = await service.conversationSummaries()
            let activeGroupIds = Set(groups.map(\.id))
            self.conversationSummariesByGroup = Dictionary(
                uniqueKeysWithValues: summaries
                    .filter { activeGroupIds.contains($0.groupIdHex) }
                    .map { ($0.groupIdHex, $0) }
            )
            // All service reads above suspend. Snapshot the live dictionary only
            // after they finish, then merge each result into that latest state in
            // one main-actor segment. A summary refresh can therefore never
            // publish a stale dictionary over a page/open/new-message update.
            var byGroup = messagesByGroup
            var freshRowsByGroup: [String: [MarmotService.MarmotMessage]] = [:]
            for page in pages {
                freshRowsByGroup[page.groupId] = page.messages
                let merged = Self.mergeMessages(
                    existing: byGroup[page.groupId] ?? [],
                    incoming: page.messages
                )
                let echoes = merged.filter(Self.isLocalTranscriptEcho)
                let mergedCanonical = merged.filter { !Self.isLocalTranscriptEcho($0) }
                let canonical: [MarmotService.MarmotMessage]
                if localTranscriptPreservesOlderEdgeGroups.contains(page.groupId) {
                    // Keep a contiguous historical window. Newer rows remain
                    // in the database and are picked up by loadLocalPage when
                    // the user returns to the live edge.
                    canonical = Array(mergedCanonical.prefix(Self.localTranscriptRetainedLimit))
                } else {
                    canonical = Array(mergedCanonical.suffix(Self.localTranscriptRetainedLimit))
                }
                if localTranscriptCursorByGroup[page.groupId] != nil {
                    // Summary refresh can trim the oldest cached row while the
                    // window is at the live edge. Advance the cursor in the same
                    // main-actor publication; otherwise the next older query
                    // starts before the evicted cursor and skips those rows.
                    localTranscriptCursorByGroup[page.groupId] = Self.oldestCursor(in: canonical)
                    if !localTranscriptPreservesOlderEdgeGroups.contains(page.groupId),
                       mergedCanonical.count > canonical.count {
                        // Rows evicted from memory are still in the local DB and
                        // must remain pageable even if the prior lookahead had
                        // reached the then-current beginning of history.
                        localTranscriptHasOlderByGroup[page.groupId] = true
                    }
                }
                byGroup[page.groupId] = Self.mergeMessages(existing: canonical, incoming: echoes)
            }
            self.publishUnread(from: summaries)
            self.groups = groups
            dropResolvedPendingDirectChats()
            self.pendingGroupInvites = invites
            self.messagesByGroup = reconcileOptimistic(
                into: byGroup,
                freshRowsByGroup: freshRowsByGroup
            )
            SNMarmotChatSnapshotCache.save(
                groups: groups,
                messagesByGroup: self.messagesByGroup,
                to: defaults
            )
            if resolveMembers {
                let relayReady = service.isRelayConnected()
                for group in groups {
                    for member in group.memberNpubs where member != npub {
                        ensureProfile(member)
                        if relayReady {
                            ensureSonarDescriptor(member)
                        }
                    }
                }
            }
            return true
        } catch {
            self.errorText = Self.describe(error)
            return false
        }
    }

    func homeRowMessage(groupId: String) -> MarmotService.MarmotMessage? {
        snMarmotHomeRowMessage(
            loaded: messagesByGroup[groupId]?.last,
            summary: conversationSummariesByGroup[groupId]
        )
    }

    private static func mergeMessages(
        existing: [MarmotService.MarmotMessage],
        incoming: [MarmotService.MarmotMessage]
    ) -> [MarmotService.MarmotMessage] {
        var byID: [String: MarmotService.MarmotMessage] = [:]
        for message in existing { byID[message.id] = message }
        for message in incoming { byID[message.id] = message }
        return byID.values.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
    }

    /// Apply updates to rows already retained in a historical source window
    /// without admitting unseen tail rows or changing the window boundaries.
    static func refreshHistoricalMessages(
        existing: [MarmotService.MarmotMessage],
        newest: [MarmotService.MarmotMessage]
    ) -> [MarmotService.MarmotMessage] {
        refreshLocalMessages(
            existing: existing,
            newest: newest,
            retainedLimit: existing.count,
            preservingOlderEdge: true
        )
    }

    /// Refresh a locally paged source without collapsing it to the newest
    /// database page. Live rows are admitted until the retained cap; a source
    /// pinned by the conversation-wide window receives retained-row updates
    /// only until the user explicitly returns to newest.
    static func refreshLocalMessages(
        existing: [MarmotService.MarmotMessage],
        newest: [MarmotService.MarmotMessage],
        retainedLimit: Int,
        preservingOlderEdge: Bool
    ) -> [MarmotService.MarmotMessage] {
        if preservingOlderEdge {
            let existingIDs = Set(existing.map(\.id))
            return mergeMessages(
                existing: existing,
                incoming: newest.filter { existingIDs.contains($0.id) }
            )
        }
        return Array(
            mergeMessages(existing: existing, incoming: newest)
                .suffix(max(0, retainedLimit))
        )
    }

    /// Pin one source when its folded conversation reaches the retained cap.
    /// The explicit newest-page load clears this marker again.
    func preserveLocalTranscriptWindow(groupId: String) {
        guard messagesByGroup[groupId]?.contains(where: { !Self.isLocalTranscriptEcho($0) }) == true
        else { return }
        localTranscriptPreservesOlderEdgeGroups.insert(groupId)
    }

    private static func isLocalTranscriptEcho(_ message: MarmotService.MarmotMessage) -> Bool {
        message.id.hasPrefix(optimisticIDPrefix) || message.id.hasPrefix(failedOptimisticIDPrefix)
    }

    private static func oldestCursor(
        in messages: [MarmotService.MarmotMessage]
    ) -> LocalTranscriptCursor? {
        guard let oldest = messages.min(by: {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }) else { return nil }
        return LocalTranscriptCursor(
            beforeSecs: UInt64(max(0, oldest.createdAt.timeIntervalSince1970.rounded(.down))),
            beforeId: oldest.id
        )
    }

    /// Poll the relays once, then reflect the (possibly updated) local state.
    /// Local chats are loaded even when the relay sync fails, so a relay outage
    /// never hides already-persisted conversations. Returns notifications for
    /// incoming messages (empty if nothing new or relay offline).
    ///
    /// Push-wake / manual refresh — Android-shaped receive path.
    ///
    /// Root cause of the ~10s banner→UI lag: `drainPending` shared the serial
    /// `workQueue` with blocking UniFFI `syncForce` (FETCH_TIMEOUT). Android
    /// never does that — drain and sync hop on independent `Dispatchers.IO`
    /// threads and the UI repaints from `conversationChanged`.
    ///
    /// Production shape:
    /// 1. Drain + paint on the dedicated receive lane first (UI can update
    ///    via `loadLocalSummaries` / polling while sync still runs).
    /// 2. Always await single-flight `syncForce` before returning — callers
    ///    (`SonarPushProcessor`) end the background wake when this returns, so
    ///    gap recovery must finish inside the granted window even when the live
    ///    buffer already had events. Merge with anything the polling loop
    ///    stole on `drainQueue` while `syncForce` was in flight (see
    ///    `pushWakeDrainBuffer`) — that drain is a separate buffer fill, so
    ///    live events already consumed above cannot reappear in it.
    /// 3. Mid-fetch, `drainQueue` still lets the polling loop paint the chat UI
    ///    from live events. Foreground resume uses `refreshAfterForeground`,
    ///    which fire-and-forgets gap recovery instead of blocking first paint.
    @discardableResult
    func refresh() async -> [DrainNotificationInfo] {
        guard await ensureConnected() else { return [] }
        guard await ensureRelayConnected() else {
            await loadLocalSummaries()
            return []
        }
        let live = (try? await service.drainPending()) ?? []
        await loadLocalSummaries()

        // Always await single-flight gap recovery before returning — the push
        // processor ends the background wake window when this call returns,
        // so recovery must finish inside the granted window even when the
        // live buffer already delivered events. Collect anything polling
        // drains during syncForce so titled push notifications are not lost.
        beginPushWakeDrainCapture()
        defer { endPushWakeDrainCapture() }
        // Await single-flight recovery for wake lifetime, but claim the drained
        // notifications once — joiners must not re-emit the same recovered set.
        _ = await ensureGapRecovery().value
        let recovered = takeGapRecoveryNotifications()
        let stolen = takePushWakeDrainBuffer()
        var notifications = live
        if !recovered.isEmpty { notifications += recovered }
        if !stolen.isEmpty { notifications += stolen }
        return notifications
    }

    private func beginPushWakeDrainCapture() {
        if pushWakeDrainWaiters == 0 {
            pushWakeDrainBuffer = []
        }
        pushWakeDrainWaiters += 1
        pushWakeDrainActive = true
    }

    private func endPushWakeDrainCapture() {
        pushWakeDrainWaiters = max(0, pushWakeDrainWaiters - 1)
        if pushWakeDrainWaiters == 0 {
            pushWakeDrainActive = false
            pushWakeDrainBuffer = []
        }
    }

    private func takeGapRecoveryNotifications() -> [DrainNotificationInfo] {
        let claimed = gapRecoveryUnclaimedDrain ?? []
        gapRecoveryUnclaimedDrain = nil
        return claimed
    }

    private func takePushWakeDrainBuffer() -> [DrainNotificationInfo] {
        let buffered = pushWakeDrainBuffer
        pushWakeDrainBuffer = []
        return buffered
    }

    /// Forward drain metadata to an in-flight push `refresh()` waiter. Polling
    /// and gap recovery both call this so a `drainQueue` race cannot drop
    /// titled-notification payloads on the floor.
    private func noteDrainedForPushWake(_ notifications: [DrainNotificationInfo]) {
        guard pushWakeDrainActive, !notifications.isEmpty else { return }
        pushWakeDrainBuffer.append(contentsOf: notifications)
    }

    /// Single-flight forced gap recovery. Shared by push wake and foreground
    /// resume so concurrent wakes coalesce onto one `syncForce`. Returns the
    /// notifications drained after `syncForce` so push wake can title them.
    @discardableResult
    private func ensureGapRecovery() -> Task<[DrainNotificationInfo], Never> {
        if let existing = gapRecoveryTask {
            return existing
        }
        gapRecoveryGeneration &+= 1
        let generation = gapRecoveryGeneration
        let task = Task<[DrainNotificationInfo], Never> { [weak self] in
            guard let self else { return [DrainNotificationInfo]() }
            defer {
                if self.gapRecoveryGeneration == generation {
                    self.gapRecoveryTask = nil
                }
            }
            do {
                try await self.service.syncForce()
                if Task.isCancelled { return [DrainNotificationInfo]() }
                self.errorText = nil
            } catch {
                if Task.isCancelled { return [DrainNotificationInfo]() }
                // A suspend abort is not a relay failure — leave the banner alone.
                if !Self.isSuspendInterrupted(error) {
                    self.errorText = Self.describe(error)
                }
            }
            if Task.isCancelled { return [DrainNotificationInfo]() }
            let notifications = (try? await self.service.drainPending()) ?? [DrainNotificationInfo]()
            await self.loadLocalSummaries()
            // One-shot claim buffer for push titled notifications.
            self.gapRecoveryUnclaimedDrain = notifications
            return notifications
        }
        gapRecoveryTask = task
        return task
    }

    func markConversationRead(groupId: String) {
        unreadSuppressGroupIds.insert(groupId)
        unreadByGroup[groupId] = nil
        Task { @MainActor in
            await service.markConversationRead(groupId: groupId)
            // End in-flight suppress for this id, then reconcile from core.
            // Viewing suppress still covers an open DM; without this release a
            // failed/raced mark could hide real unread for the rest of the process.
            unreadSuppressGroupIds.remove(groupId)
            // Always reconcile. `readOnlyNonThrowing` maps FFI failure to [],
            // which clears badges until the next successful summary load — the
            // same self-correcting window as Compose's null-vs-empty split, and
            // required so an empty inbox still drops stale dots.
            publishUnread(from: await service.conversationSummaries())
        }
    }

    /// Bind chat-list unread suppression to the DM currently on screen.
    /// Call with the folded Marmot group ids at open; call with `[]` on pop.
    func setViewingUnreadGroups(_ groupIds: [String]) {
        viewingUnreadGroupIds = Set(groupIds)
        for groupId in groupIds {
            unreadByGroup[groupId] = nil
        }
    }

    private func publishUnread(from summaries: [MarmotService.ConversationSummary]) {
        let tuples = summaries.map { ($0.groupIdHex, $0.unreadCount) }
        unreadSuppressGroupIds = SNUnreadCounts.pruneConfirmedSuppressions(
            unreadSuppressGroupIds,
            summaries: tuples
        )
        unreadByGroup = SNUnreadCounts.unreadByGroup(
            from: tuples,
            suppressing: unreadSuppressGroupIds.union(viewingUnreadGroupIds)
        )
    }

    /// Publish our own kind-0 profile so peers see our nickname, not our npub.
    /// Background variant: the relay send must not hold the engine queue (a
    /// rename can happen while a chat is open and sending).
    func publishProfile(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { try? await service.publishProfileBackground(name: trimmed) }
    }

    /// Fetch our own kind-0, cache it, let the host adopt name/NIP-05, and
    /// re-claim the handle when the core sidecar is empty so later publishes
    /// cannot drop `nip05`. Returns whether it is safe to republish kind-0.
    @discardableResult
    func hydrateOwnProfileFromRelays() async -> Bool {
        let localNick = (profileNameProvider?() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let localBip = localBip353Provider?() ?? ""
        let domain = handleDomainProvider?() ?? defaultHandleDomain()
        let claimedNow = await service.claimedHandle()
        let needsFetch = OwnProfileHydration.needsRelayFetch(
            localNickname: localNick,
            localBip353: localBip,
            localClaimedHandle: claimedNow,
            handleDomain: domain
        )
        if !needsFetch {
            return !localNick.isEmpty && OwnProfileHydration.canPublishOwnProfile(
                localBip353: localBip,
                coreClaimedHandle: claimedNow
            )
        }
        // Handle-less accounts only need one own-profile fetch per process to
        // learn whether relays hold a nip05. Keep retrying when a Sonar-domain
        // pref still lacks a sidecar (reclaim may have failed earlier).
        let bipTrimmed = localBip.trimmingCharacters(in: .whitespacesAndNewlines)
        let sonarMissingSidecar = !bipTrimmed.isEmpty
            && bipTrimmed.lowercased().hasSuffix("@\(domain.lowercased())")
            && (claimedNow?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if didFetchOwnProfileThisSession, !localNick.isEmpty, !sonarMissingSidecar {
            return OwnProfileHydration.canPublishOwnProfile(
                localBip353: localBip,
                coreClaimedHandle: claimedNow
            )
        }
        guard let me = npub?
            .trimmingCharacters(in: .whitespacesAndNewlines), !me.isEmpty
        else {
            return !localNick.isEmpty && OwnProfileHydration.canPublishOwnProfile(
                localBip353: localBip,
                coreClaimedHandle: claimedNow
            )
        }
        guard let profile = try? await service.fetchProfile(npub: me) else {
            // Do not set didFetchOwnProfileThisSession — a miss should retry.
            return !localNick.isEmpty && OwnProfileHydration.canPublishOwnProfile(
                localBip353: localBip,
                coreClaimedHandle: claimedNow
            )
        }
        didFetchOwnProfileThisSession = true
        let key = SNMarmotProfileCache.canonicalKey(me)
        await MainActor.run {
            profilesByNpub[key] = profile
            profileFetchedAt[key] = Date()
            scheduleProfileCacheWrite()
            onOwnProfileFetched?(profile)
        }
        let claimed = await service.claimedHandle()
        let plan = OwnProfileHydration.plan(
            localNickname: profileNameProvider?() ?? "",
            localBip353: localBip353Provider?() ?? localBip,
            localClaimedHandle: claimed,
            remoteName: profile.bestName,
            remoteNip05: profile.nip05,
            handleDomain: domain
        )
        var handleSeeded = plan.handleLocalToClaim == nil
        if let local = plan.handleLocalToClaim, !local.isEmpty {
            let offer = await handleOfferProvider?()
            if let address = try? await service.claimHandle(handle: local, offer: offer) {
                handleSeeded = true
                await MainActor.run { onOwnHandleSidecarSeeded?(address) }
            }
        }
        return plan.shouldPublishNickname && handleSeeded
    }

    /// Claim a unified handle at the Sonar registrar (blocking network inside
    /// the core; never call on the render path). Returns the claimed address.
    func claimHandle(handle: String, offer: String?) async throws -> String {
        try await service.claimHandle(handle: handle, offer: offer)
    }

    /// Locally stored claimed handle address (nil when never claimed).
    func claimedHandle() async -> String? {
        await service.claimedHandle()
    }

    /// Resolve a handle (`vincenzo` / `alice@domain`) to its owner via NIP-05.
    func resolveHandle(_ input: String) async throws -> MarmotService.ResolvedHandle {
        try await service.resolveHandle(input)
    }

    /// True if `address` currently NIP-05-resolves to `npub`.
    func verifyNip05(address: String, npub: String) async throws -> Bool {
        try await service.verifyNip05(address: address, npub: npub)
    }

    /// Publish the app-level Sonar descriptor. This is separate from kind-0
    /// profile metadata so protocol capability discovery can evolve safely.
    func publishSonarDescriptor(callsEnabled: Bool = true) {
        let bolt12Offer = descriptorBolt12Offer
        Task { try? await service.publishSonarDescriptor(callsEnabled: callsEnabled, bolt12Offer: bolt12Offer) }
    }

    /// Publish the descriptor with explicit payment metadata. The desired offer
    /// is retained immediately so concurrent capability refreshes do not drop
    /// it, while callers can still await the relay publish result.
    func publishSonarDescriptor(callsEnabled: Bool = true, bolt12Offer: String?) async throws {
        descriptorBolt12Offer = bolt12Offer
        try await service.publishSonarDescriptor(callsEnabled: callsEnabled, bolt12Offer: bolt12Offer)
    }

    /// BLE-name vs kind-0 mismatch is a rename signal: refetch past the
    /// in-flight guard. Capped to one forced refetch per 30 min so a
    /// permanently-different BLE handle cannot loop relay queries.
    func refreshProfileOnNameMismatch(npub npubValue: String, liveName: String?) {
        let key = SNMarmotProfileCache.canonicalKey(npubValue)
        guard let liveName, !liveName.isEmpty else { return }
        guard let cached = profilesByNpub[key]?.bestName, cached != liveName else { return }
        // Do NOT evict profileFetches first: a fetch may be in flight, and a
        // duplicate completion could overwrite a fresher name. ensureProfile's
        // in-flight guard + refreshStaleProfiles cap the forced refetch to one
        // per 30-min window — matching Compose.
        guard !profileFetches.contains(key) else { return }
        ensureProfile(key)
    }

    /// Fire-and-forget relay enrichment must not start while the app is
    /// backgrounded.
    ///
    /// `ensureProfile` / `ensureSonarDescriptor` both dispatch onto
    /// `MarmotService`'s SERIAL work queue and park inside uncancellable blocking
    /// FFI — `FETCH_TIMEOUT` is 10s, and a descriptor fetch runs two of them.
    /// `loadLocalSummaries(resolveMembers: true)` kicks one pair per group
    /// member, and a push wake calls it three times, so a handful of contacts
    /// queues minutes of blocking work. `closeStoreAfterBackgroundWake()` ->
    /// `closeNode()` hops onto that same serial queue, so it lands behind all of
    /// it and the process suspends still holding the App Group flock and the
    /// SQLCipher locks — the RunningBoard 0xdead10cc kill.
    ///
    /// Nothing renders while backgrounded, so these are pure waste there.
    ///
    /// This self-heals because the guard sits BEFORE the `profileFetches` /
    /// `descriptorFetches` in-flight inserts: a skipped npub leaves no marker, so the
    /// next foreground `loadLocalSummaries(resolveMembers: true)` simply calls it again
    /// and it proceeds. Do not move the guard below those inserts — that would leave a
    /// permanent in-flight marker for an npub that was never fetched and suppress it
    /// forever. Note `refreshStaleProfiles()` does NOT cover this: it only clears
    /// entries whose `profileFetchedAt` is older than the TTL, and a skipped npub has
    /// no `profileFetchedAt` entry at all. The push-notification title path is unaffected —
    /// `resolveSenderName(npub:)` awaits `service.fetchProfile` directly instead
    /// of going through `ensureProfile`.
    private var canPrefetchFromRelays: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState != .background
        #else
        return true
        #endif
    }

    /// Fetch + cache a peer's kind-0 profile, so their name/avatar replaces the
    /// raw npub in the chat list, header, and avatar. Retries (via the periodic
    /// `refresh()`) until the peer has published a profile.
    func ensureProfile(_ npubToFetch: String) {
        guard canPrefetchFromRelays else { return }
        let key = SNMarmotProfileCache.canonicalKey(npubToFetch)
        let ownKey = npub.map(SNMarmotProfileCache.canonicalKey)
        guard !key.isEmpty, key != ownKey else { return }
        let hadCachedProfile = profilesByNpub[key] != nil || profilesByNpub[npubToFetch] != nil
        guard profileFetches.insert(key).inserted else { return } // in flight
        Task {
            let profile = try? await service.fetchProfile(npub: key)
            await MainActor.run {
                if let profile, profile.bestName != nil {
                    self.profilesByNpub[key] = profile
                    self.profileFetchedAt[key] = Date()
                    if key != npubToFetch {
                        self.profilesByNpub.removeValue(forKey: npubToFetch)
                    }
                    self.scheduleProfileCacheWrite()
                } else {
                    if !hadCachedProfile {
                        self.profileFetches.remove(key) // not published yet — allow retry
                    } else {
                        // Previously cached but the relay returned nothing useful.
                        // Stamp the attempt so refreshStaleProfiles() retries
                        // after TTL instead of leaving the entry stuck forever.
                        self.profileFetchedAt[key] = Date()
                    }
                }
            }
        }
    }

    /// Clear stale profile fetch guards so updated aliases/names get re-fetched
    /// during long sessions. Returns true when any profiles were marked stale,
    /// so the caller can trigger member re-resolution.
    @discardableResult
    func refreshStaleProfiles() -> Bool {
        let stale = Self.staleKeys(
            from: profileFetchedAt,
            cutoff: Date().addingTimeInterval(-Self.profileRefreshTTL)
        )
        guard !stale.isEmpty else { return false }
        for key in stale {
            profileFetches.remove(key)
            profileFetchedAt.removeValue(forKey: key)
        }
        return true
    }

    /// Pure computation of npub keys whose last fetch is older than the TTL
    /// cutoff. Extracted so the staleness logic is unit-testable without a
    /// `MarmotService` or `@MainActor` instance.
    nonisolated static func staleKeys(from fetchedAt: [String: Date], cutoff: Date) -> [String] {
        fetchedAt.filter { $0.value < cutoff }.map { $0.key }
    }

    /// Fetch + cache a peer's public Sonar descriptor. Not finding one keeps the
    /// npub usable for White Noise/Marmot chat, but it does not unlock calls.
    /// Positive results are periodically refreshed so protocol upgrades or
    /// capability changes are noticed during long-running sessions.
    func ensureSonarDescriptor(_ npubToFetch: String) {
        // See `canPrefetchFromRelays`: a background wake must not flood the
        // serial work queue that `closeNode()` has to get through.
        guard canPrefetchFromRelays else { return }
        guard !npubToFetch.isEmpty, npubToFetch != npub else { return }
        if sonarDescriptorsByNpub[npubToFetch] != nil,
           let fetchedAt = sonarDescriptorFetchedAtByNpub[npubToFetch],
           Date().timeIntervalSince(fetchedAt) < Self.sonarDescriptorRefreshInterval {
            return
        }
        if let miss = sonarDescriptorMissesByNpub[npubToFetch],
           Date().timeIntervalSince(miss) < Self.sonarDescriptorMissRetryInterval {
            return
        }
        guard descriptorFetches.insert(npubToFetch).inserted else { return }
        // Capture the generation HERE, not inside the task: a wipe between
        // scheduling and start would otherwise let this fetch adopt the new
        // account's generation and persist the old account's contact.
        let generation = descriptorCacheGeneration
        Task {
            await performDescriptorFetch(npubToFetch, generation: generation)
        }
    }

    /// Synchronous variant: awaits the relay fetch and returns the descriptor.
    /// Use when the descriptor is missing and the caller needs it before
    /// proceeding (e.g. opening a pay sheet). When the descriptor is already
    /// cached and just stale, prefer the fire-and-forget `ensureSonarDescriptor`.
    func fetchSonarDescriptorSync(
        _ npubToFetch: String,
        bypassRecentMiss: Bool = true
    ) async -> MarmotService.SonarDescriptor? {
        guard !npubToFetch.isEmpty, npubToFetch != npub else { return nil }
        let cached = sonarDescriptorsByNpub[npubToFetch]
        let hasBolt12 = cached?.bolt12Offer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if hasBolt12,
           let fetchedAt = sonarDescriptorFetchedAtByNpub[npubToFetch],
           Date().timeIntervalSince(fetchedAt) < Self.sonarDescriptorRefreshInterval {
            return cached
        }
        if !bypassRecentMiss,
           let miss = sonarDescriptorMissesByNpub[npubToFetch],
           Date().timeIntervalSince(miss) < Self.sonarDescriptorMissRetryInterval {
            return sonarDescriptorsByNpub[npubToFetch]
        }
        descriptorFetches.insert(npubToFetch)
        await performDescriptorFetch(npubToFetch, generation: descriptorCacheGeneration)
        return sonarDescriptorsByNpub[npubToFetch]
    }

    // ── Contact-cache persistence (profiles + Sonar descriptors) ──
    //
    // Both caches re-encode their WHOLE map on every successful fetch, and both
    // `save` calls used to run inside `MainActor.run`. A boot / foreground sweep
    // (`refreshDescriptors(forKnownNpubs:)`, `refreshChatMemberProfiles`)
    // resolves N contacts, so that was N full-map JSON encodes on the main
    // actor while the user may be scrolling or sending.
    //
    // These schedule the encode off the actor and commit on it. The commit
    // itself is cheap — `defaults.set` is in-memory, the OS flushes later — and
    // doing it back on the actor is what makes the ordering safe: a teardown
    // that bumps `contactCacheWriteGeneration` is serialized against the commit
    // hop, so a write encoded before a wipe can never land after it.
    //
    // Teardown paths must NOT use these. They call `.clear(from:)` directly,
    // which is synchronous, and bump the generation.

    private func scheduleProfileCacheWrite() {
        let snapshot = profilesByNpub
        let defaults = self.defaults
        let generation = contactCacheWriteGeneration
        profileCacheScheduledSeq &+= 1
        let seq = profileCacheScheduledSeq
        Task.detached(priority: .utility) { [weak self] in
            guard let payload = SNMarmotProfileCache.encoded(snapshot) else { return }
            guard let self else { return }
            await MainActor.run {
                guard generation == self.contactCacheWriteGeneration else { return }
                // A newer snapshot already landed — this one is stale.
                guard seq > self.profileCacheCommittedSeq else { return }
                self.profileCacheCommittedSeq = seq
                SNMarmotProfileCache.commit(payload, to: defaults)
            }
        }
    }

    private func scheduleDescriptorCacheWrite() {
        let snapshot = sonarDescriptorsByNpub
        let defaults = self.defaults
        let generation = contactCacheWriteGeneration
        descriptorCacheScheduledSeq &+= 1
        let seq = descriptorCacheScheduledSeq
        Task.detached(priority: .utility) { [weak self] in
            guard let data = SNMarmotDescriptorCache.encoded(snapshot) else { return }
            guard let self else { return }
            await MainActor.run {
                guard generation == self.contactCacheWriteGeneration else { return }
                // A newer snapshot already landed — this one is stale.
                guard seq > self.descriptorCacheCommittedSeq else { return }
                self.descriptorCacheCommittedSeq = seq
                SNMarmotDescriptorCache.commit(data, to: defaults)
            }
        }
    }

    /// Apply a completed descriptor fetch to the cache.
    ///
    /// A relay MISS (`fetched == nil`) is a transient answer, not proof the peer
    /// has no descriptor: relays reconnecting after background, the 10 s core
    /// `FETCH_TIMEOUT` expiring, or a relay that simply does not hold the event
    /// all produce it. Evicting on a miss silently drops the peer's BOLT12
    /// offer, so a chat that was payable a moment ago loses "Send money" from
    /// the "+" sheet until some later fetch happens to succeed — the intermittent
    /// "bitcoin payment is not showing" report. Keep the last resolved
    /// descriptor and stamp only the miss, so the 60 s miss cooldown (not the
    /// 15 min success TTL) drives the retry. Mirrors Compose
    /// `SonarAppState.performDescriptorFetch`.
    nonisolated static func descriptorCacheAfterFetch(
        cached: MarmotService.SonarDescriptor?,
        fetched: MarmotService.SonarDescriptor?
    ) -> (descriptor: MarmotService.SonarDescriptor?, stampFetchedAt: Bool, missed: Bool) {
        if let fetched { return (fetched, true, false) }
        return (cached, false, true)
    }

    private func performDescriptorFetch(_ npubToFetch: String, generation: Int) async {
        do {
            let descriptor = try await service.fetchSonarDescriptor(npub: npubToFetch)
            await MainActor.run {
                self.descriptorFetches.remove(npubToFetch)
                // The cache is durable now, so a fetch started under the previous
                // identity must not write (and persist) its contacts into the new
                // account after a wipe/restore.
                guard generation == self.descriptorCacheGeneration else { return }
                let outcome = Self.descriptorCacheAfterFetch(
                    cached: self.sonarDescriptorsByNpub[npubToFetch],
                    fetched: descriptor
                )
                if outcome.stampFetchedAt {
                    self.sonarDescriptorFetchedAtByNpub[npubToFetch] = Date()
                }
                self.sonarDescriptorsByNpub[npubToFetch] = outcome.descriptor
                self.sonarDescriptorsByNpub = SNMarmotDescriptorCache.capped(self.sonarDescriptorsByNpub)
                if outcome.missed {
                    self.sonarDescriptorMissesByNpub[npubToFetch] = Date()
                } else {
                    self.sonarDescriptorMissesByNpub[npubToFetch] = nil
                }
                // A miss leaves the cache byte-identical, so skip the encode.
                // `save` runs a full JSON encode of the whole dictionary on the
                // MainActor; a boot/foreground refresh sweep would otherwise do
                // that once per missed contact for no state change. Compose's
                // miss branch does not persist either.
                if !outcome.missed {
                    self.scheduleDescriptorCacheWrite()
                }
            }
        } catch {
            await MainActor.run {
                _ = self.descriptorFetches.remove(npubToFetch)
            }
        }
    }

    /// Proactively refresh Sonar descriptors for a set of known npubs (e.g. all
    /// persisted fingerprint↔npub links). Only the relay-ready startup pass clears
    /// miss timestamps; foreground refreshes preserve the miss retry cooldown.
    func refreshDescriptors(forKnownNpubs npubs: [String], clearMisses: Bool = false) {
        for npub in npubs {
            if clearMisses {
                sonarDescriptorMissesByNpub[npub] = nil
            }
            ensureSonarDescriptor(npub)
        }
    }

    /// Best display name for a member npub, if we've resolved their profile.
    func displayName(forNpub member: String) -> String? {
        profilesByNpub[SNMarmotProfileCache.canonicalKey(member)]?.bestName
            ?? profilesByNpub[member]?.bestName
    }

    /// Resolve sender name for push notifications: in-memory kind-0 → App Group
    /// mirror (NSE-shared) → relay fetch → short npub.
    func resolveSenderName(npub: String) async -> String {
        if let cached = displayName(forNpub: npub) { return cached }
        if let shared = SonarSharedProfileNames.bestName(for: npub) { return shared }
        if let profile = try? await service.fetchProfile(npub: npub),
           let name = profile.bestName { return name }
        return String(npub.prefix(12)) + "…"
    }

    /// Resolved author label for a Marmot group message: cached profile name,
    /// or short npub with an async fetch kicked off so it resolves on the next
    /// SwiftUI invalidation cycle.
    func marmotAuthorName(_ m: MarmotService.MarmotMessage) -> String? {
        snResolvedMarmotAuthorName(
            m,
            profilesByNpub: profilesByNpub,
            fetchMissingProfile: ensureProfile,
            shortNpub: snShortNpubLabel
        )
    }

    /// Merge still-pending optimistic echoes into the freshly-synced
    /// transcripts. An optimistic message is dropped once the relay copy of
    /// the same outgoing text (mine, same content) has come back, so the
    /// echoed-back copy never duplicates; otherwise it stays visible until
    /// the round-trip completes.
    private func reconcileOptimistic(
        into byGroup: [String: [MarmotService.MarmotMessage]],
        freshRowsByGroup: [String: [MarmotService.MarmotMessage]] = [:]
    ) -> [String: [MarmotService.MarmotMessage]] {
        guard !pendingOptimistic.isEmpty else { return byGroup }
        var merged = byGroup
        for (groupId, pending) in pendingOptimistic {
            let reconciliation = Self.reconciledOptimisticMessages(
                source: byGroup[groupId] ?? [],
                pending: pending,
                exclusionsByOptimisticID: preexistingCanonicalMessageIDsByOptimisticID,
                freshCanonical: freshRowsByGroup[groupId] ?? []
            )
            for echo in pending where !reconciliation.survivors.contains(where: { $0.id == echo.id }) {
                preexistingCanonicalMessageIDsByOptimisticID[echo.id] = nil
            }
            if reconciliation.survivors.isEmpty {
                pendingOptimistic[groupId] = nil
            } else {
                pendingOptimistic[groupId] = reconciliation.survivors
            }
            merged[groupId] = reconciliation.visible
        }
        return merged
    }

    /// How far BEFORE the echo's creation a server row may be timestamped and
    /// still count as this send's relay copy. The real copy is always stamped
    /// at/after the echo (`send()` appends the echo, then `sendChain` runs
    /// `sendText`), so only a few seconds of slack are needed for
    /// second-granularity `created_at` + minor clock jitter. A wider window
    /// would let a recent identical send consume this still-pending echo.
    private static let optimisticMatchSlack: TimeInterval = 5

    static func serverMessage(
        _ server: MarmotService.MarmotMessage,
        matchesOptimistic optimistic: MarmotService.MarmotMessage,
        excludingServerIDs: Set<String> = []
    ) -> Bool {
        guard !optimistic.id.hasPrefix(failedOptimisticIDPrefix) else { return false }
        guard !server.id.hasPrefix(optimisticIDPrefix),
              !server.id.hasPrefix(failedOptimisticIDPrefix) else { return false }
        guard server.isMine,
              server.content == optimistic.content,
              server.stickerRef == optimistic.stickerRef
        else { return false }
        guard !excludingServerIDs.contains(server.id) else { return false }
        // Only a row created around/after the echo can be THIS send's copy.
        // Without this, re-sending text identical to an OLDER own message
        // matched that old row and dropped the still-pending echo on the next
        // page load — leaving the chat and coming back made the in-flight
        // message vanish until the real send landed.
        guard server.createdAt >= optimistic.createdAt.addingTimeInterval(-Self.optimisticMatchSlack) else {
            return false
        }
        guard !optimistic.media.isEmpty else { return server.media.isEmpty }
        return optimistic.media.allSatisfy { pending in
            server.media.contains {
                $0.filename == pending.filename && $0.mimeType == pending.mimeType
            }
        }
    }

    struct OptimisticReconciliation {
        let survivors: [MarmotService.MarmotMessage]
        let visible: [MarmotService.MarmotMessage]
    }

    /// Reconcile only canonical rows; [source] can contain local echoes from a
    /// previous local-first paint, but those are re-added exactly once below.
    ///
    /// [freshCanonical] carries the rows just read from the local database. A
    /// group pinned to its older historical edge admits no new rows into
    /// [source], so without it the relay copy of an outgoing send never reaches
    /// this match and the echo stays "Sending" forever. An echo fulfilled by an
    /// out-of-window row is replaced by that row so the sent message stays
    /// visible with its real delivery state.
    static func reconciledOptimisticMessages(
        source: [MarmotService.MarmotMessage],
        pending: [MarmotService.MarmotMessage],
        exclusionsByOptimisticID: [String: Set<String>] = [:],
        freshCanonical: [MarmotService.MarmotMessage] = []
    ) -> OptimisticReconciliation {
        let canonical = source.filter { !isLocalTranscriptEcho($0) }
        let windowedIDs = Set(canonical.map(\.id))
        let outOfWindow = freshCanonical.filter {
            !isLocalTranscriptEcho($0) && !windowedIDs.contains($0.id)
        }
        var unmatchedCanonical = canonical + outOfWindow
        var survivors: [MarmotService.MarmotMessage] = []
        var admitted: [MarmotService.MarmotMessage] = []
        for optimistic in pending {
            if let match = unmatchedCanonical.firstIndex(where: {
                serverMessage(
                    $0,
                    matchesOptimistic: optimistic,
                    excludingServerIDs: exclusionsByOptimisticID[optimistic.id] ?? []
                )
            }) {
                let fulfilled = unmatchedCanonical.remove(at: match)
                if !windowedIDs.contains(fulfilled.id) {
                    admitted.append(fulfilled)
                }
            } else {
                survivors.append(optimistic)
            }
        }
        return OptimisticReconciliation(
            survivors: survivors,
            visible: mergeMessages(existing: canonical + admitted, incoming: survivors)
        )
    }

    private func appendOptimistic(
        _ echo: MarmotService.MarmotMessage,
        to groupId: String
    ) {
        preexistingCanonicalMessageIDsByOptimisticID[echo.id] = Set(
            messagesByGroup[groupId, default: []]
                .filter { !Self.isLocalTranscriptEcho($0) }
                .map(\.id)
        )
        pendingOptimistic[groupId, default: []].append(echo)
        messagesByGroup[groupId, default: []].append(echo)
    }

    private func discardOptimistic(id: String, from groupId: String) {
        preexistingCanonicalMessageIDsByOptimisticID[id] = nil
        pendingOptimistic[groupId]?.removeAll { $0.id == id }
        messagesByGroup[groupId, default: []].removeAll { $0.id == id }
    }

    private func discardOptimistic(for groupId: String) {
        pendingOptimistic[groupId]?.forEach {
            preexistingCanonicalMessageIDsByOptimisticID[$0.id] = nil
        }
        pendingOptimistic[groupId] = nil
    }

    func startChat(with peer: String) {
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sendsSuspendedForAccountMutation else { return }
        let clean = SNMarmotProfileCache.canonicalKey(trimmed)
        guard !clean.isEmpty else { return }
        if directGroup(forNpub: clean) != nil { return }
        ensureProfile(clean)
        ensureSonarDescriptor(clean)
        Task {
            _ = await startChatReturningId(with: clean)
        }
    }

    func startChatReturningId(with peer: String) async -> String? {
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sendsSuspendedForAccountMutation else { return nil }
        let clean = SNMarmotProfileCache.canonicalKey(trimmed)
        guard !clean.isEmpty else { return nil }
        if let existing = directGroup(forNpub: clean) {
            return existing.id
        }
        if let existingSetup = directChatSetupTasks[clean] {
            return await existingSetup.task.value
        }

        pendingDirectChats[clean] = Date()
        let setupToken = UUID()
        let generation = sendGeneration
        let setupTask = Task { @MainActor [weak self] in
            await self?.performDirectChatSetup(with: clean, generation: generation)
        }
        directChatSetupTasks[clean] = (setupToken, setupTask)
        let groupId = await setupTask.value
        if directChatSetupTasks[clean]?.token == setupToken {
            directChatSetupTasks[clean] = nil
            pendingDirectChats[clean] = nil
        }
        return groupId
    }

    private func performDirectChatSetup(with npub: String, generation: UInt64) async -> String? {
        guard !Task.isCancelled,
              generation == sendGeneration,
              !sendsSuspendedForAccountMutation
        else { return nil }
        guard await ensureRelayConnected() else {
            self.errorText = "Not connected yet — try again in a moment."
            return nil
        }
        guard !Task.isCancelled,
              generation == sendGeneration,
              !sendsSuspendedForAccountMutation
        else { return nil }
        if let existing = directGroup(forNpub: npub) {
            return existing.id
        }
        do {
            let groupId = try await service.startDirectMessage(with: npub, name: "")
            guard !Task.isCancelled,
                  generation == sendGeneration,
                  !sendsSuspendedForAccountMutation
            else { return nil }
            await loadLocalPage(groupId: groupId, mode: .newestPage)
            Task { [weak self] in
                await self?.refreshWhenConnected(groupId: groupId, hydrateBeforeSync: false)
            }
            return groupId
        } catch {
            self.errorText = Self.describe(error)
            return nil
        }
    }

    func send(
        _ text: String,
        to groupId: String,
        onEchoVisible: (() -> Void)? = nil,
        onFailure: (() -> Void)? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sendsSuspendedForAccountMutation else { return }
        errorText = nil
        let echo = MarmotService.MarmotMessage(
            id: Self.optimisticIDPrefix + UUID().uuidString,
            senderNpub: npub ?? "",
            content: trimmed,
            createdAt: Date(),
            isMine: true,
            media: []
        )
        appendOptimistic(echo, to: groupId)
        onEchoVisible?()
        let prev = sendChain
        let generation = sendGeneration
        sendChain = Task { [weak self] in
            _ = await prev?.result
            guard let self,
                  !Task.isCancelled,
                  self.sendGeneration == generation,
                  !self.sendsSuspendedForAccountMutation
            else { return }
            do {
                guard await self.ensureConnected(timeoutSeconds: 2) else {
                    throw MarmotService.ServiceError.notConnected
                }
                try await self.service.sendText(groupId: groupId, text: trimmed)
            } catch {
                self.discardOptimistic(id: echo.id, from: groupId)
                onFailure?()
                self.errorText = Self.describe(error)
                return
            }
            // The core conversation-change callback refreshes this one bounded
            // local page. Periodic connection healing owns re-subscription; a
            // user send must not rescan every chat or repair subscriptions.
        }
    }

    func send(_ texts: [String], to groupId: String) async -> Bool {
        let trimmed = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return true }
        // Per-operation outcome (local `succeeded`), not shared `errorText`.
        // Still paints a group optimistic — used when a pending-chat echo was
        // already transferred/removed. Mesh→WN flush uses `sendQueuedText`.
        var allOk = true
        for text in trimmed {
            // A batch spans multiple awaits, so an erase can begin between items.
            // Each iteration assigns a NEW sendChain tail, which a quiesce that
            // already snapshotted the chain would never see — so re-check here
            // instead of relying on the entry guard alone.
            guard !sendsSuspendedForAccountMutation, !Task.isCancelled else { return false }
            var succeeded = false
            let echo = MarmotService.MarmotMessage(
                id: Self.optimisticIDPrefix + UUID().uuidString,
                senderNpub: npub ?? "",
                content: text,
                createdAt: Date(),
                isMine: true,
                media: []
            )
            appendOptimistic(echo, to: groupId)
            let previous = sendChain
            let generation = sendGeneration
            let queuedSend = Task { [weak self] in
                _ = await previous?.result
                guard let self,
                      !Task.isCancelled,
                      self.sendGeneration == generation,
                      !self.sendsSuspendedForAccountMutation
                else { return }
                do {
                    guard await self.ensureConnected(timeoutSeconds: 2) else {
                        throw MarmotService.ServiceError.notConnected
                    }
                    guard self.isCurrentAccountWork(generation) else { return }
                    try await self.service.sendText(groupId: groupId, text: text)
                    succeeded = true
                } catch {
                    guard self.isCurrentAccountWork(generation) else { return }
                    self.discardOptimistic(id: echo.id, from: groupId)
                    self.errorText = Self.describe(error)
                }
            }
            sendChain = queuedSend
            await queuedSend.value
            if !succeeded { allOk = false }
        }
        return allOk
    }

    /// Flush text that already owns a mesh/pending echo. Unlike `send(_:to:)`,
    /// this must not create a second optimistic row, and it reports the chain
    /// task's own success flag (Compose / `sendQueuedSticker` parity).
    func sendQueuedText(groupId: String, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sendsSuspendedForAccountMutation else { return false }
        var succeeded = false
        let previous = sendChain
        let generation = sendGeneration
        let queuedSend = Task { [weak self] in
            _ = await previous?.result
            guard let self,
                  !Task.isCancelled,
                  self.sendGeneration == generation,
                  !self.sendsSuspendedForAccountMutation
            else { return }
            do {
                guard await self.ensureConnected(timeoutSeconds: 2) else {
                    throw MarmotService.ServiceError.notConnected
                }
                guard self.isCurrentAccountWork(generation) else { return }
                try await self.service.sendText(groupId: groupId, text: trimmed)
                succeeded = true
            } catch {
                guard self.isCurrentAccountWork(generation) else { return }
                self.errorText = Self.describe(error)
            }
        }
        sendChain = queuedSend
        await queuedSend.value
        guard succeeded else { return false }
        await loadLocalPage(groupId: groupId, mode: .preserveHistoricalWindow)
        Task { [weak self] in try? await self?.service.ensureSubscriptions() }
        return true
    }

    /// Durable outgoing row present for a mesh→WN flush echo (R-011).
    func hasCanonicalOutgoingMatch(groupId: String, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let messages = messagesByGroup[groupId] ?? []
        return messages.contains { message in
            guard message.isMine,
                  !message.id.hasPrefix(Self.optimisticIDPrefix),
                  !message.id.hasPrefix(Self.failedOptimisticIDPrefix)
            else { return false }
            return message.content == trimmed
        }
    }

    func hasCanonicalOutgoingStickerMatch(
        groupId: String,
        packCoordinate: String,
        shortcode: String,
        plaintextSha256: String
    ) -> Bool {
        let messages = messagesByGroup[groupId] ?? []
        return messages.contains { message in
            guard message.isMine,
                  !message.id.hasPrefix(Self.optimisticIDPrefix),
                  !message.id.hasPrefix(Self.failedOptimisticIDPrefix),
                  let ref = message.stickerRef
            else { return false }
            return ref.packCoordinate == packCoordinate
                && ref.shortcode == shortcode
                && ref.plaintextSha256 == plaintextSha256
        }
    }

    private func isCurrentAccountWork(_ generation: UInt64) -> Bool {
        !Task.isCancelled &&
            generation == sendGeneration &&
            !sendsSuspendedForAccountMutation
    }

    /// Media uploads stay parallel, while their task ownership is explicit so
    /// account deletion can cancel and join every operation before wiping.
    private func launchIndependentAccountWork(
        _ operation: @escaping @MainActor (MarmotChatModel, UInt64) async -> Void
    ) {
        guard !sendsSuspendedForAccountMutation else { return }
        let taskID = UUID()
        let generation = sendGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.independentAccountTasks[taskID] = nil }
            guard self.isCurrentAccountWork(generation) else { return }
            await operation(self, generation)
        }
        independentAccountTasks[taskID] = task
    }

    /// Retry a core-backed failed row without creating a second transcript row
    /// or re-running MLS encryption. The core flips the durable row back to
    /// pending before republishing the original encrypted wrapper event.
    func retryMessage(messageId: String) {
        guard !sendsSuspendedForAccountMutation else { return }
        errorText = nil
        launchIndependentAccountWork { model, generation in
            do {
                guard await model.ensureConnected(timeoutSeconds: 2) else {
                    throw MarmotService.ServiceError.notConnected
                }
                guard model.isCurrentAccountWork(generation) else { return }
                let groupId = try await model.service.retryMessage(messageId: messageId)
                guard model.isCurrentAccountWork(generation) else { return }
                await model.loadLocalPage(groupId: groupId, mode: .preserveHistoricalWindow)
            } catch {
                guard model.isCurrentAccountWork(generation) else { return }
                model.errorText = Self.describe(error)
            }
        }
    }

    /// Remove a failed platform-local media echo after its replacement upload
    /// echo is visible, so retry never leaves a gap in the transcript.
    func removeFailedOptimisticMessage(groupId: String, messageId: String) {
        guard Self.isFailedOptimisticMessageId(messageId) else { return }
        pendingOptimistic[groupId]?.removeAll { $0.id == messageId }
        messagesByGroup[groupId, default: []].removeAll { $0.id == messageId }
    }

    /// Send a media attachment (encrypt with the group key, upload the ciphertext
    /// to Blossom, publish the kind-445 with the imeta tag). Refreshes on success.
    func sendMedia(
        groupId: String,
        data: Data,
        filename: String,
        mime: String,
        caption: String = "",
        localPreviewURL: String? = nil,
        onEchoVisible: (() -> Void)? = nil,
        onComplete: (() -> Void)? = nil,
        onFailure: (() -> Void)? = nil
    ) {
        guard !sendsSuspendedForAccountMutation else { return }
        let echo = MarmotService.MarmotMessage(
            id: Self.optimisticIDPrefix + UUID().uuidString,
            senderNpub: npub ?? "",
            content: caption,
            createdAt: Date(),
            isMine: true,
            media: [
                MarmotService.MarmotMedia(
                    url: localPreviewURL ?? "pending-media-\(UUID().uuidString)",
                    mimeType: mime,
                    filename: filename,
                    width: nil,
                    height: nil,
                    durationMs: nil
                )
            ]
        )
        launchIndependentAccountWork { model, generation in
            var echoVisible = false
            let listener = SNMediaUploadListener { [weak model] pendingId, fraction in
                Task { @MainActor in
                    model?.noteMediaUploadProgress(pendingId, fraction)
                }
            }
            model.registerMediaUploadListener(echo.id, listener)
            do {
                // Wait for a local Marmot node (`isConnected`), not relay
                // (`isRelayConnected`). Blossom PUTs do not need relays; kind-445
                // publish still goes through the durable outbox after the URL
                // exists. Without this short wait, cold-start media can fail
                // with notConnected before staging.
                guard await model.ensureConnected(timeoutSeconds: 2) else {
                    throw MarmotService.ServiceError.notConnected
                }
                guard model.isCurrentAccountWork(generation) else { return }
                await model.loadLocalPage(groupId: groupId, mode: .preserveHistoricalWindow)
                guard model.isCurrentAccountWork(generation) else { return }
                model.noteMediaUploadProgress(echo.id, 0)
                model.appendOptimistic(echo, to: groupId)
                echoVisible = true
                onEchoVisible?()
                #if DEBUG
                let uploadStarted = Date()
                SecureLogger.info(
                    "SONAR_BENCH media_upload_begin id=\(echo.id) bytes=\(data.count) mime=\(mime) album=1",
                    category: .session
                )
                #endif
                try await model.service.sendMediaWithProgress(
                    groupId: groupId,
                    data: data,
                    filename: filename,
                    mime: mime,
                    caption: caption,
                    clientPendingId: echo.id,
                    listener: listener
                )
                #if DEBUG
                let ms = Int(Date().timeIntervalSince(uploadStarted) * 1000)
                SecureLogger.info(
                    "SONAR_BENCH media_upload_end id=\(echo.id) ok=1 elapsed_ms=\(ms)",
                    category: .session
                )
                #endif
                model.clearMediaUploadListener(echo.id)
                guard model.isCurrentAccountWork(generation) else { return }
                onComplete?()
                await model.refreshWhenConnected(groupId: groupId, hydrateBeforeSync: false)
            } catch {
                #if DEBUG
                SecureLogger.info(
                    "SONAR_BENCH media_upload_end id=\(echo.id) ok=0 err=\(Self.describe(error))",
                    category: .session
                )
                #endif
                if Self.isMediaUploadInFlight(error) {
                    // Owner (resume or prior send) still uploading — keep echo.
                    return
                }
                // Release the listener and drop the echo even when the account
                // moved on; only the user-visible failure row and errorText are
                // skipped for retired work.
                model.clearMediaUploadListener(echo.id)
                model.discardOptimistic(id: echo.id, from: groupId)
                if Self.isMediaUploadCancelled(error) {
                    return
                }
                guard model.isCurrentAccountWork(generation) else { return }
                if echoVisible {
                    let failed = MarmotService.MarmotMessage(
                        id: Self.failedOptimisticIDPrefix + UUID().uuidString,
                        senderNpub: echo.senderNpub,
                        content: echo.content,
                        createdAt: echo.createdAt,
                        isMine: true,
                        media: echo.media
                    )
                    model.pendingOptimistic[groupId, default: []].append(failed)
                    model.messagesByGroup[groupId, default: []].append(failed)
                }
                onFailure?()
                model.errorText = Self.describe(error)
            }
        }
    }

    /// Send N attachments as ONE album message (single kind-445, N imeta tags).
    /// Shows a single optimistic echo carrying every pending preview so the
    /// transcript paints the card deck immediately; the canonical message
    /// replaces it after publish. Mirrors [sendMedia]'s echo lifecycle.
    func sendMediaAlbum(
        groupId: String,
        items: [MarmotService.MediaAlbumItem],
        caption: String = "",
        localPreviewURLs: [String],
        onEchoVisible: (() -> Void)? = nil,
        onComplete: (() -> Void)? = nil,
        onFailure: (() -> Void)? = nil
    ) {
        guard !sendsSuspendedForAccountMutation,
              !items.isEmpty,
              items.count == localPreviewURLs.count
        else { return }
        let echo = MarmotService.MarmotMessage(
            id: Self.optimisticIDPrefix + UUID().uuidString,
            senderNpub: npub ?? "",
            content: caption,
            createdAt: Date(),
            isMine: true,
            media: zip(items, localPreviewURLs).map { item, url in
                MarmotService.MarmotMedia(
                    url: url,
                    mimeType: item.mime,
                    filename: item.filename,
                    width: nil,
                    height: nil,
                    durationMs: nil
                )
            }
        )
        launchIndependentAccountWork { model, generation in
            var echoVisible = false
            let listener = SNMediaUploadListener { [weak model] pendingId, fraction in
                Task { @MainActor in
                    model?.noteMediaUploadProgress(pendingId, fraction)
                }
            }
            model.registerMediaUploadListener(echo.id, listener)
            do {
                // Same as sendMedia: local node only — not `ensureRelayConnected`.
                guard await model.ensureConnected(timeoutSeconds: 2) else {
                    throw MarmotService.ServiceError.notConnected
                }
                guard model.isCurrentAccountWork(generation) else { return }
                await model.loadLocalPage(groupId: groupId, mode: .preserveHistoricalWindow)
                guard model.isCurrentAccountWork(generation) else { return }
                model.noteMediaUploadProgress(echo.id, 0)
                model.appendOptimistic(echo, to: groupId)
                echoVisible = true
                onEchoVisible?()
                #if DEBUG
                let uploadStarted = Date()
                let albumBytes = items.reduce(0) { $0 + $1.data.count }
                SecureLogger.info(
                    "SONAR_BENCH media_upload_begin id=\(echo.id) bytes=\(albumBytes) mime=album album=\(items.count)",
                    category: .session
                )
                #endif
                try await model.service.sendMediaMultiWithProgress(
                    groupId: groupId,
                    items: items,
                    caption: caption,
                    clientPendingId: echo.id,
                    listener: listener
                )
                #if DEBUG
                let ms = Int(Date().timeIntervalSince(uploadStarted) * 1000)
                SecureLogger.info(
                    "SONAR_BENCH media_upload_end id=\(echo.id) ok=1 elapsed_ms=\(ms)",
                    category: .session
                )
                #endif
                model.clearMediaUploadListener(echo.id)
                guard model.isCurrentAccountWork(generation) else { return }
                onComplete?()
                await model.refreshWhenConnected(groupId: groupId, hydrateBeforeSync: false)
            } catch {
                #if DEBUG
                SecureLogger.info(
                    "SONAR_BENCH media_upload_end id=\(echo.id) ok=0 err=\(Self.describe(error))",
                    category: .session
                )
                #endif
                if Self.isMediaUploadInFlight(error) {
                    return
                }
                // Release the listener and drop the echo even when the account
                // moved on; only the user-visible failure row and errorText are
                // skipped for retired work.
                model.clearMediaUploadListener(echo.id)
                model.discardOptimistic(id: echo.id, from: groupId)
                if Self.isMediaUploadCancelled(error) {
                    return
                }
                guard model.isCurrentAccountWork(generation) else { return }
                if echoVisible {
                    let failed = MarmotService.MarmotMessage(
                        id: Self.failedOptimisticIDPrefix + UUID().uuidString,
                        senderNpub: echo.senderNpub,
                        content: echo.content,
                        createdAt: echo.createdAt,
                        isMine: true,
                        media: echo.media
                    )
                    model.pendingOptimistic[groupId, default: []].append(failed)
                    model.messagesByGroup[groupId, default: []].append(failed)
                }
                onFailure?()
                model.errorText = Self.describe(error)
            }
        }
    }

    func sendSticker(
        groupId: String,
        packCoordinate: String,
        shortcode: String,
        plaintextSha256: String,
        onEchoVisible: (() -> Void)? = nil,
        onComplete: (() -> Void)? = nil,
        onFailure: (() -> Void)? = nil
    ) {
        guard !sendsSuspendedForAccountMutation else { return }
        errorText = nil
        let echo = MarmotService.MarmotMessage(
            id: Self.optimisticIDPrefix + UUID().uuidString,
            senderNpub: npub ?? "",
            content: "",
            createdAt: Date(),
            isMine: true,
            media: [],
            stickerRef: MarmotService.MarmotStickerRef(
                packCoordinate: packCoordinate,
                shortcode: shortcode,
                plaintextSha256: plaintextSha256
            )
        )
        appendOptimistic(echo, to: groupId)
        onEchoVisible?()

        let previous = sendChain
        let generation = sendGeneration
        sendChain = Task { [weak self] in
            _ = await previous?.result
            guard let self,
                  !Task.isCancelled,
                  self.sendGeneration == generation,
                  !self.sendsSuspendedForAccountMutation
            else { return }
            do {
                guard await self.ensureConnected(timeoutSeconds: 2) else {
                    throw MarmotService.ServiceError.notConnected
                }
                try await self.service.sendSticker(
                    groupId: groupId,
                    packCoordinate: packCoordinate,
                    shortcode: shortcode,
                    plaintextSha256: plaintextSha256
                )
                onComplete?()
            } catch {
                self.pendingOptimistic[groupId]?.removeAll { $0.id == echo.id }
                self.messagesByGroup[groupId, default: []].removeAll { $0.id == echo.id }
                let failed = MarmotService.MarmotMessage(
                    id: Self.failedOptimisticIDPrefix + UUID().uuidString,
                    senderNpub: echo.senderNpub,
                    content: echo.content,
                    createdAt: echo.createdAt,
                    isMine: true,
                    media: [],
                    stickerRef: echo.stickerRef
                )
                self.pendingOptimistic[groupId, default: []].append(failed)
                self.messagesByGroup[groupId, default: []].append(failed)
                onFailure?()
                self.errorText = Self.describe(error)
                return
            }
            // The core writes the canonical row locally before publishing.
            // Refresh outside the send chain so the next queued send never
            // waits on transcript hydration or relay subscription work.
            Task { [weak self] in
                await self?.loadLocalPage(groupId: groupId, mode: .preserveHistoricalWindow)
                try? await self?.service.ensureSubscriptions()
            }
        }
    }

    /// Flush a sticker that already owns an optimistic echo in the pending-chat
    /// queue. Unlike `sendSticker`, this must not create a second echo, and it
    /// reports the actual local-core send result so Apple matches Compose.
    func sendQueuedSticker(
        groupId: String,
        packCoordinate: String,
        shortcode: String,
        plaintextSha256: String
    ) async -> Bool {
        guard !sendsSuspendedForAccountMutation else { return false }
        var succeeded = false
        let previous = sendChain
        let generation = sendGeneration
        let queuedSend = Task { [weak self] in
            _ = await previous?.result
            guard let self,
                  !Task.isCancelled,
                  self.sendGeneration == generation,
                  !self.sendsSuspendedForAccountMutation
            else { return }
            do {
                guard await self.ensureConnected(timeoutSeconds: 2) else {
                    throw MarmotService.ServiceError.notConnected
                }
                try await self.service.sendSticker(
                    groupId: groupId,
                    packCoordinate: packCoordinate,
                    shortcode: shortcode,
                    plaintextSha256: plaintextSha256
                )
                succeeded = true
            } catch {
                self.errorText = Self.describe(error)
            }
        }
        sendChain = queuedSend
        await queuedSend.value
        guard succeeded else { return false }
        // Keep the transferred pending echo visible until this bounded local
        // hydration observes the canonical row written by the core.
        await loadLocalPage(groupId: groupId, mode: .preserveHistoricalWindow)
        Task { [weak self] in try? await self?.service.ensureSubscriptions() }
        return true
    }

    func fetchStickerPack(
        authorPubkeyHex: String,
        identifier: String,
        relayUrls: [String],
        expectedGeneration: UInt64? = nil
    ) async -> StickerPackInfo? {
        let generation = expectedGeneration ?? stickerCacheGeneration
        guard !Task.isCancelled, stickerCacheGeneration == generation else { return nil }
        let cacheKey = "30031:\(authorPubkeyHex.lowercased()):\(identifier)"
        if let cached = stickerPacksByCoordinate[cacheKey] {
            touchStickerPack(cacheKey)
            return cached
        }
        do {
            // Do not gate on ensureRelayConnected: core is local-first for
            // validated disk metadata, and a warm cache must not wait on relays.
            let pack = try await service.fetchStickerPack(
                authorPubkeyHex: authorPubkeyHex,
                identifier: identifier,
                relayUrls: relayUrls
            )
            guard !Task.isCancelled, stickerCacheGeneration == generation else { return nil }
            rememberStickerPack(pack, cacheKey: cacheKey)
            return pack
        } catch MarmotService.ServiceError.cancelled {
            return nil
        } catch {
            SecureLogger.debug(
                "sticker pack lookup failed: \(Self.describe(error))",
                category: .session
            )
            return nil
        }
    }

    /// App-lifetime pack metadata already verified/fetched by the core.
    /// Picker views use this synchronously for a zero-spinner first frame.
    func cachedStickerPacksSnapshot() -> [StickerPackInfo] {
        stickerPackLRU.compactMap { coordinate in
            guard let pack = stickerPacksByCoordinate[coordinate] else { return nil }
            return Self.shouldExposeCachedStickerPack(
                coordinate: coordinate,
                installedCoordinates: installedPackCoordinates
            ) ? pack : nil
        }
    }

    func fetchStickerImage(
        url: String,
        expectedSha256: String,
        expectedGeneration: UInt64? = nil
    ) async -> Data? {
        let generation = expectedGeneration ?? stickerCacheGeneration
        guard !Task.isCancelled, stickerCacheGeneration == generation else { return nil }
        if let cached = stickerImageFromMemory(expectedSha256: expectedSha256) { return cached }
        do {
            let data = try await service.fetchStickerImage(url: url, expectedSha256: expectedSha256)
            guard !Task.isCancelled, stickerCacheGeneration == generation else { return nil }
            rememberStickerImage(data, expectedSha256: expectedSha256)
            return data
        } catch MarmotService.ServiceError.cancelled {
            return nil
        } catch {
            SecureLogger.debug(
                "sticker image lookup failed: \(Self.describe(error))",
                category: .session
            )
            return nil
        }
    }

    /// Resolve a received sticker. Never gated on the pack being installed: the
    /// picker's installed list decides what you can SEND, while anything a peer
    /// sends must render from the reference alone (pack metadata off the relay,
    /// bytes off Blossom, both hash-verified).
    ///
    /// `userInitiated` marks an explicit tap on the failed placeholder, which
    /// always retries even a ref previously judged unresolvable.
    func stickerData(
        for ref: MarmotService.MarmotStickerRef,
        userInitiated: Bool = false
    ) async -> Data? {
        let generation = stickerCacheGeneration
        let refKey = Self.stickerRefMemoryKey(
            packCoordinate: ref.packCoordinate,
            shortcode: ref.shortcode,
            plaintextSha256: ref.plaintextSha256
        )
        // The core is the sole authority on whether the LATEST validated pack
        // still authorizes this exact ref, so every ref lookup asks it. There is
        // deliberately no host-side memory shortcut here: the byte LRU is keyed
        // by sha alone and cannot answer "does the current pack still contain
        // this sticker", which is what the core's validated read enforces.
        switch await cachedStickerImage(for: ref, generation: generation) {
        case .hit(let data):
            return data
        case .invalidated:
            return nil
        case .miss:
            break
        }
        guard stickerCacheGeneration == generation else { return nil }
        // A ref the latest pack has already disowned must not re-drive relay
        // work on every bubble mount and retry tick — but a human tap is
        // bounded by the human, so it always gets a fresh attempt.
        if userInitiated {
            forgetUnresolvableStickerRef(refKey)
        } else if unresolvableStickerRefKeySet.contains(refKey) {
            return nil
        }
        guard let parts = Self.stickerPackParts(ref.packCoordinate),
              let pack = await fetchStickerPack(
                  authorPubkeyHex: parts.author,
                  identifier: parts.identifier,
                  relayUrls: [],
                  expectedGeneration: generation
              )
        else { return nil }
        func matching(_ pack: StickerPackInfo) -> StickerInfo? {
            pack.stickers.first(where: {
                $0.shortcode == ref.shortcode &&
                    $0.sha256.caseInsensitiveCompare(ref.plaintextSha256) == .orderedSame
            })
        }
        var sticker = matching(pack)
        if sticker == nil {
            // Session pack metadata can be stale: a sticker published to the
            // pack after this session cached its metadata — or a copy served
            // by the offline validated-local fallback — is missing from the
            // cached copy while every older sticker still renders. Evict and
            // refetch once so one early failed relay fetch cannot pin a stale
            // pack for the session.
            guard stickerCacheGeneration == generation else { return nil }
            evictStickerPack(coordinate: ref.packCoordinate)
            guard let refreshed = await fetchStickerPack(
                authorPubkeyHex: parts.author,
                identifier: parts.identifier,
                relayUrls: [],
                expectedGeneration: generation
            ) else { return nil }
            sticker = matching(refreshed)
            if sticker == nil {
                // Only trust "not in pack" when we actually reached a relay.
                // The core falls back to stale validated-local metadata when the
                // fetch fails, so negative-caching an offline answer would keep
                // a perfectly good sticker black for the rest of the session —
                // exactly the stale-metadata failure this PR exists to fix.
                if stickerCacheGeneration == generation, service.isRelayConnected() {
                    rememberUnresolvableStickerRef(refKey)
                }
                return nil
            }
        }
        guard let sticker else { return nil }
        return await fetchStickerImage(
            url: sticker.url,
            expectedSha256: ref.plaintextSha256,
            expectedGeneration: generation
        )
    }

    private func cachedStickerImage(
        for ref: MarmotService.MarmotStickerRef,
        generation: UInt64
    ) async -> CachedStickerImageResult {
        let data = try? await service.cachedStickerImage(for: ref)
        switch Self.stickerCacheLookupState(
            hasData: data != nil,
            startedGeneration: generation,
            currentGeneration: stickerCacheGeneration
        ) {
        case .hit:
            guard let data else { return .miss }
            rememberStickerImage(data, expectedSha256: ref.plaintextSha256)
            return .hit(data)
        case .miss:
            return .miss
        case .invalidated:
            return .invalidated
        }
    }

    private func stickerImageFromMemory(expectedSha256: String) -> Data? {
        #if DEBUG
        let started = stickerBenchmarkRecording ? DispatchTime.now().uptimeNanoseconds : nil
        #endif
        let cacheKey = expectedSha256.lowercased()
        guard let cached = stickerImagesBySHA256[cacheKey] else { return nil }
        stickerImageLRU.removeAll { $0 == cacheKey }
        stickerImageLRU.append(cacheKey)
        #if DEBUG
        if let started {
            let elapsedMicroseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000
            SecureLogger.info(
                "SONAR_BENCH sticker_image_fetch purpose=foreground source=memory " +
                    "bytes=\(cached.count) total_us=\(elapsedMicroseconds)",
                category: .session
            )
        }
        #endif
        return cached
    }

    private func rememberStickerImage(_ data: Data, expectedSha256: String) {
        let cacheKey = expectedSha256.lowercased()
        if let replaced = stickerImagesBySHA256.removeValue(forKey: cacheKey) {
            stickerImageMemoryBytes -= replaced.count
        }
        stickerImageLRU.removeAll { $0 == cacheKey }
        guard data.count <= Self.stickerImageMemoryBudgetBytes else { return }
        while stickerImagesBySHA256.count >= Self.stickerImageMemoryEntryLimit
            || stickerImageMemoryBytes + data.count > Self.stickerImageMemoryBudgetBytes {
            guard !stickerImageLRU.isEmpty else { break }
            let oldest = stickerImageLRU.removeFirst()
            if let removed = stickerImagesBySHA256.removeValue(forKey: oldest) {
                stickerImageMemoryBytes -= removed.count
            }
        }
        stickerImagesBySHA256[cacheKey] = data
        stickerImageLRU.append(cacheKey)
        stickerImageMemoryBytes += data.count
    }

    private func clearStickerImageMemoryCache() {
        stickerImagesBySHA256 = [:]
        stickerImageLRU = []
        stickerImageMemoryBytes = 0
    }

    private func clearStickerCaches() {
        stickerCacheGeneration = stickerCacheGeneration &+ 1
        stickerPacksByCoordinate = [:]
        stickerPackLRU = []
        unresolvableStickerRefKeys = []
        unresolvableStickerRefKeySet = []
        clearStickerImageMemoryCache()
        installedPackCoordinates = []
    }

    /// Cache insertion kept as one production path so identity-reset regression
    /// tests can seed the same picker state that relay hydration creates.
    func rememberStickerPack(_ pack: StickerPackInfo, cacheKey: String) {
        let normalized = snNormalizeStickerPackCoordinate(cacheKey)
        stickerPacksByCoordinate.removeValue(forKey: normalized)
        stickerPackLRU.removeAll { $0 == normalized }
        if stickerPacksByCoordinate.count >= 20, let oldest = stickerPackLRU.first {
            stickerPacksByCoordinate.removeValue(forKey: oldest)
            stickerPackLRU.removeFirst()
        }
        stickerPacksByCoordinate[normalized] = pack
        stickerPackLRU.append(normalized)
    }

    private func touchStickerPack(_ cacheKey: String) {
        stickerPackLRU.removeAll { $0 == cacheKey }
        stickerPackLRU.append(cacheKey)
    }

    /// Drop one pack's session metadata so the next fetch consults the relay
    /// again. Used when a transcript ref is missing from the cached copy.
    private func evictStickerPack(coordinate: String) {
        let normalized = snNormalizeStickerPackCoordinate(coordinate)
        stickerPacksByCoordinate.removeValue(forKey: normalized)
        stickerPackLRU.removeAll { $0 == normalized }
    }

    private func forgetUnresolvableStickerRef(_ refKey: String) {
        guard unresolvableStickerRefKeySet.remove(refKey) != nil else { return }
        unresolvableStickerRefKeys.removeAll { $0 == refKey }
    }

    private func rememberUnresolvableStickerRef(_ refKey: String) {
        guard !unresolvableStickerRefKeySet.contains(refKey) else { return }
        while unresolvableStickerRefKeys.count >= Self.unresolvableStickerRefLimit {
            let oldest = unresolvableStickerRefKeys.removeFirst()
            unresolvableStickerRefKeySet.remove(oldest)
        }
        unresolvableStickerRefKeys.append(refKey)
        unresolvableStickerRefKeySet.insert(refKey)
    }

    func replaceInstalledPackCoordinates(_ coordinates: [String]) {
        installedPackCoordinates = Set(coordinates.map(snNormalizeStickerPackCoordinate))
    }

    func fetchInstalledPacks() async -> [String]? {
        let generation = stickerCacheGeneration
        do {
            let coords = try await service.fetchInstalledPacks()
            guard stickerCacheGeneration == generation else { return nil }
            replaceInstalledPackCoordinates(coords)
            return coords
        } catch {
            guard stickerCacheGeneration == generation else { return nil }
            self.errorText = Self.describe(error)
            return nil
        }
    }

    func isStickerPackInstalled(_ coordinate: String) -> Bool {
        installedPackCoordinates.contains(snNormalizeStickerPackCoordinate(coordinate))
    }

    func installStickerPack(coordinate: String) async -> Bool {
        let generation = stickerCacheGeneration
        do {
            try await service.installStickerPack(coordinate: coordinate)
            guard stickerCacheGeneration == generation else { return false }
            installedPackCoordinates.insert(snNormalizeStickerPackCoordinate(coordinate))
            return true
        } catch {
            guard stickerCacheGeneration == generation else { return false }
            self.errorText = Self.describe(error)
            return false
        }
    }

    func uninstallStickerPack(coordinate: String) async -> Bool {
        let generation = stickerCacheGeneration
        do {
            try await service.uninstallStickerPack(coordinate: coordinate)
            guard stickerCacheGeneration == generation else { return false }
            let normalized = snNormalizeStickerPackCoordinate(coordinate)
            installedPackCoordinates.remove(normalized)
            // Signal separates saved/available metadata from installed packs;
            // the composer cache only represents the installed picker surface.
            stickerPacksByCoordinate.removeValue(forKey: normalized)
            stickerPackLRU.removeAll { $0 == normalized }
            return true
        } catch {
            guard stickerCacheGeneration == generation else { return false }
            self.errorText = Self.describe(error)
            return false
        }
    }

    /// Download + decrypt a media blob. The store caches the decoded image.
    func fetchMedia(groupId: String, url: String) async -> Data? {
        do {
            return try await service.fetchMedia(groupId: groupId, url: url)
        } catch {
            let description = Self.describe(error)
            SecureLogger.warning("SonarMedia: Marmot fetchMedia failed group=\(groupId.prefix(12)) urlHash=\(Self.mediaLogId(for: url)) error=\(description)", category: .session)
            self.errorText = description
            return nil
        }
    }

    /// Download and decrypt media directly into a private partial file. Errors
    /// are propagated so the attachment bubble can present retry/cancel state
    /// without turning a transfer failure into a global chat error.
    func fetchMediaToFile(
        groupId: String,
        url: String,
        destination: URL,
        listener: MediaDownloadListener
    ) async throws -> UInt64 {
        try await service.fetchMediaToFile(
            groupId: groupId,
            url: url,
            destination: destination,
            listener: listener
        )
    }

    private static func mediaLogId(for url: String) -> String {
        SHA256.hash(data: Data(url.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func stickerPackParts(_ coordinate: String) -> (author: String, identifier: String)? {
        let parts = coordinate.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "30031" else { return nil }
        return (String(parts[1]), String(parts[2]))
    }

    /// Drive LIVE updates off the core's watermarked relay subscriptions: park
    /// on `waitForMarmotEvent` and, the instant a welcome/message is pushed,
    /// drain + process it and reload the UI from the local DB. On the idle
    /// timeout (no push), re-subscribe with the current watermark to self-heal
    /// after relay disconnects — much lighter than the old `refresh()`/`sync()`
    /// poll that did a full blocking fetch.
    func startPolling() {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.refreshStaleProfiles() {
                    await self.loadLocalSummaries()
                }
                let woke = await self.service.waitForMarmotEvent(timeoutSeconds: 25)
                if Task.isCancelled { return }
                #if DEBUG
                // SONAR_BENCH: first waitForMarmotEvent returned (T3b). t3a→t3b is
                // the wait; t3b→t4 is the drainPending() MLS processing cost.
                if !self.benchFirstWakeLogged {
                    self.benchFirstWakeLogged = true
                    SecureLogger.info("SONAR_BENCH t3b_first_wake woke=\(woke ? 1 : 0)", category: .session)
                }
                #endif
                if woke {
                    let notifications = (try? await self.service.drainPending()) ?? []
                    // If a push refresh is awaiting gap recovery, keep the
                    // notification metadata for SonarPushProcessor — drain is
                    // destructive and this path only paints the UI.
                    self.noteDrainedForPushWake(notifications)
                    #if DEBUG
                    // SONAR_BENCH: first post-connect event burst applied to local
                    // storage (T4) — the cold-start relay sync has produced data.
                    if !self.benchFirstDrainLogged {
                        self.benchFirstDrainLogged = true
                        SecureLogger.info("SONAR_BENCH t4_first_drain woke=1 notif=\(notifications.count)", category: .session)
                    }
                    #endif
                    if !notifications.isEmpty {
                        await self.loadLocalSummaries()
                    }
                    // Advance historical per-group catch-up on live cycles too.
                    // Steady live traffic keeps woke true; core throttles this
                    // pass, so most ticks are a cheap no-op. Do not retry the
                    // outbox here: that can republish in-flight Pending rows.
                    // `try?` elsewhere is fine, but a suspend abort must stop
                    // the loop here too: swallowing it lets the loop iterate
                    // once more, and that iteration's `notConnected` (the node
                    // is gone by then) falls into the idle catch below and arms
                    // a reconnect that reopens the store while backgrounded.
                    do {
                        try await self.service.ensureSubscriptions()
                    } catch {
                        if Self.isSuspendInterrupted(error) {
                            self.syncTask = nil
                            return
                        }
                    }
                } else {
                    #if DEBUG
                    // SONAR_BENCH: first wait cycle resolved with no buffered events
                    // (initial subscription EOSE was empty — nothing new to sync).
                    if !self.benchFirstDrainLogged {
                        self.benchFirstDrainLogged = true
                        SecureLogger.info("SONAR_BENCH t4_first_drain woke=0 notif=0", category: .session)
                    }
                    #endif
                    do {
                        try await self.service.ensureSubscriptions()
                    } catch {
                        // A suspend abort is not a lost subscription — the node
                        // is being closed for background suspension. Falling
                        // into the reconnect path below would arm
                        // scheduleRelayConnect(2s), and because closeNode()
                        // clears `nodeClosing` when it finishes, that task can
                        // REOPEN the SQLCipher store while the app is still
                        // backgrounded — the exact 0xdead10cc kill this close
                        // exists to prevent (the same hazard
                        // closeStoreAfterBackgroundWake() cancels relayConnectTask
                        // for). Just stop the loop; the foreground resume
                        // restarts polling through performConnect.
                        if Self.isSuspendInterrupted(error) {
                            self.syncTask = nil
                            return
                        }
                        self.relayConnected = false
                        self.errorText = Self.describe(error)
                        SecureLogger.warning("⚠️ Marmot relay subscription lost: \(self.errorText ?? "unknown error")", category: .session)
                        self.syncTask = nil
                        self.scheduleRelayConnect(delaySeconds: 2)
                        return
                    }
                }
            }
        }
    }

    func stopPolling() {
        relayConnectTask?.cancel()
        relayConnectTask = nil
        // Latch core cancel before clearing the Task slot so an in-flight quiet
        // resume on mediaLane observes cancel (observer=None otherwise ignores
        // Task.cancel). Do not nil the slot until the task finishes — same
        // stacked-resume hazard as gapRecovery.
        let resume = mediaResumeTask
        mediaResumeTask?.cancel()
        service.cancelAllMediaUploads()
        Task { [weak self] in
            _ = await resume?.value
            await MainActor.run {
                // Task is a struct — identity `===` is unavailable. Clear the
                // slot after this resume finishes; a newer schedule replaces it.
                if resume != nil {
                    self?.mediaResumeTask = nil
                }
            }
        }
        syncTask?.cancel()
        syncTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        // Do not nil/cancel `gapRecoveryTask` here: UniFFI `syncForce` is not
        // abortable, and clearing the slot would allow a stacked second fetch.
        // Wipe paths bump generation explicitly below.
    }

    // MARK: - P2P calls (pass-throughs to the call engine in MarmotService)

    func callStart() async throws {
        guard await ensureRelayConnected() else { throw MarmotService.ServiceError.notConnected }
        try await service.callStart()
    }
    func callLocalAddress() async throws -> String { try await service.callLocalAddress() }
    func callPlace(callId: String, video: Bool) async throws { try await service.callPlace(callId: callId, video: video) }
    func callIncomingOffer(callId: String, addrB64: String, video: Bool) async throws {
        try await service.callIncomingOffer(callId: callId, addrB64: addrB64, video: video)
    }
    func callAnswer(callId: String, answer: CallAnswerKind, addrB64: String) async throws {
        try await service.callAnswer(callId: callId, answer: answer, addrB64: addrB64)
    }
    func callAccept(callId: String) async throws { try await service.callAccept(callId: callId) }
    func callHangup(callId: String) async throws { try await service.callHangup(callId: callId) }
    func callSetMuted(callId: String, muted: Bool) async throws {
        try await service.callSetMuted(callId: callId, muted: muted)
    }
    func callWaitEvent(timeoutSeconds: UInt64) async -> CallEventInfo? {
        await service.callWaitEvent(timeoutSeconds: timeoutSeconds)
    }

    /// Drop one group from in-memory home/transcript state immediately so Delete
    /// / Leave paint like Compose (filter chats first) instead of waiting on FFI.
    func dropGroupFromLocalState(_ groupId: String) {
        groups.removeAll { $0.id == groupId }
        messagesByGroup[groupId] = nil
        conversationSummariesByGroup[groupId] = nil
        discardOptimistic(for: groupId)
        localTranscriptCursorByGroup[groupId] = nil
        localTranscriptHasOlderByGroup[groupId] = nil
        localTranscriptLoadingGroups.remove(groupId)
        localTranscriptPreservesOlderEdgeGroups.remove(groupId)
        unreadByGroup[groupId] = nil
        SNMarmotChatSnapshotCache.save(groups: groups, messagesByGroup: messagesByGroup, to: defaults)
    }

    /// Delete ONE White Noise / Marmot chat locally (messages + MLS keys), then
    /// drop it from the in-memory state. Local-only — the peer is not notified.
    func deleteGroup(_ groupId: String) async throws {
        // Optimistic list paint before durable purge (core delete is local-first;
        // still avoid waiting behind other workQueue items for first paint).
        dropGroupFromLocalState(groupId)
        SecureLogger.info("deleteGroup begin id=\(groupId.prefix(12))", category: .session)
        do {
            try await service.deleteGroup(groupId: groupId)
            SecureLogger.info("deleteGroup ok id=\(groupId.prefix(12))", category: .session)
        } catch {
            SecureLogger.error(error, context: "deleteGroup failed id=\(groupId.prefix(12))", category: .session)
            throw error
        }
        profileFetches = []
        profileFetchedAt = [:]
        installedPackCoordinates = []
    }

    /// Leave a multi-member Marmot group, then drop it from the in-memory state.
    func leaveGroup(_ groupId: String) async throws {
        dropGroupFromLocalState(groupId)
        SecureLogger.info("leaveGroup begin id=\(groupId.prefix(12))", category: .session)
        do {
            try await service.leaveGroup(groupId)
            SecureLogger.info("leaveGroup ok id=\(groupId.prefix(12))", category: .session)
        } catch {
            errorText = Self.describe(error)
            SecureLogger.error(error, context: "leaveGroup failed id=\(groupId.prefix(12))", category: .session)
            throw error
        }
        profileFetches = []
        profileFetchedAt = [:]
        installedPackCoordinates = []
    }

    /** Stop every send/setup task and await the tail before deleting state.
     * Cancelling without awaiting is insufficient because the FFI operation
     * already in progress may complete non-cancellably. The send-chain tail
     * joins every predecessor; the generation check retires queued successors. */
    @discardableResult
    private func quiesceAccountWork() async -> Bool {
        guard !sendsSuspendedForAccountMutation else { return false }
        sendsSuspendedForAccountMutation = true
        sendGeneration &+= 1
        let chain = sendChain
        sendChain = nil
        chain?.cancel()

        let setups = directChatSetupTasks.values.map(\.task)
        directChatSetupTasks = [:]
        pendingDirectChats = [:]
        setups.forEach { $0.cancel() }

        let independentTasks = Array(independentAccountTasks.values)
        independentAccountTasks = [:]
        independentTasks.forEach { $0.cancel() }

        if let chain { await chain.value }
        for setup in setups { _ = await setup.value }
        for task in independentTasks { await task.value }
        return true
    }

    private func resumeAccountWork(ifOwned ownsMutation: Bool) {
        if ownsMutation {
            sendsSuspendedForAccountMutation = false
        }
    }

    /// Keep the model quiesced across host-owned cache/wallet deletion too.
    /// The returned lease must be passed to [resumeAccountWorkAfterHostMutation].
    func suspendAccountWorkForHostMutation() async -> Bool {
        await quiesceAccountWork()
    }

    func resumeAccountWorkAfterHostMutation(_ mutationLease: Bool) {
        resumeAccountWork(ifOwned: mutationLease)
    }

    /// Panic-wipe the encrypted Marmot database + its Keychain key and reset
    /// in-memory state. Called from the emergency-wipe path.
    func wipeDatabase() async {
        let mutationLease = await quiesceAccountWork()
        defer { resumeAccountWork(ifOwned: mutationLease) }
        stopPolling()
        invalidateGapRecovery()
        conversationRefreshTask?.cancel()
        conversationRefreshTask = nil
        pendingConversationRefreshGroups = []
        clearIdentityScopedState()
        clearAccountContactDescriptors()
        do {
            try await service.wipeDatabase()
        } catch {
            SecureLogger.error(error, context: "Marmot panic wipe failed", category: .session)
        }
    }

    /// Reset every account-bound in-memory/cache value through the same path as
    /// panic wipe, then await deletion of the old persistent database. The wipe
    /// operation is injected so tests can verify ordering without touching the
    /// developer's real application-support directory.
    func prepareForIdentityReplacement(wipeDatabase: () async throws -> Void) async throws {
        let mutationLease = await quiesceAccountWork()
        defer { resumeAccountWork(ifOwned: mutationLease) }
        stopPolling()
        invalidateGapRecovery()
        clearIdentityScopedState()
        clearAccountContactDescriptors()
        try await wipeDatabase()
    }

    /// Drop the single-flight gap-recovery slot on account teardown. Soft-cancel
    /// only — in-flight UniFFI `syncForce` still finishes on `workQueue`.
    private func invalidateGapRecovery() {
        gapRecoveryGeneration &+= 1
        gapRecoveryTask?.cancel()
        gapRecoveryTask = nil
        gapRecoveryUnclaimedDrain = nil
        pushWakeDrainWaiters = 0
        pushWakeDrainActive = false
        pushWakeDrainBuffer = []
    }

    private func clearIdentityScopedState() {
        relayConnected = false
        npub = nil
        groups = []
        pendingGroupInvites = []
        messagesByGroup = [:]
        conversationSummariesByGroup = [:]
        unreadByGroup = [:]
        unreadSuppressGroupIds = []
        viewingUnreadGroupIds = []
        pendingOptimistic = [:]
        preexistingCanonicalMessageIDsByOptimisticID = [:]
        localTranscriptCursorByGroup = [:]
        localTranscriptHasOlderByGroup = [:]
        localTranscriptLoadingGroups = []
        localTranscriptPreservesOlderEdgeGroups = []
        descriptorBolt12Offer = nil
        profilesByNpub = [:]
        profileFetches = []
        profileFetchedAt = [:]
        // Invalidate any in-flight syncForce slot so a post-wipe wake cannot
        // join the previous identity's FETCH_TIMEOUT park.
        gapRecoveryGeneration &+= 1
        gapRecoveryTask = nil
        gapRecoveryUnclaimedDrain = nil
        pushWakeDrainWaiters = 0
        pushWakeDrainActive = false
        pushWakeDrainBuffer = []
        refreshTask?.cancel()
        refreshTask = nil
        clearStickerCaches()
        // Invalidate every deferred contact-cache write queued so far, so none
        // of them can commit after these clears.
        contactCacheWriteGeneration &+= 1
        profileCacheScheduledSeq = 0; profileCacheCommittedSeq = 0
        descriptorCacheScheduledSeq = 0; descriptorCacheCommittedSeq = 0
        SNMarmotProfileCache.clear(from: defaults)
        SNMarmotChatSnapshotCache.clear(from: defaults)
    }

    /// Drop every peer descriptor (their BOLT12 offers and call routes) plus the
    /// durable cache.
    ///
    /// Identity-replacement ONLY. `eraseChatsKeepIdentity()` must not call this:
    /// the account survives that flow, so wiping descriptors would strip a pure
    /// White Noise contact's payment affordance until a relay fetch succeeds.
    /// Compose `eraseAllChats()` retains `sonarDescriptorsByNpubHex` for the
    /// same reason.
    private func clearAccountContactDescriptors() {
        sonarDescriptorsByNpub = [:]
        sonarDescriptorMissesByNpub = [:]
        sonarDescriptorFetchedAtByNpub = [:]
        descriptorFetches = []
        descriptorCacheGeneration &+= 1
        contactCacheWriteGeneration &+= 1
        descriptorCacheScheduledSeq = 0; descriptorCacheCommittedSeq = 0
        SNMarmotDescriptorCache.clear(from: defaults)
    }

    /// Erase every White Noise / Marmot chat but KEEP the identity: wipe the
    /// encrypted DB (which preserves `marmot-nsec`, deleting only the DB and
    /// its SQLCipher key), then reconnect with the same nsec so a fresh, empty
    /// store is opened and our KeyPackage is republished — new secure chats
    /// keep working. Used by "erase all chats" (not the full panic wipe).
    func eraseChatsKeepIdentity() async {
        let mutationLease = await quiesceAccountWork()
        defer { resumeAccountWork(ifOwned: mutationLease) }
        let wasPolling = syncTask != nil
        stopPolling()
        conversationRefreshTask?.cancel()
        conversationRefreshTask = nil
        pendingConversationRefreshGroups = []
        clearIdentityScopedState()
        do {
            try await service.wipeDatabase()
        } catch {
            errorText = Self.describe(error)
            return
        }
        errorText = nil
        // Reopen a fresh DB with the SAME identity and republish our KeyPackage.
        // Await a FORCED reconnect (not `connectIfNeeded()`, whose busy/npub
        // guard could silently skip it and leave the node "not connected yet").
        busy = true
        let connected = await performConnect()
        busy = false
        if wasPolling && connected { startPolling() }
    }

    /// Short label for a 1:1 group: the other member's npub prefix.
    func title(for group: MarmotService.MarmotGroup) -> String {
        let others = otherMembers(in: group)
        guard others.count == 1, let other = others.first else {
            return group.name.isEmpty ? "Group chat" : group.name
        }
        // A 1:1 group is titled by the counterpart's LIVE kind-0 profile name.
        // The MLS group name is a creation-time snapshot (e.g. sonar-cli
        // --group-name) and must not freeze the row or shadow a rename.
        if let name = displayName(forNpub: other) { return name }
        ensureProfile(other)
        return group.name.isEmpty ? String(other.prefix(12)) + "…" : group.name
    }

    func otherMembers(in group: MarmotService.MarmotGroup) -> [String] {
        let ownKey = npub.map(SNMarmotProfileCache.canonicalKey)
        return Array(Set(group.memberNpubs.map(SNMarmotProfileCache.canonicalKey).filter {
            guard !$0.isEmpty else { return false }
            guard let ownKey else { return true }
            return $0 != ownKey
        })).sorted()
    }

    func isDirectGroup(_ group: MarmotService.MarmotGroup) -> Bool {
        snDirectMarmotPeerKey(for: group, ownNpub: npub) != nil
    }

    func directGroup(forNpub peerNpub: String) -> MarmotService.MarmotGroup? {
        let target = SNMarmotProfileCache.canonicalKey(peerNpub)
        return groups.first { snDirectMarmotPeerKey(for: $0, ownNpub: npub) == target }
    }

    private func dropResolvedPendingDirectChats() {
        guard !pendingDirectChats.isEmpty else { return }
        for npub in pendingDirectChats.keys where directGroup(forNpub: npub) != nil {
            pendingDirectChats[npub] = nil
        }
    }

    func startGroup(name: String, members: [String]) async throws -> String {
        let cleanMembers = Array(Set(members.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        guard cleanMembers.count >= 2 else {
            throw MarmotService.ServiceError.invalidInput("add at least two people")
        }
        let id = try await service.startGroup(with: cleanMembers, name: name)
        await loadLocal()
        return id
    }

    func addGroupMembers(_ members: [String], to groupId: String) async throws {
        try await service.addGroupMembers(members, to: groupId)
        await loadLocal()
    }

    func removeGroupMembers(_ members: [String], from groupId: String) async throws {
        try await service.removeGroupMembers(members, from: groupId)
        await loadLocal()
    }

    func createInviteLink(groupId: String, groupName: String) async throws -> String {
        try await service.createInviteLink(groupId: groupId, groupName: groupName)
    }

    func pendingJoinRequests(groupId: String) async throws -> [JoinRequestInfo] {
        try await service.pendingJoinRequests(groupId: groupId)
    }

    func approveJoinRequest(groupId: String, requesterNpub: String) async throws {
        try await service.approveJoinRequest(groupId: groupId, requesterNpub: requesterNpub)
        await loadLocal()
    }

    func declineJoinRequest(groupId: String, requesterNpub: String) async throws {
        try await service.declineJoinRequest(groupId: groupId, requesterNpub: requesterNpub)
    }

    func requestJoinViaLink(token: String) async throws {
        try await service.requestJoinViaLink(token: token)
    }

    func acceptGroupInvite(_ invite: MarmotService.GroupInvite) async throws -> String {
        let id = try await service.acceptGroupInvite(invite.id)
        await loadLocal()
        return id
    }

    func declineGroupInvite(_ invite: MarmotService.GroupInvite) async throws {
        try await service.declineGroupInvite(invite.id)
        await loadLocal()
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case MarmotService.ServiceError.notConnected:
            return "Not connected yet — try again in a moment."
        case MarmotService.ServiceError.cancelled:
            return "Operation cancelled."
        case MarmotService.ServiceError.backupAlreadyInProgress:
            return "Backup already in progress."
        case MarmotService.ServiceError.invalidInput(let detail):
            return "Invalid input: \(detail)"
        case MarmotService.ServiceError.core(let detail):
            return detail
        default:
            return error.localizedDescription
        }
    }
}

/// List of Marmot secure chats + entry point to start one by npub.
struct MarmotChatsView: View {
    @StateObject private var model = MarmotChatModel()
    @State private var newPeer = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                banner
                if let error = model.errorText {
                    Text(error)
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(SonarTheme.danger)
                        .padding(.horizontal, 18)
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                newChatRow
                chatList
            }
            .background(SonarTheme.bg)
            .navigationTitle("Secure chats")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.npub == nil)
                }
            }
        }
        .onAppear {
            model.connectIfNeeded()
            model.startPolling()
        }
        .onDisappear { model.stopPolling() }
    }

    private var banner: some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text("End-to-end encrypted groups over the internet")
                    .font(SonarTheme.uiFont(size: 12.5, weight: .semibold))
                if let npub = model.npub {
                    Text(npub)
                        .font(SonarTheme.monoFont(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(model.busy ? "Connecting…" : "Setting up your identity…")
                        .font(SonarTheme.uiFont(size: 12))
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(SonarTheme.netDeep)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(SonarTheme.netSoft)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var newChatRow: some View {
        HStack(spacing: 8) {
            TextField("npub of a Sonar or White Noise user", text: $newPeer)
                .font(SonarTheme.monoFont(size: 13))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(SonarTheme.surface2)
                .clipShape(Capsule())
            Button {
                model.startChat(with: newPeer)
                newPeer = ""
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(SonarTheme.onNet)
                    .frame(width: 34, height: 34)
                    .background(SonarTheme.netFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(newPeer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var chatList: some View {
        Group {
            if model.groups.isEmpty && model.pendingDirectChats.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 26))
                        .foregroundColor(SonarTheme.netDeep)
                        .frame(width: 56, height: 56)
                        .background(SonarTheme.netSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.bottom, 8)
                    Text("No secure chats yet")
                        .font(SonarTheme.uiFont(size: 17, weight: .bold))
                        .foregroundColor(SonarTheme.text)
                    Text("Paste a friend's npub above — or have them message yours from White Noise.")
                        .font(SonarTheme.uiFont(size: 13.5))
                        .foregroundColor(SonarTheme.text2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 44)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.pendingDirectChats.sorted(by: { $0.value > $1.value }), id: \.key) { entry in
                        let npub = entry.key
                        HStack(spacing: 12) {
                            let title = model.displayName(forNpub: npub) ?? String(npub.prefix(12)) + "…"
                            SonarAvatar(name: title, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .font(SonarTheme.uiFont(size: 16.5, weight: .semibold))
                                    .foregroundColor(SonarTheme.text)
                                Text("Setting up secure chat…")
                                    .font(SonarTheme.uiFont(size: 14))
                                    .foregroundColor(SonarTheme.text2)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 3)
                        .listRowBackground(SonarTheme.bg)
                    }
                    ForEach(model.groups, id: \.id) { group in
                        NavigationLink {
                            MarmotConversationView(group: group, model: model)
                        } label: {
                            HStack(spacing: 12) {
                                SonarAvatar(name: model.title(for: group), size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.title(for: group))
                                        .font(SonarTheme.uiFont(size: 16.5, weight: .semibold))
                                        .foregroundColor(SonarTheme.text)
                                    Text(model.messagesByGroup[group.id]?.last?.content ?? "Say hi 👋")
                                        .font(SonarTheme.uiFont(size: 14))
                                        .foregroundColor(SonarTheme.text2)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .listRowBackground(SonarTheme.bg)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

/// One Marmot conversation: history + composer. Own bubbles are indigo —
/// these messages always travel over the internet (Nostr relays).
struct MarmotConversationView: View {
    let group: MarmotService.MarmotGroup
    @ObservedObject var model: MarmotChatModel
    @State private var draft = ""
    @State private var isNearBottom = true

    private var messages: [MarmotService.MarmotMessage] {
        model.messagesByGroup[group.id] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(messages, id: \.id) { message in
                            bubble(for: message)
                                .id(message.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom-anchor")
                            .onAppear { isNearBottom = true }
                            .onDisappear { isNearBottom = false }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .onChange(of: messages.count) { _ in
                    guard isNearBottom, let last = messages.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            composer
        }
        .background(SonarTheme.bg)
        .navigationTitle(model.title(for: group))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func bubble(for message: MarmotService.MarmotMessage) -> some View {
        HStack {
            if message.isMine { Spacer(minLength: 60) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .font(SonarTheme.uiFont(size: 16))
                    .foregroundColor(message.isMine ? SonarTheme.onNet : SonarTheme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isMine ? SonarTheme.netFill : SonarTheme.bubbleOther)
                    .clipShape(RoundedRectangle(cornerRadius: SonarTheme.bubbleRadius, style: .continuous))
                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(SonarTheme.uiFont(size: 10.5))
                    .foregroundColor(SonarTheme.text3)
            }
            if !message.isMine { Spacer(minLength: 60) }
        }
        .padding(.top, 7)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            SNMessageComposerField(
                text: $draft,
                prompt: Text("Message"),
                onSend: {
                    guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    model.send(draft, to: group.id)
                    draft = ""
                }
            )
                .font(SonarTheme.uiFont(size: 16))
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(SonarTheme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            Button {
                model.send(draft, to: group.id)
                draft = ""
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(SonarTheme.onNet)
                    .frame(width: 34, height: 34)
                    .background(
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? AnyShapeStyle(SonarTheme.surface2)
                            : AnyShapeStyle(SonarTheme.netFill)
                    )
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SonarTheme.bg)
    }
}
