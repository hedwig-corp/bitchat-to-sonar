# Sonar for Beeper / Matrix

`matrix-sonar` is a [mautrix Bridge v2](https://pkg.go.dev/maunium.net/go/mautrix/bridgev2) connector that makes a Sonar account appear in Beeper. The first release is a self-hosted third-party bridge for `bbctl`; the same connector/daemon boundary is intended to support a future community or officially listed Beeper network.

The connector never owns Sonar private keys. Each login launches one `sonar-bridge-daemon` account actor, which owns the MLS database, stores its identity in an envelope-encrypted file, journals Matrix sends before side effects, and streams stable Sonar event IDs back to Bridge v2. Portal IDs are the peer's canonical Nostr public-key hex, so a room can be created immediately from an `npub` before an MLS group exists.

The bridge is an encryption endpoint, not end-to-end encryption directly between Beeper and a Sonar mobile app. It decrypts Sonar/MLS messages and re-encrypts them for Matrix (and the reverse outbound), so the bridge host and anyone who controls its process can access message plaintext while translating it. Run it only on infrastructure you trust.

## Supported in v1

- A bridge-specific generated Sonar identity
- Exact `npub1…` or 64-character hex direct-message lookup
- 1:1 text messages
- Images, video, audio, and generic files with captions, filenames, and MIME types
- Bounded local history replay and live incremental delivery
- Offline local startup and local-first sends in established direct chats

Groups, reactions, edits, replies, read receipts, typing, disappearing messages, calls, payments, stickers, and multi-device identity sharing are deliberately advertised as unsupported. The login metadata contains only an opaque account ID, public key, state-directory ID, and replay cursor; this leaves room to replace the local credential reference with a multi-device credential provider later.

## Build

Requirements are Rust 1.85+, Go 1.25+, a C toolchain for SQLite, and `bbctl`.

```sh
cd core
cargo build --release -p sonar-bridge-daemon

cd ../bridges/sonar
go build -tags goolm -o matrix-sonar ./cmd/matrix-sonar
```

The `goolm` tag selects mautrix's pure-Go Olm implementation and avoids a system `libolm` dependency.

The included `Dockerfile` builds both binaries and runs as numeric UID/GID `65532`; bind-mounted config, master-key, database, and account-state paths must be readable or writable by that identity as appropriate. `matrix-sonar.service` is the corresponding hardened systemd unit for installations that place config under `/etc/matrix-sonar` and durable state under `/var/lib/matrix-sonar`.

## Configure with bbctl

Follow Beeper's current [third-party bridge self-hosting guide](https://developers.beeper.com/bridges/self-hosting#running-third-party-bridges):

```sh
bbctl login
bbctl config --type bridgev2 sh-sonar
```

`bbctl config` writes the Matrix/appservice portion and tells you where the generated bridge config lives. Add this `network` block to that file, adjusting absolute paths:

```yaml
network:
  daemon_path: /usr/local/bin/sonar-bridge-daemon
  state_dir: /var/lib/matrix-sonar/accounts
  master_key_file: /etc/matrix-sonar/master-key
  relays:
    - wss://relay.damus.io
    - wss://nos.lol
    - wss://relay.primal.net
  blossom_server: https://nostr.download
  media_download_hosts:
    - nostr.download
  poll_interval_millis: 2000
```

For the included systemd unit, create the service account/directories and operator master key without putting the key in the config, environment, command arguments, or logs (use your distribution's equivalent service-user command if `useradd` differs):

```sh
sudo useradd --system --home-dir /var/lib/matrix-sonar --shell /usr/sbin/nologin matrix-sonar 2>/dev/null || true
sudo install -d -o matrix-sonar -g matrix-sonar -m 700 /etc/matrix-sonar /var/lib/matrix-sonar /var/lib/matrix-sonar/accounts
umask 077
openssl rand -hex -out /tmp/matrix-sonar-master-key 32
sudo install -o matrix-sonar -g matrix-sonar -m 600 /tmp/matrix-sonar-master-key /etc/matrix-sonar/master-key
rm /tmp/matrix-sonar-master-key
```

Install the completed generated config for the same service identity, then run the bridge normally:

```sh
sudo install -o matrix-sonar -g matrix-sonar -m 600 /absolute/path/to/generated-config.yaml /etc/matrix-sonar/config.yaml
sudo -u matrix-sonar /usr/local/bin/matrix-sonar -c /etc/matrix-sonar/config.yaml
```

For a foreground development build, use config, key, and state paths owned by the current user instead. To run persistently, install `matrix-sonar.service` and start it with `systemctl` after copying the config.

Bridge v2 connects directly using the generated appservice configuration. Do not use the legacy `bbctl proxy` flow.

In Beeper, open the bridge bot/provisioning UI, choose **Create Sonar identity**, and start a chat by entering the peer's exact `npub`. A self-hosted bridge does not automatically create an official Sonar tile in Beeper account settings; that requires Beeper's listing/review process.

## Persistence and lifecycle

Back up these together while the service is stopped:

- the Bridge v2 database/config generated by `bbctl`;
- the entire `state_dir`, including `account.sealed.json`, both SQLCipher databases and their WAL/SHM files, journals, media spool, and Sonar sidecars;
- the operator master-key file, stored separately from the backup where possible.

Losing the master key makes the account intentionally unrecoverable. A wrong or corrupt key never causes identity regeneration. Only one daemon may open an account directory at a time.

`bbctl delete sh-sonar` removes the remote Beeper bridge registration; it does not wipe third-party local files. Conversely, deleting the local state does not unregister the remote bridge. A complete destructive wipe must be an explicit, stopped-service operation covering the generated bridge database/config, account state directory, SQLCipher WAL/SHM files, sealed identity, spool/exports, and master key. There is intentionally no automatic wipe command in v1.

## Local-first and delivery semantics

Existing rooms and bounded transcript pages open from SQLCipher without waiting for relay health. Relay sync runs after local readiness and writes into the same local database. The daemon replays inbound rows with stable Sonar event IDs; Bridge v2 deduplicates those IDs.

Outbound source transactions are inserted into an encrypted journal before MLS work. A normal retry returns the stored Sonar ID. An established DM commits text locally even while relays are unavailable and the core outbox publishes it in the background. A brand-new DM still needs the peer's relay-hosted KeyPackage; if that lookup is unavailable, Bridge v2 reports a retriable pending send and the same Matrix event can be retried safely. If a process dies in the narrow interval after a command is claimed but before its Sonar ID is durably recorded, the command is reported as `indeterminate` and is not blindly replayed, preventing duplicate messages at the cost of requiring reconciliation.

Media paths—not byte arrays—cross the Go/Rust process boundary. Matrix downloads are immediately imported into an encrypted, account-private spool, temporary plaintext files are mode `0600`, and startup removes orphaned decrypted partials. Individual attachments are capped at 25 MiB.

## Native app interoperability and tracked gap

The bridge calls the same `sonar-core` Marmot message/media APIs used by both `ios/` and `apps/sonar/`; it does not introduce a bridge-only wire format. Core and bridge CI cover stable event IDs, bounded local paging, offline startup, encrypted identity persistence, journaling, filenames, media-kind mapping, and Bridge v2 compilation.

Tracked gap `BRIDGE-PLATFORM-1`: this repository's CI cannot build the gitignored native FFI artifacts or run a signed Beeper session, so it does not yet execute an automated real-device round trip against either Apple or Compose. Before community/official listing, add a nightly matrix that sends text and each media kind Beeper → Apple, Apple → Beeper, Beeper → Compose, and Compose → Beeper, including offline recovery and restart replay. Until then, every release candidate requires the manual checklist in [INTEROP-CHECKLIST.md](./INTEROP-CHECKLIST.md).

One protocol limitation is explicit: Marmot's current media reference does not carry a voice-note-versus-audio marker, so `audio/*` round-trips as Matrix audio. Preserving Matrix voice-note classification is part of `BRIDGE-PLATFORM-1` and requires a backward-compatible core/wire metadata extension across Apple and Compose before the bridge advertises voice notes as fully supported.
