package chat.bitchat.sonar

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/**
 * First Compose Multiplatform screen — the smoke test that proves the shared
 * UI (commonMain) can drive the shared Rust core (sonar-core via UniFFI Kotlin,
 * behind the expect/actual [SonarCore] bridge). Tapping the button generates a
 * real Nostr identity inside the Rust .so and shows its npub.
 */
@Composable
fun App() {
    MaterialTheme {
        Surface(Modifier.fillMaxSize()) {
            var npub by remember { mutableStateOf<String?>(null) }
            var error by remember { mutableStateOf<String?>(null) }

            Column(
                modifier = Modifier.fillMaxSize().padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Text(
                    text = "Sonar",
                    style = MaterialTheme.typography.headlineMedium
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    text = "Compose Multiplatform + Rust core",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(Modifier.height(28.dp))
                Button(onClick = {
                    error = null
                    try {
                        npub = SonarCore.generateNpub()
                    } catch (t: Throwable) {
                        error = t.message ?: t.toString()
                    }
                }) {
                    Text("Generate identity (Rust core)")
                }
                Spacer(Modifier.height(20.dp))
                npub?.let {
                    Text(
                        text = it,
                        style = MaterialTheme.typography.bodySmall,
                        textAlign = TextAlign.Center
                    )
                }
                error?.let {
                    Text(
                        text = "error: $it",
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall,
                        textAlign = TextAlign.Center
                    )
                }
            }
        }
    }
}
