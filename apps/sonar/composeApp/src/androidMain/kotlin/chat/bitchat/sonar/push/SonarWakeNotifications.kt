package chat.bitchat.sonar.push

import chat.bitchat.sonar.MUTE_BLOB_KEY
import chat.bitchat.sonar.Notifier
import chat.bitchat.sonar.PROFILE_CACHE_BLOB_KEY
import chat.bitchat.sonar.SonarConversationSummary
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.SonarNotificationKind
import chat.bitchat.sonar.SonarNotificationPrefs
import chat.bitchat.sonar.SonarNotificationRouter
import chat.bitchat.sonar.SonarNotificationSound
import chat.bitchat.sonar.SonarProfile
import chat.bitchat.sonar.canonicalProfileKey
import chat.bitchat.sonar.decodeMuteMap
import chat.bitchat.sonar.decodeProfileCache
import chat.bitchat.sonar.isMutedAt
import chat.bitchat.sonar.resolvePushSenderName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Renders titled notifications for unread conversations from LOCAL storage.
 *
 * Shared between [SonarPushProcessingService] (the normal foreground-service
 * wake) and [SonarPushInlineFallback] (the bounded in-window fallback when
 * Android denies the foreground-service start, #203) so the two paths cannot
 * drift on mute handling, name resolution, call filtering, or trill sounds.
 */
internal object SonarWakeNotifications {

    private const val PROFILE_FETCH_BUDGET_MS = 5_000L

    /** Render titled notifications for every unread conversation from local
     *  storage. Returns how many conversations were notified.
     *
     *  [scope] hosts the profile fetches: [SonarCore.fetchProfile] is a
     *  blocking UniFFI call that a `withTimeoutOrNull` child cannot actually
     *  cancel, so the fetches run as orphan jobs on the caller's scope and
     *  only the await is bounded (see [prefetchSenderProfiles]).
     */
    suspend fun notifyUnreadConversations(
        prefs: SonarNotificationPrefs,
        scope: CoroutineScope,
        profileFetchBudgetMs: Long = PROFILE_FETCH_BUDGET_MS,
    ): Int {
        val summaries = SonarCore.conversationSummaries()
        val unread = summaries.filter { it.unreadCount > 0 }
        if (unread.isEmpty()) return 0

        // The drain runs while the UI may be dead, so resolve nicknames the
        // same way the foreground path does: persisted kind-0 cache first,
        // then a bounded relay fetch (relays are already connected here).
        // Never title a notification with the raw npub when a name exists.
        // Skip the network entirely when names are hidden -- the router
        // discards senderName in that case, so the fetches would be wasted.
        val cachedProfiles = decodeProfileCache(SonarCore.loadBlob(PROFILE_CACHE_BLOB_KEY))
        val fetchedProfiles =
            if (prefs.showNames) {
                prefetchSenderProfiles(unread, cachedProfiles, scope, profileFetchBudgetMs)
            } else {
                emptyMap()
            }

        // Per-chat mute is honored on the killed-app drain too: rows and unread
        // counts still accrued in local storage — only the banner is skipped.
        // muteChat persists the whole folded-id set, so a direct group-id
        // lookup is sufficient here.
        val mutes = decodeMuteMap(SonarCore.loadBlob(MUTE_BLOB_KEY))
        val nowSecs = System.currentTimeMillis() / 1000

        var notified = 0
        for (summary in unread) {
            if (isMutedAt(mutes[summary.groupIdHex], nowSecs)) continue
            val kind = SonarNotificationRouter.classifyContent(
                summary.latestContent,
                isCallControl = { SonarCore.callParseControl(it) != null },
            )
            if (kind == SonarNotificationKind.Call) continue

            val notif = SonarNotificationRouter.build(
                idKey = summary.groupIdHex,
                kind = kind,
                conversationTitle = summary.name.ifBlank { null },
                senderName = if (!prefs.showNames) null else summary.latestSenderNpub
                    .takeIf { it.isNotBlank() }
                    ?.let { npub ->
                        // Everything is prefetched above under one budget, so
                        // the fetch lambda is a pure map read (no network).
                        resolvePushSenderName(npub, cachedProfiles) { missing ->
                            fetchedProfiles[canonicalProfileKey(missing)]
                        }
                    },
                preview = summary.latestContent,
                unreadCount = summary.unreadCount,
                prefs = prefs,
            )
            if (notif != null) {
                Notifier.notify(
                    id = notif.id,
                    title = notif.title,
                    body = notif.body,
                    // A trill rings its distinct bell on background drains too.
                    sound = if (kind == SonarNotificationKind.Trill) {
                        SonarNotificationSound.Trill
                    } else {
                        SonarNotificationSound.Default
                    },
                    conversationId = summary.groupIdHex,
                )
                notified++
            }
        }
        return notified
    }

    /**
     * Resolve every uncached sender's kind-0 profile for this wakeup under ONE
     * total budget, keyed by [canonicalProfileKey].
     *
     * Fetches run in parallel and, crucially, are launched on the caller's own
     * [scope] rather than as children of the timeout block: [SonarCore.fetchProfile]
     * hops to `Dispatchers.IO` and makes a blocking UniFFI call (with its own
     * ~10s core-internal timeout), so a `withTimeoutOrNull` wrapped directly
     * around it could not actually cancel the blocking child and would wait the
     * full core timeout anyway. By awaiting orphaned [scope] jobs inside the
     * budget, the await is genuinely cancellable -- when the budget expires we
     * fall back to the npub label immediately while the stragglers finish
     * harmlessly in the background. A single budget also bounds total wall time
     * regardless of how many distinct uncached senders are unread (otherwise it
     * would grow as senderCount x timeout, delaying later notifications and
     * stopSelf).
     */
    private suspend fun prefetchSenderProfiles(
        unread: List<SonarConversationSummary>,
        cachedProfiles: Map<String, SonarProfile>,
        scope: CoroutineScope,
        budgetMs: Long,
    ): Map<String, SonarProfile?> {
        // canonicalKey -> npub, de-duplicated and skipping cache hits.
        val missing = LinkedHashMap<String, String>()
        for (summary in unread) {
            val npub = summary.latestSenderNpub.takeIf { it.isNotBlank() } ?: continue
            val key = canonicalProfileKey(npub)
            if (cachedProfiles[key]?.bestName != null) continue
            missing.putIfAbsent(key, npub)
        }
        if (missing.isEmpty()) return emptyMap()

        val jobs = missing.map { (key, npub) ->
            scope.async { key to runCatching { SonarCore.fetchProfile(npub) }.getOrNull() }
        }
        val resolved = HashMap<String, SonarProfile?>()
        withTimeoutOrNull(budgetMs) {
            jobs.forEach { job ->
                val (key, profile) = job.await()
                resolved[key] = profile
            }
        }
        return resolved
    }

    /** The generic "you have a message" banner used when local state has
     *  nothing titled to show. */
    fun notifyFallback(prefs: SonarNotificationPrefs) {
        val notif = SonarNotificationRouter.build(
            idKey = "marmot-push",
            kind = SonarNotificationKind.Message,
            unreadCount = 1,
            prefs = prefs.copy(showPreview = false),
        ) ?: return
        Notifier.notify(notif.id, notif.title, notif.body)
    }
}
