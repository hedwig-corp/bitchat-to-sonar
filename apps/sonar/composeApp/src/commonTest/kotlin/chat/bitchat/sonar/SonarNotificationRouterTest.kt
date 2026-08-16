package chat.bitchat.sonar

import kotlinx.coroutines.test.runTest
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

    // Regression for the v0.1-alpha.9 push-drain path: notifications must be
    // titled with the sender's nickname, not the truncated npub, whenever a
    // kind-0 profile is available from the cache or a fetch.
    @Test
    fun pushSenderNamePrefersCachedProfileOverNpub() = runTest {
        val npub = "npub1exampleexampleexampleexampleabcd"
        val name = resolvePushSenderName(
            npub = npub,
            cachedProfiles = mapOf(npub to SonarProfile("alice", "Alice", null, null, null)),
            fetchProfile = { error("must not fetch when the cache has a name") },
        )

        assertEquals("Alice", name)
    }

    @Test
    fun pushSenderNameFetchesProfileOnCacheMiss() = runTest {
        val name = resolvePushSenderName(
            npub = "npub1exampleexampleexampleexampleabcd",
            cachedProfiles = emptyMap(),
            fetchProfile = { SonarProfile("bob", null, null, null, null) },
        )

        assertEquals("bob", name)
    }

    @Test
    fun pushSenderNameFallsBackToNpubLabelOnlyWithoutProfile() = runTest {
        val npub = "npub1exampleexampleexampleexampleabcd"
        val name = resolvePushSenderName(
            npub = npub,
            cachedProfiles = emptyMap(),
            fetchProfile = { null },
        )

        assertEquals(shortNpubLabel(npub), name)
    }

    @Test
    fun mentionsAnnounceThemselvesInTheTitle() {
        val n = SonarNotificationRouter.build(
            idKey = "chat-1",
            kind = SonarNotificationKind.Mention,
            conversationTitle = "Alice",
            senderName = "Alice",
            groupName = "Signal Room",
            preview = "hey @vincenzo",
            prefs = SonarNotificationPrefs(showNames = true, showPreview = true),
        )

        assertEquals("Alice mentioned you", n?.title)
        assertEquals("hey @vincenzo", n?.body)
    }

    @Test
    fun mentionsStillHonourThePrivacyToggles() {
        // R-012: the Show names / Message preview toggles govern every kind.
        // A mention must not become a back door that leaks the sender or body.
        val n = SonarNotificationRouter.build(
            idKey = "chat-1",
            kind = SonarNotificationKind.Mention,
            conversationTitle = "Alice",
            senderName = "Alice",
            groupName = "Signal Room",
            preview = "hey @vincenzo",
            prefs = SonarNotificationPrefs(showNames = false, showPreview = false),
        )

        assertEquals("You were mentioned", n?.title)
        assertEquals("Open Sonar to read it.", n?.body)
    }

    @Test
    fun mentionsAreSuppressedWhenNotificationsAreOff() {
        val n = SonarNotificationRouter.build(
            idKey = "chat-1",
            kind = SonarNotificationKind.Mention,
            senderName = "Alice",
            preview = "hey @vincenzo",
            prefs = SonarNotificationPrefs(enabled = false),
        )

        assertNull(n)
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
