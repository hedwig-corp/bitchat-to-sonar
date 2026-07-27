package chat.bitchat.sonar.push

/**
 * Which transport delivers background push wakeups on this device.
 *
 * Pure and platform-neutral so the decision is unit-testable from commonTest
 * (`apps/sonar` has no androidUnitTest source set — see docs/REGRESSIONS.md
 * "Unguarded" notes). The Android host feeds it real Play-Services /
 * distributor probes; desktop has no push and never calls it.
 */
enum class PushTransport {
    /** Firebase Cloud Messaging — Play Services present (incl. sandboxed Play on GrapheneOS). */
    FCM,

    /** UnifiedPush distributor (e.g. ntfy) — degoogled devices. */
    UNIFIED_PUSH,

    /** No transport available: no Play Services and no UnifiedPush distributor installed. */
    NONE,
}

object PushTransportPolicy {
    /**
     * Pick the wakeup transport.
     *
     * FCM wins whenever Play Services is usable: it is the transport the
     * transponder + Breez NDS already speak, and on devices with (sandboxed)
     * Play it is strictly more reliable than a distributor app the user may
     * not have configured. UnifiedPush is the degoogled fallback; NONE means
     * the UI must say so instead of pretending pushes will arrive.
     *
     * @param playServicesAvailable GoogleApiAvailability == SUCCESS
     * @param distributorAvailable  a UnifiedPush distributor is installed
     *                              (saved/acked one, or any candidate)
     */
    fun choose(playServicesAvailable: Boolean, distributorAvailable: Boolean): PushTransport =
        when {
            playServicesAvailable -> PushTransport.FCM
            distributorAvailable -> PushTransport.UNIFIED_PUSH
            else -> PushTransport.NONE
        }
}
