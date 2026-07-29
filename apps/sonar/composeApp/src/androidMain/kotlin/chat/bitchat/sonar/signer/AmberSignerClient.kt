package chat.bitchat.sonar.signer

import android.content.Intent
import android.net.Uri
import android.util.Log
import chat.bitchat.sonar.AppContextHolder
import chat.bitchat.sonar.SonarLifecycle
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/**
 * NIP-55 external signer transport (Amber and compatible signer apps).
 *
 * Two paths, per the spec:
 *  1. **ContentResolver first** — background-capable, no UI, works from push
 *     wakes and killed-app drains once the user granted "remember" permissions
 *     at login. Arguments ride in the `projection` parameter (spec footgun:
 *     its prose says selectionArgs, its code and Amber use projection).
 *  2. **Intent fallback** — needs a foreground Activity registered via
 *     [ExternalSignerBridge]. Requests carry a correlation `id`; responses may
 *     arrive individually or batched in a `results` JSON array when the
 *     signer merges queued approvals into one screen.
 *
 * The Rust core calls [uniffi.sonar_ffi.ForeignNostrSigner] methods from its
 * own blocking-safe threads (spawn_blocking), so blocking here is by design.
 */
object AmberSignerClient : uniffi.sonar_ffi.ForeignNostrSigner {
    private const val TAG = "AmberSigner"

    /** How long to wait for the user to act on a signer approval screen. */
    private const val INTENT_TIMEOUT_MS = 60_000L

    private val ctx get() = AppContextHolder.ctx

    /** In-flight intent requests awaiting an activity result, by request id. */
    private val pending = ConcurrentHashMap<String, CompletableDeferred<Nip55.Response>>()

    /** The account this signer signs for (hex), set once configured. */
    @Volatile var currentUserHex: String = ""

    /** Preferred signer package (targeted intents skip the OS chooser). */
    @Volatile var signerPackage: String? = null

    /** Drop the in-process account binding (wipe / nsec restore). Without this
     *  a later fresh Amber login would carry a stale `current_user`/package. */
    fun reset() {
        currentUserHex = ""
        signerPackage = null
    }

    // ── availability ──────────────────────────────────────────────────────────

    fun isSignerInstalled(): Boolean = resolveSignerActivities().isNotEmpty()

    private fun resolveSignerActivities(): List<String> = runCatching {
        val probe = Intent(Intent.ACTION_VIEW, Uri.parse("${Nip55.SCHEME}:"))
        ctx.packageManager.queryIntentActivities(probe, 0)
            .mapNotNull { it.activityInfo?.packageName }
    }.getOrDefault(emptyList())

    // ── login (get_public_key, foreground only) ───────────────────────────────

