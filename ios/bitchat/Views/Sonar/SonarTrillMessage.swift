//
// SonarTrillMessage.swift
// bitchat
//
// ⚡TRILL: the MSN-style "nudge" convention inside normal encrypted chat
// content (spec: docs/SONAR-TRILL.md). A trill is a persisted message whose
// content is a reserved control line, following the same idiom as ⚡PAY:
//
//   sender →  ⚡TRILL|1|<id>    buzz the peer's screen for attention
//
// The line rides the exact same message paths a text message takes (mesh
// private message or Marmot kind-9), so it bumps recency, counts as unread,
// and advances resync watermarks. Only rendering and alerting differ.
// On old clients an unknown version harmlessly renders as plain text.
//
// This file also carries the receiver-side alert policy (throttle + the
// silence-semantics decision table) and the per-chat mute store — all pure
// logic, pinned by SonarTrillMessageTests.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import AVFoundation
import Foundation

// MARK: - ⚡TRILL codec

/// One ⚡TRILL nudge line. Field separator is `|`. Version locked to 1 —
/// parsers reject any other version so future versions degrade to plain
/// text on old clients instead of mis-rendering (same rule as ⚡PAY).
struct SonarTrillMessage: Equatable {

    private static let prefix = "\u{26A1}TRILL|"

    /// Sender-generated token, 1-64 chars of `[0-9a-fA-F-]` (hex-or-dash,
    /// same shape as ⚡PAY ids). Used to recognise the same trill if it
    /// arrives on both the mesh and Marmot legs.
    let id: String

    func encoded() -> String {
        "\(Self.prefix)1|\(id)"
    }

    /// Decode a ⚡TRILL line. Version locked to 1; no trailing fields
    /// (`⚡TRILL|1|abc|extra` is NOT a trill line).
    static func decode(_ text: String) -> SonarTrillMessage? {
        guard text.hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        let parts = rest.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0] == "1",
              isValidID(parts[1])
        else { return nil }
        return SonarTrillMessage(id: String(parts[1]))
    }

    static func isTrillLine(_ text: String) -> Bool {
        decode(text) != nil
    }

    /// Fresh sender token: random 16-hex, the same shape mesh peer ids use.
    static func makeID() -> String {
        (0..<16).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
    }

    private static func isValidID(_ s: Substring) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}

// MARK: - Receiver alert policy (silence semantics, docs/SONAR-TRILL.md)

/// What one incoming trill does beyond persisting as a row. The invariant:
/// a trill never produces less than a persisted row, and never more than
/// the chat's notification level already allows.
enum SonarTrillAlert: Equatable {
    /// Row only (blocked upstream, pre-launch replay, muted chat, or
    /// throttled inside the 8s receiver window).
    case suppress
    /// Foreground: whole-view shake + bell + haptic.
    case buzz
    /// Background: local notification with the trill sound.
    case notify
}

enum SonarTrillPolicy {

    /// Sender cooldown (MSN's own guard) and the receiver alert window share
    /// the same 8-second duration.
    static let cooldownSeconds: TimeInterval = 8

    /// Decision table for one incoming trill. `admitThrottle` is a closure so
    /// a muted/blocked/replayed trill never consumes the throttle window —
    /// the receiver enforces its own window because client cooldowns cannot
    /// be trusted. Throttled trills are row-only on both platforms (no silent
    /// banner) — "at most one alert per window".
    static func alertDecision(
        arrivedBeforeLaunch: Bool,
        isBlocked: Bool,
        isMuted: Bool,
        isForeground: Bool,
        admitThrottle: () -> Bool
    ) -> SonarTrillAlert {
        if isBlocked || arrivedBeforeLaunch || isMuted { return .suppress }
        guard admitThrottle() else { return .suppress }
        return isForeground ? .buzz : .notify
    }

    /// Remaining sender cooldown for a chat, nil when sending is allowed.
    static func cooldownRemaining(until: Date?, now: Date = Date()) -> TimeInterval? {
        guard let until, until > now else { return nil }
        return until.timeIntervalSince(now)
    }
}

/// Per-chat alert throttle: at most one buzz/notification per chat per
/// window. Excess trills still persist as rows but produce no alert.
final class SonarTrillThrottle {
    static let shared = SonarTrillThrottle()

