package chat.bitchat.sonar

import chat.bitchat.sonar.CallControlAdmission.Kind
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * #420 — a ☎CALL line is an ordinary group message, so without binding, any
 * member of a group containing the victim could ring them with an OFFER
 * carrying the attacker's own address (media hijack + spoofed caller name),
 * or answer someone else's outgoing call (core's `on_answer` overwrites the
 * pin — the last answerer wins).
 */
class CallControlAdmissionTest {

    private val me = "me"
    private val peer = "peer"
    private val attacker = "attacker"

    @Test
    fun groupMemberCannotRingYou() {
        // The reported attack: attacker is a legitimate member of a group
        // that also contains the victim.
        assertFalse(
            CallControlAdmission.isAdmissible(
                kind = Kind.Offer,
                otherMemberKeys = listOf(peer, attacker),
                structurallyDirect = false,
                senderKey = attacker,
                activeCallConversationId = null,
                conversationId = "marmot:g",
            )
        )
    }

    @Test
    fun groupMemberCannotAnswerYourCall() {
        assertFalse(
            CallControlAdmission.isAdmissible(
                kind = Kind.Answer,
                otherMemberKeys = listOf(peer, attacker),
                structurallyDirect = false,
                senderKey = attacker,
                activeCallConversationId = "marmot:g",
                conversationId = "marmot:g",
            )
        )
    }

    @Test
    fun directPeerCanOfferAndAnswer() {
        assertTrue(
            CallControlAdmission.isAdmissible(
                kind = Kind.Offer,
                otherMemberKeys = listOf(peer),
                structurallyDirect = false,
                senderKey = peer,
                activeCallConversationId = null,
                conversationId = "marmot:dm",
            )
        )
        assertTrue(
            CallControlAdmission.isAdmissible(
                kind = Kind.Answer,
                otherMemberKeys = listOf(peer),
                structurallyDirect = false,
                senderKey = peer,
                activeCallConversationId = "marmot:dm",
                conversationId = "marmot:dm",
            )
        )
    }

    @Test
    fun someoneElseInADirectChatCannotDriveIt() {
        // Sender is not the conversation's peer: the id was reused/forged.
        assertFalse(
            CallControlAdmission.isAdmissible(
                kind = Kind.Offer,
                otherMemberKeys = listOf(peer),
                structurallyDirect = false,
                senderKey = attacker,
                activeCallConversationId = null,
                conversationId = "marmot:dm",
            )
        )
    }

    @Test
    fun answerFromAnotherConversationCannotSteerTheActiveCall() {
        // A callId learned elsewhere must not end/answer the live call.
        // Answer is the security-load-bearing kind — core's `on_answer`
        // overwrites the remote pin, so the last answerer wins (#420) — and an
        // earlier draft of this test asserted only End/Cancel while its name
        // claimed Answer coverage.
        assertFalse(
            CallControlAdmission.isAdmissible(
                kind = Kind.Answer,
                otherMemberKeys = listOf(peer),
                structurallyDirect = false,
                senderKey = peer,
                activeCallConversationId = "marmot:dm",
                conversationId = "marmot:other",
            )
        )
        assertFalse(
            CallControlAdmission.isAdmissible(
                kind = Kind.End,
                otherMemberKeys = listOf(peer),
                structurallyDirect = false,
                senderKey = peer,
                activeCallConversationId = "marmot:dm",
                conversationId = "marmot:other",
            )
        )
        assertFalse(
            CallControlAdmission.isAdmissible(
                kind = Kind.Cancel,
                otherMemberKeys = listOf(peer),
                structurallyDirect = false,
                senderKey = peer,
                activeCallConversationId = null,
                conversationId = "marmot:dm",
            )
        )
    }

