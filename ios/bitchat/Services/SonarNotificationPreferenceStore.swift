//
// SonarNotificationPreferenceStore.swift
// bitchat
//
// Shared read path for notification privacy prefs (main app + push processor).
// Values are mirrored into the App Group by SonarAppStore so the NSE can
// read the same keys for enable/suppress.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

enum SonarNotificationPreferenceStore {
    static let appGroupId = "group.sh.hedwig.sonar"
    static let enabledKey = "sonar.notifications.enabled"
    static let showNamesKey = "sonar.notifications.showNames"
    static let showPreviewKey = "sonar.notifications.showPreview"
    static let showPaymentAmountKey = "sonar.notifications.showPaymentAmount"

    /// Default for "show payment amounts": follow the message-preview choice.
    ///
    /// This used to be a hardcoded `true` at every construction site, so a user
    /// who turned message previews OFF still had "21,000 sats received from
    /// Alice." on their lock screen — a strictly larger leak than the message
    /// text they had already asked to hide. Hiding your chats and broadcasting
    /// your balance is not a coherent state.
    ///
    /// Signal never lets an amount reach the notification layer at all (its
    /// payment notification is the fixed string "💳 Payment"). Sonar shows the
    /// amount deliberately — money should read as money — which means Sonar
    /// owns the gate Signal gets for free. Inheriting `showPreview` keeps the
    /// promise the user already made, and existing installs that hid previews
    /// stop leaking on upgrade without being asked again.
    static func resolvedShowPaymentAmount(
        _ defaults: UserDefaults,
        showPreview: Bool
    ) -> Bool {
        defaults.object(forKey: showPaymentAmountKey) as? Bool ?? showPreview
    }

    /// Load prefs from the given defaults suite. Defaults match Settings:
    /// notifications on, names on, message preview off, amounts follow preview.
    static func load(from defaults: UserDefaults = .standard) -> SonarLocalNotificationPrefs {
        let showPreview = defaults.object(forKey: showPreviewKey) as? Bool ?? false
        return SonarLocalNotificationPrefs(
            enabled: defaults.object(forKey: enabledKey) as? Bool ?? true,
            showNames: defaults.object(forKey: showNamesKey) as? Bool ?? true,
            showPreview: showPreview,
            showPaymentAmount: resolvedShowPaymentAmount(defaults, showPreview: showPreview)
        )
    }

    /// Prefer standard (where Settings writes), fall back to the App Group
    /// mirror so a push-wake that races ahead of a sync still sees toggles.
    static func loadMerged() -> SonarLocalNotificationPrefs {
        let standard = load(from: .standard)
        guard let shared = UserDefaults(suiteName: appGroupId) else { return standard }
        // If the user has never toggled in this process, standard may still
        // be the default while the App Group holds an earlier explicit choice.
        let sharedNames = shared.object(forKey: showNamesKey) as? Bool
        let sharedPreview = shared.object(forKey: showPreviewKey) as? Bool
        let sharedEnabled = shared.object(forKey: enabledKey) as? Bool
        let sharedAmount = shared.object(forKey: showPaymentAmountKey) as? Bool
        let standardTouchedNames = UserDefaults.standard.object(forKey: showNamesKey) != nil
        let standardTouchedPreview = UserDefaults.standard.object(forKey: showPreviewKey) != nil
        let standardTouchedEnabled = UserDefaults.standard.object(forKey: enabledKey) != nil
        let standardTouchedAmount = UserDefaults.standard.object(forKey: showPaymentAmountKey) != nil
        let showPreview = standardTouchedPreview
            ? standard.showPreview
            : (sharedPreview ?? standard.showPreview)
        return SonarLocalNotificationPrefs(
            enabled: standardTouchedEnabled ? standard.enabled : (sharedEnabled ?? standard.enabled),
            showNames: standardTouchedNames ? standard.showNames : (sharedNames ?? standard.showNames),
            showPreview: showPreview,
            // Resolve against the MERGED preview value, not `standard`'s: an
            // untouched amount key inherits the preview choice, and taking that
            // from the un-merged copy would ignore an App Group value the user
            // set before this process started.
            showPaymentAmount: standardTouchedAmount
                ? standard.showPaymentAmount
                : (sharedAmount ?? showPreview)
        )
    }
}
