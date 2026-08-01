//
// SonarCallControlAdmission.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Which call-control lines a conversation is allowed to act on (#420).
/// Mirror of Compose `CallControlAdmission` — keep the two in step
/// (Cross-Platform Feature Rule).
///
/// `CallControl` carries no sender identity and core enforces nothing about
/// conversation shape — `on_answer` even overwrites `slot.remote_id`
/// unconditionally, so the LAST answerer wins. Binding is host
/// responsibility, and it was missing: a `☎CALL` line is an ordinary kind-445
/// group message, so any member of a group containing the victim could ring
/// them with an OFFER carrying the attacker's own iroh address, or answer
/// someone else's outgoing call.
///
/// On Apple the OFFER leg happened to be blocked already, but only through
/// the conversation-*folding* helper (`snDirectMarmotPeerKey`, which is
/// `others.count == 1 ? … : nil`) — a routing detail, not a security check,
/// and one a "resolve the group peer more leniently" change would silently
/// undo. Answer/Cancel/End had no binding at all.
enum SonarCallControlAdmission {

    /// The kinds of control line, decoupled from the FFI enum.
    enum Kind {
        case offer
        case answer
        case cancel
        case end
    }

    /// - Parameters:
    ///   - otherMemberKeys: members of the conversation the line arrived in,
    ///     EXCLUDING us, canonicalized the same way as `senderKey`. Empty
    ///     means "no roster" — see `structurallyDirect`.
    ///   - structurallyDirect: true when the conversation is 2-party by
    ///     construction and carries no roster (a BLE/Noise mesh DM is keyed by
    ///     the peer itself, so no third party can inject a line into it).
    ///     Group-backed conversations are never this.
    ///   - senderKey: canonicalized author of the message; may be empty on
    ///     transports that do not surface one.
    ///   - activeCallConversationId: conversation of the in-progress call.
    static func isAdmissible(
        kind: Kind,
        otherMemberKeys: [String],
        structurallyDirect: Bool,
        senderKey: String,
        activeCallConversationId: String?,
        conversationId: String
    ) -> Bool {
        let peers = Array(Set(otherMemberKeys.filter { !$0.isEmpty }))
        if peers.isEmpty {
            // No roster to judge. Admit only when the transport itself makes
            // the conversation 2-party; otherwise we are back to "any group
            // member can drive a call".
            if !structurallyDirect { return false }
        } else {
            // Calls are 2-party: more than one other member means no
            // unambiguous peer, so nothing in that conversation may drive
            // call state — not even a decline reply, which would leak
            // presence to every member.
            guard peers.count == 1, let peer = peers.first else { return false }
            // The line must come FROM that peer. Membership alone is what made
            // the group hijack work.
            //
            // A named sender must BE the peer.
            //
            // A blank sender is a refusal only when the roster is the sole
            // proof of 2-party-ness. Checking the sender merely "when we can
            // see who sent it" was a fail-open: a Marmot message whose author
            // we cannot canonicalize proves nothing, and admitting it hands the
            // supplied endpoint control of the call — mic and camera — under
            // the peer's name.
            //
            // But refusing EVERY blank sender over-corrects: a mesh chat is
            // keyed by the peer, so the transport itself proves 2-party-ness,
            // and the caller still passes a roster for it because a folded
            // conversation resolves the Marmot leg's members. A Bitchat peer
            // with no npub yet would then have its calls dropped. When the
            // transport is structurally direct, absent author identity is fine.
            if !senderKey.isEmpty {
                if senderKey != peer { return false }
            } else if !structurallyDirect {
                return false
            }
        }
        switch kind {
        case .offer:
            return true
        case .answer, .cancel, .end:
            // These act on an in-progress call, which callId alone used to
            // gate. Require the same conversation, so a matching id learned
            // elsewhere cannot steer it.
            guard let active = activeCallConversationId else { return false }
            return active == conversationId
        }
    }
}
