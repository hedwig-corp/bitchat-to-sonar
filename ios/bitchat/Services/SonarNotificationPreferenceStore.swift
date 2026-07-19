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

    /// Load prefs from the given defaults suite. Defaults match Settings:
    /// notifications on, names on, message preview off.
    static func load(from defaults: UserDefaults = .standard) -> SonarLocalNotificationPrefs {
        SonarLocalNotificationPrefs(
            enabled: defaults.object(forKey: enabledKey) as? Bool ?? true,
            showNames: defaults.object(forKey: showNamesKey) as? Bool ?? true,
            showPreview: defaults.object(forKey: showPreviewKey) as? Bool ?? false,
            showPaymentAmount: true
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
        let standardTouchedNames = UserDefaults.standard.object(forKey: showNamesKey) != nil
        let standardTouchedPreview = UserDefaults.standard.object(forKey: showPreviewKey) != nil
        let standardTouchedEnabled = UserDefaults.standard.object(forKey: enabledKey) != nil
        return SonarLocalNotificationPrefs(
            enabled: standardTouchedEnabled ? standard.enabled : (sharedEnabled ?? standard.enabled),
            showNames: standardTouchedNames ? standard.showNames : (sharedNames ?? standard.showNames),
            showPreview: standardTouchedPreview ? standard.showPreview : (sharedPreview ?? standard.showPreview),
            showPaymentAmount: true
        )
    }
}
