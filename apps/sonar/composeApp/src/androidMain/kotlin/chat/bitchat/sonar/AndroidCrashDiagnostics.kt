package chat.bitchat.sonar

import android.os.Build
import android.os.Process
import android.os.SystemClock
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStreamWriter
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.system.exitProcess

/**
 * Persists the process's last uncaught JVM exception synchronously.
 *
 * AndroidRuntime/logcat is not available to remote testers, while the normal
 * app log intentionally writes asynchronously and can lose its tail when the
 * process aborts. This handler writes a separate bounded file, fsyncs it, then
 * delegates to Android's original handler so platform crash semantics remain
 * unchanged. The file survives relaunch and is included by Share diagnostics.
 *
 * Native aborts, LMK/OOM kills, and ANRs are outside this JVM handler; those
 * still need platform exit-info / tombstones (follow-up on API 30+).
 */
internal object AndroidCrashDiagnostics {
    private const val CRASH_FILE_NAME = "sonar-crash.log"
    private val breadcrumb = AtomicReference<String?>(null)
    private val crashOwner = AtomicBoolean(false)

    @Volatile
    private var installed = false

    private var previousHandler: Thread.UncaughtExceptionHandler? = null

    fun note(message: String) {
        breadcrumb.set(message.take(2_048))
    }

    /** Drop in-memory + on-disk crash context on wipe / account replacement. */
    fun clear() {
        breadcrumb.set(null)
        runCatching {
            val file = crashFile()
            file.delete()
            File(file.parentFile, "$CRASH_FILE_NAME.tmp").delete()
        }
    }

    fun crashFile(): File = File(SonarFileLog.directory(), CRASH_FILE_NAME)

    @Synchronized
    fun install() {
        if (installed) return
        previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            val firstCrash = crashOwner.compareAndSet(false, true)
            try {
                if (firstCrash) {
                    runCatching { persist(thread, throwable) }
                        .onFailure {
                            // Never format the failure throwable: Log.e(msg, t)
                            // can itself OOM and skip default-handler chaining.
                            runCatching {
                                android.util.Log.e(
                                    "SonarCrash",
                                    "could not persist uncaught exception",
                                )
                            }
                        }
                }
            } finally {
                val previous = previousHandler
                if (previous != null) {
                    previous.uncaughtException(thread, throwable)
                } else {
                    Process.killProcess(Process.myPid())
                    exitProcess(10)
                }
            }
        }
        installed = true
    }

    private fun persist(thread: Thread, throwable: Throwable) {
        val processUptime = if (Build.VERSION.SDK_INT >= 24) {
            SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime()
        } else {
            SystemClock.elapsedRealtime()
        }
        val report = formatDiagnosticCrashReport(
            generatedAtMillis = System.currentTimeMillis(),
            appVersion = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
            sdk = Build.VERSION.SDK_INT.toString(),
            device = "${Build.MANUFACTURER} ${Build.MODEL}",
            processUptimeMillis = processUptime,
            threadName = thread.name,
            breadcrumb = breadcrumb.get(),
            // Bound before formatter allocations — stackTraceToString can be huge.
            throwableText = throwable.stackTraceToString().take(MAX_CRASH_STACK_CHARS),
        )
        val file = crashFile()
        val parent = file.parentFile ?: return
        parent.mkdirs()
        val tmp = File(parent, "$CRASH_FILE_NAME.tmp")
        FileOutputStream(tmp, false).use { stream ->
            val writer = OutputStreamWriter(stream, StandardCharsets.UTF_8)
            writer.write(report)
            writer.flush()
            stream.fd.sync()
        }
        // Keep the previous report until the new file replaces it.
        try {
            Files.move(
                tmp.toPath(),
                file.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (_: Exception) {
            Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }

    private const val MAX_CRASH_STACK_CHARS = 200 * 1024
}
