package chat.bitchat.sonar

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        // Startup smoke test: prove the Rust core .so loads and runs from a
        // Compose Multiplatform app (logged so it can be verified headlessly).
        try {
            Log.i("SonarCoreSmoke", "npub=" + SonarCore.generateNpub())
        } catch (t: Throwable) {
            Log.e("SonarCoreSmoke", "core call failed", t)
        }
        setContent {
            App()
        }
    }
}
