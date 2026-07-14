package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals

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
}
