package chat.bitchat.sonar.signer

import chat.bitchat.sonar.SonarNativeLoader
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Pins the Kotlin permission-batch mirror against the CORE-owned list of
 * identity-signed kinds, across the real FFI boundary. This is the guard the
 * hand-maintained mirror needs: when the Rust core starts signing a new kind
 * with the identity key (and adds it to
 * `sonar_core::signer_kinds::IDENTITY_SIGNED_KINDS`), this test fails until
 * `Nip55.SIGN_EVENT_KINDS` follows — without it, signer users would hit a
 * surprise approval screen (or a silent background failure) for the new kind.
 */
class Nip55KindsFfiParityTest {

    @Test
    fun kotlinMirrorMatchesCoreList() {
        SonarNativeLoader.ensureLoaded()
        val core = uniffi.sonar_ffi.identitySignedKinds().map { it.toInt() }
        assertEquals(
            core.sorted(),
            Nip55.SIGN_EVENT_KINDS.sorted(),
            "Nip55.SIGN_EVENT_KINDS must mirror sonar_core::signer_kinds::IDENTITY_SIGNED_KINDS",
        )
    }
}
