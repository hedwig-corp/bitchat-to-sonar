//
// NoiseSecurityValidator.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

struct NoiseSecurityValidator {
    
    /// Validate message size
    static func validateMessageSize(_ data: Data) -> Bool {
        return data.count <= NoiseSecurityConstants.maxMessageSize
    }

    /// Ordinary transport ciphertext: same ceiling as a plaintext.
    static func validateCiphertextSize(_ data: Data) -> Bool {
        return data.count <= NoiseSecurityConstants.maxMessageSize
    }

    /// A `.privateFile` plaintext (type byte included) may exceed the Noise
    /// ceiling up to the framed-file budget.
    static func validatePrivateFileMessageSize(_ data: Data) -> Bool {
        return data.count <= NoiseSecurityConstants.maxPrivateFilePlaintextSize
    }

    /// Ciphertext of a `.privateFile` plaintext.
    static func validatePrivateFileCiphertextSize(_ data: Data) -> Bool {
        return data.count <= NoiseSecurityConstants.maxPrivateFileCiphertextSize
    }

    /// Validate handshake message size
    static func validateHandshakeMessageSize(_ data: Data) -> Bool {
        return data.count <= NoiseSecurityConstants.maxHandshakeMessageSize
    }
}
