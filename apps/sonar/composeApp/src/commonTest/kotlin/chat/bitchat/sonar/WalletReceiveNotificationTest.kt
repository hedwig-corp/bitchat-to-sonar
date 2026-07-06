package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull

/** Rendering of the offline wallet-receive notification (no chat context). */
class WalletReceiveNotificationTest {

    @Test
    fun showsFormattedAmountByDefault() {
        val n = SonarNotificationRouter.buildWalletReceive("wallet-tx1", 21_500)!!
        assertEquals("Payment received", n.title)
        assertEquals("21,500 sats received.", n.body)
        assertEquals(SonarNotificationKind.Payment, n.kind)
    }

    @Test
    fun hidesAmountWhenPrefDisabled() {
        val n = SonarNotificationRouter.buildWalletReceive(
            "wallet-tx1", 21_500,
            SonarNotificationPrefs(showPaymentAmount = false),
        )!!
        assertEquals("Open Sonar to view the payment.", n.body)
    }

    @Test
    fun disabledPrefsProduceNothing() {
        assertNull(
            SonarNotificationRouter.buildWalletReceive(
                "wallet-tx1", 100,
                SonarNotificationPrefs(enabled = false),
            )
        )
    }

    @Test
    fun distinctPaymentsGetDistinctNotificationIds() {
        val a = SonarNotificationRouter.buildWalletReceive("wallet-tx1", 1)!!
        val b = SonarNotificationRouter.buildWalletReceive("wallet-tx2", 1)!!
        assertNotEquals(a.id, b.id)
    }
}