    private let windowSeconds: TimeInterval
    private var lastAdmittedByChat: [String: Date] = [:]

    init(windowSeconds: TimeInterval = SonarTrillPolicy.cooldownSeconds) {
        self.windowSeconds = windowSeconds
    }

    /// Returns true (and records the admission) when the chat is outside its
    /// alert window; false while a previous admission is still fresh.
    @discardableResult
    func admit(chatKey: String, at now: Date = Date()) -> Bool {
        if let last = lastAdmittedByChat[chatKey],
           now.timeIntervalSince(last) < windowSeconds {
            return false
        }
        lastAdmittedByChat[chatKey] = now
        return true
    }

    func reset() {
        lastAdmittedByChat = [:]
    }
}

// MARK: - Per-chat mute (general, not trill-specific)

/// UserDefaults-persisted map of muted conversation keys → mute end date
/// (`.distantFuture` = "until I turn it back on"). Mute is local to the
/// install (not synced across linked devices — tracked gap, Signal syncs it).
///
/// Mute suppresses notification/sound/haptic/shake for ALL message kinds in
/// the chat; rows and unread badges still accrue. Expiry is lazy: an expired
/// entry reads as unmuted and is dropped on the next query.
final class SonarChatMuteStore: ObservableObject {
    static let shared = SonarChatMuteStore()
    /// Single declaration lives in `SonarNSEDecoratePolicy` (compiled into
    /// both the app and the appex), so the writer and the NSE reader cannot
    /// drift apart on the key string.
    static let defaultsKey = SonarNSEDecoratePolicy.mutesUserDefaultsKey
    static let appGroupId = "group.sh.hedwig.sonar"

