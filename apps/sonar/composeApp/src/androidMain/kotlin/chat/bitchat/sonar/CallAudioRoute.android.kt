package chat.bitchat.sonar

import android.content.Context
import android.media.AudioManager
import android.os.PowerManager

actual object CallAudioRoute {
    private val audio: AudioManager
        get() = AppContextHolder.ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    /** iOS `isProximityMonitoringEnabled` parity: while a voice call is active
     *  the proximity wake lock blanks the screen at the ear (and swallows
     *  accidental touches). Held for the call duration, released in
     *  `configure(active = false)` on every teardown path. */
    private var proximityLock: PowerManager.WakeLock? = null

    @Suppress("DEPRECATION")
    actual fun configure(active: Boolean, speakerOn: Boolean, voiceProximity: Boolean) {
        val manager = audio
        if (active) {
            manager.mode = AudioManager.MODE_IN_COMMUNICATION
            manager.isSpeakerphoneOn = speakerOn
        } else {
            manager.isSpeakerphoneOn = false
            manager.mode = AudioManager.MODE_NORMAL
        }
        if (active && voiceProximity) acquireProximity() else releaseProximity()
    }

    private fun acquireProximity() {
        if (proximityLock?.isHeld == true) return
        val pm = AppContextHolder.ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (!pm.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) return
        proximityLock = runCatching {
            pm.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "sonar:call-proximity")
                // Held for the call duration; every end path calls
                // configure(active = false) which releases it.
                .also { it.acquire() }
        }.getOrNull()
    }

    private fun releaseProximity() {
        runCatching { proximityLock?.takeIf { it.isHeld }?.release() }
        proximityLock = null
    }

    @Suppress("DEPRECATION")
    actual fun setSpeaker(speakerOn: Boolean) {
        val manager = audio
        manager.mode = AudioManager.MODE_IN_COMMUNICATION
        manager.isSpeakerphoneOn = speakerOn
    }
}
