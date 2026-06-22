//
// InviteShare.swift
// bitchat
//
// Shareable group-invite link helpers, mirrored from the Compose app's
// InviteShare.kt so both platforms emit and parse the same forms.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Builders + parsing for shareable group invite links.
///
/// The payload lives in the URL **fragment** of the universal link
/// (`https://<host>/join#sinvite1…`) so it is never sent to the host — same
/// client-side privacy property as the bare token, while the https URL
/// linkifies in other apps and (once the domain serves the Universal Links
/// association file) opens Sonar directly. The Rust core re-normalizes any of
/// these forms, so parsing here only needs to extract the candidate string.
enum InviteShare {
    /// Host backing the universal link. Single switch for the domain in code —
    /// every client surface works before it is live; only browser auto-open waits
    /// on hosting `.well-known/apple-app-site-association` and adding the
    /// `applinks:` associated-domains entitlement. See `web/README.md`.
    ///
    /// NOTE: `bitchat.entitlements` (`applinks:…`) and the Android manifest
    /// hardcode this same host and must be kept in sync if it changes.
    static let joinLinkHost = "sonarprivacy.xyz"

    /// Shareable universal link — preferred form (linkifies, travels across apps).
    static func universalLink(_ token: String) -> String {
        "https://\(joinLinkHost)/join#\(token)"
    }

    /// Legacy custom-scheme link — kept as a backward-compatible alias (PR #89).
    static func deepLink(_ token: String) -> String {
        "sonar://invite/\(token)"
    }

    /// Human-readable preview for a settings row sub-label.
    static func preview(_ token: String) -> String {
        "\(joinLinkHost)/join#…\(String(token.suffix(6)))"
    }

    /// Extract a bare `sinvite1…` token from any incoming invite URL form.
    static func token(from url: URL) -> String? {
        if url.scheme == "sonar", url.host == "invite",
           let last = url.pathComponents.last, last.hasPrefix("sinvite1") {
            return last
        }
        if url.scheme == "https" || url.scheme == "http", url.host == joinLinkHost,
           let fragment = url.fragment, fragment.contains("sinvite1") {
            return fragment
        }
        return nil
    }

    /// Extract a token from arbitrary shared/pasted text (clipboard, share sheet).
    static func token(fromText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let token = token(from: url) {
            return token
        }
        // Bare token (possibly with surrounding text) — let the core normalize.
        return trimmed.contains("sinvite1") ? trimmed : nil
    }
}
