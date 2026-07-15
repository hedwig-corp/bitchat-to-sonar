package chat.bitchat.sonar.darkmatter

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val controller = (application as DarkmatterApplication).controller
        setContent {
            val state by controller.state.collectAsState()
            BackHandler(enabled = state.selectedConversationId != null) {
                controller.closeConversation()
            }
            SonarDarkmatterApp(controller.state, controller)
        }
    }
}
