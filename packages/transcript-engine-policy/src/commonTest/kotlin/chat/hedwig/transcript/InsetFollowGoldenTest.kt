package chat.hedwig.transcript

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Loads [inset-follow.json] from golden/ — same contract as SPM golden tests (R-009).
 */
class InsetFollowGoldenTest {

    @Test
    fun insetFollow_matchesGoldenCases() {
        val text = checkNotNull(
            this::class.java.classLoader?.getResourceAsStream("inset-follow.json"),
        ) { "missing inset-follow.json in test resources" }
            .bufferedReader()
            .readText()

        assertCase(text, "at_tail_pins", TranscriptScrollDecision.Pin(animate = false))
        assertCase(text, "away_from_tail_locksteps", TranscriptScrollDecision.Lockstep)
        assertCase(text, "user_scrolling_ignores", TranscriptScrollDecision.Ignore)
        assertCase(text, "prepending_ignores", TranscriptScrollDecision.Ignore)
    }

    private fun assertCase(text: String, name: String, expected: TranscriptScrollDecision) {
        val block = caseBlock(text, name)
        val wasAtTail = jsonBool(block, "wasAtTail") ?: error("wasAtTail missing in $name")
        val userScrolling = jsonBool(block, "userScrolling") ?: error("userScrolling missing in $name")
        val isPrepending = jsonBool(block, "isPrepending") ?: error("isPrepending missing in $name")
        assertEquals(
            expected,
            TranscriptScrollPolicy.decideInsetChange(
                wasAtTail = wasAtTail,
                userScrolling = userScrolling,
                prepending = isPrepending,
            ),
            "golden case $name",
        )
    }

    private fun caseBlock(text: String, name: String): String {
        val marker = "\"name\": \"$name\""
        val start = text.indexOf(marker)
        assertTrue(start >= 0, "case $name not found in golden JSON")
        val next = text.indexOf("\"name\":", start + marker.length).let { if (it < 0) text.length else it }
        return text.substring(start, next)
    }

    private fun jsonBool(block: String, key: String): Boolean? {
        val re = Regex(""""$key"\s*:\s*(true|false)""")
        return re.find(block)?.groupValues?.get(1)?.toBooleanStrict()
    }
}
