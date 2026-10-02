package chat.bitchat.sonar.chatlist

import app.cash.molecule.RecompositionMode
import app.cash.molecule.moleculeFlow
import androidx.compose.runtime.snapshots.Snapshot
import app.cash.turbine.test
import chat.bitchat.sonar.MeshDmRow
import chat.bitchat.sonar.SonarChat
import chat.bitchat.sonar.SonarGroupInvite
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * [ChatListPresenter] run headless with Molecule (`RecompositionMode.Immediate`)
 * and asserted with Turbine: no emulator, no UI, no relay.
 *
 * The repository under the presenter is the real one over [FakeChatListCore];
 * [FakeChatListSources] stands in for the folding/dedupe projection that still
 * lives in `SonarAppState` (pinned by the JVM tests that build a real one).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatListPresenterTest {
    private val giulia = SonarChat("g-giulia", "", listOf("npub1me", "npub1giulia"))
    private val team = SonarChat("g-team", "Team", listOf("npub1me", "npub1a", "npub1b"))
    private val note = SonarChat("g-note", "Note to Self", listOf("npub1me"))
    private val sara = MeshDmRow(peerId = "f3237e63", name = "Sara D", preview = "over bluetooth", tsSecs = 150)

    private fun TestScope.repository(
        core: FakeChatListCore,
        initialChats: List<SonarChat> = emptyList(),
    ): ChatListRepository {
        lateinit var repo: ChatListRepository
        repo = ChatListRepository(
            core = core,
            scope = backgroundScope,
            initialChats = initialChats,
            initialMessagesByChat = emptyMap(),
            initialLatestByChat = emptyMap(),
            viewingGroupIds = { emptySet() },
            reload = { repo.publishLocal(repo.loadChats(), repo.chats.map { it.id }) },
        )
        return repo
    }

    /**
     * The presenter's models, recomposed on the test's queued dispatcher.
     *
     * Turbine collects on an unconfined dispatcher, and Molecule schedules its
     * snapshot apply on the collecting context, so without [flowOn] every
     * single state write recomposes synchronously and emits its own model.
     * The app recomposes on the UI frame clock, where a burst of writes lands
     * in one frame; a queued dispatcher is the faithful stand-in.
     *
     * Setup writes are applied first: in the app the platform's global
     * snapshot manager applies writes as they happen, so a presenter never
     * starts with a backlog of unapplied changes.
     */
    private fun TestScope.models(
        presenter: ChatListPresenter,
        events: MutableSharedFlow<ChatListEvent> = MutableSharedFlow(),
    ): Flow<ChatListModel> {
        Snapshot.sendApplyNotifications()
        return moleculeFlow(RecompositionMode.Immediate) { presenter.present(events) }
            .flowOn(StandardTestDispatcher(testScheduler))
    }

    @Test
    fun theFirstModelIsPaintedFromLocalStateBeforeCoreAnswersAnything() = runTest {
        // The core's local read is parked (a cold store still opening) and no
        // relay exists at all. The list must still paint what is on the device.
        val core = FakeChatListCore().apply {
            chats = listOf(giulia, team)
            summaries = listOf(summary(giulia.id, 300, unread = 2), summary(team.id, 200))
            chatsGate = CompletableDeferred()
        }
        val repo = repository(core, initialChats = listOf(team, giulia))
        val sources = FakeChatListSources().apply {
            showMarmot(
                team to marmotRowModel(team, title = "Team", sub = "restored", tsSecs = 200),
                giulia to marmotRowModel(giulia, title = "Giulia", sub = "restored", tsSecs = 100),
            )
        }

        models(ChatListPresenter(repo, sources)).test {
            val first = awaitItem()
            assertTrue(first.hydrated)
            assertEquals(listOf("Team", "Giulia"), first.rows.map { it.title })
            assertEquals(0, core.chatsCalls + core.summariesCalls, "first paint read nothing from core")

            // A reload starts and parks in the slow local read: nothing
            // repaints, and nothing waits for it.
            val reload = launch { repo.refresh(); repo.refreshUnread() }
            runCurrent()
            assertEquals(1, core.chatsCalls)
            expectNoEvents()

            // The local store answers; its unread count reaches the row.
            core.chatsGate!!.complete(Unit)
            reload.join()
            assertTrue(awaitItem().rows.first { it.key == giulia.id }.unread)
            expectNoEvents()
        }
    }

    @Test
    fun beforeHydrationPhoneHomeShowsOnlyALoadingRow() = runTest {
        val sources = FakeChatListSources().apply {
            homeMessagesHydrated = false
            showMarmot(giulia to marmotRowModel(giulia, title = "Giulia"))
        }
        val presenter = ChatListPresenter(repository(FakeChatListCore()), sources)
        models(presenter).test {
            val loading = awaitItem()
            assertFalse(loading.hydrated)
            assertTrue(loading.rows.isEmpty(), "never paint an incomplete Home")

            sources.homeMessagesHydrated = true
            assertEquals(listOf("Giulia"), awaitItem().rows.map { it.title })
        }
    }

    @Test
    fun theDesktopSidebarPaintsTheRestoredSnapshotBeforeHydration() = runTest {
        val sources = FakeChatListSources().apply {
            homeMessagesHydrated = false
            showMarmot(giulia to marmotRowModel(giulia, title = "Giulia"))
        }
        val presenter = ChatListPresenter(repository(FakeChatListCore()), sources, waitForHydration = false)
        models(presenter).test {
            assertEquals(listOf("Giulia"), awaitItem().rows.map { it.title })
        }
    }

    @Test
    fun bothChatKindsMergeIntoOneRecencyOrderWithNoteToSelfPinned() = runTest {
        val sources = FakeChatListSources().apply {
            meshRows = listOf(sara)
            noteToSelfGroupId = note.id
            showMarmot(
                note to marmotRowModel(note, title = "Note to Self", tsSecs = 10),
                giulia to marmotRowModel(giulia, title = "Giulia", tsSecs = 300),
                team to marmotRowModel(team, title = "Team", tsSecs = 100, multiMember = true),
            )
        }
        val presenter = ChatListPresenter(repository(FakeChatListCore()), sources)
        models(presenter).test {
            val rows = awaitItem().rows
            // Note to Self first although it is the oldest; then pure recency
            // across transports: Giulia (300) > Sara over BLE (150) > Team (100).
            assertEquals(listOf(note.id, giulia.id, "mesh:${sara.peerId}", team.id), rows.map { it.key })
            val mesh = rows[2] as ChatListRow.Mesh
            assertEquals("mesh:${sara.peerId}", mesh.conversationId)
            assertTrue((rows[3] as ChatListRow.Marmot).group)
            assertTrue((rows[0] as ChatListRow.Marmot).noteToSelf)
        }
    }

    @Test
    fun unreadIsSummedOverEveryDuplicateGroupAndNoteToSelfNeverShowsIt() = runTest {
        val core = FakeChatListCore().apply {
            // Giulia's unread message sits in her SECOND direct group.
            summaries = listOf(
                summary("g-giulia-2", 400, unread = 1),
                summary(note.id, 50, unread = 4),
            )
        }
        val repo = repository(core)
        repo.refreshUnread()
        val sources = FakeChatListSources().apply {
            noteToSelfGroupId = note.id
            showMarmot(
                note to marmotRowModel(note, title = "Note to Self"),
                giulia to marmotRowModel(giulia, title = "Giulia", groupIds = listOf(giulia.id, "g-giulia-2")),
            )
        }
        models(ChatListPresenter(repo, sources)).test {
            val rows = awaitItem().rows.associateBy { it.key }
            assertTrue(rows.getValue(giulia.id).unread, "a badge in any folded group lights the row")
            assertFalse(rows.getValue(note.id).unread, "your own notes are never unread")
        }
    }

    @Test
    fun aMeshFoldedRowShowsTheUnreadOfItsWhiteNoiseLegs() = runTest {
        // Sara was met over Bluetooth; she now writes over White Noise, so her
        // unread message sits in a Marmot group folded into her mesh row.
        val core = FakeChatListCore().apply { summaries = listOf(summary("g-sara", 500, unread = 2)) }
        val repo = repository(core)
        repo.refreshUnread()
        val sources = FakeChatListSources().apply {
            meshRows = listOf(sara.copy(groupIds = listOf("g-sara"), verified = true))
        }
        models(ChatListPresenter(repo, sources)).test {
            val row = awaitItem().rows.single() as ChatListRow.Mesh
            assertTrue(row.unread, "the dot a pure Marmot chat would show")
            assertTrue(row.verified)
            // Opening the mesh chat read-marks the same folded set.
            repo.markRead(listOf("g-sara"))
            assertFalse(awaitItem().rows.single().unread)
        }
    }

    @Test
    fun markingAConversationReadClearsItsBadgeInTheNextModel() = runTest {
        val core = FakeChatListCore().apply { summaries = listOf(summary(giulia.id, 400, unread = 3)) }
        val repo = repository(core)
        repo.refreshUnread()
        val sources = FakeChatListSources().apply {
            showMarmot(giulia to marmotRowModel(giulia, title = "Giulia"))
        }
        models(ChatListPresenter(repo, sources)).test {
            assertTrue(awaitItem().rows.single().unread)
            repo.markRead(listOf(giulia.id))
            assertFalse(awaitItem().rows.single().unread, "optimistic: no wait for core")
            runCurrent()
            assertEquals(listOf(giulia.id), core.markedRead)
            expectNoEvents()
        }
    }

    @Test
    fun aBurstOfStateWritesProducesOneModel() = runTest {
        val chats = (1..20).map { SonarChat("g$it", "", listOf("npub1me", "npub1p$it")) }
        val core = FakeChatListCore().apply { summaries = chats.map { summary(it.id, 100, unread = 1) } }
        val repo = repository(core)
        repo.refreshUnread()
        val sources = FakeChatListSources().apply {
            showMarmot(*chats.map { it to marmotRowModel(it, title = it.id) }.toTypedArray())
        }
        models(ChatListPresenter(repo, sources)).test {
            assertTrue(awaitItem().rows.all { it.unread })
            // Twenty separate writes in one burst (reading through a synced
            // backlog): the presenter recomposes once, not twenty times.
            chats.forEach { repo.markRead(listOf(it.id)) }
            assertTrue(awaitItem().rows.none { it.unread })
            runCurrent()
            expectNoEvents()
        }
    }

    @Test
    fun theFilterMatchesTitlesAndRawGroupNames() = runTest {
        val events = MutableSharedFlow<ChatListEvent>(extraBufferCapacity = 8)
        val sources = FakeChatListSources().apply {
            meshRows = listOf(sara)
            showMarmot(
                // A 1:1 whose group name is a stale creation-time label: the
                // shown title is what people search for.
                giulia to marmotRowModel(giulia, title = "Giulia Rossi"),
                team.copy(name = "Weekend crew") to marmotRowModel(team, title = "Team"),
            )
        }
        models(ChatListPresenter(repository(FakeChatListCore()), sources), events).test {
            assertEquals(3, awaitItem().rows.size)
            events.emit(ChatListEvent.Filter("rossi"))
            assertEquals(listOf("Giulia Rossi"), awaitItem().rows.map { it.title })
            events.emit(ChatListEvent.Filter("CREW"))
            assertEquals(listOf("Team"), awaitItem().rows.map { it.title })
            events.emit(ChatListEvent.Filter(" sara "))
            assertEquals(listOf("Sara D"), awaitItem().rows.map { it.title })
            events.emit(ChatListEvent.Filter(""))
            assertEquals(3, awaitItem().rows.size)
        }
    }

    @Test
    fun eventsReachTheRightActionForEachChatKind() = runTest {
        val events = MutableSharedFlow<ChatListEvent>(extraBufferCapacity = 16)
        val invite = SonarGroupInvite("inv1", "g-new", "Hikers", "", "npub1w", 4, emptyList())
        val sources = FakeChatListSources().apply {
            meshRows = listOf(sara)
            groupInvites = listOf(invite)
            showMarmot(giulia to marmotRowModel(giulia, title = "Giulia"))
        }
        models(ChatListPresenter(repository(FakeChatListCore()), sources), events).test {
            val model = awaitItem()
            val mesh = model.rows.first { it is ChatListRow.Mesh }
            val marmot = model.rows.first { it is ChatListRow.Marmot }
            assertEquals(listOf(invite), model.invites)
            assertEquals(marmot.key, model.lastKey)

            events.emit(ChatListEvent.Open(mesh))
            events.emit(ChatListEvent.Open(marmot))
            events.emit(ChatListEvent.Mute(mesh.conversationId, 3600))
            events.emit(ChatListEvent.Unmute(marmot.conversationId))
            events.emit(ChatListEvent.Delete(sara.peerId, mesh = true))
            events.emit(ChatListEvent.Delete(giulia.id, mesh = false))
            events.emit(ChatListEvent.AcceptInvite(invite.id))
            events.emit(ChatListEvent.DeclineInvite(invite.id))
            runCurrent()
            assertEquals(
                listOf(
                    // A mesh row opens the folded DM by peer; a Marmot row by chat.
                    "openDm:${sara.peerId}:Sara D",
                    "openChat:${giulia.id}",
                    "mute:mesh:${sara.peerId}:3600",
                    "unmute:${giulia.id}",
                    "deleteMesh:${sara.peerId}",
                    "deleteMarmot:${giulia.id}",
                    "accept:inv1",
                    "decline:inv1",
                ),
                sources.actions,
            )
            expectNoEvents()
        }
    }

    @Test
    fun anEmptyListSaysSoAndInvitesAloneAreNotEmpty() = runTest {
        val sources = FakeChatListSources()
        models(ChatListPresenter(repository(FakeChatListCore()), sources)).test {
            val empty = awaitItem()
            assertTrue(empty.empty)
            assertEquals(null, empty.lastKey)
            sources.groupInvites = listOf(SonarGroupInvite("inv1", "g", "Hikers", "", "npub1w", 3, emptyList()))
            val withInvite = awaitItem()
            assertFalse(withInvite.empty)
            assertEquals("invite:inv1", withInvite.lastKey)
        }
    }

    @Test
    fun theCatchUpHintFollowsTheSyncWithoutGatingRows() = runTest {
        val sources = FakeChatListSources().apply {
            catchingUp = true
            showMarmot(giulia to marmotRowModel(giulia, title = "Giulia"))
        }
        models(ChatListPresenter(repository(FakeChatListCore()), sources)).test {
            val syncing = awaitItem()
            assertTrue(syncing.catchingUp)
            assertEquals(1, syncing.rows.size, "a catch-up sync never holds back local rows")
            sources.catchingUp = false
            assertFalse(awaitItem().catchingUp)
        }
    }
}
