package chat.bitchat.sonar.screens

import kotlin.test.Test
import kotlin.test.assertEquals

class SonarSearchScreenTest {
    @Test
    fun startSecureChatClosesSearchBeforeStartingChat() {
        val actions = mutableListOf<String>()

        startSecureChatFromSearch(
            closeSearch = { actions += "close-search" },
            startChat = { actions += "start-chat" },
        )

        assertEquals(listOf("close-search", "start-chat"), actions)
    }
}
