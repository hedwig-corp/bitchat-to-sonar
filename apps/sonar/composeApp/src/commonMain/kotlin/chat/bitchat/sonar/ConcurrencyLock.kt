package chat.bitchat.sonar

/**
 * Minimal cross-platform monitor for guarding a small critical section that is
 * touched from more than one thread (e.g. a store mutated from both the app's
 * main scope and a background SDK callback thread). Both supported targets
 * (androidTarget, jvm) are JVM, so the actuals delegate to the JVM
 * `synchronized` intrinsic; kept behind expect/actual so commonMain stays
 * platform-agnostic.
 */
internal expect class ConcurrencyLock() {
    fun <R> withLock(block: () -> R): R
}
