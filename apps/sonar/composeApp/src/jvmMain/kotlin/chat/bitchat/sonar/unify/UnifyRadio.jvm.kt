package chat.bitchat.sonar.unify

/**
 * Desktop (JVM) `actual`: like [chat.bitchat.sonar.MeshRadio], the Unify
 * nearby-payments BLE radio needs phone BLE hardware (scanner + GATT server), so
 * it is unavailable on desktop and every operation is an inert no-op.
 */
actual object UnifyRadio {
    actual fun available(): Boolean = false

    actual fun startScanning() {}
    actual fun stopScanning() {}
    actual fun peers(): List<UnifyPeer> = emptyList()
    actual suspend fun fetchOffer(peerId: String): String? = null

    actual fun startAdvertising(offer: String, name: String) {}
    actual fun stopAdvertising() {}
    actual fun isAdvertising(): Boolean = false
}
