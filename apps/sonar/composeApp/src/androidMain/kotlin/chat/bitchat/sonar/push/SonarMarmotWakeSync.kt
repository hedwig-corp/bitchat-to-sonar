package chat.bitchat.sonar.push

import android.util.Log
import chat.bitchat.sonar.RelayConnectionPolicy
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.SonarLifecycle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Process-wide single-flight for the Marmot push-wake reconnect + drain.
 *
 * Two FCM deliveries arrive as two independent coroutines. Left concurrent,
 * the second wake's [SonarCore.invalidateRelayConnection] supersedes the
 * first wake's in-flight attach and then replaces and closes its node while
 * it is inside [SonarCore.syncForce] — and syncForce swallows node failures,
 * so the first wake is recorded as synced without ever fetching its message.
 * Followers join the owner instead of starting their own reconnect, and a
 * push observed while the owner is already draining sets the rerun flag so
 * its own row is still fetched before the owner completes.
 *
 * This lives OUTSIDE `SonarPushProcessingService` because the denied-FGS
 * inline fallback (#203) runs the same reconnect from the FCM handler
 * thread: state private to the service would leave a service wake and an
 * inline wake racing exactly as two service wakes used to.
 */
internal object SonarMarmotWakeSync {

    private const val TAG = "SonarMarmotWake"

    private val lock = Mutex()

    /** The wake currently reconnecting + draining. Later deliveries join it
     *  instead of invalidating and replacing the node underneath it. */
    private var inFlight: Deferred<Boolean>? = null

    /** Set when a delivery joins an owner that may already be past the drain,
     *  so the owner runs one more fetch before completing — otherwise the
     *  joining push's own message can be missed. */
    private var needsRerun = false

    /** Identifies the installed owner so a retiring wake only clears its own
     *  slot. Without it, the `finally` cleanup of a wake that already retired
     *  normally could null out the owner a later delivery installed, and two
     *  owners would reconnect concurrently again. */
    private var ownerGeneration = 0L

    /** Ceiling on rerun passes for ONE owner.
     *
     *  A service-hosted owner used to die with the service; an inline-hosted
     *  one runs on a process-scoped scope nothing cancels, and every joining
     *  delivery sets [needsRerun] — so without a cap, one push per attempt
     *  keeps invalidating and rebuilding the relay node forever. Push
     *  frequency is attacker-influenced, and background relay-node rebuild
     *  churn is a regression this repo has already shipped once. */
    private const val MAX_OWNER_RERUNS = 3

    /**
     * Join the in-flight wake or become its owner. [scope] hosts the owner
     * job; a follower only awaits. [timeoutMs] bounds ONE owner attempt.
     */
    suspend fun syncForWake(scope: CoroutineScope, timeoutMs: Long): Boolean {
        val owner = lock.withLock {
            // Only an in-flight owner can be joined: a leftover completed (or
            // cancelled-with-the-service) Deferred must not swallow this wake.
            // An owner that already closed its rerun gate has cleared the slot,
            // so a late delivery becomes a new owner instead of setting a flag
            // nobody will read.
            inFlight?.takeIf { it.isActive }?.also { needsRerun = true }
                ?: run {
                    val generation = ++ownerGeneration
                    scope.async { runOwner(generation, timeoutMs) }.also { inFlight = it }
                }
        }
        return owner.await()
    }

    /** Owner body: reconnect + force the batched fetch, repeating while another
     *  push landed mid-drain. Failures surface through [Deferred.await] to every
     *  joined wake, which each fall back to the generic notification. */
    private suspend fun runOwner(generation: Long, timeoutMs: Long): Boolean =
        // Claim the node for the whole wake (#567): this process has no UI
        // session, so without the claim a scheduled auto-backup seal would
        // close the node underneath the drain.
        chat.bitchat.sonar.backup.withMarmotSessionClaim {
            runOwnerLocked(generation, timeoutMs)
        }

    private suspend fun runOwnerLocked(generation: Long, timeoutMs: Long): Boolean {
        var reruns = 0
        try {
            while (true) {
                lock.withLock { needsRerun = false }
                val synced = withTimeoutOrNull(timeoutMs) {
                    SonarCore.start()
                    // Doze/freeze can leave the host latch true after sockets die.
                    // Without this, connectRelays() no-ops and syncForce talks to a
                    // dead node — the killed-app path works only because a fresh
                    // process starts with relayConnected=false. A push that lands
                    // while the UI is visible reaches a healthy node, so leave it
                    // alone: rebuilding would close a node in-flight sends hold.
                    if (RelayConnectionPolicy.shouldInvalidateOnPushWake(SonarLifecycle.appVisible)) {
                        SonarCore.invalidateRelayConnection()
                    }
                    SonarCore.connectRelays()
                    // Push wake: force the batched gap-recovery fetch. A routine
                    // sync() would short-circuit while live subscriptions are marked
                    // active even though the socket was torn down while backgrounded,
                    // leaving the pushed message unfetched.
                    SonarCore.syncForce()
                } != null
                // Close the rerun gate and retire this owner in ONE locked
                // section. Checking the flag, releasing, then clearing the slot
                // leaves a window where a delivery still sees an active owner and
                // sets a flag that owner will never read — its message goes
                // unfetched while it inherits synced=true and skips the fallback
                // notification.
                val retired = lock.withLock {
                    if (needsRerun && reruns < MAX_OWNER_RERUNS) {
                        reruns++
                        false
                    } else {
                        retire(generation)
                        true
                    }
                }
                if (retired) return synced
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Marmot wake sync failed", t)
            throw t
        } finally {
            // Must run even when the hosting scope is cancelled mid-wake, or the
            // stale owner would be joined by the next process-alive wake. No-op
            // once the loop retired us, so it cannot clear a newer owner.
            withContext(NonCancellable) {
                lock.withLock { retire(generation) }
            }
        }
    }

    /** Clear the owner slot iff [generation] is still the installed owner, so a
     *  retired wake's cleanup cannot evict the owner that replaced it. Caller
     *  must hold [lock]. */
    private fun retire(generation: Long) {
        if (ownerGeneration != generation) return
        inFlight = null
        needsRerun = false
    }
}
