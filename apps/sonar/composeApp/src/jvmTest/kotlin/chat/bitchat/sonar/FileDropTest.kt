package chat.bitchat.sonar

import java.nio.file.Files
import kotlin.io.path.createDirectory
import kotlin.io.path.createFile
import kotlin.io.path.writeBytes
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class FileDropTest {
    @Test
    fun readsFileUrisAndPreservesFilename() {
        val dir = Files.createTempDirectory("sonar-drop-test")
        val file = dir.resolve("hello world.txt").createFile()
        val bytes = "desktop drop".encodeToByteArray()
        file.writeBytes(bytes)

        val result = readDroppedFiles(listOf(file.toUri().toString()), maxBytes = 1024)

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
            maxBytes = 4,
        )

        assertTrue(result.files.isEmpty())
        assertEquals(2, result.rejectedCount)
    }
}
