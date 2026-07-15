package chat.bitchat.sonar.darkmatter

import android.app.Application
import dev.ipf.marmotkit.MarmotAndroid
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

class DarkmatterApplication : Application() {
    lateinit var controller: DarkmatterController
        private set

    override fun onCreate() {
        super.onCreate()
        MarmotAndroid.initialize(this)

        val runtimeRoot = File(noBackupFilesDir, "marmot-v0.9.4")
        val backend = MarmotDarkmatterBackend(runtimeRoot, DEFAULT_RELAYS)
        val pendingStore = EncryptedPreferencesPendingStore(
            getSharedPreferences("sonar_darkmatter_pending", MODE_PRIVATE),
        )
        controller = DarkmatterController(
            backend = backend,
            pendingStore = pendingStore,
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
            nowSeconds = { System.currentTimeMillis() / 1_000L },
            idFactory = { UUID.randomUUID().toString() },
        )
        controller.start()
    }

    override fun onTerminate() {
        controller.close()
        super.onTerminate()
    }

    companion object {
        val DEFAULT_RELAYS = listOf(
            "wss://relay.damus.io",
            "wss://nos.lol",
            "wss://relay.primal.net",
            "wss://nostr.relay.hedwig.sh",
        )
    }
}