    @Test
    fun meshDmsStayCallableWithoutARoster() {
        // BLE/Noise mesh + NIP-17 DMs are keyed by the peer, so they are
        // 2-party by construction and surface no member list (and often no
        // sender npub). Breaking these would break mesh calling outright.
        assertTrue(
            CallControlAdmission.isAdmissible(
                kind = Kind.Offer,
                otherMemberKeys = emptyList(),
                structurallyDirect = true,
                senderKey = "",
                activeCallConversationId = null,
                conversationId = "mesh:abc",
            )
        )
        assertTrue(
            CallControlAdmission.isAdmissible(
                kind = Kind.End,
                otherMemberKeys = emptyList(),
                structurallyDirect = true,
                senderKey = "",
                activeCallConversationId = "mesh:abc",
                conversationId = "mesh:abc",
            )
        )
    }

    @Test
    fun aRosterlessGroupConversationIsNotAdmissible() {
        // No roster AND not structurally direct: fail closed rather than
        // assume 2-party.
        assertFalse(
            CallControlAdmission.isAdmissible(
                kind = Kind.Offer,
                otherMemberKeys = emptyList(),
                structurallyDirect = false,
                senderKey = peer,
                activeCallConversationId = null,
                conversationId = "marmot:g",
            )
        )
    }

    @Test
    fun duplicateRosterEntriesStillResolveToOnePeer() {
        assertTrue(
            CallControlAdmission.isAdmissible(
                kind = Kind.Offer,
                otherMemberKeys = listOf(peer, peer, ""),
                structurallyDirect = false,
                senderKey = peer,
                activeCallConversationId = null,
                conversationId = "marmot:dm",
            )
        )
    }
    /**
     * #420 review round 2: a roster-backed control whose author we cannot
     * canonicalize must be REFUSED, not admitted. The first version checked the
     * sender only `if (senderKey.isNotBlank())`, so a Marmot message with an
     * empty/unresolvable senderNpub skipped the only author binding and the
     * attacker-supplied endpoint could drive the call under the peer's name.
     *
     * Missing sender identity stays acceptable only for structurally-direct
     * mesh messages, which carry no roster — covered by the rosterless tests.
     */
    @Test
    fun aRosterBackedControlWithNoSenderIsNotAdmissible() {
        assertFalse(
            CallControlAdmission.isAdmissible(
                kind = Kind.Offer,
                otherMemberKeys = listOf(peer),
                structurallyDirect = false,
                senderKey = "",
                activeCallConversationId = null,
                conversationId = "marmot:dm",
            )
        )
    }

    /** Same hole, reached with a blank-but-not-empty sender. */
    @Test
    fun aRosterBackedControlWithABlankSenderIsNotAdmissible() {
        assertFalse(
            CallControlAdmission.isAdmissible(
                kind = Kind.Offer,
                otherMemberKeys = listOf(peer),
                structurallyDirect = false,
                senderKey = "   ",
                activeCallConversationId = null,
                conversationId = "marmot:dm",
            )
        )
    }

    /**
     * The other side of that refusal, and the reason it is conditional: a mesh
     * chat is keyed by the peer, so the TRANSPORT proves 2-party-ness. The
     * caller still supplies a roster for it, because a folded conversation
     * resolves the Marmot leg's members (`otherMemberKeys(callChatId)`), and a
     * Bitchat peer may have no npub yet. Refusing every blank sender dropped
     * those calls silently.
     */
    @Test
    fun aStructurallyDirectControlStaysAdmissibleWithoutASender() {
        assertTrue(
            CallControlAdmission.isAdmissible(
                kind = Kind.Offer,
                otherMemberKeys = listOf(peer),
                structurallyDirect = true,
                senderKey = "",
                activeCallConversationId = null,
                conversationId = "mesh:dm",
            )
        )
    }

    /** A NAMED sender must still match, even on a direct transport. */
    @Test
    fun aStructurallyDirectControlFromAnotherNamedSenderIsNotAdmissible() {
        assertFalse(
            CallControlAdmission.isAdmissible(
                kind = Kind.Offer,
                otherMemberKeys = listOf(peer),
                structurallyDirect = true,
                senderKey = "npub1someoneelse",
                activeCallConversationId = null,
                conversationId = "mesh:dm",
            )
        )
    }
}
