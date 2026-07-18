import XCTest
@testable import bitchat

final class OwnProfileHydrationTests: XCTestCase {
    func testRestoreWithBlankLocalStateAdoptsKind0NameAndHandle() {
        let plan = OwnProfileHydration.plan(
            localNickname: "",
            localBip353: "",
            localClaimedHandle: nil,
            remoteName: "Alice",
            remoteNip05: "alice@sonarprivacy.xyz"
        )
        XCTAssertEqual(plan.nicknameToAdopt, "Alice")
        XCTAssertEqual(plan.nip05ToAdopt, "alice@sonarprivacy.xyz")
        XCTAssertEqual(plan.handleLocalToClaim, "alice")
        XCTAssertTrue(plan.shouldPublishNickname)
    }

    func testBlankLocalWithoutRemoteMustNotPublish() {
        let plan = OwnProfileHydration.plan(
            localNickname: "  ",
            localBip353: "",
            localClaimedHandle: nil,
            remoteName: nil,
            remoteNip05: nil
        )
        XCTAssertNil(plan.nicknameToAdopt)
        XCTAssertNil(plan.nip05ToAdopt)
        XCTAssertNil(plan.handleLocalToClaim)
        XCTAssertFalse(plan.shouldPublishNickname)
    }

    func testExistingLocalNicknameIsNotOverwrittenByRemote() {
        let plan = OwnProfileHydration.plan(
            localNickname: "local-nick",
            localBip353: "",
            localClaimedHandle: nil,
            remoteName: "Alice",
            remoteNip05: "alice@sonarprivacy.xyz"
        )
        XCTAssertNil(plan.nicknameToAdopt)
        XCTAssertEqual(plan.nip05ToAdopt, "alice@sonarprivacy.xyz")
        XCTAssertEqual(plan.handleLocalToClaim, "alice")
        XCTAssertTrue(plan.shouldPublishNickname)
    }

    func testAlreadyClaimedHandleSkipsReclaimAndPrefMirror() {
        let plan = OwnProfileHydration.plan(
            localNickname: "Alice",
            localBip353: "alice@sonarprivacy.xyz",
            localClaimedHandle: "alice@sonarprivacy.xyz",
            remoteName: "Alice",
            remoteNip05: "alice@sonarprivacy.xyz"
        )
        XCTAssertNil(plan.nicknameToAdopt)
        XCTAssertNil(plan.nip05ToAdopt)
        XCTAssertNil(plan.handleLocalToClaim)
        XCTAssertTrue(plan.shouldPublishNickname)
    }

    func testRenameMustNotPublishWhenHandlePrefLacksCoreSidecar() {
        XCTAssertFalse(
            OwnProfileHydration.canPublishOwnProfile(
                localBip353: "alice@sonarprivacy.xyz",
                coreClaimedHandle: nil
            )
        )
        XCTAssertFalse(
            OwnProfileHydration.canPublishOwnProfile(
                localBip353: "alice@sonarprivacy.xyz",
                coreClaimedHandle: "  "
            )
        )
        XCTAssertTrue(
            OwnProfileHydration.canPublishOwnProfile(
                localBip353: "alice@sonarprivacy.xyz",
                coreClaimedHandle: "alice@sonarprivacy.xyz"
            )
        )
        XCTAssertTrue(
            OwnProfileHydration.canPublishOwnProfile(
                localBip353: "",
                coreClaimedHandle: nil
            )
        )
    }

    func testRestoreClearedNicknameMustNotMintAnonymousOnRelaunch() {
        XCTAssertTrue(OwnProfileHydration.shouldMintAnonymousNickname(savedValue: nil))
        XCTAssertFalse(OwnProfileHydration.shouldMintAnonymousNickname(savedValue: ""))
        XCTAssertFalse(OwnProfileHydration.shouldMintAnonymousNickname(savedValue: "Alice"))
    }
}
