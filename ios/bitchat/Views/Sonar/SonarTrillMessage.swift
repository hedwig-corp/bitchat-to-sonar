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
    /// Row only (blocked upstream, pre-launch replay, muted chat, or a
    /// throttled trill while the app is foregrounded).
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
    static let defaultsKey = "sonar.chat.mutes.v1"

    @Published private(set) var mutedUntil: [String: Date]

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = SonarChatMuteStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode([String: Date].self, from: data) {
            mutedUntil = stored
        } else {
            mutedUntil = [:]
        }
    }

    /// Equivalent lookup keys for one raw conversation key, so the check
    /// works whichever id shape a notification path carries (see
    /// docs/CHAT-TYPES.md — five strings can identify one conversation):
    /// the raw key, a 64-hex fingerprint's canonical 16-hex short form, and
    /// a `marmot:<groupId>` route's bare group id (and vice versa).
    static func normalizedCandidates(_ rawKey: String) -> [String] {
        var keys = [rawKey]
        if rawKey.hasPrefix("marmot:") {
            keys.append(String(rawKey.dropFirst("marmot:".count)))
        } else if rawKey.count == 64, rawKey.allSatisfy(\.isHexDigit) {
            keys.append(String(rawKey.prefix(16)))
            keys.append("marmot:" + rawKey)
        }
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
        // whichever id form a path carries later.
        for raw in keys where !raw.isEmpty {
            for candidate in Self.normalizedCandidates(raw) {
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
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(mutedUntil) {
            defaults.set(data, forKey: key)
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
