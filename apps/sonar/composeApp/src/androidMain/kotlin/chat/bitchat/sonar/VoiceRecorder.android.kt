package chat.bitchat.sonar

import android.Manifest
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import java.io.File

actual object AudioNotePlayer {
    private var mp: MediaPlayer? = null
    private var file: File? = null
    private var onDone: (() -> Unit)? = null

    actual fun play(bytes: ByteArray, onComplete: () -> Unit) {
        stop() // tears down + notifies any previous note before starting this one
        val f = File(AppContextHolder.ctx.cacheDir, "play-${System.currentTimeMillis()}.m4a")
        runCatching {
            f.writeBytes(bytes)
            mp = MediaPlayer().apply {
                setDataSource(f.absolutePath)
                setOnCompletionListener { stop() }
                prepare()
                start()
            }
            file = f
            onDone = onComplete
        }.onFailure { f.delete(); onComplete() }
    }

    actual fun stop() {
        mp?.let { runCatching { it.stop() }; runCatching { it.release() } }
        mp = null
        file?.delete()
        file = null
        val cb = onDone
        onDone = null
        cb?.invoke()
    }
}

actual class VoiceRecorder {
    private var rec: MediaRecorder? = null
    private var path: String? = null
    private var startMs: Long = 0L

    actual suspend fun start(): Boolean {
        val ctx = AppContextHolder.ctx
        if (ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) return false
        val file = File(ctx.cacheDir, "vn-${System.currentTimeMillis()}.m4a")
        @Suppress("DEPRECATION")
        val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(ctx) else MediaRecorder()
        return try {
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioEncodingBitRate(64_000)
            r.setAudioSamplingRate(44_100)
            r.setOutputFile(file.absolutePath)
            r.prepare()
            r.start()
            rec = r
            path = file.absolutePath
            startMs = System.currentTimeMillis()
            true
        } catch (e: Exception) {
            runCatching { r.release() }
            file.delete()
            false
        }
    }

    actual fun elapsed(): Int =
        if (startMs == 0L) 0 else ((System.currentTimeMillis() - startMs) / 1000).toInt()

    actual fun level(): Float {
        val a = runCatching { rec?.maxAmplitude ?: 0 }.getOrDefault(0)
        return (a / 12_000f).coerceIn(0f, 1f)
    }

    actual fun finish(): ByteArray? {
        val r = rec ?: return null
        runCatching { r.stop() }
        runCatching { r.release() }
        rec = null
        startMs = 0L
        val p = path ?: return null
        path = null
        val f = File(p)
        // Drop empty/instant taps — they aren't useful notes.
        val bytes = if (f.length() >= 1500L) runCatching { f.readBytes() }.getOrNull() else null
        f.delete()
        return bytes
    }

    actual fun cancel() {
        rec?.let { runCatching { it.stop() }; runCatching { it.release() } }
        rec = null
        startMs = 0L
        path?.let { File(it).delete() }
        path = null
    }
}
