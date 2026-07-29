package chat.bitchat.sonar.signer

import android.content.Intent
import android.net.Uri
import android.os.Looper
import android.util.Log
import chat.bitchat.sonar.AppContextHolder
import chat.bitchat.sonar.SonarLifecycle
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import uniffi.sonar_ffi.ForeignSignerResult

/**
 * NIP-55 external signer transport (Amber and compatible signer apps),
 * account-scoped: the account pubkey and target signer package arrive via the
 * constructor (they are owned by the persisted account state, not by this
 * bridge), so the class carries no mutable account state. Process-wide
 * TRANSPORT state (in-flight request correlation, the activity launcher, the
 * approval circuit breaker) lives in the companion.
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
 * own blocking-safe threads (spawn_blocking), so blocking here is by design —
 * but NEVER on the Android main thread (see [mainThreadGuard]): results are
 * delivered on main, so blocking main self-deadlocks until the timeout.
 */
class AmberSignerClient(
    /** The account this signer signs for (hex or npub — passed as-is to the
     *  signer's `current_user`, which accepts both). */
    private val userPubkey: String,
    /** The signer application package. Non-login requests are ALWAYS sent as
     *  explicit (targeted) intents: an implicit `nostrsigner:` intent would
     *  hand the request payload — DM plaintext for `nip44_encrypt` — to
     *  whichever app registered the scheme. When null, the sole installed
     *  signer is used; with zero or several candidates the intent path is
     *  refused rather than broadcast. */
    signerPackage: String?,
) : uniffi.sonar_ffi.ForeignNostrSigner {

    private val targetPackage: String? =
        signerPackage ?: resolveSignerActivities().distinct().singleOrNull()

    override fun signEvent(unsignedEventJson: String): ForeignSignerResult =
        request(
            type = Nip55.TYPE_SIGN_EVENT,
            authority = "SIGN_EVENT",
            payload = unsignedEventJson,
            peerPubkeyHex = "",
        ) { event, result -> event ?: result }

    override fun nip44Encrypt(peerPubkeyHex: String, plaintext: String): ForeignSignerResult =
        request(
            type = Nip55.TYPE_NIP44_ENCRYPT,
            authority = "NIP44_ENCRYPT",
            payload = plaintext,
            peerPubkeyHex = peerPubkeyHex,
        ) { _, result -> result?.takeIf(Nip55::isUsableResult) }

    override fun nip44Decrypt(peerPubkeyHex: String, ciphertext: String): ForeignSignerResult =
        request(
            type = Nip55.TYPE_NIP44_DECRYPT,
            authority = "NIP44_DECRYPT",
            payload = ciphertext,
            peerPubkeyHex = peerPubkeyHex,
        ) { _, result -> result?.takeIf(Nip55::isUsableResult) }

    /**
     * True when the signer answered "I definitively cannot decrypt this".
     * Distinct from "no remembered grant": retrying (or prompting) can never
     * turn this into plaintext, and a gift wrap stuck on it would pin the
     * sync watermark forever while re-prompting the user.
     */
    private fun isDefinitiveDecryptFailure(type: String, result: String?): Boolean =
        type == Nip55.TYPE_NIP44_DECRYPT && result == Nip55.DECRYPT_FAILURE_SENTINEL

    /** Provider-first, intent-fallback request with tri-state outcome. */
    private fun request(
        type: String,
        authority: String,
        payload: String,
        peerPubkeyHex: String,
        extract: (event: String?, result: String?) -> String?,
    ): ForeignSignerResult {
        val pkg = targetPackage
            ?: return unavailable(type, "no unambiguous signer package to target")
        when (val viaProvider = queryProvider(pkg, authority, payload, peerPubkeyHex)) {
            is ProviderResult.Success -> {
                val value = extract(viaProvider.event, viaProvider.result)
                if (value != null) return ForeignSignerResult.Ok(value)
                // The signer decrypted and failed: permanent. Do NOT fall
                // through to the intent path — prompting cannot help, and
                // classifying it transient would pin the sync watermark.
                if (isDefinitiveDecryptFailure(type, viaProvider.result)) {
                    return ForeignSignerResult.Failed("signer could not decrypt the payload")
                }
                // A row came back but carried nothing usable — treat like a
                // missing grant and let the intent path ask the user.
            }
            ProviderResult.Rejected -> return ForeignSignerResult.Rejected
            ProviderResult.Unavailable -> Unit
        }
        mainThreadGuard(type)?.let { return it }
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("${Nip55.SCHEME}:${Uri.encode(payload)}"))
        intent.`package` = pkg
        intent.putExtra("type", type)
        intent.putExtra("current_user", userPubkey)
        if (peerPubkeyHex.isNotEmpty()) {
            intent.putExtra("pubkey", peerPubkeyHex)
            intent.putExtra("pubKey", peerPubkeyHex) // legacy extra casing some signers read
        }
        // Required: queued requests merge into the already-open approval
        // screen instead of stacking new ones (and responses batch).
        intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return when (val response = launchForResult(intent)) {
            null -> unavailable(type, "no approval UI available or approval timed out")
            else -> when {
                response.rejected -> {
                    approvalBreaker.recordFailure()
                    ForeignSignerResult.Rejected
                }
                else -> {
                    val value = extract(response.event, response.result)
                    when {
                        value != null -> {
                            approvalBreaker.recordSuccess()
                            ForeignSignerResult.Ok(value)
                        }
                        // The user approved and the signer still could not
                        // decrypt — permanent (see isDefinitiveDecryptFailure).
                        // Counts as a success for the breaker: the approval UI
                        // worked, the ciphertext is simply undecryptable.
                        isDefinitiveDecryptFailure(type, response.result) -> {
                            approvalBreaker.recordSuccess()
                            ForeignSignerResult.Failed("signer could not decrypt the payload")
                        }
                        else -> {
                            approvalBreaker.recordFailure()
                            unavailable(type, "signer returned no usable value")
                        }
                    }
                }
            }
        }
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
        pkg: String,
        authority: String,
        payload: String,
        peerPubkeyHex: String,
    ): ProviderResult {
        // The query is a synchronous binder call into the signer app with NO
        // client-side timeout, executed here on an uncancellable tokio
        // blocking thread — a wedged signer would pin it forever. Bound it on
        // a private executor: on timeout the orphaned call keeps its executor
        // thread (bounded pool) but the core call fails transient and retries.
        val future = providerExecutor.submit<ProviderResult> {
            runCatching {
                val uri = Uri.parse("content://$pkg.$authority")
                // Projection IS the argument vector: [payload, peer pubkey, user].
                val projection = arrayOf(payload, peerPubkeyHex, userPubkey)
                ctx.contentResolver.query(uri, projection, null, null, null).use { cursor ->
                    if (cursor == null || !cursor.moveToFirst()) {
                        return@runCatching ProviderResult.Unavailable
                    }
                    // Read the VALUE, not just the column's presence: Amber
                    // only emits this column when rejecting, but a signer that
                    // mirrors the response object (rejected=false on success)
                    // would otherwise have every successful call misread as a
                    // permanent rejection — which silently disables all
                    // background signing.
                    if (cursor.getColumnIndex("rejected") >= 0) {
                        val raw = cursor.readColumn("rejected")
                        val rejected = raw == null || raw == "1" || raw.equals("true", true)
                        if (rejected) return@runCatching ProviderResult.Rejected
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
        return try {
            future.get(PROVIDER_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (_: TimeoutException) {
            future.cancel(true)
            Log.w(TAG, "signer provider $authority timed out after ${PROVIDER_TIMEOUT_MS}ms")
            ProviderResult.Unavailable
        } catch (e: Exception) {
            Log.w(TAG, "signer provider $authority failed: ${e.message}")
            ProviderResult.Unavailable
        }
    }

    private fun android.database.Cursor.readColumn(name: String): String? {
        val idx = getColumnIndex(name)
        if (idx < 0) return null
        return runCatching { getString(idx) }.getOrNull()
    }

    private fun unavailable(op: String, reason: String): ForeignSignerResult {
        Log.w(TAG, "signer $op unavailable: $reason")
        return ForeignSignerResult.Unavailable(reason)
    }

    companion object {
        private const val TAG = "AmberSigner"

        /** How long to wait for the user to act on a signer approval screen. */
        private const val INTENT_TIMEOUT_MS = 60_000L

        /** Bound on one synchronous provider (binder) call into the signer. */
        private const val PROVIDER_TIMEOUT_MS = 15_000L

        private val ctx get() = AppContextHolder.ctx

        /** Bounded pool for provider calls: a wedged signer can strand at most
         *  this many threads, and stranded calls fail transient upstream. */
        private val providerExecutor: ExecutorService = Executors.newFixedThreadPool(4)

        /** In-flight intent requests awaiting an activity result, by request id. */
        private val pending = ConcurrentHashMap<String, CompletableDeferred<Nip55.Response>>()

        /** Set once any request times out: a stale answer to it may still
         *  arrive, so id-less responses can no longer be attributed safely. */
        private val idLessAttributionUnsafe = java.util.concurrent.atomic.AtomicBoolean(false)

        /** Stops a peer-driven approval storm: any drain of N gift wraps
         *  without a remembered decrypt grant would otherwise pop N approval
         *  screens. After [ApprovalBreaker.MAX_CONSECUTIVE_FAILURES] rejected
         *  or timed-out approvals the intent path stays closed for
         *  [ApprovalBreaker.OPEN_MS]; one success re-arms it. */
        private val approvalBreaker = ApprovalBreaker()

        fun isSignerInstalled(): Boolean = resolveSignerActivities().isNotEmpty()

        private fun resolveSignerActivities(): List<String> = runCatching {
            val probe = Intent(Intent.ACTION_VIEW, Uri.parse("${Nip55.SCHEME}:"))
            ctx.packageManager.queryIntentActivities(probe, 0)
                .mapNotNull { it.activityInfo?.packageName }
        }.getOrDefault(emptyList())

        // ── login (get_public_key, foreground only) ───────────────────────────

        suspend fun login(): ExternalSignerLogin {
            if (!isSignerInstalled()) {
                throw ExternalSignerException("No NIP-55 signer app installed")
            }
            // Account-neutral login intent: no `current_user` (the user picks
            // the account in the signer) and no package (the OS chooser
            // handles multiple signers). The response's `package` extra tells
            // us which signer to target afterwards.
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("${Nip55.SCHEME}:"))
            intent.putExtra("type", Nip55.TYPE_GET_PUBLIC_KEY)
            intent.putExtra("permissions", Nip55.loginPermissionsJson())
            intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            val response = launchForResult(intent)
                ?: throw ExternalSignerException("Signer sign-in timed out")
            if (response.rejected) throw ExternalSignerException("Signer sign-in was rejected")
            val raw = response.result?.trim().orEmpty()
            // Also the RESULT_CANCELED (back-press) shape: failAllPending
            // completes transiently with no result.
            if (raw.isEmpty()) throw ExternalSignerException("Signer sign-in did not complete")
            // Older Amber builds omit the `package` extra outside get_public_key
            // responses and may omit it in batched results; fall back to the
            // sole installed signer so later requests can be targeted.
            val pkg = response.packageName?.takeIf(String::isNotBlank)
                ?: resolveSignerActivities().distinct().singleOrNull()
            return ExternalSignerLogin(pubkeyHex = raw, packageName = pkg)
        }

        // ── Intent path (shared transport) ────────────────────────────────────

        /** Fail fast instead of self-deadlocking: intent results are delivered
         *  on the main thread, so blocking main here waits the full timeout. */
        private fun mainThreadGuard(type: String): ForeignSignerResult? {
            if (Looper.myLooper() != Looper.getMainLooper()) return null
            Log.e(TAG, "signer $type invoked on the main thread; refusing to block it")
            return ForeignSignerResult.Unavailable("signer call on the main thread")
        }

        /**
         * Launch a signer intent through the foreground Activity and block
         * until its result (or timeout). Returns null when no Activity is
         * available (background), the breaker is open, on timeout, or when
         * the launch fails.
         */
        private fun launchForResult(intent: Intent): Nip55.Response? {
            val launcher = ExternalSignerBridge.launchSignerIntent ?: run {
                Log.w(TAG, "no foreground activity for signer intent (${intent.getStringExtra("type")})")
                return null
            }
            // Background sync must never pop the signer UI (the OS would block
            // the start anyway) — fail fast instead of parking on the 60s
            // timeout. Exception: while requests are in flight, the signer's
            // own approval screen covers us (appVisible=false) and new intents
            // merge into it.
            if (!SonarLifecycle.appVisible && pending.isEmpty()) {
                Log.w(TAG, "signer intent skipped: app not visible (${intent.getStringExtra("type")})")
                return null
            }
            if (approvalBreaker.isOpen()) {
                Log.w(TAG, "signer intent skipped: approval breaker open (${intent.getStringExtra("type")})")
                return null
            }
            val id = UUID.randomUUID().toString()
            intent.putExtra("id", id)
            val deferred = CompletableDeferred<Nip55.Response>()
            pending[id] = deferred
            return try {
                launcher(intent)
                val response = runBlocking {
                    withTimeoutOrNull(INTENT_TIMEOUT_MS) { deferred.await() }
                }
                if (response == null) {
                    approvalBreaker.recordFailure()
                    // The signer may still answer this abandoned request later.
                    idLessAttributionUnsafe.set(true)
                }
                response
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

        /** The posted `launcher.launch(intent)` threw on the main looper
         *  (signer uninstalled mid-session, launcher unregistered): fail the
         *  one request the intent carried instead of crashing the process. */
        fun onLaunchFailed(intent: Intent, cause: Throwable) {
            Log.w(TAG, "signer launch failed: ${cause.message}")
            val id = intent.getStringExtra("id") ?: return
            // Complete with an empty (non-rejected) response: the caller maps
            // "no usable value" to a transient Unavailable outcome.
            pending.remove(id)?.complete(
                Nip55.Response(id = id, result = null, event = null, rejected = false, packageName = null),
            )
        }

        private fun resolve(response: Nip55.Response) {
            val id = response.id
            if (id != null) {
                // A KNOWN id that is no longer pending (timed out, already
                // resolved, or from an earlier merged approval screen) must be
                // dropped — completing an unrelated request with a foreign
                // response would hand one message's plaintext to another
                // decrypt call, or "confirm" an unsent event.
                val waiter = pending.remove(id)
                if (waiter != null) {
                    waiter.complete(response)
                } else {
                    Log.w(TAG, "dropping signer response for unknown request id")
                }
                return
            }
            // No id echoed at all: resolve the single pending request only
            // while attribution is still unambiguous ACROSS TIME. Once any
            // request has timed out, its approval screen may still be
            // answered later — attributing that late answer to whatever is
            // pending now would hand one message's plaintext to another
            // decrypt call (we always send an `id`, so compliant signers
            // never take this path).
            if (idLessAttributionUnsafe.get()) {
                Log.w(TAG, "dropping id-less signer response: a prior request timed out")
                return
            }
            val keys = pending.keys().toList()
            if (keys.size == 1) {
                pending.remove(keys[0])?.complete(response)
            } else {
                Log.w(TAG, "unmatched id-less signer response (pending=${keys.size})")
            }
        }

        /**
         * Fail every in-flight request TRANSIENTLY. Reached on
         * `RESULT_CANCELED` — a back-press or a killed signer activity, which
         * NIP-55 does not define as a rejection (that is `RESULT_OK` + the
         * `rejected` extra). Marking these permanent made one back-press
         * during a drain durably drop every pending welcome/DM.
         */
        private fun failAllPending() {
            val entries = pending.keys().toList()
            entries.forEach { id ->
                pending.remove(id)?.complete(
                    Nip55.Response(id = id, result = null, event = null, rejected = false, packageName = null),
                )
            }
        }
    }
}

/** Consecutive-failure circuit breaker for the signer approval intent path. */
private class ApprovalBreaker {
    private val consecutiveFailures = AtomicInteger(0)
    private val openUntilElapsedMs = AtomicLong(0)

    fun isOpen(): Boolean = android.os.SystemClock.elapsedRealtime() < openUntilElapsedMs.get()

    fun recordSuccess() {
        consecutiveFailures.set(0)
        openUntilElapsedMs.set(0)
    }

    fun recordFailure() {
        if (consecutiveFailures.incrementAndGet() >= MAX_CONSECUTIVE_FAILURES) {
            openUntilElapsedMs.set(android.os.SystemClock.elapsedRealtime() + OPEN_MS)
            consecutiveFailures.set(0)
        }
    }

    companion object {
        const val MAX_CONSECUTIVE_FAILURES = 3
        const val OPEN_MS = 120_000L
    }
}

/**
 * Foreground seam for signer intents, same pattern as [chat.bitchat.sonar.ActivityBridge]:
 * MainActivity registers a `StartActivityForResult` launcher here and forwards
 * every result to [AmberSignerClient.onSignerResult]. Cleared in `onDestroy` —
 * a destroyed activity can never deliver a result.
 */
object ExternalSignerBridge {
    @Volatile var launchSignerIntent: ((Intent) -> Unit)? = null
}
