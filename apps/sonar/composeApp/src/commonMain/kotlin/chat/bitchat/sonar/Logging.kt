package chat.bitchat.sonar

/**
 * Tiny multiplatform log sink. commonMain code (e.g. the [SonarAppState] poll
 * loop) used to call `android.util.Log` directly, which broke once a non-Android
 * (desktop JVM) target was added. Each platform routes this to its native logger:
 *  - androidMain → android.util.Log.i (logcat),
 *  - jvmMain (desktop) → stdout.
 */
internal expect fun sonarLog(tag: String, message: String)

/**
 * Whether `SONAR_BENCH` timing markers may be emitted (scripts/bench/ parses
 * them; see docs/PERFORMANCE.md). Debug builds only — mirrors the iOS rule
 * that a benchmark hook must never change Release behavior:
 *  - androidMain → BuildConfig.DEBUG,
 *  - jvmMain (desktop) → the `sonar.bench.markers` system property.
 */
internal expect val sonarBenchMarkersEnabled: Boolean
