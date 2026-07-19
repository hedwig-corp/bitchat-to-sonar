import Testing
@testable import Sonar

struct OwnProfileHydrationTests {
    private let domain = "sonarprivacy.xyz"

    @Test
    func restoreWithBlankLocalStateAdoptsKind0NameAndHandle() {
        let plan = OwnProfileHydration.plan(
            localNickname: "",
            localBip353: "",
            localClaimedHandle: nil,
            remoteName: "Alice",
            remoteNip05: "alice@sonarprivacy.xyz",
            handleDomain: domain
        )
        #expect(plan.nicknameToAdopt == "Alice")
        #expect(plan.nip05ToAdopt == "alice@sonarprivacy.xyz")
        #expect(plan.handleLocalToClaim == "alice")
        #expect(plan.shouldPublishNickname)
    }

    @Test
    func blankLocalWithoutRemoteMustNotPublish() {
        let plan = OwnProfileHydration.plan(
            localNickname: "  ",
            localBip353: "",
            localClaimedHandle: nil,
            remoteName: nil,
            remoteNip05: nil,
            handleDomain: domain
        )
        #expect(plan.nicknameToAdopt == nil)
        #expect(plan.nip05ToAdopt == nil)
        #expect(plan.handleLocalToClaim == nil)
        #expect(!plan.shouldPublishNickname)
    }

    @Test
    func remoteKind0NameAndNip05WinOverDivergentLocal() {
        let plan = OwnProfileHydration.plan(
            localNickname: "local-nick",
            localBip353: "stale@other.com",
            localClaimedHandle: nil,
            remoteName: "Alice",
            remoteNip05: "alice@sonarprivacy.xyz",
            handleDomain: domain
        )
        // Remote values are already taken on relays — never keep divergent local.
        #expect(plan.nicknameToAdopt == "Alice")
        #expect(plan.nip05ToAdopt == "alice@sonarprivacy.xyz")
        #expect(plan.handleLocalToClaim == "alice")
        #expect(plan.shouldPublishNickname)
    }

    @Test
    func matchingLocalNeedsNoAdoption() {
        let plan = OwnProfileHydration.plan(
            localNickname: "Alice",
            localBip353: "alice@sonarprivacy.xyz",
            localClaimedHandle: "alice@sonarprivacy.xyz",
            remoteName: "Alice",
            remoteNip05: "alice@sonarprivacy.xyz",
            handleDomain: domain
        )
        #expect(plan.nicknameToAdopt == nil)
        #expect(plan.nip05ToAdopt == nil)
        #expect(plan.handleLocalToClaim == nil)
        #expect(plan.shouldPublishNickname)
    }

    @Test
    func externalNip05MustNotReclaimOrPublish() {
        let plan = OwnProfileHydration.plan(
            localNickname: "",
            localBip353: "",
            localClaimedHandle: nil,
            remoteName: "Alice",
            remoteNip05: "alice@example.com",
            handleDomain: domain
        )
        #expect(plan.nicknameToAdopt == "Alice")
        #expect(plan.nip05ToAdopt == "alice@example.com")
        #expect(plan.handleLocalToClaim == nil)
        #expect(!plan.shouldPublishNickname)
    }

    @Test
    func renameMustNotPublishWhenHandlePrefLacksCoreSidecar() {
        #expect(
            !OwnProfileHydration.canPublishOwnProfile(
                localBip353: "alice@sonarprivacy.xyz",
                coreClaimedHandle: nil
            )
        )
        #expect(
            !OwnProfileHydration.canPublishOwnProfile(
                localBip353: "alice@sonarprivacy.xyz",
                coreClaimedHandle: "  "
            )
        )
        #expect(
            OwnProfileHydration.canPublishOwnProfile(
                localBip353: "alice@sonarprivacy.xyz",
                coreClaimedHandle: "alice@sonarprivacy.xyz"
            )
        )
        #expect(
            OwnProfileHydration.canPublishOwnProfile(
                localBip353: "",
                coreClaimedHandle: nil
            )
        )
    }

    @Test
    func restoreClearedNicknameMustNotMintAnonymousOnRelaunch() {
        #expect(OwnProfileHydration.shouldMintAnonymousNickname(savedValue: nil))
        #expect(!OwnProfileHydration.shouldMintAnonymousNickname(savedValue: ""))
        #expect(!OwnProfileHydration.shouldMintAnonymousNickname(savedValue: "Alice"))
    }

    @Test
    func needsRelayFetchOnlyWhenRestoreSymptomsPresent() {
        #expect(
            OwnProfileHydration.needsRelayFetch(
                localNickname: "",
                localBip353: "",
                localClaimedHandle: nil,
                handleDomain: domain
            )
        )
        // Nick present but no handle pref/sidecar: must fetch — relays may hold nip05.
        #expect(
            OwnProfileHydration.needsRelayFetch(
                localNickname: "Alice",
                localBip353: "",
                localClaimedHandle: nil,
                handleDomain: domain
            )
        )
        #expect(
            !OwnProfileHydration.needsRelayFetch(
                localNickname: "Alice",
                localBip353: "alice@sonarprivacy.xyz",
                localClaimedHandle: "alice@sonarprivacy.xyz",
                handleDomain: domain
            )
        )
        #expect(
            OwnProfileHydration.needsRelayFetch(
                localNickname: "Alice",
                localBip353: "alice@sonarprivacy.xyz",
                localClaimedHandle: nil,
                handleDomain: domain
            )
        )
        #expect(
            !OwnProfileHydration.needsRelayFetch(
                localNickname: "Alice",
                localBip353: "alice@example.com",
                localClaimedHandle: nil,
                handleDomain: domain
            )
        )
    }
}
