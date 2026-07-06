package chat.bitchat.sonar

internal actual class ConcurrencyLock actual constructor() {
    private val monitor = Any()
    actual fun <R> withLock(block: () -> R): R = synchronized(monitor, block)
}
