//
// SonarSharedProfileNames.swift
// bitchat
//
// App Group mirror of kind-0 bestName labels for the Notification Service
// Extension. Main-app `SNMarmotProfileCache` lives in `.standard` and is
// invisible to the NSE; without this mirror, killed-app Transponder banners
// can only show pubkey fingerprints.
//
// Foundation-only — safe to compile into SonarNotificationService.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

enum SonarSharedProfileNames {
    static let appGroupId = "group.sh.hedwig.sonar"
    static let defaultsKey = "marmot.profileNamesByKey.v1"

    static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupId)
    }

    static func load(from defaults: UserDefaults? = sharedDefaults()) -> [String: String] {
        guard let defaults,
              let data = defaults.data(forKey: defaultsKey),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    static func save(_ names: [String: String], to defaults: UserDefaults? = sharedDefaults()) {
        guard let defaults,
              let data = try? JSONEncoder().encode(names)
        else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func clear(from defaults: UserDefaults? = sharedDefaults()) {
        defaults?.removeObject(forKey: defaultsKey)
    }

    /// Resolve a human alias for a sender npub/hex using the App Group map.
    /// Tries exact then lowercased keys — writers store npub + lowercase hex.
    static func bestName(for sender: String, in names: [String: String]) -> String? {
        let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let name = names[trimmed]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        let lower = trimmed.lowercased()
        if lower != trimmed,
           let name = names[lower]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return nil
    }

    static func bestName(for sender: String) -> String? {
        bestName(for: sender, in: load())
    }
}
