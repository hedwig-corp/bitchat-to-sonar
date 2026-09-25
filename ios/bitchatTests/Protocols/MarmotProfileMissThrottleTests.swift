//
// MarmotProfileMissThrottleTests.swift
// bitchatTests
//
// A contact with no kind-0 profile must not turn every Home/header render into
// a relay query. `title(for:)` calls `ensureProfile` on each render, and the
// fetch runs on the serial Marmot work queue that sends and syncs share. Before
// the miss throttle, a single profile-less contact re-queried every relay about
// twice a second for as long as the app was open.
//

import Foundation
import Testing
@testable import Sonar

@MainActor
@Suite(.serialized)
struct MarmotProfileMissThrottleTests {
    private static let peer = "npub1ghmjy6aj9kncekftjvz3dmxd73yqzrdl092f2ym2mak002dtepfqp89xna"

    private func makeModel() -> (MarmotChatModel, () -> Void) {
        let suiteName = "MarmotProfileMissThrottleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // No relays and no node: every profile fetch fails fast, which is the
        // same "no profile" outcome a contact without a kind-0 produces.
        let model = MarmotChatModel(
            service: MarmotService(relayUrls: []),
            keychain: MockKeychain(),
            defaults: defaults
        )
        return (model, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func directGroup() -> MarmotService.MarmotGroup {
        MarmotService.MarmotGroup(id: "ab12", name: "", memberNpubs: [Self.peer])
    }

    private func waitForMiss(_ model: MarmotChatModel, key: String) async throws {
        for _ in 0..<300 where model.profileMissedAt[key] == nil || model.profileFetches.contains(key) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Pins the real call site: a render after a miss must not start another
    /// fetch. Without the throttle the second `title(for:)` re-inserts the key
    /// into the in-flight set and queues another relay query.
    @Test
    func renderAfterAMissDoesNotRefetchTheProfile() async throws {
        let (model, cleanup) = makeModel()
        defer { cleanup() }
        let group = directGroup()
        let key = SNMarmotProfileCache.canonicalKey(Self.peer)

        _ = model.title(for: group)
        try await waitForMiss(model, key: key)
        #expect(model.profileMissedAt[key] != nil, "the failed fetch must record a miss")
        #expect(!model.profileFetches.contains(key))

        _ = model.title(for: group)
        _ = model.title(for: group)
        #expect(
            !model.profileFetches.contains(key),
            "a render inside the miss TTL must not start another relay fetch"
        )
    }

    /// The fallback title is the same short form the pending chat and the
    /// lookup card use, so the header and its name-derived avatar do not change
    /// when a pending chat resolves to its real group.
    @Test
    func unnamedDirectChatFallsBackToTheSharedShortNpub() {
        let (model, cleanup) = makeModel()
        defer { cleanup() }
        let key = SNMarmotProfileCache.canonicalKey(Self.peer)

        #expect(model.title(for: directGroup()) == snShortNpubLabel(key))
        #expect(model.title(for: directGroup()) == SonarAppStore.shortNpub(key))
    }

    @Test
    func missThrottleExpiresAfterTheTTL() {
        let now = Date()
        #expect(!MarmotChatModel.profileMissThrottled(missedAt: nil, now: now))
        #expect(MarmotChatModel.profileMissThrottled(missedAt: now, now: now))
        #expect(MarmotChatModel.profileMissThrottled(
            missedAt: now.addingTimeInterval(-(MarmotChatModel.profileMissTTL - 1)),
            now: now
        ))
        #expect(!MarmotChatModel.profileMissThrottled(
            missedAt: now.addingTimeInterval(-MarmotChatModel.profileMissTTL),
            now: now
        ))
    }

    @Test
    func paymentMetadataRetryBacksOffAndCaps() {
        let delays = (0..<8).map { SonarAppStore.paymentMetadataRetryDelaySecs(attempt: $0) }
        #expect(delays == [30, 60, 120, 240, 480, 900, 900, 900])
        #expect(SonarAppStore.paymentMetadataRetryDelaySecs(attempt: -3) == 30)
    }
}
