package chat.bitchat.sonar

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
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

    @Test
    fun freshParsedOfferIsTheOnlyDeltaThatRings() {
        val now = 10_000L
        val post = SonarNotificationRouter.actionForDelta(
            delta = delta("call"), notificationsAllowed = true,
            prefs = SonarNotificationPrefs(), nowSecs = now,
            parseCallControl = { SonarCallControl.Offer("c", false, "addr", now) },
        )
        assertEquals(SonarNotificationKind.Call, assertIs<SonarDeltaNotificationAction.Post>(post).notification.kind)

        listOf(now - 61, now + 61).forEach { timestamp ->
            assertIs<SonarDeltaNotificationAction.Cancel>(
                SonarNotificationRouter.actionForDelta(
                    delta("call"), true, SonarNotificationPrefs(), now,
                    parseCallControl = { SonarCallControl.Offer("c", false, "addr", timestamp) },
                ),
            )
        }
    }

    @Test
    fun terminalCallControlsCancelOnlyTheirCallNotification() {
        val controls = listOf(
            SonarCallControl.Answer("c", SonarAnswer.Accept, "addr"),
            SonarCallControl.Cancel("c"),
            SonarCallControl.End("c", "done"),
        )
        controls.forEach { control ->
            val action = SonarNotificationRouter.actionForDelta(
                delta("control"), false, SonarNotificationPrefs(enabled = false), 10_000,
                parseCallControl = { control },
            )
            assertEquals(
                SonarNotificationRouter.notificationId(
                    SonarNotificationRouter.callNotificationKey("group", "c"),
                ),
                assertIs<SonarDeltaNotificationAction.Cancel>(action).notificationId,
            )
        }
        assertEquals(
            false,
            SonarNotificationRouter.notificationId(
                SonarNotificationRouter.callNotificationKey("group", "c"),
            ) == SonarNotificationRouter.notificationId(
                SonarNotificationRouter.callNotificationKey("group", "new-call"),
            ),
        )
    }

    @Test
    fun staleTerminalCannotDismissAReusedGroupCall() {
        val action = SonarNotificationRouter.actionForDelta(
            delta("control").copy(createdAtSecs = 9_900),
            true,
            SonarNotificationPrefs(),
            10_000,
            parseCallControl = { SonarCallControl.End("old-call", "done") },
        )

        assertIs<SonarDeltaNotificationAction.Acknowledge>(action)
    }

    @Test
    fun blockedSenderIsPolicyAcknowledgedWithoutPlatformUi() {
        val action = SonarNotificationRouter.actionForDelta(
            delta("secret"), true, SonarNotificationPrefs(), 10_000,
            senderAllowed = false,
        )

        assertIs<SonarDeltaNotificationAction.Acknowledge>(action)
    }

    @Test
    fun disabledNotificationPolicyAcknowledgesWithoutCreatingBacklog() {
        val permissionDenied = SonarNotificationRouter.actionForDelta(
            delta("secret"), false, SonarNotificationPrefs(), 10_000,
        )
        val preferenceDisabled = SonarNotificationRouter.actionForDelta(
            delta("secret"), true, SonarNotificationPrefs(enabled = false), 10_000,
        )

        assertIs<SonarDeltaNotificationAction.Acknowledge>(permissionDenied)
        assertIs<SonarDeltaNotificationAction.Acknowledge>(preferenceDisabled)
    }

    @Test
    fun unparsedCallLookingTextIsRenderedAsMessageNotCall() {
        val action = SonarNotificationRouter.actionForDelta(
            delta("☎CALL|1|OFFER|forged|voice|addr|10000"), true,
            SonarNotificationPrefs(), 10_000, parseCallControl = { null },
        )
        assertEquals(
            SonarNotificationKind.Message,
            assertIs<SonarDeltaNotificationAction.Post>(action).notification.kind,
        )
    }

    private fun delta(content: String) = SonarDrainNotification(
        messageId = "message", groupId = "group", createdAtSecs = 10_000,
        senderNpub = "npub1alice", groupName = "Alice", contentPreview = content,
    )
}
