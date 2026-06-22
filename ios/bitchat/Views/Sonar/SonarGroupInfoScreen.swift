//
// SonarGroupInfoScreen.swift
// bitchat
//
// Group info screen: encryption banner, member list with crown/you badges,
// inline add-member field, leave group with confirmation. Ported from the
// Compose Multiplatform SonarGroupInfoScreen.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SonarCore
import SwiftUI

struct SonarGroupInfoScreen: View {
    @EnvironmentObject private var store: SonarAppStore
    let peerId: String

    @State private var addDraft = ""
    @State private var leaveSheet = false
    @State private var inviteLink: String? = nil
    @State private var pendingJoinRequests: [JoinRequestInfo] = []
    @State private var toast: String? = nil

    private var peer: SNPeerItem { store.peerItem(peerId) }
    private var members: [SNGroupContact] { store.groupMemberContacts(forConversationId: peerId) }

    private var groupTitle: String {
        let row = store.dmRows.first { $0.id == peerId }
        return row?.title ?? peer.name
    }

    var body: some View {
        VStack(spacing: 0) {
            SNNavHeader(hairline: false, onBack: { store.pop() }) {
                SNHeaderName("Group info")
            }

            ScrollView {
                VStack(spacing: 0) {
                    // ── Hero ──
                    VStack(spacing: 0) {
                        SonarAvatar(name: groupTitle, size: 80)
                        Text(verbatim: groupTitle)
                            .font(SonarTheme.uiFont(size: 22, weight: .black))
                            .foregroundColor(SonarTheme.text)
                            .padding(.top, 8)
                        Text(verbatim: "\(members.count + 1) members")
                            .font(SonarTheme.uiFont(size: 14))
                            .foregroundColor(SonarTheme.text2)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .padding(.bottom, 16)

                    // ── Encryption banner ──
                    SNBanner(
                        icon: .lock, tone: .enc,
                        bold: "End-to-end encrypted",
                        rest: " — only group members can read messages"
                    )
                    .padding(.bottom, 8)

                    // ── Invite link ──
                    SNSectionLabel("Invite link")
                    if let link = inviteLink {
                        // QR of the universal link — scan in person to request to join.
                        SNSettingsCard {
                            VStack(spacing: 12) {
                                QRCodeImage(data: InviteShare.universalLink(link), size: 196)
                                Text(verbatim: InviteShare.preview(link))
                                    .font(SonarTheme.uiFont(size: 12.5))
                                    .foregroundColor(SonarTheme.text3)
                                HStack(spacing: 10) {
                                    Button {
                                        copyInviteLink(link)
                                        showToast("Invite link copied")
                                    } label: {
                                        inviteActionLabel(icon: .copy, text: "Copy",
                                                          fg: SonarTheme.text, bg: SonarTheme.surface2)
                                    }
                                    .buttonStyle(SNScaleStyle(scale: 0.97))

                                    ShareLink(item: InviteShare.universalLink(link)) {
                                        inviteActionLabel(icon: .share, text: "Share",
                                                          fg: SonarTheme.onAccent, bg: SonarTheme.accentFill)
                                    }
                                    .buttonStyle(SNScaleStyle(scale: 0.97))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(EdgeInsets(top: 16, leading: 14, bottom: 14, trailing: 14))
                        }
                    } else {
                        SNSettingsCard {
                            SNSettingsRow(
                                icon: .link, tone: .cyan,
                                label: "Create invite link",
                                sub: "Share a link or QR code to let people request to join",
                                trail: .chevron, divider: false
                            ) {
                                guard let groupId = store.marmotGroupId(peerId) else { return }
                                Task { @MainActor in
                                    do {
                                        let link = try await store.marmot.createInviteLink(
                                            groupId: groupId, groupName: groupTitle
                                        )
                                        inviteLink = link
                                        copyInviteLink(link)
                                        showToast("Invite link created and copied")
                                    } catch {
                                        showToast("Couldn't create link: \(error.localizedDescription)")
                                    }
                                }
                            }
                        }
                    }

                    if !pendingJoinRequests.isEmpty {
                        SNSectionLabel("Join requests")
                        SNSettingsCard {
                            ForEach(Array(pendingJoinRequests.enumerated()), id: \.element.requesterNpub) { index, request in
                                PendingJoinRequestRow(
                                    request: request,
                                    divider: index < pendingJoinRequests.count - 1,
                                    approve: { approveJoinRequest(request) },
                                    decline: { declineJoinRequest(request) }
                                )
                            }
                        }
                    }

                    // ── Members ──
                    SNSectionLabel("Members")
                    SNSettingsCard {
                        // "You" row
                        HStack(spacing: 12) {
                            SonarAvatar(name: store.nick.isEmpty ? "you" : store.nick, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(verbatim: store.nick.isEmpty ? "you" : store.nick)
                                        .font(SonarTheme.uiFont(size: 15.5, weight: .semibold))
                                        .foregroundColor(SonarTheme.text)
                                    Text("you")
                                        .font(SonarTheme.uiFont(size: 11, weight: .bold))
                                        .foregroundColor(SonarTheme.accentDeep)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(SonarTheme.accentSoft))
                                }
                                Text(verbatim: SonarAppStore.shortNpub(store.marmot.npub ?? ""))
                                    .font(SonarTheme.uiFont(size: 12.5))
                                    .foregroundColor(SonarTheme.text2)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(SonarTheme.hairline).frame(height: 1).padding(.leading, 64)
                        }

                        // Other members
                        ForEach(Array(members.enumerated()), id: \.element.id) { i, member in
                            Button {
                                store.push(.contactProfile(member.npub, member.title))
                            } label: {
                                HStack(spacing: 12) {
                                    SonarAvatar(name: member.title, size: 38)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: member.title)
                                            .font(SonarTheme.uiFont(size: 15.5, weight: .semibold))
                                            .foregroundColor(SonarTheme.text)
                                            .lineLimit(1)
                                        Text(verbatim: member.subtitle)
                                            .font(SonarTheme.uiFont(size: 12.5))
                                            .foregroundColor(SonarTheme.text2)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    SNIcon(name: .chevron, size: 14, weight: 2.2)
                                        .foregroundColor(SonarTheme.text3)
                                }
                                .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
                                .contentShape(Rectangle())
                                .overlay(alignment: .bottom) {
                                    if i < members.count - 1 {
                                        Rectangle().fill(SonarTheme.hairline).frame(height: 1).padding(.leading, 64)
                                    }
                                }
                            }
                            .buttonStyle(SNRowPressStyle())
                        }
                    }

                    // ── Add member ──
                    SNSectionLabel("Add member")
                    HStack(spacing: 8) {
                        TextField(
                            "",
                            text: $addDraft,
                            prompt: Text(verbatim: "npub1\u{2026}").foregroundColor(SonarTheme.text3)
                        )
                        .textFieldStyle(.plain)
                        .font(SonarTheme.monoFont(size: 13))
                        .foregroundColor(SonarTheme.text)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))

                        Button {
                            let npub = addDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard npub.hasPrefix("npub1"),
                                  let groupId = store.marmotGroupId(peerId) else { return }
                            addDraft = ""
                            Task { try? await store.marmot.addGroupMembers([npub], to: groupId) }
                        } label: {
                            SNIcon(name: .plus, size: 19, weight: 2.1)
                                .foregroundColor(addDraft.hasPrefix("npub1") ? SonarTheme.onAccent : SonarTheme.text3)
                                .frame(width: 42, height: 42)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(addDraft.hasPrefix("npub1") ? SonarTheme.accentFill : SonarTheme.surface2)
                                )
                        }
                        .buttonStyle(SNScaleStyle(scale: 0.94))
                        .disabled(!addDraft.hasPrefix("npub1"))
                    }
                    .padding(.horizontal, 14)

                    // ── Actions ──
                    SNSectionLabel("Actions")
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: .trash, tone: .red, label: "Leave group",
                            danger: true, trail: .none, divider: false
                        ) {
                            leaveSheet = true
                        }
                    }

