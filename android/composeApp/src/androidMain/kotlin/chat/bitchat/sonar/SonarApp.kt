package chat.bitchat.sonar

import android.app.Application
import android.content.Context

/** Holds the application context for the androidMain SonarCore actual. */
object AppContextHolder {
    lateinit var ctx: Context
}

class SonarApp : Application() {
    override fun onCreate() {
        super.onCreate()
        AppContextHolder.ctx = this
    }
}
