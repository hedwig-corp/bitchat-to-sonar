package chat.bitchat.sonar

import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Bounded rotating file tee for [sonarLog] — the Android half of the
 * diagnostics log export feature (Settings → Diagnostics → "Share debug
 * bundle"). Lines are appended on a single background thread so logging call
 * sites never block on disk I/O; the `sonar-app.log` family is capped at
 * [MAX_FILE_BYTES] × ([MAX_ROTATIONS] + 1) total. As a hard privacy backstop
 * any `nsec1…` material is scrubbed before hitting disk.
 */
internal object SonarFileLog {
    private const val FILE_NAME = "sonar-app.log"
    private const val MAX_FILE_BYTES = 2L * 1024 * 1024
    private const val MAX_ROTATIONS = 2

    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "sonar-file-log").apply { isDaemon = true }
    }
    private val nsecPattern = Regex("nsec1[a-z0-9]+")

    fun directory(): File =
        File(AppContextHolder.ctx.filesDir, "sonar-marmot/logs/app").apply { mkdirs() }

    fun append(tag: String, message: String) {
        executor.execute {
            runCatching {
                val scrubbed =
                    if (message.contains("nsec1")) message.replace(nsecPattern, "nsec1[REDACTED]")
                    else message
                val stamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US)
                    .format(Date())
                val file = File(directory(), FILE_NAME)
                file.appendText("$stamp [$tag] $scrubbed\n")
                if (file.length() >= MAX_FILE_BYTES) rotate(file)
            }
        }
    }

    /** Current log file family (newest first) for the debug bundle. */
    fun files(): List<File> {
        val dir = directory()
        return (listOf(File(dir, FILE_NAME)) +
            (1..MAX_ROTATIONS).map { File(dir, "$FILE_NAME.$it") })
            .filter { it.exists() }
    }

    private fun rotate(base: File) {
        val dir = base.parentFile ?: return
        for (i in MAX_ROTATIONS downTo 1) {
            val src = if (i == 1) base else File(dir, "${base.name}.${i - 1}")
            val dst = File(dir, "${base.name}.$i")
            dst.delete()
            if (src.exists()) src.renameTo(dst)
        }
    }
}
