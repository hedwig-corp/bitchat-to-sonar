package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class SonarNotificationRouterTest {
    @Test
    fun ordinaryMessagesShowSenderByDefault() {
        val n = SonarNotificationRouter.build(
            idKey = "chat-1",
            kind = SonarNotificationKind.Message,
            conversationTitle = "Alice",
            preview = "secret text",
        )

        assertEquals("Alice", n?.title)
        assertEquals("Open Sonar to read it.", n?.body)
    }

    @Test
    fun groupMessagesShowSenderAndGroup() {
        val n = SonarNotificationRouter.build(
            idKey = "chat-1",
            kind = SonarNotificationKind.Message,
            conversationTitle = "Alice",
            senderName = "Alice",
            groupName = "Signal Room",
            preview = "secret text",
        )

        assertEquals("Alice in Signal Room", n?.title)
        assertEquals("Open Sonar to read it.", n?.body)
    }

    @Test
    fun previewsRequireOptIn() {
        val n = SonarNotificationRouter.build(
            idKey = "chat-1",
            kind = SonarNotificationKind.Message,
            senderName = "Alice",
            preview = "hello\nthere",
            prefs = SonarNotificationPrefs(showNames = true, showPreview = true),
        )

        assertEquals("Alice", n?.title)
        assertEquals("hello there", n?.body)
    }

    @Test
    fun disabledPrefsSuppressNotification() {
        val n = SonarNotificationRouter.build(
            idKey = "chat-1",
            kind = SonarNotificationKind.Message,
            prefs = SonarNotificationPrefs(enabled = false),
        )

        assertNull(n)
    }

    @Test
    fun paymentShowsAmountAndCallShowsSender() {
        val payment = SonarNotificationRouter.build(
            idKey = "chat-1",
            kind = SonarNotificationKind.Payment,
            senderName = "Alice",
            preview = "⚡PAY|1|abc-123|2100",
        )
        val call = SonarNotificationRouter.build(
            idKey = "chat-1",
            kind = SonarNotificationKind.Call,
            senderName = "Alice",
        )

        assertEquals("Payment from Alice", payment?.title)
        assertEquals("2,100 sats received from Alice.", payment?.body)
        assertEquals("Incoming call from Alice", call?.title)
        assertEquals("Tap to answer.", call?.body)
    }

    @Test
    fun contentClassificationFindsPaymentsAndCalls() {
        assertEquals(
            SonarNotificationKind.Payment,
            SonarNotificationRouter.classifyContent("⚡PAY|1|abc-123|2100"),
        )
        assertEquals(
            SonarNotificationKind.Call,
            SonarNotificationRouter.classifyContent("☎CALL|1|OFFER|c|voice|addr|1"),
        )
        assertEquals(
            SonarNotificationKind.Message,
            SonarNotificationRouter.classifyContent("hello"),
        )
    }
}
