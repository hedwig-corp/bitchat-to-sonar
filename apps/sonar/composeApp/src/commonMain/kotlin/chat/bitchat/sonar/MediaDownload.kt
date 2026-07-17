package chat.bitchat.sonar

import chat.bitchat.sonar.crypto.Sha256

enum class MediaTransferPhase {
    NotDownloaded,
    Downloading,
    Available,
    Failed,
}

/** Signal-style attachment pointer/stream state shared by Android and desktop. */
data class MediaTransferState(
    val phase: MediaTransferPhase,
    val progress: Float? = null,
    val localPath: String? = null,
) {
    companion object {
        val NotDownloaded = MediaTransferState(MediaTransferPhase.NotDownloaded)
        fun downloading(progress: Float?) = MediaTransferState(MediaTransferPhase.Downloading, progress)
        fun available(path: String) = MediaTransferState(MediaTransferPhase.Available, 1f, path)
        val Failed = MediaTransferState(MediaTransferPhase.Failed)
    }
}

/** Platform-neutral listener wrapped by each UniFFI actual implementation. */
interface SonarMediaDownloadListener {
    fun onProgress(bytesReceived: ULong, totalBytes: ULong?)
    fun isCancelled(): Boolean
}

internal class MediaDownloadControl(
    private val progress: (ULong, ULong?) -> Unit,
) : SonarMediaDownloadListener {
    @Volatile private var cancelled = false

    override fun onProgress(bytesReceived: ULong, totalBytes: ULong?) {
        progress(bytesReceived, totalBytes)
    }

    override fun isCancelled(): Boolean = cancelled

    fun cancel() {
        cancelled = true
    }
}

internal fun mediaCacheKey(url: String): String =
    Sha256.hash(url.encodeToByteArray())
        .joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }

/** Private, file-backed decrypted attachment cache. */
expect object MediaCache {
    fun finalPath(url: String): String
    fun partialPath(url: String, token: String): String

    /** Downscaled transcript thumbnail for [url] (see [MediaThumbnailDiskCache]).
     *  Lives under the cache root so `wipe()` removes it with the attachment. */
    fun thumbnailPath(url: String): String
    suspend fun prepare()
    suspend fun exists(path: String): Boolean
    suspend fun read(path: String): ByteArray?
    suspend fun readPrefix(path: String, maxBytes: Int): ByteArray?
    suspend fun write(path: String, bytes: ByteArray): Boolean
    suspend fun promote(partialPath: String, finalPath: String): Boolean
    suspend fun remove(path: String)
    suspend fun wipe()
}
