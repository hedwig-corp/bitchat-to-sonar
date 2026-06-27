package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SonarSlashCommandsTest {
    @Test
    fun parsesCanonicalCommandsAndArguments() {
        val parsed = SonarSlashCommands.parse("/msg @alice hello there")

        assertEquals(SonarSlashCommand.Message, parsed?.command)
        assertEquals("@alice hello there", parsed?.args)
    }

    @Test
    fun parsesIosAliases() {
        assertEquals(SonarSlashCommand.Message, SonarSlashCommands.parse("/m @alice")?.command)
        assertEquals(SonarSlashCommand.Who, SonarSlashCommands.parse("/w")?.command)
    }

    @Test
    fun ignoresUnknownCommandsSoTheyCanSendAsText() {
        assertNull(SonarSlashCommands.parse("hello"))
        assertNull(SonarSlashCommands.parse("/unknown value"))
    }

    @Test
    fun filtersHintsByCanonicalNameOrAlias() {
        assertEquals(listOf(SonarSlashCommand.Slap), SonarSlashCommands.matches("/sl"))
        assertTrue(SonarSlashCommand.Message in SonarSlashCommands.matches("/m"))
        assertTrue(SonarSlashCommand.Who in SonarSlashCommands.matches("/w"))
    }

    @Test
    fun noArgumentCommandsDoNotNeedTrailingSpace() {
        assertEquals(false, SonarSlashCommand.Who.needsArgument)
        assertEquals(false, SonarSlashCommand.Clear.needsArgument)
        assertEquals(true, SonarSlashCommand.Block.needsArgument)
    }
}
