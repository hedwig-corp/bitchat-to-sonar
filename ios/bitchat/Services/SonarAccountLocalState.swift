import Foundation

/// Per-account host values that a switch sets aside instead of deleting.
///
/// A switch is not a restore: the account being left must find its local
/// state again when the user comes back. Most host state is device-level and
/// simply stays where it is (mesh transcripts, verification marks, mutes, the
/// payment-bubble ledger, peer profiles, the media cache: the BLE/Noise
/// identity is shared by every account on the phone). The few values that
/// belong to ONE account — its nickname, its handle, its cellular-backup
/// consent, its wallet activity, its call log — are copied into a per-account
/// record before the teardown resets them, and copied back when that account
/// becomes active again.
///
/// Crash safety: the record is one UserDefaults value. `park` writes it
/// BEFORE the live values are reset, the store applies a record BEFORE it
/// clears it, and every launch replays a record left for the active account
/// (`SonarAppStore.recoverParkedAccountStateIfNeeded`). A crash anywhere in a
/// switch therefore either finds the live values untouched or finds a
/// complete record to replay.
///
/// Mirror of Compose `AccountLocalStateParking`; keep the value lists in step.
enum SonarAccountLocalState {
    static let recordPrefix = "sonar.accounts.parked."

    static func recordKey(_ pubkeyHex: String) -> String {
        recordPrefix + pubkeyHex.lowercased()
    }

    /// The live values of `keys`, absent ones omitted.
    static func capture(keys: [String], from defaults: UserDefaults) -> [String: Any] {
        var record: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) { record[key] = value }
        }
        return record
    }

    /// Store `record` as `pubkeyHex`'s parked state, replacing an older one.
    static func park(_ record: [String: Any], for pubkeyHex: String, defaults: UserDefaults) {
        defaults.set(record, forKey: recordKey(pubkeyHex))
    }

    /// `pubkeyHex`'s parked state, or nil when it has none (a first visit).
    static func record(for pubkeyHex: String, defaults: UserDefaults) -> [String: Any]? {
        defaults.dictionary(forKey: recordKey(pubkeyHex))
    }

    /// Write `record` into the live `keys`. A key the record does not name is
    /// removed: the live slot must never keep the previous account's value.
    static func apply(_ record: [String: Any], keys: [String], to defaults: UserDefaults) {
        for key in keys {
            if let value = record[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    static func clearRecord(for pubkeyHex: String, defaults: UserDefaults) {
        defaults.removeObject(forKey: recordKey(pubkeyHex))
    }

    /// Panic wipe: every account's parked state goes with the accounts.
    static func discardAll(defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(recordPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
