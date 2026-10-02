//
// MarmotLookupLaneTests.swift
// bitchatTests
//
// Relay-only lookups and publishes must not queue behind the serial work
// queue that `syncForce` runs on (R-056). On 1.15.3 a foreground member sweep
// put a profile and a descriptor fetch per stale member in front of the gap
// sync, so it never ran in a short visit.
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Testing
@testable import Sonar

struct MarmotLookupLaneTests {
    private let npub = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"

    /// With no node every call fails fast, so the elapsed time is the time
    /// spent waiting for a lane. A call routed through `workQueue` waits out
    /// the parked queue (2 s); one on its own lane returns at once.
    private func elapsed(_ body: (MarmotService) async -> Void) async -> TimeInterval {
        let service = MarmotService(relayUrls: [])
        service.occupyWorkQueueForTesting(seconds: 2)
        let started = Date()
        await body(service)
        return Date().timeIntervalSince(started)
    }

    @Test
    func profileFetchDoesNotWaitBehindTheWorkQueue() async {
        let waited = await elapsed { _ = try? await $0.fetchProfile(npub: npub) }
        #expect(waited < 1.0, "fetchProfile waited \(waited)s behind workQueue")
    }

    @Test
    func descriptorFetchDoesNotWaitBehindTheWorkQueue() async {
        let waited = await elapsed { _ = try? await $0.fetchSonarDescriptor(npub: npub) }
        #expect(waited < 1.0, "fetchSonarDescriptor waited \(waited)s behind workQueue")
    }

    @Test
    func descriptorPublishDoesNotWaitBehindTheWorkQueue() async {
        let waited = await elapsed { _ = try? await $0.publishSonarDescriptor() }
        #expect(waited < 1.0, "publishSonarDescriptor waited \(waited)s behind workQueue")
    }

    @Test
    func walletOfferBackupCallsDoNotWaitBehindTheWorkQueue() async {
        let waited = await elapsed {
            _ = try? await $0.fetchWalletOfferBackups()
            _ = try? await $0.publishWalletOfferBackup("backup")
        }
        #expect(waited < 1.0, "wallet offer backup calls waited \(waited)s behind workQueue")
    }

    /// Positive control: the gap sync itself still runs on the serial queue,
    /// so the seam really parks it. Without this the four tests above would
    /// pass even if the seam did nothing.
    @Test
    func syncForceStillRunsOnTheWorkQueue() async {
        let waited = await elapsed { _ = try? await $0.syncForce() }
        #expect(waited >= 1.5, "syncForce returned after \(waited)s; the seam did not park workQueue")
    }
}
