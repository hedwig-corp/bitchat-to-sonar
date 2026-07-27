//
// SonarShareIntake.swift
// bitchat
//
// App side of the iOS share extension hand-off: pick up staged payloads,
// let the user choose a chat, send.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// A staged share plus the resolved on-disk URLs of its files, ready for the
/// recipient picker.
struct SNPendingShare: Identifiable, Equatable {
    let payload: SonarSharePayload
    let fileURLs: [URL]

    var id: String { payload.id }
    var text: String? { payload.text }
    var items: [SonarSharedItem] { payload.items }

    var summary: String {
        if let text, !text.isEmpty { return text }
        if items.count == 1 { return items[0].filename }
        return "\(items.count) files"
    }
}

extension SonarAppStore {
    /// The App Group both processes agree on. Read from the build-injected
    /// Info.plist value rather than derived from the bundle id, which drifts
    /// as soon as a dev build overrides one and not the other.
    static var shareAppGroupID: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String
            ?? MarmotAppGroupStore.appGroupId
    }

    /// Pick up anything the share extension staged. Safe to call repeatedly —
    /// foreground, `sonar://share` open, and cold launch all funnel here.
    ///
    /// Never sends on its own. The old behaviour blind-sent into whatever chat
    /// happened to be selected, which with no selection meant broadcasting the
    /// user's shared link to the public mesh.
    func ingestPendingShares() {
        // Before onboarding there is no identity to send from — leave the
        // payload staged rather than dropping it.
        guard onboarded else { return }
        // A picker is already up; the next scan happens after it resolves.
        guard pendingShare == nil else { return }

        let groupID = Self.shareAppGroupID
        let payloads = SonarShareInbox.pendingPayloads(appGroupID: groupID)
            .filter { !inFlightSharePayloadIDs.contains($0.id) }
        guard let payload = payloads.first else {
            ingestLegacySharedContent()
            return
        }

        // A Sonar invite link shared back into Sonar means "join", not "send" —
        // asking the user to pick a recipient for it would be nonsense.
        if payload.items.isEmpty,
           let text = payload.text,
           let token = InviteShare.token(fromText: text) {
            SonarShareInbox.discard(payload.id, appGroupID: groupID)
            submitInviteLink(token)
            rescanPendingSharesAfterDismiss()
            return
        }

        pendingShare = SNPendingShare(
            payload: payload,
            fileURLs: SonarShareInbox.fileURLs(for: payload, appGroupID: groupID)
        )
    }

    /// Payloads written by a build that predates `SonarSharePayload`. Routed
    /// through the same picker instead of the old blind send, so an in-flight
    /// upgrade cannot broadcast to the mesh either.
    private func ingestLegacySharedContent() {
        guard let defaults = UserDefaults(suiteName: Self.shareAppGroupID),
              let content = defaults.string(forKey: "sharedContent")
        else {
            return
        }
        // Read the timestamp before clearing the keys so a payload staged days
        // ago (e.g. before an app upgrade) is not re-offered as a fresh share.
        let writtenAt = defaults.object(forKey: "sharedContentDate") as? Date
        defaults.removeObject(forKey: "sharedContent")
        defaults.removeObject(forKey: "sharedContentType")
        defaults.removeObject(forKey: "sharedContentDate")

        // Older than the SonarShareInbox staleness window: the keys are cleared
        // but the payload is dropped instead of being offered again.
        if let writtenAt, Date().timeIntervalSince(writtenAt) > SonarShareInbox.staleAfterSeconds {
            return
        }

        // A shared invite link means "join", not "send" — same as before.
        if let token = InviteShare.token(fromText: content) {
            submitInviteLink(token)
            return
        }
        // The legacy URL type wrapped the link in a JSON envelope.
        var text = content
        if let data = content.data(using: .utf8),
           let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let url = envelope["url"] {
            text = url
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingShare = SNPendingShare(
            payload: SonarSharePayload(text: text, items: []),
            fileURLs: []
        )
    }

    /// User dismissed the picker: drop the payload and its staged files.
    func cancelPendingShare() {
        guard let share = pendingShare else { return }
        pendingShare = nil
        SonarShareInbox.discard(share.payload.id, appGroupID: Self.shareAppGroupID)
        rescanPendingSharesAfterDismiss()
    }

    /// Pick up a payload queued behind the one just resolved — but only once
    /// the sheet has actually gone. Re-presenting during the dismiss animation
    /// leaves SwiftUI with a sheet that never appears.
    func rescanPendingSharesAfterDismiss() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            self?.ingestPendingShares()
        }
    }

    /// Send the pending share into `conversationID`, then open that chat.
    ///
    /// Text goes first so a link with attachments reads as a caption above its
    /// files, matching how the composer orders a send.
    func sendPendingShare(to conversationID: String) {
        guard let share = pendingShare else { return }
        pendingShare = nil

        let groupID = Self.shareAppGroupID
        let payloadID = share.payload.id
        inFlightSharePayloadIDs.insert(payloadID)
        let text = share.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileURLs = share.fileURLs
        let droppedCount = share.payload.droppedCount
        // The read budget is the ceiling of what ANY route can carry — not what
        // the mesh alone supports. `sendAttachment` chooses mesh vs the encrypted
        // White Noise route and already falls back to White Noise for payloads
        // that exceed the mesh file-packet limit. Capping the read here with the
        // lower mesh limit would reject an oversized photo before that fallback
        // could run: a large share to a mesh-reachable peer that ALSO has an
        // internet route would be silently dropped instead of sent. Android reads
        // with the internet ceiling for the same reason.
        let limit = SonarShareInbox.maxStagedBytes

        openDM(conversationID)

        if let text, !text.isEmpty {
            sendDm(conversationID, text)
        }

        guard !fileURLs.isEmpty else {
            inFlightSharePayloadIDs.remove(payloadID)
            SonarShareInbox.discard(payloadID, appGroupID: groupID)
            if droppedCount > 0 {
                showToast("\(droppedCount) file\(droppedCount == 1 ? "" : "s") couldn't be attached")
            }
            return
        }

        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                snReadAttachments(fileURLs, maxTotalBytes: limit)
            }.value

            guard !result.attachments.isEmpty else {
                showToast(result.oversizedCount > 0
                    ? "File is too large to send"
                    : "Couldn't attach that file")
                // Too large or unreadable is not transient — a retry against a
                // different recipient would fail identically, so drop the
                // staged copies rather than leaking them until the 24h prune.
                SonarShareInbox.discard(payloadID, appGroupID: groupID)
                inFlightSharePayloadIDs.remove(payloadID)
                return
            }

            // Restoring the picker after a route failure must NOT re-offer the
            // text: it was already sent above, and a second pick would deliver
            // it twice. Only the files are still pending.
            let filesOnlyRetry = SNPendingShare(
                payload: SonarSharePayload(
                    version: share.payload.version,
                    id: share.payload.id,
                    createdAt: share.payload.createdAt,
                    text: nil,
                    items: share.payload.items,
                    droppedCount: share.payload.droppedCount
                ),
                fileURLs: fileURLs
            )

            switch await prepareMediaRoute(conversationID) {
            case .ready:
                break
            case .unavailable:
                showToast("This contact must be online to receive files")
                // Transient failure — keep the staged files and restore the
                // picker so the user can retry instead of losing the payload.
                inFlightSharePayloadIDs.remove(payloadID)
                pendingShare = filesOnlyRetry
                return
            case .failed:
                showToast("Couldn't set up a secure file transfer")
                inFlightSharePayloadIDs.remove(payloadID)
                pendingShare = filesOnlyRetry
                return
            }

            var sent = 0
            for attachment in result.attachments {
                if sendAttachment(
                    conversationID,
                    data: attachment.data,
                    filename: attachment.filename,
                    mime: attachment.mime
                ) {
                    sent += 1
                }
            }
            // At least one send was attempted, so the staged copies are now dead
            // weight — discard only after the loop, never on a route failure.
            SonarShareInbox.discard(payloadID, appGroupID: groupID)
            inFlightSharePayloadIDs.remove(payloadID)
            // `droppedCount` covers what the extension could not stage at all,
            // so a partly-delivered multi-file share never looks complete.
            let offered = result.attachments.count + result.rejectedCount + droppedCount
            if sent == 0 {
                showToast("Couldn't send — start the secure chat first.")
            } else if sent < offered {
                showToast("Sent \(sent) of \(offered) files")
            }
        }
    }

}
