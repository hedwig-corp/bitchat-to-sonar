//
// NoiseDecryptFailureTracker.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Counts consecutive Noise decrypt failures per peer.
///
/// Anyone can emit a packet under any claimed sender ID, so a single AEAD
/// failure is not evidence that our session is out of sync. Tearing a session
/// down on one packet hands an attacker a session-teardown primitive: address a
/// garbage payload as the victim and the victim's session is discarded. Only a
/// run of failures indicates real desync (nonce mismatch, peer restart), and any
/// successful decrypt clears the run.
struct NoiseDecryptFailureTracker {
    private var counts: [PeerID: Int] = [:]
    private let threshold: Int
    private let trackingCap: Int

    init(
        threshold: Int = TransportConfig.noiseDecryptFailuresBeforeSessionReset,
        trackingCap: Int = TransportConfig.noiseDecryptFailureTrackingCap
    ) {
        self.threshold = threshold
        self.trackingCap = trackingCap
    }

    /// Current consecutive-failure count for a peer.
    func failureCount(for peerID: PeerID) -> Int {
        counts[peerID] ?? 0
    }

    /// Records one decrypt failure. Returns `true` when the run has reached the
    /// threshold and the session should be reset, clearing the run so the next
    /// attempt starts fresh.
    mutating func recordFailure(for peerID: PeerID) -> Bool {
        // Bound the map: a flood of unknown sender IDs must not grow it forever.
        if counts[peerID] == nil && counts.count >= trackingCap {
            counts.removeAll()
        }
        let next = (counts[peerID] ?? 0) + 1
        guard next >= threshold else {
            counts[peerID] = next
            return false
        }
        counts.removeValue(forKey: peerID)
        return true
    }

    mutating func recordSuccess(for peerID: PeerID) {
        counts.removeValue(forKey: peerID)
    }

    mutating func removeAll() {
        counts.removeAll()
    }
}
