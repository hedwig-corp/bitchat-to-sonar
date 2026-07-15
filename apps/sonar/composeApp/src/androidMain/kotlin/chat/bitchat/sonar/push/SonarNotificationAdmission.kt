package chat.bitchat.sonar.push

import android.content.Context
import chat.bitchat.sonar.SonarNotificationAdmissionState
import chat.bitchat.sonar.markRenderedSnapshotSurfaced as applyRenderedSnapshotSurface

/** One synchronously committed record owns push admission and surfaced
 * progress. A process death can observe either the old record or the new one,
 * never a generation without its matching progress fields. */
internal object SonarNotificationAdmission {
    private const val PREFS = "sonar_notification_admission"
    private const val STATE = "state_v2"
    private val lock = Any()

    fun admit(context: Context, ownerId: String): SonarNotificationAdmissionState = synchronized(lock) {
        val next = readLocked(context).admit(ownerId)
        check(writeLocked(context, next)) { "Could not persist notification admission" }
        next
    }

    fun current(context: Context): SonarNotificationAdmissionState = synchronized(lock) {
        readLocked(context)
    }

    /** Returns the admitted state only when both the persisted owner and the
     * currently installed account match the work input. If the persisted record
     * itself belongs to a retired account, clear it without touching a newer
     * account's record. */
    fun currentForWork(
        context: Context,
        expectedOwnerId: String,
        currentOwnerId: String?,
    ): SonarNotificationAdmissionState? = synchronized(lock) {
        val state = readLocked(context)
        if (currentOwnerId == null || !state.belongsTo(currentOwnerId)) {
            if (state.ownerId.isNotEmpty()) {
                check(clearLocked(context)) { "Could not retire stale notification admission" }
            }
            return@synchronized null
        }
        state.takeIf { expectedOwnerId == currentOwnerId }
    }

    fun markSurfaced(context: Context, ownerId: String, throughGeneration: Long) =
        synchronized(lock) {
            updateOwnedLocked(context, ownerId) { it.markSurfaced(throughGeneration) }
        }

    fun markRenderedSnapshotSurfaced(
        context: Context,
        ownerId: String,
        renderedGeneration: Long,
    ) = synchronized(lock) {
        updateOwnedLocked(context, ownerId) {
            applyRenderedSnapshotSurface(it, renderedGeneration)
        }
    }

    fun markFallback(context: Context, ownerId: String, throughGeneration: Long) =
        synchronized(lock) {
            updateOwnedLocked(context, ownerId) { it.markFallback(throughGeneration) }
        }

    fun markCompleted(context: Context, ownerId: String, throughGeneration: Long) =
        synchronized(lock) {
            updateOwnedLocked(context, ownerId) { it.markCompleted(throughGeneration) }
        }

    fun clear(context: Context) = synchronized(lock) {
        check(clearLocked(context)) { "Could not clear notification admission" }
    }

    private fun readLocked(context: Context): SonarNotificationAdmissionState {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val encoded = prefs.getString(STATE, null)
        if (encoded == null) {
            // Ownerless v1 records cannot safely survive an account boundary.
            // Retire them instead of guessing which current account owns them.
            if (prefs.contains("state_v1")) {
                check(prefs.edit().remove("state_v1").commit()) {
                    "Could not retire ownerless notification admission"
                }
            }
            return SonarNotificationAdmissionState()
        }
        val fields = encoded.split(',')
        return SonarNotificationAdmissionState(
            ownerId = fields.getOrNull(0).orEmpty(),
            generation = fields.getOrNull(1)?.toLongOrNull() ?: 0,
            surfacedGeneration = fields.getOrNull(2)?.toLongOrNull() ?: 0,
            fallbackGeneration = fields.getOrNull(3)?.toLongOrNull() ?: 0,
            completedGeneration = fields.getOrNull(4)?.toLongOrNull() ?: 0,
        )
    }

    private inline fun updateOwnedLocked(
        context: Context,
        ownerId: String,
        update: (SonarNotificationAdmissionState) -> SonarNotificationAdmissionState,
    ) {
        val current = readLocked(context)
        if (!current.belongsTo(ownerId)) return
        check(writeLocked(context, update(current))) { "Could not persist notification progress" }
    }

    private fun writeLocked(
        context: Context,
        state: SonarNotificationAdmissionState,
    ): Boolean = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        .edit()
        .remove("state_v1")
        .putString(
            STATE,
            "${state.ownerId},${state.generation},${state.surfacedGeneration},${state.fallbackGeneration}," +
                "${state.completedGeneration}",
        )
        .commit()

    private fun clearLocked(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(STATE)
            .remove("state_v1")
            .commit()
}
