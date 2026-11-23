package chat.bitchat.sonar

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.media.ExifInterface
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.File

/**
 * The Android leg of QA-190 on a real device: the JNI core strips the photo,
 * and the `BitmapFactory` re-encode rotates the pixels it would otherwise send
 * sideways. `ImagePrivacyFixtureTest` covers the same decision on the JVM.
 */
@RunWith(AndroidJUnit4::class)
class ImagePrivacyAndroidTest {
    /** A 24×16 camera-style JPEG: GPS, make, serial, Orientation 6. */
    private fun locatedJpeg(): ByteArray {
        val bitmap = Bitmap.createBitmap(24, 16, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.RED) }
        val file = File.createTempFile("located", ".jpg", InstrumentationRegistry.getInstrumentation().targetContext.cacheDir)
        try {
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) }
            ExifInterface(file.absolutePath).apply {
                setAttribute(ExifInterface.TAG_MAKE, "LEAKMAKE")
                setAttribute(ExifInterface.TAG_MODEL, "LEAKMODEL")
                setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
                setAttribute(ExifInterface.TAG_GPS_LATITUDE, "45/1,30/1,1525/100")
                setAttribute(ExifInterface.TAG_GPS_LATITUDE_REF, "N")
                setAttribute(ExifInterface.TAG_GPS_LONGITUDE, "9/1,11/1,3000/100")
                setAttribute(ExifInterface.TAG_GPS_LONGITUDE_REF, "E")
                saveAttributes()
            }
            return file.readBytes()
        } finally {
            file.delete()
        }
    }

    private fun exif(bytes: ByteArray) = ExifInterface(ByteArrayInputStream(bytes))

    private fun hasGps(bytes: ByteArray) = exif(bytes).getAttribute(ExifInterface.TAG_GPS_LATITUDE) != null

    private fun ByteArray.contains(text: String): Boolean {
        val needle = text.encodeToByteArray()
        return (0..size - needle.size).any { at -> needle.indices.all { this[at + it] == needle[it] } }
    }

    @Test
    fun aPhotoSentAsAFileLosesItsLocationButNotItsOrientation() {
        val original = locatedJpeg()
        assertTrue("fixture has no GPS", hasGps(original))
        assertTrue(original.contains("LEAKMAKE"))

        val send = imageBytesForSend(original, "IMG_0001.jpg", "image/jpeg") as ImageSendDecision.Send
        assertFalse("GPS survived", hasGps(send.bytes))
        assertNull(exif(send.bytes).getAttribute(ExifInterface.TAG_MAKE))
        assertFalse(send.bytes.contains("LEAK"))
        assertEquals(
            ExifInterface.ORIENTATION_ROTATE_90,
            exif(send.bytes).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_UNDEFINED),
        )
        assertEquals("IMG_0001.jpg", send.filename)
    }

    @Test
    fun thePickerReencodeTurnsThePixelsUpright() {
        val jpeg = requireNotNull(reencodeToJpeg(locatedJpeg())) { "re-encode failed" }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, bounds)
        assertEquals(16, bounds.outWidth)
        assertEquals(24, bounds.outHeight)
        assertFalse("GPS survived", hasGps(jpeg))
        // Rotated in the pixels, so no tag asks the viewer to rotate it again
        // (ExifInterface reports a missing tag as UNDEFINED).
        val orientation = exif(jpeg).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_UNDEFINED)
        assertTrue("orientation $orientation", orientation == ExifInterface.ORIENTATION_UNDEFINED || orientation == ExifInterface.ORIENTATION_NORMAL)
    }
}
