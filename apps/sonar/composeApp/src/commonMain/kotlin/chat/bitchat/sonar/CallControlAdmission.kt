package chat.bitchat.sonar

/**
 * Which call-control lines a conversation is allowed to act on (#420).
 *
 * `CallControl` carries no sender identity and core enforces nothing about
 * conversation shape — `on_answer` even overwrites `slot.remote_id`
 * unconditionally, so the LAST answerer wins. Binding is therefore host
 * responsibility, and it was missing: a `☎CALL` line is an ordinary kind-445
 * group message, so any member of a group containing the victim could ring
 * them with an OFFER carrying the attacker's own iroh address (media hijack
 * plus a spoofed caller name), or answer someone else's outgoing call.
 *
 * Pure so both hosts can pin it — neither `SonarAppState` nor `SonarAppStore`
 * is constructible in a test.
 */
object CallControlAdmission {

    /** The kinds of control line, decoupled from each platform's own enum. */
    enum class Kind { Offer, Answer, Cancel, End }

    /**
     * @param kind which control line arrived.
     * @param otherMemberKeys members of the conversation the line arrived in,
     *   EXCLUDING us, already canonicalized (same encoding as [senderKey]).
     *   Empty means "no roster" — see [structurallyDirect].
     * @param structurallyDirect true when the conversation is 2-party by
     *   construction and carries no roster: a BLE/Noise mesh DM or a NIP-17
     *   direct DM is keyed by the peer itself, so there is no third party who
     *   could inject a line into it. Group-backed conversations are never
     *   this, and must be judged on [otherMemberKeys].
     * @param senderKey canonicalized author of the message carrying the line;
     *   may be blank on transports that do not surface one.
     * @param activeCallConversationId conversation of the call currently in
     *   progress, or null when there is none.
     * @param conversationId conversation the line arrived in.
     */
    fun isAdmissible(
        kind: Kind,
        otherMemberKeys: List<String>,
        structurallyDirect: Boolean,
        senderKey: String,
        activeCallConversationId: String?,
        conversationId: String,
    ): Boolean {
        val peers = otherMemberKeys.filter { it.isNotBlank() }.distinct()
        if (peers.isEmpty()) {
            // No roster to judge. Admit only when the transport itself makes
            // the conversation 2-party; otherwise we would be right back to
            // "any group member can drive a call".
            if (!structurallyDirect) return false
        } else {
            // Calls are 2-party: a conversation with more than one other
            // member has no unambiguous peer, so nothing in it may drive call
            // state — not even a decline reply, which would leak presence to
            // every member.
            val peer = peers.singleOrNull() ?: return false
            // The line must come FROM that peer when we can see who sent it.
            // Membership alone is what made the group hijack work: the
            // attacker was a legitimate member.
            if (senderKey.isNotBlank() && senderKey != peer) return false
        }
        // Answer/Cancel/End act on an in-progress call, which callId alone
        // used to gate. Require the line to arrive in the SAME conversation as
        // that call, so a matching id learned elsewhere cannot steer it.
        return when (kind) {
            Kind.Offer -> true
            Kind.Answer, Kind.Cancel, Kind.End ->
                activeCallConversationId != null && activeCallConversationId == conversationId
        }
    }
}
