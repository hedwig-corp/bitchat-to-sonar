//
// SonarShareSheet.swift
// bitchat
//
// "Send to…" recipient picker for content arriving from the system share sheet.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Recipient picker shown when the share extension hands content to the app.
///
/// Deliberately a picker rather than an auto-send: sharing a link used to go
/// straight into whatever chat happened to be selected, which with nothing
/// selected meant broadcasting to the public mesh.
struct SNShareSheetContent: View {
    @EnvironmentObject private var store: SonarAppStore
    let share: SNPendingShare
    let onClose: () -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var rows: [SNDMRow] {
        let all = store.dmRows
        guard !normalizedQuery.isEmpty else { return all }
        return all.filter {
            "\($0.title) \($0.preview)".lowercased().contains(normalizedQuery)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            preview
            searchField
            ScrollView {
                VStack(spacing: 0) {
                    if rows.isEmpty {
                        SNEmptyState(
                            icon: normalizedQuery.isEmpty ? .people : .search,
                            iconSize: 22,
                            title: normalizedQuery.isEmpty ? "No chats yet" : "No results",
                            desc: normalizedQuery.isEmpty
                                ? "Start a chat first, then share into it."
                                : "No chat matches that name."
                        )
                        .padding(.vertical, 18)
                    } else {
                        ForEach(rows) { row in
                            SNActionRow(
                                icon: row.presence ? .mesh : .lock,
                                label: row.title,
                                desc: row.preview
                            ) {
                                store.sendPendingShare(to: row.id)
                                onClose()
                            }
                        }
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(maxHeight: 360)
        }
        .onAppear {
            // No autofocus: the list is the primary action here, and raising
            // the keyboard would bury it behind the composer.
            focused = false
        }
    }

    /// What is about to be sent. Files show as a name list rather than
    /// thumbnails — the bytes are staged in the App Group and decoding them
    /// for a preview would pull the whole payload into memory.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let text = share.text, !text.isEmpty {
                Text(verbatim: text)
                    .font(SonarTheme.uiFont(size: 14))
                    .foregroundColor(SonarTheme.text)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            if !share.items.isEmpty {
                ForEach(share.items) { item in
                    HStack(spacing: 8) {
                        SNIcon(name: .data, size: 14, weight: 2)
                            .foregroundColor(SonarTheme.text3)
                        Text(verbatim: item.filename)
                            .font(SonarTheme.uiFont(size: 13))
                            .foregroundColor(SonarTheme.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(verbatim: SNShareByteCount.string(item.byteCount))
                            .font(SonarTheme.uiFont(size: 12))
                            .foregroundColor(SonarTheme.text3)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
        .padding(EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 0))
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            SNIcon(name: .search, size: 17, weight: 2.2)
                .foregroundColor(SonarTheme.text3)
            TextField(
                "",
                text: $query,
                prompt: Text("Search chats").foregroundColor(SonarTheme.text3)
            )
            .textFieldStyle(.plain)
            .font(SonarTheme.uiFont(size: 16))
            .foregroundColor(SonarTheme.text)
            .focused($focused)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SonarTheme.surface2))
        .padding(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
    }
}

/// Short human byte counts for the share preview.
enum SNShareByteCount {
    static func string(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
