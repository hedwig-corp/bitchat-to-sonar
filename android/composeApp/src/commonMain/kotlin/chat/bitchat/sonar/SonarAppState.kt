package chat.bitchat.sonar

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

sealed interface Screen {
    data object Home : Screen
    data object Settings : Screen
    data object Profile : Screen
    data object Nearby : Screen
    data class Chat(val id: String, val name: String) : Screen
    data class Channel(val geohash: String) : Screen
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
    private var stack by mutableStateOf<List<Screen>>(listOf(Screen.Home))
    val screen: Screen get() = stack.last()

    var dark by mutableStateOf(SonarCore.isDark())
        private set

    fun push(s: Screen) { stack = stack + s }
    fun toggleDark() { dark = !dark; SonarCore.setDark(dark) }

    fun wipe() {
        scope.launch {
            SonarCore.wipe()
            stack = listOf(Screen.Home)
            chats = emptyList(); messages = emptyList()
            onboarded = false; nick = ""; npub = ""; started = false
        }
    }
    var messages by mutableStateOf<List<SonarMsg>>(emptyList())
        private set
    var channels by mutableStateOf(SonarCore.joinedChannels())
        private set
    var channelMsgs by mutableStateOf<List<SonarChannelMsg>>(emptyList())
        private set
    var toast by mutableStateOf<String?>(null)

    fun joinChannel(geohash: String) {
        val g = geohash.trim().lowercase()
        if (g.isEmpty()) return
        SonarCore.joinChannel(g)
        channels = SonarCore.joinedChannels()
        openChannel(g)
    }

    fun openChannel(geohash: String) {
        push(Screen.Channel(geohash))
        channelMsgs = emptyList()
        scope.launch { channelMsgs = SonarCore.channelMessages(geohash) }
    }

    fun sendChannelMsg(geohash: String, text: String) {
        val t = text.trim()
        if (t.isEmpty()) return
        scope.launch {
            try {
                SonarCore.sendChannel(geohash, t)
                channelMsgs = SonarCore.channelMessages(geohash)
            } catch (e: Throwable) {
                toast = "send failed: ${e.message}"
            }
        }
    }

    var onboarded by mutableStateOf(SonarCore.onboardingComplete())
        private set
    var nick by mutableStateOf(SonarCore.nickname())
        private set

    fun fingerprint(): String = SonarCore.fingerprint()

    fun completeOnboarding(nickname: String) {
        SonarCore.setNickname(nickname)
        SonarCore.setOnboardingComplete(true)
        nick = nickname
        onboarded = true
    }

    fun updateNickname(value: String) {
        SonarCore.setNickname(value)
        nick = value
    }

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
        push(Screen.Chat(chat.id, chat.name))
        scope.launch { messages = SonarCore.messages(chat.id) }
    }

    fun back() {
        if (stack.size > 1) stack = stack.dropLast(1)
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
                (screen as? Screen.Channel)?.let { channelMsgs = SonarCore.channelMessages(it.geohash) }
            }
        }
    }
}
