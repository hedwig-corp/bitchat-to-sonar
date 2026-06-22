//
// NostrRelayURLCanonicalizationTests.swift
// bitchatTests
//
// Verifies that relay URLs that refer to the same relay under different spellings
// (explicit default port, trailing slash, host case) collapse to one canonical key.
// Without this, a relay added as both "wss://host:443" and "wss://host" is connected
// and subscribed twice, doubling traffic and delaying sync.
//

import Testing
@testable import Sonar

struct NostrRelayURLCanonicalizationTests {

    @Test func stripsDefaultWssPort() {
        #expect(NostrRelayManager.canonicalRelayURL("wss://nostr.hifish.org:443") == "wss://nostr.hifish.org")
    }

    @Test func stripsDefaultWsPort() {
        #expect(NostrRelayManager.canonicalRelayURL("ws://relay.local:80") == "ws://relay.local")
    }

    @Test func preservesNonDefaultPort() {
        #expect(NostrRelayManager.canonicalRelayURL("wss://nas01.synology.me:7778") == "wss://nas01.synology.me:7778")
    }

    @Test func stripsTrailingSlash() {
        #expect(NostrRelayManager.canonicalRelayURL("wss://relay.damus.io/") == "wss://relay.damus.io")
    }

    @Test func lowercasesSchemeAndHost() {
        #expect(NostrRelayManager.canonicalRelayURL("WSS://Relay.Example.COM") == "wss://relay.example.com")
    }

    @Test func trimsWhitespace() {
        #expect(NostrRelayManager.canonicalRelayURL("  wss://relay.example.com:443/  ") == "wss://relay.example.com")
    }

    @Test func preservesNonRootPath() {
        #expect(NostrRelayManager.canonicalRelayURL("wss://relay.example.com/v2") == "wss://relay.example.com/v2")
    }

    /// The exact duplication observed on-device: the two spellings must produce the
    /// same canonical key so they dedupe to a single connection/subscription.
    @Test func portAndBareSpellingsCollapse() {
        let withPort = NostrRelayManager.canonicalRelayURL("wss://nostr.sathoarder.com:443")
        let bare = NostrRelayManager.canonicalRelayURL("wss://nostr.sathoarder.com")
        #expect(withPort == bare)
    }

    /// Malformed input should pass through (trimmed) rather than crash or drop the relay.
    @Test func passesThroughUnparseableInput() {
        #expect(NostrRelayManager.canonicalRelayURL("not a url") == "not a url")
    }
}
