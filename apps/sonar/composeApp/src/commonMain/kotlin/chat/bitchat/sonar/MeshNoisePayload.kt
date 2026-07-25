package chat.bitchat.sonar

/** Mirror of `sonar_core::mesh::noise_payload` (core/sonar-core/src/mesh.rs).
 *  The Rust core owns these tag numbers; the Android driver goes through the
 *  FFI engine and never sees them, but the desktop JVM bridge speaks the
 *  wire format directly. Keep both sides in sync — a mismatch silently
 *  breaks desktop text or delivery receipts with no error anywhere. */
internal object MeshNoisePayload {
    const val PRIVATE_MESSAGE: Int = 0x01
    const val DELIVERED: Int = 0x03
}
