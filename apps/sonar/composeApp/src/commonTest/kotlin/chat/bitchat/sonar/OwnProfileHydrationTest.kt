package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class OwnProfileHydrationTest {
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
        )
        assertNull(plan.nicknameToAdopt)
        assertNull(plan.nip05ToAdopt)
        assertNull(plan.handleLocalToClaim)
        assertFalse(plan.shouldPublishNickname)
    }

    @Test
    fun existingLocalNicknameIsNotOverwrittenByRemote() {
        val plan = planOwnProfileHydration(
            localNickname = "local-nick",
            localBip353 = "",
            localClaimedHandle = null,
            remote = remote,
        )
        assertNull(plan.nicknameToAdopt)
        assertEquals("alice@sonarprivacy.xyz", plan.nip05ToAdopt)
        assertEquals("alice", plan.handleLocalToClaim)
        assertTrue(plan.shouldPublishNickname)
    }

    @Test
    fun alreadyClaimedHandleSkipsReclaimAndPrefMirror() {
        val plan = planOwnProfileHydration(
            localNickname = "Alice",
            localBip353 = "alice@sonarprivacy.xyz",
            localClaimedHandle = "alice@sonarprivacy.xyz",
            remote = remote,
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
        )
        assertEquals("bob", plan.nicknameToAdopt)
        assertTrue(plan.shouldPublishNickname)
    }

    @Test
    fun renameMustNotPublishWhenHandlePrefLacksCoreSidecar() {
        assertFalse(canPublishOwnProfile("alice@sonarprivacy.xyz", null))
        assertFalse(canPublishOwnProfile("alice@sonarprivacy.xyz", "  "))
        assertTrue(canPublishOwnProfile("alice@sonarprivacy.xyz", "alice@sonarprivacy.xyz"))
        assertTrue(canPublishOwnProfile("", null))
    }
}
