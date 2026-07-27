//
// NoiseSessionError.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

enum NoiseSessionError: Error, Equatable {
    case invalidState
    case notEstablished
    case sessionNotFound
    case alreadyEstablished
    /// The handshake authenticated a static key that does not derive the peer
    /// ID the packet claimed to come from.
    case peerIdentityMismatch
}
