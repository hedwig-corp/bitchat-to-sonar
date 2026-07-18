package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class OwnProfileHydrationTest {
    private val domain = "sonarprivacy.xyz"
    private val remote = SonarProfile(
        name = "alice",
        displayName = "Alice",
        about = "hi",
        picture = null,
        nip05 = "alice@sonarprivacy.xyz",
    )

    @Test
    fun restoreWithBlankLocalStateAdoptsKind0NameAndHandle() {
        val plan = planOwnProfileHydration(
            localNickname = "",
            localBip353 = "",
            localClaimedHandle = null,
            remote = remote,
            handleDomain = domain,
        )
        assertEquals("Alice", plan.nicknameToAdopt)
        assertEquals("alice@sonarprivacy.xyz", plan.nip05ToAdopt)
        assertEquals("alice", plan.handleLocalToClaim)
        assertTrue(plan.shouldPublishNickname)
    }

    @Test
    fun blankLocalWithoutRemoteMustNotPublish() {
        val plan = planOwnProfileHydration(
            localNickname = "  ",
            localBip353 = "",
            localClaimedHandle = null,
            remote = null,
            handleDomain = domain,
        )
        assertNull(plan.nicknameToAdopt)
        assertNull(plan.nip05ToAdopt)
        assertNull(plan.handleLocalToClaim)
        assertFalse(plan.shouldPublishNickname)
    }

    @Test
    fun remoteKind0NameAndNip05WinOverDivergentLocal() {
        val plan = planOwnProfileHydration(
            localNickname = "local-nick",
            localBip353 = "stale@other.com",
            localClaimedHandle = null,
            remote = remote,
            handleDomain = domain,
        )
        // Remote values are already taken on relays — never keep divergent local.
        assertEquals("Alice", plan.nicknameToAdopt)
        assertEquals("alice@sonarprivacy.xyz", plan.nip05ToAdopt)
        assertEquals("alice", plan.handleLocalToClaim)
        assertTrue(plan.shouldPublishNickname)
    }

    @Test
    fun matchingLocalNeedsNoAdoption() {
        val plan = planOwnProfileHydration(
            localNickname = "Alice",
            localBip353 = "alice@sonarprivacy.xyz",
            localClaimedHandle = "alice@sonarprivacy.xyz",
            remote = remote,
            handleDomain = domain,
        )
        assertNull(plan.nicknameToAdopt)
        assertNull(plan.nip05ToAdopt)
        assertNull(plan.handleLocalToClaim)
        assertTrue(plan.shouldPublishNickname)
    }

    @Test
    fun nameFieldUsedWhenDisplayNameMissing() {
        val plan = planOwnProfileHydration(
            localNickname = "",
            localBip353 = "",
            localClaimedHandle = null,
            remote = SonarProfile("bob", null, null, null, null),
            handleDomain = domain,
        )
        assertEquals("bob", plan.nicknameToAdopt)
        assertTrue(plan.shouldPublishNickname)
    }

    @Test
    fun externalNip05MustNotReclaimOrPublish() {
        val plan = planOwnProfileHydration(
            localNickname = "",
            localBip353 = "",
            localClaimedHandle = null,
            remote = SonarProfile("Alice", null, null, null, "alice@example.com"),
            handleDomain = domain,
        )
        assertEquals("Alice", plan.nicknameToAdopt)
        assertEquals("alice@example.com", plan.nip05ToAdopt)
        assertNull(plan.handleLocalToClaim)
        assertFalse(plan.shouldPublishNickname)
    }

    @Test
    fun renameMustNotPublishWhenHandlePrefLacksCoreSidecar() {
        assertFalse(canPublishOwnProfile("alice@sonarprivacy.xyz", null))
        assertFalse(canPublishOwnProfile("alice@sonarprivacy.xyz", "  "))
        assertTrue(canPublishOwnProfile("alice@sonarprivacy.xyz", "alice@sonarprivacy.xyz"))
        assertTrue(canPublishOwnProfile("", null))
    }

    @Test
    fun needsRelayFetchOnlyWhenRestoreSymptomsPresent() {
        assertTrue(needsOwnProfileRelayFetch("", "", null, domain))
        // Nick present but no handle pref/sidecar: must fetch — relays may hold nip05.
        assertTrue(needsOwnProfileRelayFetch("Alice", "", null, domain))
        assertFalse(
            needsOwnProfileRelayFetch(
                "Alice",
                "alice@sonarprivacy.xyz",
                "alice@sonarprivacy.xyz",
                domain,
            ),
        )
        assertTrue(
            needsOwnProfileRelayFetch("Alice", "alice@sonarprivacy.xyz", null, domain),
        )
        // External handle pref can never seed the sidecar — skip the RTT.
        assertFalse(
            needsOwnProfileRelayFetch("Alice", "alice@example.com", null, domain),
        )
    }
}