    suspend fun login(): ExternalSignerLogin {
        if (!isSignerInstalled()) {
            throw ExternalSignerException("No NIP-55 signer app installed")
        }
        // Account-neutral login intent: no `current_user` (the user picks the
        // account in the signer) and no package (the OS chooser handles
        // multiple signers). The response's `package` extra tells us which
        // signer to target afterwards.
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("${Nip55.SCHEME}:"))
        intent.putExtra("type", Nip55.TYPE_GET_PUBLIC_KEY)
        intent.putExtra("permissions", Nip55.loginPermissionsJson())
        intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val response = launchForResult(intent)
            ?: throw ExternalSignerException("Signer sign-in timed out")
        if (response.rejected) throw ExternalSignerException("Signer sign-in was rejected")
        val raw = response.result?.trim().orEmpty()
        if (raw.isEmpty()) throw ExternalSignerException("Signer returned no public key")
        // Amber returns hex on current builds, npub on older ones — the FFI
        // constructor accepts both; normalization to hex happens there.
        return ExternalSignerLogin(pubkeyHex = raw, packageName = response.packageName)
    }

    // ── ForeignNostrSigner (called by the Rust core) ──────────────────────────

    override fun signEvent(unsignedEventJson: String): String? {
        val viaProvider = queryProvider(
            authority = "SIGN_EVENT",
            payload = unsignedEventJson,
            peerPubkeyHex = "",
        )
        when (viaProvider) {
            is ProviderResult.Success ->
                return viaProvider.event
                    ?: viaProvider.result?.let { Nip55.assembleSignedEvent(unsignedEventJson, it) }
            ProviderResult.Rejected -> return null
            ProviderResult.Unavailable -> Unit // fall through to the intent path
        }
        val response = launchForResult(
            baseIntent(payload = unsignedEventJson, type = Nip55.TYPE_SIGN_EVENT),
        ) ?: return null
        if (response.rejected) return null
        // Prefer the signer's full event; a signature-only response is
        // assembled locally (the Rust adapter verifies either way).
        return response.event
            ?: response.result?.let { Nip55.assembleSignedEvent(unsignedEventJson, it) }
    }

    override fun nip44Encrypt(peerPubkeyHex: String, plaintext: String): String? =
        cryptoOperation(Nip55.TYPE_NIP44_ENCRYPT, "NIP44_ENCRYPT", peerPubkeyHex, plaintext)

    override fun nip44Decrypt(peerPubkeyHex: String, ciphertext: String): String? =
        cryptoOperation(Nip55.TYPE_NIP44_DECRYPT, "NIP44_DECRYPT", peerPubkeyHex, ciphertext)

    private fun cryptoOperation(
        type: String,
        authority: String,
        peerPubkeyHex: String,
        payload: String,
    ): String? {
        when (val viaProvider = queryProvider(authority, payload, peerPubkeyHex)) {
            is ProviderResult.Success ->
                return viaProvider.result.takeIf(Nip55::isUsableResult)
            ProviderResult.Rejected -> return null
            ProviderResult.Unavailable -> Unit
        }
        val intent = baseIntent(payload = payload, type = type)
        intent.putExtra("pubkey", peerPubkeyHex)
        intent.putExtra("pubKey", peerPubkeyHex) // legacy extra casing some signers read
        val response = launchForResult(intent) ?: return null
        if (response.rejected) return null
        return response.result?.takeIf(Nip55::isUsableResult)
    }

    // ── ContentResolver path ──────────────────────────────────────────────────

    private sealed interface ProviderResult {
        data class Success(val result: String?, val event: String?) : ProviderResult

        /** Permanent user rejection — spec says do NOT fall back to an intent. */
        data object Rejected : ProviderResult

        /** No remembered grant / signer unknown → try the intent path. */
        data object Unavailable : ProviderResult
    }

    private fun queryProvider(
        authority: String,
        payload: String,
        peerPubkeyHex: String,
    ): ProviderResult {
        val pkg = signerPackage ?: return ProviderResult.Unavailable
        val user = currentUserHex
        if (user.isEmpty()) return ProviderResult.Unavailable
        return runCatching {
            val uri = Uri.parse("content://$pkg.$authority")
            // Projection IS the argument vector: [payload, peer pubkey, user].
            val projection = arrayOf(payload, peerPubkeyHex, user)
            ctx.contentResolver.query(uri, projection, null, null, null).use { cursor ->
                if (cursor == null || !cursor.moveToFirst()) {
                    return@runCatching ProviderResult.Unavailable
                }
                if (cursor.getColumnIndex("rejected") >= 0) {
                    return@runCatching ProviderResult.Rejected
                }
                val result = cursor.readColumn("result") ?: cursor.readColumn("signature")
                val event = cursor.readColumn("event")
                ProviderResult.Success(result = result, event = event)
            }
        }.getOrElse { e ->
            Log.w(TAG, "signer provider $authority failed: ${e.message}")
            ProviderResult.Unavailable
        }
    }

    private fun android.database.Cursor.readColumn(name: String): String? {
        val idx = getColumnIndex(name)
        if (idx < 0) return null
        return runCatching { getString(idx) }.getOrNull()
    }

    // ── Intent path ───────────────────────────────────────────────────────────

    private fun baseIntent(payload: String, type: String): Intent {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("${Nip55.SCHEME}:${Uri.encode(payload)}"))
        intent.putExtra("type", type)
        if (currentUserHex.isNotEmpty()) intent.putExtra("current_user", currentUserHex)
        signerPackage?.let { intent.`package` = it }
        // Required: queued requests merge into the already-open approval
        // screen instead of stacking new ones (and responses batch).
        intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return intent
    }

    /**
     * Launch a signer intent through the foreground Activity and block until
     * its result (or timeout). Returns null when no Activity is available
     * (background), on timeout, or when the launch fails.
     */
    private fun launchForResult(intent: Intent): Nip55.Response? {
        val launcher = ExternalSignerBridge.launchSignerIntent ?: run {
            Log.w(TAG, "no foreground activity for signer intent (${intent.getStringExtra("type")})")
            return null
        }
        // Background sync must never pop the signer UI (the OS would block the
        // start anyway) — fail fast instead of parking on the 60s timeout.
        // Exception: while requests are in flight, the signer's own approval
        // screen covers us (appVisible=false) and new intents merge into it.
        if (!SonarLifecycle.appVisible && pending.isEmpty()) {
            Log.w(TAG, "signer intent skipped: app not visible (${intent.getStringExtra("type")})")
            return null
        }
        val id = UUID.randomUUID().toString()
        intent.putExtra("id", id)
        val deferred = CompletableDeferred<Nip55.Response>()
        pending[id] = deferred
        return try {
            launcher(intent)
            runBlocking {
                withTimeoutOrNull(INTENT_TIMEOUT_MS) { deferred.await() }
            }
        } catch (e: Exception) {
            Log.w(TAG, "signer intent launch failed: ${e.message}")
            null
        } finally {
            pending.remove(id)
        }
    }

    /**
     * Deliver an activity result from the signer. Handles both shapes: the
     * batched `results` JSON array and plain single-response extras.
     * Responses without a usable id resolve the oldest pending request (the
     * signer echoes ids, but a blanket-approval response may drop them).
     */
    fun onSignerResult(resultCode: Int, data: Intent?) {
        if (resultCode != android.app.Activity.RESULT_OK || data == null) {
            // Signer crashed or the user backed out: fail every in-flight
            // request so core operations error out instead of waiting 60s.
            failAllPending()
            return
        }
        val batch = data.getStringExtra("results")
        if (!batch.isNullOrBlank()) {
            Nip55.parseResultsArray(batch).forEach(::resolve)
            return
        }
        resolve(
            Nip55.Response(
                id = data.getStringExtra("id"),
                result = data.getStringExtra("result") ?: data.getStringExtra("signature"),
                event = data.getStringExtra("event"),
                rejected = data.getBooleanExtra("rejected", false),
                packageName = data.getStringExtra("package"),
            ),
        )
    }

    private fun resolve(response: Nip55.Response) {
        val byId = response.id?.let(pending::remove)
        if (byId != null) {
            byId.complete(response)
            return
        }
        // No id echoed: resolve the single pending request if unambiguous.
        val keys = pending.keys().toList()
        if (keys.size == 1) {
            pending.remove(keys[0])?.complete(response)
        } else {
            Log.w(TAG, "unmatched signer response (id=${response.id}, pending=${keys.size})")
        }
    }

    private fun failAllPending() {
        val entries = pending.keys().toList()
        entries.forEach { id ->
            pending.remove(id)?.complete(
                Nip55.Response(id = id, result = null, event = null, rejected = true, packageName = null),
            )
        }
    }
}

/**
 * Foreground seam for signer intents, same pattern as [chat.bitchat.sonar.ActivityBridge]:
 * MainActivity registers a `StartActivityForResult` launcher here and forwards
 * every result to [AmberSignerClient.onSignerResult].
 */
object ExternalSignerBridge {
    @Volatile var launchSignerIntent: ((Intent) -> Unit)? = null
}
