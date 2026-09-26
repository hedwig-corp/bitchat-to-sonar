package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.SonarNativeLoader
import chat.bitchat.sonar.crypto.Bech32
import java.nio.ByteBuffer
import java.nio.file.Files
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import uniffi.sonar_ffi.FfiConverterTypeWalletFfiError
import uniffi.sonar_ffi.WalletFfiException

/**
 * The real UniFFI bindings + the host dylib: the typed `WalletFfiError`
 * survives the boundary into [CashuWalletException], which is what the
 * engine branches on (never on message text).
 */
class CashuFfiBoundaryTest {

    @BeforeTest
    fun load() = SonarNativeLoader.ensureLoaded()

    private fun tempDir(): String =
        Files.createTempDirectory("sonar-cashu-ffi").resolve("mainnet").toString()

    @Test
    fun insufficientFundsLiftedFromTheWireStaysTyped() {
        // Exactly what `uniffiRustCallWithError` does with an error RustBuffer:
        // the generated converter reads the i32 variant tag (5 =
        // InsufficientFunds, per wallet.rs declaration order).
        val wire = ByteBuffer.allocate(4).putInt(5).also { it.flip() }
        val lifted = FfiConverterTypeWalletFfiError.read(wire)
        assertTrue(lifted is WalletFfiException.InsufficientFunds, "got $lifted")
        assertTrue(lifted.common() is CashuWalletException.InsufficientFunds)
    }

    @Test
    fun everyFfiVariantMapsToItsTypedTwin() {
        val pairs = listOf(
            WalletFfiException.NotConnected() to CashuWalletException.NotConnected::class,
            WalletFfiException.Busy("r") to CashuWalletException.Busy::class,
            WalletFfiException.Unsupported("r") to CashuWalletException.Unsupported::class,
            WalletFfiException.InvalidDestination("r") to CashuWalletException.InvalidDestination::class,
            WalletFfiException.InsufficientFunds() to CashuWalletException.InsufficientFunds::class,
            WalletFfiException.InvalidInput("r") to CashuWalletException.InvalidInput::class,
            WalletFfiException.Network("r") to CashuWalletException.Network::class,
            WalletFfiException.Timeout() to CashuWalletException.Timeout::class,
            WalletFfiException.Backend("r") to CashuWalletException.Backend::class,
        )
        for ((ffi, expected) in pairs) assertEquals(expected, ffi.common()::class)
        assertTrue(WalletFfiException.Network("x").common().isOffline)
        assertTrue(WalletFfiException.Timeout().common().isOffline)
        assertFalse(WalletFfiException.InsufficientFunds().common().isOffline)
    }

    @Test
    fun aRealRustErrorCrossesTheBoundaryTyped() {
        // Thrown by the Rust constructor, lifted by the generated bindings,
        // mapped by the actual — no fake anywhere on this path.
        val e = assertFailsWith<CashuWalletException> {
            openCashuNative("not-a-key", CASHU_MINT_URL, tempDir())
        }
        assertTrue(e is CashuWalletException.InvalidInput, "got $e")
    }

    @Test
    fun aRealWalletIsLocalUntilConnectAndSaysSoTyped() {
        val nsec = Bech32.encode("nsec", ByteArray(32) { 1 })!!
        // Unroutable mint: construction must not touch the network.
        val wallet = openCashuNative(nsec, "https://mint.invalid", tempDir())
        try {
            assertFalse(wallet.isConnected())
            assertFailsWith<CashuWalletException.NotConnected> { wallet.balance() }
            assertFailsWith<CashuWalletException.NotConnected> { wallet.sync() }
        } finally {
            wallet.close()
        }
    }
}
