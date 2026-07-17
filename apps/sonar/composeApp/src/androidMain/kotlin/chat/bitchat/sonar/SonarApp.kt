package chat.bitchat.sonar

import android.app.Application
import android.content.Context
import chat.bitchat.sonar.push.SonarPushRegistration

/** Holds the application context for the androidMain SonarCore actual. */
object AppContextHolder {
    lateinit var ctx: Context
}

/**
 * Publishes the JavaVM + Application Context to the Rust `ndk_context` static so
 * the P2P call path works. libsonar_ffi.so is dlopen'd by UniFFI's JNA bindings,
 * so no ndk-glue/android-activity ever initializes ndk_context; without this the
 * first iroh `Endpoint::bind()` (and any cpal/oboe audio open) panics with
 * "android context was not initialized", surfacing as a UniFFI InternalException
 * on SonarNode.callStart().
 *
 * `System.loadLibrary` is what makes the JVM resolve the `external` JNI symbol
 * (JNA's own load does not register JNI methods). It loads the SAME
 * libsonar_ffi.so JNA uses — loading it twice is harmless.
 */
object NdkContext {
    @Volatile private var done = false

    init { System.loadLibrary("sonar_ffi") }

    /** Idempotent: safe to call on every process start (also guarded in Rust). */
    @Synchronized fun install(context: Context) {
        if (done) return
        nativeInit(context.applicationContext)
        done = true
    }

    private external fun nativeInit(context: Context)
}

class SonarApp : Application() {
    override fun onCreate() {
        super.onCreate()
        AppContextHolder.ctx = this
        // Publish JavaVM + app Context to Rust's ndk_context BEFORE any FFI call
        // (iroh DNS on bind, cpal/oboe audio read it). Once per process.
        NdkContext.install(this)
        // FCM can render notification-payload fallbacks before the shared UI is
        // created, so its custom-sound channel must exist at process startup.
        Notifier.ensureChannel()
        SonarPushRegistration.ensureRegistered()
    }

    /**
     * Give decoded transcript pixels back under memory pressure.
     *
     * MediaImageMemoryCache holds up to 48MB of bitmaps that are pure cache:
     * each costs only a re-decode from its disk thumbnail, which is a far
     * better trade than letting the OS kill a backgrounded chat app — Sonar
     * losing its process drops BLE links and relay subscriptions.
     *
     * The thresholds mirror Glide's `LruResourceCache.trimMemory` (the cache
     * Signal-Android relies on for exactly this): once the app is on the LRU
     * kill list keep nothing, and halve when it is merely under pressure.
     *
     * Deprecation: API 35 deprecated every level except TRIM_MEMORY_UI_HIDDEN,
     * but minSdk is 26 and API 26-34 devices — the ones actually tight on RAM —
     * still deliver the rest, so both paths stay until minSdk rises.
     *
     * Runs on the main thread, where the cache is already confined, so this
     * introduces no locking.
     */
    @Suppress("DEPRECATION")
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        when {
            level >= TRIM_MEMORY_BACKGROUND -> MediaImageMemoryCache.clear()
            level >= TRIM_MEMORY_UI_HIDDEN || level == TRIM_MEMORY_RUNNING_CRITICAL ->
                MediaImageMemoryCache.trimTo(MediaImageMemoryCache.costBytes / 2)
            else -> Unit
        }
    }

    /** Pre-API-14 fallback the platform still invokes on real memory pressure. */
    @Suppress("DEPRECATION")
    override fun onLowMemory() {
        super.onLowMemory()
        MediaImageMemoryCache.clear()
    }
}
