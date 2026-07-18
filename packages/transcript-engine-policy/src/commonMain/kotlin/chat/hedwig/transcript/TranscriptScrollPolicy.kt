package chat.hedwig.transcript

/**
 * Shared Signal-shaped transcript scroll / open / continuity policy.
 *
 * Pure decision types consumed by Compose and UIKit transcript hosts.
 * Apps supply message identity, row measure, composer height, and DB paging;
 * the library owns open / inset / pin policy only.
 *
 * See: packages/transcript-engine/INTEGRATION.md
 */

/** Declarative chat-open scroll target (Signal `CVScrollAction` shape). */
sealed class TranscriptOpenAction {
    /** Fully-read open → pin the live edge (newest row). */
    data object LiveEdge : TranscriptOpenAction()

    /** Unread open → land on the unread divider / oldest unread. */
    data object UnreadDivider : TranscriptOpenAction()

    /** Jump to a specific message id (search / deep link). */
    data class Jump(val id: String) : TranscriptOpenAction()
}

/**
 * Decision after capturing was-at-tail before an inset/viewport Δ
 * (Signal `updateContentInsets`: pin live edge, else lockstep offset, else ignore).
 */
sealed class TranscriptScrollDecision {
    /** Re-anchor to the live edge. [animate] follows an appended row. */
    data class Pin(val animate: Boolean = false) : TranscriptScrollDecision()

    /** Shift content with the inset delta (reader in history). */
    data object Lockstep : TranscriptScrollDecision()

    /** User scrolling, history prepend, or no-op — leave scroll alone. */
    data object Ignore : TranscriptScrollDecision()
}

/**
 * Continuity across loadOlder / loadNewer land: keep the reader's place by
 * message identity plus either distance-from-edge or a pixel offset.
 */
data class TranscriptContinuityToken(
    val anchorId: String,
    val edgeDistancePx: Int? = null,
    val pixelOffset: Int? = null,
) {
    init {
        require(edgeDistancePx != null || pixelOffset != null) {
            "ContinuityToken needs edgeDistancePx or pixelOffset"
        }
    }
}

/**
 * Pure policy surface. Stateful layout-frame latching lives in
 * [TranscriptTailPinSession].
 */
object TranscriptScrollPolicy {
    /** Signal `DebouncedEventLastOnly(0.01)` — coalesce inset thrash. */
    const val INSET_COALESCE_MS: Long = 10L

    /**
     * Resolve the declarative open action.
     *
     * Mirrors iOS `TranscriptScrollPolicy.openAction`: fully-read (or abandoned
     * unread) → [TranscriptOpenAction.LiveEdge]; otherwise unread divider.
     * `null` [unreadCountAtOpen] is **provisional live edge** (avoid mid-history
     * first paint while capture settles; hosts may re-anchor to the divider
     * if a settled count > 0 lands). An explicit [jumpMessageId] wins when set.
     */
    fun resolveOpenAction(
        unreadAnchorId: String?,
        unreadCountAtOpen: Long?,
        unreadAnchorAbandoned: Boolean = false,
        jumpMessageId: String? = null,
    ): TranscriptOpenAction {
        if (jumpMessageId != null) return TranscriptOpenAction.Jump(jumpMessageId)
        if (unreadCountAtOpen == null) {
            return if (unreadAnchorId == null && !unreadAnchorAbandoned) {
                TranscriptOpenAction.LiveEdge
            } else {
                TranscriptOpenAction.UnreadDivider
            }
        }
        val fullyRead =
            unreadAnchorId == null && (unreadCountAtOpen <= 0L || unreadAnchorAbandoned)
        return if (fullyRead) TranscriptOpenAction.LiveEdge else TranscriptOpenAction.UnreadDivider
    }

    /**
     * Signal was-at-tail → pin | lockstep | ignore for an inset / viewport change.
     */
    fun decideInsetChange(
        wasAtTail: Boolean,
        userScrolling: Boolean,
        prepending: Boolean,
    ): TranscriptScrollDecision = when {
        userScrolling || prepending -> TranscriptScrollDecision.Ignore
        wasAtTail -> TranscriptScrollDecision.Pin(animate = false)
        else -> TranscriptScrollDecision.Lockstep
    }

    /** Capture a continuity token before a loadOlder / loadNewer land. */
    fun captureContinuityToken(
        anchorId: String,
        edgeDistancePx: Int? = null,
        pixelOffset: Int? = null,
    ): TranscriptContinuityToken =
        TranscriptContinuityToken(
            anchorId = anchorId,
            edgeDistancePx = edgeDistancePx,
            pixelOffset = pixelOffset,
        )
}

/**
 * Previous-frame tail latch (Signal `wasScrolledToBottom` shape).
 *
 * Viewport frames use pin-or-ignore only; use [TranscriptScrollPolicy.decideInsetChange]
 * for the inset-Δ path.
 */
class TranscriptTailPinSession {
    private var wasPinned = false
    private var lastCount = -1

    fun onLayoutFrame(
        itemCount: Int,
        tailFullyVisible: Boolean,
        scrolling: Boolean,
        prepending: Boolean,
    ): TranscriptScrollDecision {
        val countChanged = itemCount != lastCount
        lastCount = itemCount
        return when {
            prepending || scrolling -> {
                wasPinned = tailFullyVisible
                TranscriptScrollDecision.Ignore
            }
            tailFullyVisible -> {
                wasPinned = true
                TranscriptScrollDecision.Ignore
            }
            wasPinned && itemCount > 0 ->
                TranscriptScrollDecision.Pin(animate = countChanged)
            else -> TranscriptScrollDecision.Ignore
        }
    }
}

/**
 * Last-event-only coalesce window (Signal 10 ms). Schedules at most one pending
 * correction per window; [consume] clears the latch when the host delivers it.
 */
class TranscriptInsetCoalescer {
    private var scheduled = false

    fun request(): Boolean {
        if (scheduled) return false
        scheduled = true
        return true
    }

    fun consume(): Boolean {
        if (!scheduled) return false
        scheduled = false
        return true
    }

    val isScheduled: Boolean get() = scheduled
}
