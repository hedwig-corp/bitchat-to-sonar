package chat.bitchat.sonar

import android.animation.ValueAnimator
import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import java.util.concurrent.Executors

/** Android `actual`: MediaPlayer for the bundled trill bell + VibrationEffect
 *  waveform for the 40/60/40 buzz. Everything runs off the calling thread. */
actual object TrillEffects {
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "sonar-trill-effects").apply { isDaemon = true }
    }

    private val ctx: Context get() = AppContextHolder.ctx

    actual fun buzz() {
        executor.execute {
            vibratePattern()
            playBell()
        }
    }

    actual fun reduceMotionEnabled(): Boolean =
        runCatching { !ValueAnimator.areAnimatorsEnabled() }.getOrDefault(false)

    private fun vibratePattern() {
        runCatching {
            val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                ctx.getSystemService(VibratorManager::class.java)?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                ctx.getSystemService(Vibrator::class.java)
            }
            if (vibrator?.hasVibrator() != true) return
            // [40ms buzz, 60ms pause, 40ms buzz] — design buzz() haptic pattern.
            vibrator.vibrate(
                VibrationEffect.createWaveform(longArrayOf(0, 40, 60, 40), -1)
            )
        }.onFailure { sonarLog("TrillEffects", "vibrate failed: ${it.message}") }
    }

    private fun playBell() {
        runCatching {
            val player = MediaPlayer.create(
                ctx,
                R.raw.sonar_trill,
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
                0,
            ) ?: return
            player.setOnCompletionListener { it.release() }
            player.setOnErrorListener { mp, _, _ -> mp.release(); true }
            player.start()
        }.onFailure { sonarLog("TrillEffects", "trill sound failed: ${it.message}") }
    }
}
