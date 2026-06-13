//
// MessageStore.swift
// bitchat
//
// On-disk persistence for the Swift app's chat history, so conversations
// survive an app restart. Everything below the UI was in-memory until now:
//   - mesh / bitchat private chats        (keyed by PeerID)
//   - public + geohash channel transcripts (keyed by channel id)
//   - (the ⚡PAY ledger already persists via UserDefaults — see note below)
//
// STORAGE CHOICE — Codable JSON files under Application Support, each
// written with `NSFileProtectionComplete` (iOS Data Protection):
//
//   * At-rest encryption: NSFileProtectionComplete ties the file's
//     encryption to the device passcode — the bytes are unreadable while the
//     device is locked. This is the same guarantee an app-level AES-GCM +
//     Keychain scheme would give, but without us hand-rolling crypto or
//     managing a key, and it is what iOS recommends for message data.
//   * No new dependency / no pbxproj edit: BitchatMessage, PeerID and
//     DeliveryStatus are ALREADY Codable, so a JSON file store needs nothing
//     linked (raw libsqlite3 would mean touching the project to add
//     libsqlite3.tbd, which the persistence handoff forbids). The rest of the
//     app already stores data as Application Support files (media, identity
//     caches), so this matches the codebase.
//   * macOS has no Data Protection; there the files are plain JSON in the
//     app's Application Support (same as every other file the app writes).
//
// LOCAL-ONLY invariant: this is a private on-device store. Nothing here is
// ever sent to a relay — mesh DMs and channel transcripts persist locally and
// are erased by `wipeAll()` on panic.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

/// Encrypted-at-rest, on-disk store for chat history. Thread-safe (an internal
/// serial queue guards all disk access); the public API is synchronous.
final class MessageStore {

    /// Shared instance backed by the real Application Support directory.
    static let shared = MessageStore()

    // MARK: - Layout

    private let baseDir: URL
    private let privateDir: URL   // one file per peer: <fingerprint>.json
    private let channelDir: URL   // one file per channel: <channel>.json
    private let io = DispatchQueue(label: "chat.bitchat.sonar.messageStore")
    private let cap = TransportConfig.privateChatCap

    /// Cap stored per channel transcript — matches the in-memory timeline cap
    /// so write-through never truncates below what the UI holds.
    private let channelCap = TransportConfig.meshTimelineCap

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// On-disk envelope for a private transcript: the PeerID is recorded
    /// explicitly so `loadAllPrivate()` can re-key it (filenames are hashes).
    private struct StoredPrivateChat: Codable {
        let peerID: PeerID
        let messages: [BitchatMessage]
    }

    // MARK: - Init

    /// - Parameter directoryName: subfolder under Application Support (tests
    ///   pass a unique name so they don't collide with the real store).
    init(directoryName: String = "Messages") {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        baseDir = support.appendingPathComponent(directoryName, isDirectory: true)
        privateDir = baseDir.appendingPathComponent("private", isDirectory: true)
        channelDir = baseDir.appendingPathComponent("channels", isDirectory: true)
        io.sync { ensureDirectories() }
    }

