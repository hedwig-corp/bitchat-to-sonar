package chat.bitchat.sonar.signer

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

actual object ExternalSigner {
    actual fun isAvailable(): Boolean = AmberSignerClient.isSignerInstalled()

    actual suspend fun login(): ExternalSignerLogin = withContext(Dispatchers.IO) {
        AmberSignerClient.login()
    }
}
