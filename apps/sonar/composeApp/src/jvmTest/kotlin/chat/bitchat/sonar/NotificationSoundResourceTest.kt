package chat.bitchat.sonar

import javax.sound.sampled.AudioFormat
import javax.sound.sampled.AudioSystem
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class NotificationSoundResourceTest {
    @Test
    fun notificationSoundsArePackagedAndDecodable() {
        listOf(
            "/sonar_notification.wav" to 1.593469f,
            "/sonar_ble_notification.wav" to 1.032018f,
        ).forEach { (resourceName, expectedDurationSecs) ->
            assertDecodable(resourceName, expectedDurationSecs)
        }
    }

    private fun assertDecodable(resourceName: String, expectedDurationSecs: Float) {
        val resource = assertNotNull(
            Notifier::class.java.getResourceAsStream(resourceName)
        )

        resource.buffered().use { input ->
            AudioSystem.getAudioInputStream(input).use { audio ->
                assertEquals(AudioFormat.Encoding.PCM_SIGNED, audio.format.encoding)
                assertEquals(1, audio.format.channels)
                assertEquals(44_100f, audio.format.sampleRate)
                assertTrue(audio.frameLength > 0)
                val durationSecs = audio.frameLength / audio.format.frameRate
                assertEquals(expectedDurationSecs, durationSecs, absoluteTolerance = 0.001f)
                assertTrue(durationSecs < 30f)
            }
        }
    }
}
