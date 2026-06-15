package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals

class SafetyNumberTest {
    @Test fun matchesIosVector() {
        val expected = listOf(
            "31142", "08761", "75904", "53523", "41618", "19237",
            "86380", "63999", "52094", "29713", "57483", "79864",
        )
        assertEquals(expected, SafetyNumber.of("npub1alice", "npub1bob"))
    }

    @Test fun orderIndependent() {
        assertEquals(SafetyNumber.of("npub1bob", "npub1alice"), SafetyNumber.of("npub1alice", "npub1bob"))
    }

    @Test fun twelveGroupsOfFive() {
        val n = SafetyNumber.of("a", "b")
        assertEquals(12, n.size)
        n.forEach { assertEquals(5, it.length) }
    }
}
