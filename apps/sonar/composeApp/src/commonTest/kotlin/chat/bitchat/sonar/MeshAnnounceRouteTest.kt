package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MeshAnnounceRouteTest {
    @Test
    fun ignoresOwnAnnounceEchoedAcrossAnotherBleLink() {
        assertEquals(
            MeshAnnounceRoute.SelfEcho,
            meshAnnounceRoute("AABBCCDD", "aabbccdd", ttl = 6u),
        )
    }

    @Test
    fun onlyFullTtlAnnounceBindsTheDirectBleNeighbour() {
        assertEquals(
            MeshAnnounceRoute.Direct,
            meshAnnounceRoute("local", "direct", ttl = 7u),
        )
        assertEquals(
            MeshAnnounceRoute.Relayed,
            meshAnnounceRoute("local", "remote", ttl = 6u),
        )
    }

    @Test
    fun verifiedSenderCannotReplaceItsSigningKey() {
        assertTrue(meshSigningKeyMatches(null, "aabb"))
        assertTrue(meshSigningKeyMatches("AABB", "aabb"))
        assertFalse(meshSigningKeyMatches("aabb", "ccdd"))
    }
}
