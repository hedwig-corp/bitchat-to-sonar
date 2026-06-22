package chat.bitchat.sonar.push

import android.util.Log
import chat.bitchat.sonar.BuildConfig
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.wallet.WalletBridge
import chat.bitchat.sonar.wallet.WalletState
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Registers the device's FCM token with both notification servers:
 *   1. Transponder — MIP-05 encrypted gift wrap (chat/call wakeups)
 *   2. Breez NDS — webhook URL (wallet wakeups, silent only)
 */
object SonarPushRegistration {

    private const val TAG = "SonarPush"
    private const val MAX_RETRIES = 3
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val transponderNpub: String get() = BuildConfig.TRANSPONDER_NPUB
    private val ndsUrl: String get() = BuildConfig.NDS_URL

    @Volatile private var cachedFcmToken: String? = null

    fun ensureRegistered() {
        if (transponderNpub.isBlank() && ndsUrl.isBlank()) {
            Log.d(TAG, "Push not configured (no TRANSPONDER_NPUB or NDS_URL)")
            return
        }
        FirebaseMessaging.getInstance().token.addOnSuccessListener { token ->
            Log.d(TAG, "FCM token collected (${token.take(8)}...)")
            cachedFcmToken = token
            registerTransponder(token)
            registerBreezWebhook(token)
        }.addOnFailureListener { e ->
            Log.w(TAG, "FCM token collection failed", e)
        }
    }

    fun onTokenRefresh(token: String) {
        Log.d(TAG, "FCM token refreshed (${token.take(8)}...)")
        cachedFcmToken = token
        registerTransponder(token)
        registerBreezWebhook(token)
    }

    /**
     * Retry Breez webhook registration after the wallet becomes Ready.
     * Called from the wallet setup path once the SDK connects.
     */
    fun retryBreezWebhookIfNeeded() {
        val token = cachedFcmToken ?: return
        registerBreezWebhook(token)
    }

    private fun registerTransponder(fcmToken: String) {
        if (transponderNpub.isBlank()) return
        scope.launch {
            var backoff = 2_000L
            for (attempt in 1..MAX_RETRIES) {
                try {
                    SonarCore.registerPushToken(
                        platform = "fcm",
                        token = fcmToken.toByteArray(Charsets.UTF_8),
                        serverNpub = transponderNpub,
                    )
                    Log.d(TAG, "Transponder: MIP-05 push token registered")
                    return@launch
                } catch (e: Exception) {
                    Log.w(TAG, "Transponder registration attempt $attempt/$MAX_RETRIES failed", e)
                    if (attempt < MAX_RETRIES) delay(backoff)
                    backoff *= 2
                }
            }
        }
    }

    private fun registerBreezWebhook(fcmToken: String) {
        if (ndsUrl.isBlank()) return
        if (WalletBridge.state() !is WalletState.Ready) {
            Log.d(TAG, "Breez NDS: wallet not ready, will retry after wallet setup")
            return
        }
        val webhookUrl = "$ndsUrl/api/v1/notify?platform=android&token=$fcmToken"
        scope.launch {
            try {
                WalletBridge.registerWebhook(webhookUrl)
                Log.d(TAG, "Breez NDS webhook registered")
            } catch (e: Exception) {
                Log.w(TAG, "Breez NDS webhook registration failed", e)
            }
        }
    }

    fun unregister() {
        scope.launch {
            try { WalletBridge.unregisterWebhook() } catch (_: Exception) {}
        }
        cachedFcmToken = null
        Log.d(TAG, "Unregistered from push servers")
    }
}
