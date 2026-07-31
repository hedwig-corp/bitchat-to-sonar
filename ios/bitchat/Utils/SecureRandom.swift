import Foundation

/// CSPRNG bytes with a *checked* status.
///
/// `SecRandomCopyBytes` returns an `OSStatus`, and the buffer handed to it is
/// left untouched when it fails. Since every caller here starts from a
/// zero-filled buffer, discarding that status turns an RNG failure into a
/// silent all-zeros "random" value — a nonce that repeats, or key material that
/// is identical on every device that hits the same failure. Nothing crashes and
/// nothing logs; the crypto just stops being crypto.
///
/// Use these helpers instead of calling `SecRandomCopyBytes` inline. The two
/// pre-existing checked call sites (`SonarWallet.createWallet`,
/// `MarmotService.databaseConfig`) already refuse to fall back — this is the
/// same rule, made reusable so the next nonce does not get it wrong.
enum SecureRandom {

    enum Failure: Error, LocalizedError {
        case rngUnavailable(OSStatus)

        var errorDescription: String? {
            switch self {
            case .rngUnavailable(let status):
                return "system CSPRNG unavailable (OSStatus \(status))"
            }
        }
    }

    /// `count` cryptographically random bytes, or throw.
    ///
    /// Prefer this everywhere the value is a nonce, IV, salt, challenge, or key
    /// material: failing the operation is always better than continuing with a
    /// predictable value.
    static func bytes(_ count: Int) throws -> Data {
        var buf = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &buf)
        guard status == errSecSuccess else {
            throw Failure.rngUnavailable(status)
        }
        return Data(buf)
    }

    /// `count` cryptographically random bytes, or `nil`.
    ///
    /// For call sites that already model failure as an optional/`false` return
    /// rather than a thrown error.
    static func optionalBytes(_ count: Int) -> Data? {
        try? bytes(count)
    }
}
