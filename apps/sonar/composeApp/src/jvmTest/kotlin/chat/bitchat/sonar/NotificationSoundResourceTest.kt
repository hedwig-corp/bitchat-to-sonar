package chat.bitchat.sonar

import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.sound.sampled.AudioFormat
import javax.sound.sampled.AudioSystem
import kotlin.math.abs
import kotlin.math.sqrt
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
            assertDecodableAndLoudEnough(resourceName, expectedDurationSecs)
        }
    }

    private fun assertDecodableAndLoudEnough(resourceName: String, expectedDurationSecs: Float) {
        val resource = assertNotNull(
            Notifier::class.java.getResourceAsStream(resourceName)
        )

        resource.buffered().use { input ->
            AudioSystem.getAudioInputStream(input).use { audio ->
                assertEquals(AudioFormat.Encoding.PCM_SIGNED, audio.format.encoding)
                assertEquals(1, audio.format.channels)
                assertEquals(44_100f, audio.format.sampleRate)
                assertEquals(16, audio.format.sampleSizeInBits)
                assertTrue(audio.frameLength > 0)
                val durationSecs = audio.frameLength / audio.format.frameRate
                assertEquals(expectedDurationSecs, durationSecs, absoluteTolerance = 0.001f)
                assertTrue(durationSecs < 30f)

                val pcm = audio.readAllBytes()
                assertTrue(pcm.size % 2 == 0, "$resourceName PCM length must be even")
                val samples = ShortArray(pcm.size / 2)
                ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(samples)

                val peak = samples.maxOf { abs(it.toInt()) }
                val active = samples.filter { abs(it.toInt()) > 500 }
                assertTrue(active.isNotEmpty(), "$resourceName has no audible samples")
                val activeRms = sqrt(active.map { it.toDouble() * it }.average())

                // Guard Signal/Telegram-comparable alert loudness. Soft masters that
                // only peak around -6 dBFS / active RMS ~-18 dBFS play too quietly
                // against system defaults even at max ringer volume.
                assertTrue(
                    peak >= 26_000,
                    "$resourceName peak $peak is too quiet (want >= 26000 ≈ -2 dBFS)",
                )
                assertTrue(
                    activeRms >= 6_000.0,
                    "$resourceName active RMS $activeRms is too quiet (want >= 6000 ≈ -15 dBFS)",
                )
            }
        }
    }
}
