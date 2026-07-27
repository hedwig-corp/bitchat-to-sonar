//
// MarmotDescriptorCacheTests.swift
// bitchatTests
//

import Foundation
import Testing
@testable import Sonar

/// The peer's BOLT12 offer lives in their Sonar descriptor, and `paymentCapable`
/// is what puts "Send money" in a chat's "+" sheet. These pin the two ways that
/// affordance used to vanish for no visible reason.
struct MarmotDescriptorCacheTests {

    private func descriptor(
        offer: String? = "lno1qcp4256ypq",
        publishedAt: Date = Date(timeIntervalSince1970: 1_753_000_000)
    ) -> MarmotService.SonarDescriptor {
        MarmotService.SonarDescriptor(
            schema: 2,
            calls: true,
            media: ["voice", "video"],
            signaling: ["marmot"],
            transports: ["iroh"],
            callIdentity: "iroh-hkdf-sonar-call-iroh-v1",
            bolt12Offer: offer,
            paymentReceipts: ["sonar.payment.receipt.v1"],
            publishedAt: publishedAt
        )
    }

    /// The regression: a relay miss used to `removeValue` the cached descriptor,
    /// so a transient timeout (relays reconnecting after background, the 10 s
    /// core FETCH_TIMEOUT, a relay that just doesn't hold the event) dropped the
    /// peer's offer and "Send money" disappeared from a payable chat.
    @Test
    func relayMissKeepsThePreviouslyResolvedDescriptor() {
        let cached = descriptor()

        let outcome = MarmotChatModel.descriptorCacheAfterFetch(cached: cached, fetched: nil)

        #expect(outcome.descriptor == cached)
        #expect(outcome.descriptor?.supportsDirectPayments == true)
        #expect(outcome.missed)
    }

    /// A miss must not stamp `fetchedAt`, or the 15-minute success TTL would
    /// suppress the retry instead of the 60-second miss cooldown.
    @Test
    func relayMissDoesNotStampTheSuccessTTL() {
        #expect(!MarmotChatModel.descriptorCacheAfterFetch(cached: descriptor(), fetched: nil).stampFetchedAt)
        #expect(MarmotChatModel.descriptorCacheAfterFetch(cached: nil, fetched: descriptor()).stampFetchedAt)
    }

    @Test
    func resolvedFetchReplacesTheCachedDescriptorAndClearsTheMiss() {
        let fresh = descriptor(offer: "lno1freshoffer")

        let outcome = MarmotChatModel.descriptorCacheAfterFetch(cached: descriptor(), fetched: fresh)

        #expect(outcome.descriptor == fresh)
        #expect(!outcome.missed)
    }

    @Test
    func missWithNothingCachedStaysUnknown() {
        let outcome = MarmotChatModel.descriptorCacheAfterFetch(cached: nil, fetched: nil)

        #expect(outcome.descriptor == nil)
        #expect(outcome.missed)
    }

    /// Cold start used to hide the payment row until a relay round-trip landed,
    /// because the descriptor map was memory-only.
    @Test
    func cacheRoundTripsTheBolt12OfferAcrossLaunches() {
        let suiteName = "MarmotDescriptorCacheTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SNMarmotDescriptorCache.save(["npub1vincent": descriptor()], to: defaults)

        let loaded = SNMarmotDescriptorCache.load(from: defaults)
        #expect(loaded["npub1vincent"]?.bolt12Offer == "lno1qcp4256ypq")
        #expect(loaded["npub1vincent"]?.supportsDirectPayments == true)
    }

    /// Identity replacement must drop the previous account's peer descriptors —
    /// they are that account's contacts, and the cache is durable now.
    ///
    /// Uses `prepareForIdentityReplacement`'s injected wipe closure, the seam
    /// the model already exposes for exactly this kind of ordering test.
    @MainActor
    @Test
    func identityReplacementDropsPeerDescriptorsAndTheirCache() async throws {
        let suiteName = "MarmotDescriptorCacheTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = MarmotChatModel(defaults: defaults)
        model.sonarDescriptorsByNpub = ["npub1vincent": descriptor()]
        SNMarmotDescriptorCache.save(model.sonarDescriptorsByNpub, to: defaults)

        try await model.prepareForIdentityReplacement(wipeDatabase: {})

        #expect(model.sonarDescriptorsByNpub.isEmpty)
        #expect(SNMarmotDescriptorCache.load(from: defaults).isEmpty)
    }

    @Test
    func clearRemovesEveryPersistedDescriptor() {
        let suiteName = "MarmotDescriptorCacheTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SNMarmotDescriptorCache.save(["npub1vincent": descriptor()], to: defaults)
        SNMarmotDescriptorCache.clear(from: defaults)

        #expect(SNMarmotDescriptorCache.load(from: defaults).isEmpty)
    }
}
