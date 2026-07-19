package chat.bitchat.sonar

/**
 * In-app trill (nudge) feedback — the app's first in-app haptic, kept behind a
 * small platform seam. Android is the real implementation (sound + vibration);
 * desktop JVM is a no-op (the tray-notification path already covers desktop
 * audio, and there is no haptic hardware to drive).
 *
 * The visual half (the bcShake viewport shake) lives in Compose (`TrillShakeHost`
 * in App.kt); this seam carries only the platform-API pieces.
 */
expect object TrillEffects {
    /** Play the bundled trill bell + the [40ms buzz, 60ms pause, 40ms buzz]
     *  haptic pattern. Must never block the caller: work is dispatched to a
     *  background thread internally, so it is safe from any thread. */
    fun buzz()

    /** True when the platform requests reduced motion (Android: animator scale
     *  set to 0 / "Remove animations"). The shake is skipped; sound and haptic
     *  still fire — mirroring the design's `prefers-reduced-motion` rule. */
    fun reduceMotionEnabled(): Boolean
}
