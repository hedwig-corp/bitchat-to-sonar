//
// OSLog+Categories.swift
// BitLogger
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if canImport(os.log)
import os.log
#endif

public extension OSLog {
    private static let subsystem = "chat.bitchat"

    static let noise        = OSLog(subsystem: subsystem, category: "noise")
    static let encryption   = OSLog(subsystem: subsystem, category: "encryption")
    static let keychain     = OSLog(subsystem: subsystem, category: "keychain")
    static let session      = OSLog(subsystem: subsystem, category: "session")
    static let security     = OSLog(subsystem: subsystem, category: "security")
    static let handshake    = OSLog(subsystem: subsystem, category: "handshake")
    static let sync         = OSLog(subsystem: subsystem, category: "sync")

    /// Category label for the diagnostics file sink. `os.OSLog` does not
    /// expose its category, so map the known BitLogger instances back to
    /// their names (identity comparison — these are the only ones used).
    var categoryName: String {
        switch self {
        case .noise: return "noise"
        case .encryption: return "encryption"
        case .keychain: return "keychain"
        case .session: return "session"
        case .security: return "security"
        case .handshake: return "handshake"
        case .sync: return "sync"
        default: return "app"
        }
    }
}
