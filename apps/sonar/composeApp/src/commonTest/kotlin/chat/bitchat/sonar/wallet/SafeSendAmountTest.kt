package chat.bitchat.sonar.wallet

import kotlin.test.Test
import kotlin.test.assertEquals

class SafeSendAmountTest {
    @Test fun drain_reserves_fee() =
        assertEquals(995L, safeSendAmount(requestedSats = 1000, balanceSats = 1000, feeSats = 5))

    @Test fun partial_amount_unchanged() =
        assertEquals(900L, safeSendAmount(requestedSats = 900, balanceSats = 1000, feeSats = 5))

    @Test fun zero_fee_unchanged() =
        assertEquals(1000L, safeSendAmount(requestedSats = 1000, balanceSats = 1000, feeSats = 0))

    @Test fun fee_exceeds_balance_keeps_requested_so_send_fails_cleanly() =
        assertEquals(1000L, safeSendAmount(requestedSats = 1000, balanceSats = 1000, feeSats = 1500))

    @Test fun amountless_invoice_unchanged() =
        assertEquals(0L, safeSendAmount(requestedSats = 0, balanceSats = 1000, feeSats = 5))

    @Test fun zero_balance_unchanged() =
        assertEquals(500L, safeSendAmount(requestedSats = 500, balanceSats = 0, feeSats = 5))
}
