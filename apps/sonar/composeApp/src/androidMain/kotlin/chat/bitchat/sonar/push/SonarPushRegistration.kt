package chat.bitchat.sonar.push

import android.net.Uri
import android.util.Log
import chat.bitchat.sonar.AppContextHolder
import chat.bitchat.sonar.BuildConfig
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.wallet.WalletBridge
import chat.bitchat.sonar.wallet.WalletState
import com.google.firebase.messaging.FirebaseMessaging
import java.security.MessageDigest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Registers the device's FCM token with both notification servers:
 *   1. Transponder — MIP-05 encrypted token shares (chat/call wakeups)
 *   2. Breez NDS — webhook URL (wallet wakeups, silent only)
 */
object SonarPushRegistration {

    private const val TAG = "SonarPush"
    private const val MAX_RETRIES = 3
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val transponderNpub: String get() = BuildConfig.TRANSPONDER_NPUB

    // Base URL of the Breez NDS. Tolerates a bare host (prepends https://) and
    // rejects the truncated "https:"/"http:" sentinels, mirroring iOS, so a
    // malformed webhook URL can never be registered (which breaks offline pay).
    private val ndsUrl: String
        get() {
            val raw = BuildConfig.NDS_URL.trim()
            if (raw.isEmpty() || raw == "https:" || raw == "http:") return ""
            return if (raw.startsWith("http://") || raw.startsWith("https://")) raw else "https://$raw"
        }

    @Volatile private var cachedFcmToken: String? = null
    @Volatile private var cachedOffer: String? = null
    @Volatile private var sessionWebhookMarker: String? = null

    fun ensureRegistered() {
        if (!SonarPushPrefs.effectivePushEnabled(AppContextHolder.ctx)) {
            Log.d(TAG, "Push not registered: disabled by user preference")
            return
        }
        if (transponderNpub.isBlank() && ndsUrl.isBlank()) {
            Log.d(TAG, "Push not configured (no TRANSPONDER_NPUB or NDS_URL)")
            return
        }
        FirebaseMessaging.getInstance().token.addOnSuccessListener { token ->
            Log.d(TAG, "FCM token collected")
            cachedFcmToken = token
            registerTransponder(token)
            retryBreezWebhookIfNeeded()
        }.addOnFailureListener { e ->
            Log.w(TAG, "FCM token collection failed", e)
        }
    }

    fun onTokenRefresh(token: String) {
        if (!SonarPushPrefs.effectivePushEnabled(AppContextHolder.ctx)) {
            Log.d(TAG, "FCM token refreshed while push disabled")
            cachedFcmToken = null
            return
        }
        Log.d(TAG, "FCM token refreshed")
        cachedFcmToken = token
        registerTransponder(token)
        retryBreezWebhookIfNeeded()
    }

    /**
     * The Breez webhook is offer-scoped on the swap server. Registering only the
     * FCM token can leave an existing BOLT12 offer with a stale/missing webhook,
     * so coordinate token + current offer and force a re-subscribe when either
     * changes. Mirrors the iOS `unregisterWebhook` -> `registerWebhook` path,
     * without trusting a persisted local marker across app launches.
     */
    fun ensureBreezWebhook(offer: String) {
        cachedOffer = offer
        retryBreezWebhookIfNeeded()
    }

    /**
     * Retry Breez webhook registration after the wallet becomes Ready.
     * Called from the wallet setup path once the SDK connects.
     */
    fun retryBreezWebhookIfNeeded() {
        val token = cachedFcmToken
        val offer = cachedOffer
        if (token == null) {
            Log.d(TAG, "Breez NDS: receive offer ready, waiting for FCM token")
            return
        }
        if (offer == null) {
            Log.d(TAG, "Breez NDS: FCM token ready, waiting for receive offer")
            return
        }
        registerBreezWebhook(token, offer)
    }

    private fun registerTransponder(fcmToken: String) {
        if (transponderNpub.isBlank()) return
        scope.launch {
            var backoff = 2_000L
            for (attempt in 1..MAX_RETRIES) {
                try {
                    SonarCore.start()
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

    private fun registerBreezWebhook(fcmToken: String, offer: String) {
        if (ndsUrl.isBlank()) return
        if (WalletBridge.state() !is WalletState.Ready) {
            Log.d(TAG, "Breez NDS: wallet not ready, will retry after wallet setup")
            return
        }
        val webhookUrl = webhookUrl(fcmToken)
        if (webhookUrl == null) {
            Log.w(TAG, "Breez NDS disabled: invalid NDS_URL build setting")
            return
        }
        val marker = webhookMarker(offer, webhookUrl)
        if (sessionWebhookMarker == marker) {
            Log.d(TAG, "Breez NDS webhook re-subscribe already queued for current offer")
            return
        }
        sessionWebhookMarker = marker
        scope.launch {
            try {
                try { WalletBridge.unregisterWebhook() } catch (_: Exception) {}
                WalletBridge.registerWebhook(webhookUrl)
                Log.d(TAG, "Breez NDS webhook force re-subscribed for current offer")
            } catch (e: Exception) {
                if (sessionWebhookMarker == marker) sessionWebhookMarker = null
                Log.w(TAG, "Breez NDS webhook registration failed", e)
            }
        }
    }

    fun unregister() {
        scope.launch {
            try { WalletBridge.unregisterWebhook() } catch (_: Exception) {}
        }
        cachedFcmToken = null
        cachedOffer = null
        sessionWebhookMarker = null
        Log.d(TAG, "Unregistered from push servers")
    }

    private fun webhookUrl(fcmToken: String): String? {
        val uri = runCatching { Uri.parse(ndsUrl.trim()) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase()
        if ((scheme != "https" && scheme != "http") || uri.host.isNullOrBlank()) return null
        return uri.buildUpon()
            .appendPath("api")
            .appendPath("v1")
            .appendPath("notify")
            .appendQueryParameter("platform", "android")
            .appendQueryParameter("token", fcmToken)
            .build()
            .toString()
    }

    private fun webhookMarker(offer: String, webhookUrl: String): String {
        val bytes = MessageDigest.getInstance("SHA-256")
            .digest("$offer|$webhookUrl".toByteArray(Charsets.UTF_8))
        return bytes.joinToString(separator = "") { "%02x".format(it.toInt() and 0xff) }
    }
}
