package chat.bitchat.sonar

import java.nio.file.Files
import kotlin.io.path.createDirectory
import kotlin.io.path.createFile
import kotlin.io.path.writeBytes
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class FileDropTest {
    @Test
    fun readsFileUrisAndPreservesFilename() {
        val dir = Files.createTempDirectory("sonar-drop-test")
        val file = dir.resolve("hello world.txt").createFile()
        val bytes = "desktop drop".encodeToByteArray()
        file.writeBytes(bytes)

        val result = readDroppedFiles(listOf(file.toUri().toString()), maxTotalBytes = 1024)

        assertEquals(0, result.rejectedCount)
        assertEquals("hello world.txt", result.files.single().filename)
        assertContentEquals(bytes, result.files.single().bytes)
        assertTrue(result.files.single().mime.isNotBlank())
    }

    @Test
    fun rejectsOversizedAndDirectoryDrops() {
        val dir = Files.createTempDirectory("sonar-drop-test").resolve("folder").createDirectory()
        val oversized = dir.parent.resolve("large.bin").createFile()
        oversized.writeBytes(ByteArray(5))

        val result = readDroppedFiles(
            listOf(oversized.toUri().toString(), dir.toUri().toString()),
            maxTotalBytes = 4,
        )

        assertTrue(result.files.isEmpty())
        assertEquals(2, result.rejectedCount)
    }

    @Test
    fun rejectsNonFileUris() {
        val result = readDroppedFiles(
            listOf("https://example.com/attachment.txt", "not a uri"),
            maxTotalBytes = 1024,
        )

        assertTrue(result.files.isEmpty())
        assertEquals(2, result.rejectedCount)
    }

    @Test
    fun boundsFileCountAndAggregateBytes() {
        val dir = Files.createTempDirectory("sonar-drop-test")
        val uris = (0..MAX_DROPPED_FILES).map { index ->
            dir.resolve("$index.bin").createFile().also {
                it.writeBytes(ByteArray(2) { index.toByte() })
            }.toUri().toString()
        }

        val result = readDroppedFiles(uris, maxTotalBytes = 5)

        assertEquals(2, result.files.size)
        assertEquals(uris.size - result.files.size, result.rejectedCount)
        assertTrue(result.files.sumOf { it.bytes.size } <= 5)
    }

    @Test
    fun acceptsDropWhileDirectSecureRouteIsStillStarting() {
        assertTrue(
            canPrepareAttachmentRoute(
                hasMeshRoute = false,
                hasExistingMarmotRoute = false,
                hasPendingDirectMarmotRoute = true,
            )
        )
        assertTrue(
            canPrepareAttachmentRoute(
                hasMeshRoute = false,
                hasExistingMarmotRoute = true,
                hasPendingDirectMarmotRoute = false,
            )
        )
        assertFalse(
            canPrepareAttachmentRoute(
                hasMeshRoute = false,
                hasExistingMarmotRoute = false,
                hasPendingDirectMarmotRoute = false,
            )
        )
    }

    @Test
    fun promotesVerifiedPdfFromGenericMime() {
        val pdf = "%PDF-1.7\nreceipt".encodeToByteArray()

        assertEquals(
            "application/pdf",
            effectiveAttachmentMime("application/octet-stream", "receipt.PDF", pdf),
        )
        assertTrue(isVerifiedPdfAttachment("application/octet-stream", "receipt.PDF", pdf))
    }

    @Test
    fun leavesFakePdfAndExplicitMimeUnchanged() {
        val fakePdf = "not a pdf".encodeToByteArray()
        val realPdf = "%PDF-1.7\nreceipt".encodeToByteArray()

        assertEquals(
            "application/octet-stream",
            effectiveAttachmentMime("application/octet-stream", "receipt.pdf", fakePdf),
        )
        assertFalse(isVerifiedPdfAttachment("application/octet-stream", "receipt.pdf", fakePdf))
        assertEquals("text/plain", effectiveAttachmentMime("text/plain; charset=utf-8", "receipt.pdf", realPdf))
    }
}
