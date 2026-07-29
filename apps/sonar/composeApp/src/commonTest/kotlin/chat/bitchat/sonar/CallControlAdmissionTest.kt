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
}
