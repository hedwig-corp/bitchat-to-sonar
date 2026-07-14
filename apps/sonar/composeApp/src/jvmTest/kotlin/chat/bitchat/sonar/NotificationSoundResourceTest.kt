package chat.bitchat.sonar

import javax.sound.sampled.AudioFormat
import javax.sound.sampled.AudioSystem
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class NotificationSoundResourceTest {
    @Test
    fun notificationSoundIsPackagedAndDecodable() {
        val resource = assertNotNull(
            Notifier::class.java.getResourceAsStream("/sonar_notification.wav")
        )

        resource.buffered().use { input ->
            AudioSystem.getAudioInputStream(input).use { audio ->
                assertEquals(AudioFormat.Encoding.PCM_SIGNED, audio.format.encoding)
                assertEquals(1, audio.format.channels)
                assertEquals(44_100f, audio.format.sampleRate)
                assertTrue(audio.frameLength > 0)
                assertTrue(audio.frameLength / audio.format.frameRate < 30f)
            }
        }
    }
}