    @Published private(set) var mutedUntil: [String: Date]

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = SonarChatMuteStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
        var didMigrate = false
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode([String: Date].self, from: data) {
            // Legacy entries may carry mixed-case hex; normalize to the
            // lowercase shape `normalizedCandidates` produces, keeping the
            // later expiry when two casings collide. Entries written before
            // both encodings were stored can be npub-only, which no push-path
            // lookup can reach — backfill the hex twin here so an upgraded
            // install honours mutes it already had, without the user having to
            // mute the chat again.
            var normalized: [String: Date] = [:]
            normalized.reserveCapacity(stored.count)
            for (k, until) in stored {
                for candidate in Self.persistableCandidates(k) {
                    normalized[candidate] = max(normalized[candidate] ?? .distantPast, until)
                }
            }
            didMigrate = normalized != stored
            mutedUntil = normalized
        } else {
            mutedUntil = [:]
        }
        // Mirror on init so mutes recorded before the mirror existed become
        // visible to the NSE without waiting for the next mute/unmute. When the
        // load actually migrated something, write the map back as well —
        // otherwise `.standard` keeps the pre-migration shape and every launch
        // redoes the same expansion. `persist()` mirrors too.
        if didMigrate {
            persist()
        } else {
            mirrorToAppGroup()
        }
    }

    /// Equivalent lookup keys for one raw conversation key, so the check
    /// works whichever id shape a notification path carries (see
    /// docs/CHAT-TYPES.md — five strings can identify one conversation).
    /// Delegates to the NSE policy helper — one normalization for the
    /// store's writes and the appex's reads.
    static func normalizedCandidates(_ rawKey: String) -> [String] {
        SonarNSEDecoratePolicy.normalizedMuteCandidates(rawKey)
    }

    /// Keys to persist for one raw key: the normalized shapes plus, when the
    /// key is a bech32 `npub1…`, the same pubkey as 64-hex.
    ///
    /// Storage has to carry both encodings because the two sides disagree:
    /// group members and profiles reach us as bech32 (`to_bech32()`), while a
    /// killed-app drain row carries the sender as 64-hex
    /// (`sender.to_string()`). The lookup cannot bridge them — it is shared
    /// with the notification extension, which does not compile `Bech32` — so
    /// the writer resolves it here, where `Bech32` exists.
    static func persistableCandidates(_ rawKey: String) -> [String] {
        var keys = normalizedCandidates(rawKey)
        let lowered = rawKey.lowercased()
        guard lowered.hasPrefix("npub1"),
              let decoded = try? Bech32.decode(lowered),
              decoded.hrp == "npub",
              decoded.data.count == 32 else { return keys }
        keys += normalizedCandidates(decoded.data.hexEncodedString())
        return keys
    }

    func isMuted(_ rawKey: String, now: Date = Date()) -> Bool {
        isMuted(anyOf: [rawKey], now: now)
    }

    func isMuted(anyOf rawKeys: [String], now: Date = Date()) -> Bool {
        var muted = false
        var expired: [String] = []
        for raw in rawKeys {
            for candidate in Self.normalizedCandidates(raw) {
                guard let until = mutedUntil[candidate] else { continue }
                if until > now {
                    muted = true
                } else {
                    expired.append(candidate)
                }
            }
        }
        if !expired.isEmpty {
            for key in expired { mutedUntil.removeValue(forKey: key) }
            persist()
        }
        return muted
    }

    /// Mute end for a chat, nil when not muted. Lazily expires stale entries.
    func muteEnd(anyOf rawKeys: [String], now: Date = Date()) -> Date? {
        guard isMuted(anyOf: rawKeys, now: now) else { return nil }
        return rawKeys
            .flatMap(Self.normalizedCandidates)
            .compactMap { mutedUntil[$0] }
            .filter { $0 > now }
            .max()
    }

    func mute(keys: [String], until: Date) {
        guard !keys.isEmpty else { return }
        // Store every normalized shape too, so lookups and removals work
        // whichever id form a path carries later — including the hex twin of a
        // bech32 peer key, which is the shape push drains look up by.
        for raw in keys where !raw.isEmpty {
            for candidate in Self.persistableCandidates(raw) {
                mutedUntil[candidate] = until
            }
        }
        persist()
    }

    func unmute(keys: [String]) {
        var changed = false
        for raw in keys {
            for candidate in SonarChatMuteStore.normalizedCandidates(raw)
            where mutedUntil.removeValue(forKey: candidate) != nil {
                changed = true
            }
        }
        if changed { persist() }
    }

    /// Emergency wipe: forget every mute (account-bound local state).
    func wipe() {
        mutedUntil = [:]
        defaults.removeObject(forKey: key)
        if mirrorsToAppGroup {
            UserDefaults(suiteName: SonarChatMuteStore.appGroupId)?
                .removeObject(forKey: key)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(mutedUntil) {
            defaults.set(data, forKey: key)
        }
        mirrorToAppGroup()
    }

    /// Only the real store mirrors — test instances with injected defaults
    /// must never write into the shared container. `bitchatTests_iOS` runs
    /// in-process with the app's App Group entitlement, so a test touching
    /// `.shared` would otherwise overwrite the device's real mirror.
    private var mirrorsToAppGroup: Bool {
        defaults === UserDefaults.standard && !Self.isRunningTests
    }

    private static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return NSClassFromString("XCTestCase") != nil ||
            env["XCTestConfigurationFilePath"] != nil ||
            env["XCTestBundlePath"] != nil
    }

    /// Write-through mirror for the NSE. `.standard` stays the source of
    /// truth (no migration risk); the App Group copy is read-only for the
    /// appex so a muted chat's killed-app push can be silenced
    /// (SonarNSEDecoratePolicy.isMuted).
    private func mirrorToAppGroup() {
        guard mirrorsToAppGroup,
              let shared = UserDefaults(suiteName: SonarChatMuteStore.appGroupId) else { return }
        if let data = try? JSONEncoder().encode(mutedUntil) {
            shared.set(data, forKey: key)
        }
    }
}

// MARK: - Trill bell (foreground)

/// Plays the bundled `sonar_trill.wav` for the foreground buzz. Uses the
/// ambient audio category so the bell respects the silent switch (a nudge
/// must never override the mute switch) and mixes with other audio.
final class SonarTrillSoundPlayer {
    static let shared = SonarTrillSoundPlayer()

    private var player: AVAudioPlayer?

    func play() {
        guard let url = Bundle.main.url(forResource: "sonar_trill", withExtension: "wav") else {
            return
        }
        #if os(iOS)
        // Never fight an active call's playAndRecord session; the caller
        // already skips the buzz during calls, this is belt and braces.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.ambient, options: [.mixWithOthers])
        }
        #endif
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
}
