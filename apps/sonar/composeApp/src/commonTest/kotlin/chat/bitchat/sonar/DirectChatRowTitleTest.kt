package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals

/** Regression: a 1:1 chat created with an MLS group name (e.g. sonar-cli
 *  `--group-name "Sonar DM Agent"`) must retitle to the counterpart's live
 *  kind-0 profile name, not keep the frozen creation name forever. */
class DirectChatRowTitleTest {
    @Test
    fun liveProfileNameWinsOverFrozenGroupName() {
        assertEquals(
            "Vincenzo Palazzo",
            directChatRowTitle("Vincenzo Palazzo", "Sonar DM Agent", "npub1abc…"),
        )
    }

    @Test
    fun groupNameIsPlaceholderUntilProfileLands() {
        assertEquals(
            "Sonar DM Agent",
            directChatRowTitle(null, "Sonar DM Agent", "npub1abc…"),
        )
    }

    @Test
    fun blankGroupNameFallsBackToShortNpub() {
        assertEquals("npub1abc…", directChatRowTitle(null, "", "npub1abc…"))
        assertEquals("npub1abc…", directChatRowTitle(null, "   ", "npub1abc…"))
    }

    @Test
    fun mismatchForcesRefetchOnlyWhenSignalIsReal() {
        assertEquals(true, shouldForceProfileRefetch("Old Name", "New Name", fetchInFlightOrRecent = false))
        assertEquals(false, shouldForceProfileRefetch("Same", "Same", fetchInFlightOrRecent = false))
        assertEquals(false, shouldForceProfileRefetch(null, "New Name", fetchInFlightOrRecent = false))
        assertEquals(false, shouldForceProfileRefetch("Old Name", null, fetchInFlightOrRecent = false))
        assertEquals(false, shouldForceProfileRefetch("Old Name", "", fetchInFlightOrRecent = false))
    }

    @Test
    fun inFlightOrRecentFetchBlocksForcedRefetch() {
        assertEquals(false, shouldForceProfileRefetch("Old Name", "New Name", fetchInFlightOrRecent = true))
    }

    @Test
    fun blankProfileNameTreatedAsMissing() {
        assertEquals("Sonar DM Agent", directChatRowTitle("", "Sonar DM Agent", "npub1abc…"))
    }
}