    private func ensureDirectories() {
        for dir in [baseDir, privateDir, channelDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Protect the whole tree at rest (best effort; no-op on macOS).
        applyProtection(to: baseDir)
    }

    // MARK: - Private chats (keyed by PeerID)

    /// Load the stored transcript for one peer (oldest → newest). Empty when
    /// nothing was stored yet.
    func load(peerID: PeerID) -> [BitchatMessage] {
        io.sync { readPrivate(at: privateFileURL(for: peerID))?.messages ?? [] }
    }

    /// Replace the stored transcript for a peer (used to mirror an in-memory
    /// array exactly, e.g. after consolidation/dedup).
    func savePrivate(peerID: PeerID, messages: [BitchatMessage]) {
        io.async { [weak self] in
            guard let self else { return }
            self.writePrivate(peerID: peerID, messages: self.trimmed(messages, cap: self.cap))
        }
    }

    /// Append one message to a peer's transcript (deduped by id, trimmed to cap).
    func appendPrivate(peerID: PeerID, message: BitchatMessage) {
        io.async { [weak self] in
            guard let self else { return }
            let url = self.privateFileURL(for: peerID)
            var messages = self.readPrivate(at: url)?.messages ?? []
            guard !messages.contains(where: { $0.id == message.id }) else { return }
            messages.append(message)
            self.writePrivate(peerID: peerID, messages: self.trimmed(messages, cap: self.cap))
        }
    }

    /// All stored private transcripts, keyed by the PeerID they were saved
    /// under. Used to hydrate `privateChats` on launch.
    func loadAllPrivate() -> [PeerID: [BitchatMessage]] {
        io.sync {
            var out: [PeerID: [BitchatMessage]] = [:]
            let files = (try? FileManager.default.contentsOfDirectory(
                at: privateDir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                guard let chat = readPrivate(at: file), !chat.messages.isEmpty else { continue }
                out[chat.peerID] = chat.messages
            }
            return out
        }
    }

    // MARK: - Channels (keyed by channel id: "mesh" / "geo:<gh>")

    func loadChannel(_ channelID: String) -> [BitchatMessage] {
        io.sync { readMessages(at: channelFileURL(for: channelID)) }
    }

    func appendChannel(_ channelID: String, message: BitchatMessage) {
        io.async { [weak self] in
            guard let self else { return }
            let url = self.channelFileURL(for: channelID)
            var messages = self.readMessages(at: url)
            guard !messages.contains(where: { $0.id == message.id }) else { return }
            messages.append(message)
            self.writeMessages(self.trimmed(messages, cap: self.channelCap), to: url)
        }
    }

    /// Mirror an in-memory channel transcript exactly (write-through on a
    /// timeline refresh that may have reordered/deduped).
    func saveChannel(_ channelID: String, messages: [BitchatMessage]) {
        io.async { [weak self] in
            guard let self else { return }
            self.writeMessages(self.trimmed(messages, cap: self.channelCap), to: self.channelFileURL(for: channelID))
        }
    }

    // MARK: - ⚡PAY ledger (generic Codable blob)
    //
    // NOTE: the live ⚡PAY ledger already persists across restart via
    // UserDefaults (SonarPayLedger, key "sonar.pay.ledger.v1") — UserDefaults
    // IS durable, so payments were never the persistence gap. These methods
    // exist so the ledger CAN be backed by the same encrypted-at-rest store if
    // desired; the app keeps the ledger in UserDefaults today.

    func loadPayLedger<T: Decodable>(_ type: T.Type) -> T? {
        io.sync {
            guard let data = try? Data(contentsOf: payLedgerURL) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }
    }

    func savePayLedger<T: Encodable>(_ ledger: T) {
        io.async { [weak self] in
            guard let self else { return }
            guard let data = try? self.encoder.encode(ledger) else { return }
            self.write(data, to: self.payLedgerURL)
        }
    }

    // MARK: - Panic wipe

    /// Erase EVERYTHING this store holds: delete the whole on-disk tree (mesh
    /// DMs, channel transcripts, any pay-ledger blob) and recreate empty
    /// directories. Called from the panic paths.
    func wipeAll() {
        io.sync {
            try? FileManager.default.removeItem(at: baseDir)
            ensureDirectories()
            SecureLogger.info("🗑️ MessageStore wiped (private chats + channel transcripts)", category: .session)
        }
    }

    // MARK: - File helpers

    /// One file per peer. Keyed by a filesystem-safe hash of the PeerID so the
    /// raw id never lands in a filename.
    private func privateFileURL(for peerID: PeerID) -> URL {
        privateDir.appendingPathComponent(Self.fileSafeKey(peerID.id) + ".json")
    }

    private func channelFileURL(for channelID: String) -> URL {
        channelDir.appendingPathComponent(Self.fileSafeKey(channelID) + ".json")
    }

    private var payLedgerURL: URL {
        baseDir.appendingPathComponent("payledger.json")
    }

    private func readMessages(at url: URL) -> [BitchatMessage] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([BitchatMessage].self, from: data)) ?? []
    }

    private func writeMessages(_ messages: [BitchatMessage], to url: URL) {
        guard let data = try? encoder.encode(messages) else { return }
        write(data, to: url)
    }

    private func readPrivate(at url: URL) -> StoredPrivateChat? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(StoredPrivateChat.self, from: data)
    }

    private func writePrivate(peerID: PeerID, messages: [BitchatMessage]) {
        let envelope = StoredPrivateChat(peerID: peerID, messages: messages)
        guard let data = try? encoder.encode(envelope) else { return }
        write(data, to: privateFileURL(for: peerID))
    }

    private func write(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: [.atomic])
            applyProtection(to: url)
        } catch {
            SecureLogger.error("MessageStore write failed: \(error)", category: .session)
        }
    }

    private func trimmed(_ messages: [BitchatMessage], cap: Int) -> [BitchatMessage] {
        let deduped = messages.cleanedAndDeduped()
        guard deduped.count > cap else { return deduped }
        return Array(deduped.suffix(cap))
    }

    /// Apply `NSFileProtectionComplete` at rest. No-op where Data Protection
    /// is unavailable (macOS); failures are non-fatal.
    private func applyProtection(to url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path
        )
        #endif
    }

    /// Map an arbitrary id to a safe, collision-resistant filename component.
    static func fileSafeKey(_ id: String) -> String {
        Data(id.utf8).sha256Fingerprint()
    }
}
