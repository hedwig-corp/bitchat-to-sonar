package chat.bitchat.sonar

import android.content.Context
import android.media.AudioManager

actual object CallAudioRoute {
    private val audio: AudioManager
        get() = AppContextHolder.ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    @Suppress("DEPRECATION")
    actual fun configure(active: Boolean, speakerOn: Boolean) {
        val manager = audio
        if (active) {
            manager.mode = AudioManager.MODE_IN_COMMUNICATION
            manager.isSpeakerphoneOn = speakerOn
        } else {
            manager.isSpeakerphoneOn = false
            manager.mode = AudioManager.MODE_NORMAL
        }
    }

    @Suppress("DEPRECATION")
    actual fun setSpeaker(speakerOn: Boolean) {
        val manager = audio
        manager.mode = AudioManager.MODE_IN_COMMUNICATION
        manager.isSpeakerphoneOn = speakerOn
    }
}
