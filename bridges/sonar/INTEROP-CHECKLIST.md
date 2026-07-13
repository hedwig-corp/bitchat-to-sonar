# Sonar ↔ Beeper release-candidate interop checklist

Record app commits, bridge commit, OS versions, relay set, and the generated account's public `npub`. Never record the `nsec`, SQLCipher key, operator master key, Matrix access token, or decrypted media URL.

For both the native Apple app and Compose app:

- Create the Beeper Sonar login and verify the same generated `npub` survives bridge and daemon restart.
- Start a chat from Beeper with the native peer's exact `npub`; verify the Beeper room appears immediately while relays are disabled.
- In an established direct chat, send two distinct text messages offline, restore relays, and verify ordered single delivery with no duplicates.
- Send text in both directions and verify restart replay produces no duplicate Matrix event.
- Send image, video, ordinary audio, and PDF/file in both directions; verify caption, filename, MIME type, dimensions/duration when available, and payload bytes.
- Send an over-25-MiB file and verify a visible terminal error without orphaned decrypted files.
- Kill the connector and daemon separately during receive, send, and media transfer; verify replay/reconnect and bounded local chat opening.
- Enter an invalid `npub`, the bridge's own `npub`, and a peer with no KeyPackage; verify no duplicate identity or MLS group is created.
- Run two bridge processes for the same account and verify the second is rejected by the account lock.

Voice notes remain the documented `BRIDGE-PLATFORM-1` gap and must be checked as ordinary audio until the shared wire model gains an explicit classification.
