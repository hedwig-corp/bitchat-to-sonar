package chat.bitchat.sonar

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

sealed interface Screen {
    data object Home : Screen
    data class Chat(val id: String, val name: String) : Screen
}

/**
 * Shared (commonMain) UI state for the Sonar app. Drives White Noise (Marmot)
 * encrypted DMs through [SonarCore]; the same logic will back the iOS app once
 * it shifts to Compose Multiplatform.
 */
class SonarAppState(private val scope: CoroutineScope) {
    var npub by mutableStateOf("")
        private set
    var started by mutableStateOf(false)
        private set
    var connecting by mutableStateOf(false)
        private set
    var chats by mutableStateOf<List<SonarChat>>(emptyList())
        private set
    var screen by mutableStateOf<Screen>(Screen.Home)
        private set
    var messages by mutableStateOf<List<SonarMsg>>(emptyList())
        private set
    var toast by mutableStateOf<String?>(null)

    fun boot() {
        if (started || connecting) return
        connecting = true
        scope.launch {
            try {
                npub = SonarCore.start()
                started = true
                refreshChats()
                poll()
            } catch (t: Throwable) {
                toast = "connect failed: ${t.message}"
            } finally {
                connecting = false
            }
        }
    }

    fun openChat(chat: SonarChat) {
        screen = Screen.Chat(chat.id, chat.name)
        scope.launch { messages = SonarCore.messages(chat.id) }
    }

    fun back() {
        screen = Screen.Home
        messages = emptyList()
        scope.launch { refreshChats() }
    }

    fun startChat(peer: String) {
        val p = peer.trim()
        if (p.isEmpty()) return
        scope.launch {
            try {
                SonarCore.startChat(p)
                refreshChats()
                toast = "chat started"
            } catch (t: Throwable) {
                toast = "couldn't start: ${t.message}"
            }
        }
    }

    fun send(chatId: String, text: String) {
        val t = text.trim()
        if (t.isEmpty()) return
        scope.launch {
            try {
                SonarCore.send(chatId, t)
                messages = SonarCore.messages(chatId)
            } catch (e: Throwable) {
                toast = "send failed: ${e.message}"
            }
        }
    }

    private suspend fun refreshChats() {
        chats = SonarCore.chats()
    }

    private fun poll() {
        scope.launch {
            while (true) {
                delay(4000)
                SonarCore.sync()
                refreshChats()
                (screen as? Screen.Chat)?.let { messages = SonarCore.messages(it.id) }
            }
        }
    }
}
