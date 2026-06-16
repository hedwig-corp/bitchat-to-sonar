package chat.bitchat.sonar

import android.app.Application
import android.content.Context

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
    }
}
