package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DurableRetirementTest {
    @Test
    fun everyFailedDurabilityStageWithholdsCompletion() {
        val events = mutableListOf<String>()
        assertFalse(completeDurableRetirement(
            quarantine = { events += "quarantine"; false },
            cleanup = { events += "cleanup"; true },
            proveAbsent = { events += "proof"; true },
        ))
        assertEquals(listOf("quarantine"), events)

        events.clear()
        assertFalse(completeDurableRetirement(
            quarantine = { events += "quarantine"; true },
            cleanup = { events += "cleanup"; false },
            proveAbsent = { events += "proof"; true },
        ))
        assertEquals(listOf("quarantine", "cleanup"), events)

        events.clear()
        assertFalse(completeDurableRetirement(
            quarantine = { events += "quarantine"; true },
            cleanup = { events += "cleanup"; true },
            proveAbsent = { events += "proof"; false },
        ))
        assertEquals(listOf("quarantine", "cleanup", "proof"), events)
    }

    @Test
    fun successfulRetirementRequiresAllThreeStages() {
        assertTrue(completeDurableRetirement(
            quarantine = { true },
            cleanup = { true },
            proveAbsent = { true },
        ))
    }
}
