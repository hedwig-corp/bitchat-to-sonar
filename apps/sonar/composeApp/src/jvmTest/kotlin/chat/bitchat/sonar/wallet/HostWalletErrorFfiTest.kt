package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.SonarNativeLoader
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.fail
import uniffi.sonar_ffi.HostMigrationSource
import uniffi.sonar_ffi.HostPayment
import uniffi.sonar_ffi.HostPaymentLookup
import uniffi.sonar_ffi.HostSendQuote
import uniffi.sonar_ffi.HostWalletException
import uniffi.sonar_ffi.probeHostMigrationPrepare

/**
 * Pins the generated `with_foreign` callback: a Kotlin `HostMigrationSource`
 * that throws [HostWalletException.InsufficientFunds] must surface that typed
 * error after UniFFI lifts it into Rust and lowers it back. A flat error
 * aborts with "Can't lift flat errors" and never reaches the planner.
 */
class HostWalletErrorFfiTest {

    @Test
    fun hostWalletErrorInsufficientFundsLiftsAcrossUniffi() {
        SonarNativeLoader.ensureLoaded()
        try {
            probeHostMigrationPrepare(InsufficientSource(), "lnbc1test", 1_000u)
            fail("prepare must throw InsufficientFunds")
        } catch (error: HostWalletException.InsufficientFunds) {
            // typed lift succeeded
        } catch (error: Throwable) {
            fail("must lift HostWalletException.InsufficientFunds, not ${error::class.simpleName}: ${error.message}")
        }
    }

    @Test
    fun hostWalletErrorFailedLiftsAcrossUniffi() {
        SonarNativeLoader.ensureLoaded()
        try {
            probeHostMigrationPrepare(FailedSource(), "lnbc1test", 1_000u)
            fail("prepare must throw Failed")
        } catch (error: HostWalletException.Failed) {
            assertEquals("bolt timeout", error.reason)
        } catch (error: Throwable) {
            fail("must lift HostWalletException.Failed, not ${error::class.simpleName}: ${error.message}")
        }
    }

    private class InsufficientSource : HostMigrationSource {
        override fun `balanceSats`(): ULong = 10_000u
        override fun `prepare`(invoice: String, amountSats: ULong): HostSendQuote {
            throw HostWalletException.InsufficientFunds()
        }
        override fun `send`(token: String, note: String): HostPayment {
            throw HostWalletException.Failed("send must not run")
        }
        override fun `lookupPayment`(paymentHash: String): HostPaymentLookup {
            throw HostWalletException.Failed("lookup must not run")
        }
    }

    private class FailedSource : HostMigrationSource {
        override fun `balanceSats`(): ULong = 10_000u
        override fun `prepare`(invoice: String, amountSats: ULong): HostSendQuote {
            throw HostWalletException.Failed("bolt timeout")
        }
        override fun `send`(token: String, note: String): HostPayment {
            throw HostWalletException.Failed("send must not run")
        }
        override fun `lookupPayment`(paymentHash: String): HostPaymentLookup {
            throw HostWalletException.Failed("lookup must not run")
        }
    }
}
