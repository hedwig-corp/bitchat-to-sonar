package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class SonarNotificationRouterTest {
    @Test
    fun ordinaryMessagesAreGenericByDefault() {
        val n = SonarNotificationRouter.build(
            idKey = "chat-1",
            kind = SonarNotificationKind.Message,
            conversationTitle = "Alice",
            preview = "secret text",
        )

        assertEquals("New Sonar message", n?.title)
        assertEquals("Open Sonar to read it.", n?.body)
    }

    @Test
    fun namesAndPreviewsRequireOptIn() {
        val n = SonarNotificationRouter.build(
            idKey = "chat-1",
            kind = SonarNotificationKind.Message,
            conversationTitle = "Alice",
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
    fun paymentAndCallUseDistinctGenericCopy() {
        val payment = SonarNotificationRouter.build("chat-1", SonarNotificationKind.Payment)
        val call = SonarNotificationRouter.build("chat-1", SonarNotificationKind.Call)

        assertEquals("Payment received", payment?.title)
        assertEquals("Open Sonar to view the payment.", payment?.body)
        assertEquals("Incoming Sonar call", call?.title)
        assertEquals("Open Sonar to answer.", call?.body)
    }

    @Test
    fun contentClassificationFindsPaymentsAndCalls() {
        assertEquals(
            SonarNotificationKind.Payment,
            SonarNotificationRouter.classifyContent("⚡PAY|1|u1|2100"),
        )
        assertEquals(
            SonarNotificationKind.Call,
            SonarNotificationRouter.classifyContent("☎CALL|1|offer") { it.startsWith("☎CALL") },
        )
        assertEquals(
            SonarNotificationKind.Message,
            SonarNotificationRouter.classifyContent("hello"),
        )
    }
}
