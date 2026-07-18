package chat.bitchat.sonar

/**
 * Shared Signal-shaped transcript scroll / open / continuity policy (Phase 1).
 *
 * Pure decision types + helpers mirrored conceptually with iOS
 * `SNTranscriptScrollPolicy`. Production list hosts still call
 * [TranscriptTailPinner] / [TranscriptTailPinning]; that adapter maps
 * [TranscriptScrollDecision] back to today's Snap/Animate/None behavior.
 *
 * Phase 2 flagged host ([TranscriptPhase2HostScaffold]) applies Pin + Lockstep
 * on owned chrome/IME Δ; production [TranscriptTailPinner] still maps
 * Lockstep → None. Do not enable reverseLayout by default.
 *
 * See: docs/SIGNAL-TRANSCRIPT-PATTERNS.md, docs/brainstorms/2026-07-18-signal-transcript-long-term-plan.md
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
 * [TranscriptTailPinSession]; [TranscriptTailPinner] remains the production adapter.
 */
object TranscriptScrollPolicy {
    /** Signal `DebouncedEventLastOnly(0.01)` — coalesce inset thrash. */
    const val INSET_COALESCE_MS: Long = 10L

    /**
     * Resolve the declarative open action.
     *
     * Mirrors iOS `SNTranscriptScrollPolicy.openAction`: fully-read (or abandoned
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
        // Provisional live edge while capture unsettled — do not leave the
        // list at a default mid-history index (agent DMs).
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
     *
     * - user scrolling or history prepend → [TranscriptScrollDecision.Ignore]
     * - was at live edge → [TranscriptScrollDecision.Pin]
     * - otherwise → [TranscriptScrollDecision.Lockstep] (offset += Δ; Phase 2 host applies it)
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

    /**
     * Map a policy decision onto today's production pin enum.
     * Lockstep → [TranscriptTailPin.None] here; the Phase 2 host applies
     * Lockstep via [transcriptPhase2LockstepScrollDelta] instead.
     */
    internal fun toLegacyPin(decision: TranscriptScrollDecision): TranscriptTailPin = when (decision) {
        is TranscriptScrollDecision.Pin ->
            if (decision.animate) TranscriptTailPin.Animate else TranscriptTailPin.Snap
        TranscriptScrollDecision.Lockstep,
        TranscriptScrollDecision.Ignore,
        -> TranscriptTailPin.None
    }
}

/**
 * Previous-frame tail latch (Signal `wasScrolledToBottom` shape).
 *
 * Same semantics as the historical [TranscriptTailPinner] body: pin when layout
 * steals a fully visible tail; ignore while the user scrolls or history prepends;
 * animate when a new row appends at the pinned edge. Does **not** emit
 * [TranscriptScrollDecision.Lockstep] — viewport frames use pin-or-ignore only;
 * use [TranscriptScrollPolicy.decideInsetChange] for the inset-Δ path.
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
