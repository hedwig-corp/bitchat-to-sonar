package chat.bitchat.sonar.push

import android.net.Uri
import android.os.SystemClock
import android.util.Log
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
import kotlinx.coroutines.withTimeout

/**
 * Registers the device's FCM token with both notification servers:
 *   1. Transponder — MIP-05 encrypted token shares (chat/call wakeups)
 *   2. Breez NDS — webhook URL (wallet wakeups, silent only)
 */
object SonarPushRegistration {

    private const val TAG = "SonarPush"
    private const val MAX_RETRIES = 3
    private const val DEFAULT_NDS_HOST = "nds.sonar.hedwig.sh"
    private const val WEBHOOK_MARKER_VERSION = "android-fcm-explicit-token-v2"
    private const val WEBHOOK_IN_FLIGHT_TIMEOUT_MS = 30_000L
    private const val WEBHOOK_REGISTRATION_TIMEOUT_MS = 20_000L
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val webhookLock = Any()

    private val transponderNpub: String get() = BuildConfig.TRANSPONDER_NPUB

    // Base URL of the Breez NDS. Tolerates a bare host (prepends https://) and
    // falls back to the production NDS host for missing/truncated settings so a
    // malformed build setting cannot disable offline pay.
    private val ndsUrl: String
        get() {
            return normalizedNdsUrl(BuildConfig.NDS_URL)
        }

    @Volatile private var cachedFcmToken: String? = null
    @Volatile private var cachedOffer: String? = null
    @Volatile private var completedSessionWebhookMarker: String? = null
    @Volatile private var inFlightWebhookMarker: String? = null
    @Volatile private var inFlightWebhookStartedAtMs: Long = 0L
    @Volatile private var inFlightWebhookGeneration: Long = 0L

    fun ensureRegistered() {
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
        val attemptGeneration = synchronized(webhookLock) {
            if (completedSessionWebhookMarker == marker) {
                Log.d(TAG, "Breez NDS webhook already re-subscribed for current offer this launch")
                return
            }
            val now = SystemClock.elapsedRealtime()
            if (inFlightWebhookMarker == marker) {
                if (now - inFlightWebhookStartedAtMs < WEBHOOK_IN_FLIGHT_TIMEOUT_MS) {
                    Log.d(TAG, "Breez NDS webhook re-subscribe already in flight for current offer")
                    return
                }
                Log.w(TAG, "Breez NDS webhook re-subscribe timed out; retrying current offer")
            }
            inFlightWebhookMarker = marker
            inFlightWebhookStartedAtMs = now
            inFlightWebhookGeneration += 1
            inFlightWebhookGeneration
        }
        scope.launch {
            try {
                forceRegisterWebhook(webhookUrl)
                if (finishWebhookAttempt(marker, attemptGeneration, completed = true)) {
                    Log.d(TAG, "Breez NDS webhook force re-subscribed for current offer")
                }
            } catch (e: Exception) {
                if (finishWebhookAttempt(marker, attemptGeneration, completed = false)) {
                    Log.w(TAG, "Breez NDS webhook registration failed", e)
                }
            }
        }
    }

    private fun finishWebhookAttempt(
        marker: String,
        generation: Long,
        completed: Boolean,
    ): Boolean {
        return synchronized(webhookLock) {
            if (inFlightWebhookMarker != marker || inFlightWebhookGeneration != generation) {
                Log.d(TAG, "Breez NDS webhook ignoring stale re-subscribe attempt")
                return@synchronized false
            }
            inFlightWebhookMarker = null
            inFlightWebhookStartedAtMs = 0L
            if (completed) {
                completedSessionWebhookMarker = marker
            }
            true
        }
    }

    fun unregister() {
        scope.launch {
            try { WalletBridge.unregisterWebhook() } catch (_: Exception) {}
        }
        cachedFcmToken = null
        cachedOffer = null
        synchronized(webhookLock) {
            completedSessionWebhookMarker = null
            inFlightWebhookMarker = null
            inFlightWebhookStartedAtMs = 0L
            inFlightWebhookGeneration += 1
        }
        Log.d(TAG, "Unregistered from push servers")
    }

    internal fun normalizedNdsUrl(rawValue: String?): String {
        val raw = rawValue?.trim().orEmpty()
        if (raw.isEmpty() || raw == "https:" || raw == "http:") return "https://$DEFAULT_NDS_HOST"
        if (raw.startsWith("http://") || raw.startsWith("https://")) {
            val uri = runCatching { Uri.parse(raw) }.getOrNull()
            val host = uri?.host
            if (host.isNullOrBlank()) return "https://$DEFAULT_NDS_HOST"
            // Breez/Boltz requires HTTPS webhook URLs. Normalize any old
            // public `http://` setting instead of propagating it.
            return uri.buildUpon().scheme("https").build().toString()
        }
        return "https://$raw"
    }

    internal fun webhookUrl(fcmToken: String): String? {
        val uri = runCatching { Uri.parse(ndsUrl.trim()) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase()
        if (scheme != "https" || uri.host.isNullOrBlank()) return null
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
            .digest("$WEBHOOK_MARKER_VERSION|$offer|$webhookUrl".toByteArray(Charsets.UTF_8))
        return bytes.joinToString(separator = "") { "%02x".format(it.toInt() and 0xff) }
    }

    private suspend fun forceRegisterWebhook(webhookUrl: String) {
        var lastError: Exception? = null
        for (attempt in 1..MAX_RETRIES) {
            try {
                withTimeout(WEBHOOK_REGISTRATION_TIMEOUT_MS) {
                    try { WalletBridge.unregisterWebhook() } catch (_: Exception) {}
                    WalletBridge.registerWebhook(webhookUrl)
                }
                return
            } catch (e: Exception) {
                lastError = e
                if (attempt < MAX_RETRIES) delay(attempt * 2_000L)
            }
        }
        throw lastError ?: IllegalStateException("webhook registration failed")
    }
}
