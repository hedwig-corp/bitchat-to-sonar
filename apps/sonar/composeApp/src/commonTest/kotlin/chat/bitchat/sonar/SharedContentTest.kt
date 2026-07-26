package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Pins the classification the share hand-off does before a recipient is picked.
 *
 * The bug this guards: content shared into Sonar was dropped into the Search
 * *query field* (`SonarSearchScreen`), which read as searching for the link
 * rather than sending it, and had no path at all for files. The routing now
 * splits three ways — join an invite, show the picker, or reject as empty — and
 * each branch has to stay distinguishable from the others.
 */
class SharedContentTest {
    private fun files(vararg names: String, rejected: Int = 0) = DroppedFiles(
        files = names.map { DroppedFile(bytes = byteArrayOf(1, 2, 3), filename = it, mime = "image/jpeg") },
        rejectedCount = rejected,
    )

    @Test fun textOnlyShareIsNotEmpty() {
        val share = SharedContent(text = "https://example.com/a", files = files())
        assertFalse(share.isEmpty)
        assertEquals("https://example.com/a", share.summary)
    }

    @Test fun fileOnlyShareIsNotEmpty() {
        val share = SharedContent(text = null, files = files("photo.jpg"))
        assertFalse(share.isEmpty)
        // A single file names itself; the picker preview has nothing else to show.
        assertEquals("photo.jpg", share.summary)
    }

    @Test fun multipleFilesSummariseByCount() {
        val share = SharedContent(text = null, files = files("a.jpg", "b.jpg", "c.pdf"))
        assertEquals("3 files", share.summary)
    }

    @Test fun textWinsTheSummaryOverFiles() {
        val share = SharedContent(text = "look at this", files = files("a.jpg", "b.jpg"))
        assertEquals("look at this", share.summary)
    }

    @Test fun blankTextWithNoFilesIsEmpty() {
        assertTrue(SharedContent(text = "   ", files = files()).isEmpty)
        assertTrue(SharedContent(text = null, files = files()).isEmpty)
    }

    /**
     * A share whose files were all rejected still has to reach the caller as
     * empty, so the user gets "couldn't attach" instead of a silent no-op.
     */
    @Test fun allFilesRejectedIsEmptyButRecordsTheRejection() {
        val share = SharedContent(text = null, files = files(rejected = 2))
        assertTrue(share.isEmpty)
        assertEquals(2, share.files.rejectedCount)
    }

    @Test fun inviteTokenIsDetectedInSharedText() {
        // A Sonar invite shared back into Sonar means "join", not "send" — the
        // picker must never be offered for it.
        val token = "sinvite1deadbeef"
        assertEquals(token, INVITE_TOKEN_IN_TEXT.find("join me $token please")?.value)
        assertEquals(token, INVITE_TOKEN_IN_TEXT.find(inviteUniversalLink(token))?.value)
        assertEquals(token, INVITE_TOKEN_IN_TEXT.find(inviteDeepLink(token))?.value)
    }

    @Test fun ordinaryTextMentioningInviteIsNotAToken() {
        // Needs a hex payload, or every message about invites would try to join.
        assertEquals(null, INVITE_TOKEN_IN_TEXT.find("sinvite1"))
        assertEquals(null, INVITE_TOKEN_IN_TEXT.find("talking about sinvite1 links"))
    }

    @Test fun sharedFilenamesAreNormalisedForMdk() {
        // Filenames arrive from other apps; a path must not survive into the
        // attachment metadata.
        assertEquals("photo.jpg", encryptedAttachmentFilename("../../etc/photo.jpg"))
        assertEquals("photo.jpg", encryptedAttachmentFilename("C:\\Users\\x\\photo.jpg"))
        assertEquals("attachment", encryptedAttachmentFilename(".."))
    }

    @Test fun sharedMimesFallBackToTheBinaryEscapeHatch() {
        assertEquals("image/jpeg", encryptedAttachmentMime("image/jpeg"))
        assertEquals("application/pdf", encryptedAttachmentMime("application/pdf"))
        // Anything MDK does not allowlist becomes the generic binary type
        // rather than being rejected outright.
        assertEquals("application/octet-stream", encryptedAttachmentMime("application/x-weird"))
    }
}
