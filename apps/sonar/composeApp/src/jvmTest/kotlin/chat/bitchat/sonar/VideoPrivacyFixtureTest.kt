package chat.bitchat.sonar

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * Real camera-style files, written by AVFoundation with a location
 * (`video/located.mov`: `udta/©xyz` + `meta` ISO 6709 key; `video/located.mp4`:
 * 3GPP `udta/loci`). The sanitized copies are also written to
 * `build/video-privacy/` so they can be re-opened by a real player; on
 * 2026-09-24 AVFoundation reported both playable, one video track, no location.
 */
class VideoPrivacyFixtureTest {
    private fun fixture(name: String): ByteArray =
        requireNotNull(javaClass.getResourceAsStream("/video/$name")) { "missing fixture $name" }.readBytes()

    private fun ByteArray.contains(needle: ByteArray): Boolean =
        (0..size - needle.size).any { i -> needle.indices.all { this[i + it] == needle[it] } }

    private fun check(name: String, marker: ByteArray) {
        val input = fixture(name)
        assertTrue(input.contains(marker), "$name must carry its location marker")

        val result = stripVideoLocationMetadata(input)

        assertIs<VideoPrivacyResult.Clean>(result)
        assertTrue(result.stripped, "$name: location boxes must be found")
        assertEquals(input.size, result.bytes.size)
        assertTrue(!result.bytes.contains(marker), "$name still carries its location")
        File("build/video-privacy").apply { mkdirs() }.resolve("clean-$name").writeBytes(result.bytes)
    }

    @Test
    fun quickTimeMovLosesItsLocation() = check("located.mov", "+46.0037".encodeToByteArray())

    @Test
    fun mp4LosesIts3gppLocation() = check("located.mp4", "loci".encodeToByteArray())
}