                    Color.clear.frame(height: 40)
                }
            }
        }
        .background(SonarTheme.bg.ignoresSafeArea())
        .overlay(alignment: .bottom) { toastView }
        .animation(.easeOut(duration: 0.2), value: toast)
        .task(id: peerId) { await loadPendingJoinRequests() }
        .snSheet(isPresented: $leaveSheet, title: "Leave group") {
            VStack(spacing: 12) {
                Text("Are you sure you want to leave this group? You won\u{2019}t be able to read or send messages anymore.")
                    .font(SonarTheme.uiFont(size: 14))
                    .lineSpacing(14 * 0.3)
                    .foregroundColor(SonarTheme.text2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                SNPrimaryButton(label: "Leave group", danger: true) {
                    leaveSheet = false
                    if let groupId = store.marmotGroupId(peerId) {
                        Task { try? await store.marmot.leaveGroup(groupId) }
                    }
                    store.pop()
                    store.pop()
                }
                .padding(.horizontal, 8)
                SNGhostButton(label: "Cancel") {
                    leaveSheet = false
                }
            }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(verbatim: toast)
                .font(SonarTheme.uiFont(size: 13.5, weight: .semibold))
                .foregroundColor(SonarTheme.onAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(SonarTheme.accentFill))
                .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func showToast(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toast == text { toast = nil }
        }
    }

    private func inviteActionLabel(icon: SNIconName, text: String, fg: Color, bg: Color) -> some View {
        HStack(spacing: 7) {
            SNIcon(name: icon, size: 17, weight: 2)
            Text(verbatim: text)
                .font(SonarTheme.uiFont(size: 14.5, weight: .bold))
        }
        .foregroundColor(fg)
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(bg))
    }

    private func copyInviteLink(_ token: String) {
        let url = InviteShare.universalLink(token)
        #if os(iOS)
        UIPasteboard.general.string = url
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        #endif
    }

    @MainActor
    private func loadPendingJoinRequests() async {
        guard let groupId = store.marmotGroupId(peerId) else {
            pendingJoinRequests = []
            return
        }
        do {
            pendingJoinRequests = try await store.marmot.pendingJoinRequests(groupId: groupId)
        } catch {
            showToast("Couldn't load join requests: \(error.localizedDescription)")
        }
    }

    private func approveJoinRequest(_ request: JoinRequestInfo) {
        guard let groupId = store.marmotGroupId(peerId) else { return }
        Task { @MainActor in
            do {
                try await store.marmot.approveJoinRequest(groupId: groupId, requesterNpub: request.requesterNpub)
                pendingJoinRequests.removeAll { $0.requesterNpub == request.requesterNpub }
                showToast("Member added")
                await loadPendingJoinRequests()
            } catch {
                showToast("Couldn't approve: \(error.localizedDescription)")
            }
        }
    }

    private func declineJoinRequest(_ request: JoinRequestInfo) {
        guard let groupId = store.marmotGroupId(peerId) else { return }
        Task { @MainActor in
            do {
                try await store.marmot.declineJoinRequest(groupId: groupId, requesterNpub: request.requesterNpub)
                pendingJoinRequests.removeAll { $0.requesterNpub == request.requesterNpub }
                showToast("Request declined")
            } catch {
                showToast("Couldn't decline: \(error.localizedDescription)")
            }
        }
    }
}

private struct PendingJoinRequestRow: View {
    let request: JoinRequestInfo
    let divider: Bool
    let approve: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(SonarTheme.greenSoft)
                    SNIcon(name: .plus, size: 18)
                        .foregroundColor(SonarTheme.green)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Join request")
                        .font(SonarTheme.uiFont(size: 15.5, weight: .semibold))
                        .foregroundColor(SonarTheme.text)
                    Text(verbatim: shortRequester(request.requesterNpub))
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(SonarTheme.text3)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    SNSmallButton(label: "Decline", expand: false, action: decline)
                    SNSmallButton(label: "Approve", primary: true, expand: false, action: approve)
                }
            }
            .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
            .overlay(alignment: .bottom) {
                if divider {
                    Rectangle().fill(SonarTheme.hairline).frame(height: 1).padding(.leading, 62)
                }
            }
        }
    }

    private func shortRequester(_ value: String) -> String {
        value.count <= 16 ? value : "\(value.prefix(10))…\(value.suffix(6))"
    }
}
