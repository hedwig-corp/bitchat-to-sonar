# Sonar Notification Stack

Two stateless servers that deliver silent pushes to iOS and Android devices
so the killed app can wake up and process events locally.

| Server | Purpose | Source |
| --- | --- | --- |
| **Transponder** | Marmot chat/call wakeups (MIP-05 privacy-preserving push) | [marmot-protocol/transponder](https://github.com/marmot-protocol/transponder) |
| **Breez NDS** | Wallet wakeups for BOLT12 receive, swap updates, LNURL-pay | [breez/notify](https://github.com/breez/notify) |

Transponder pushes trigger user-visible notifications (the client renders
the copy locally). Breez NDS pushes are **silent infrastructure only** — they
wake the wallet to settle a payment, but the user-visible "Payment received"
notification comes from the transponder/chat path when the sender's `⚡PAY`
control line arrives. This prevents duplicate notifications.

## Prerequisites

- Docker and Docker Compose v2+
- An Apple Developer account (for APNS credentials)
- A Firebase project (for FCM credentials)

## Secrets

All secrets live in `deploy/secrets/` which is gitignored. You need four
files:

| File | Source | Used by |
| --- | --- | --- |
| `transponder-server.key` | Generated locally | Transponder |
| `apns.p8` | Apple Developer portal | Transponder |
| `firebase.json` | Firebase Console | Both servers |

### 1. Generate the transponder server keypair

```sh
# Pull the transponder image first
docker pull ghcr.io/marmot-protocol/transponder:latest

# Generate a secp256k1 keypair
docker run --rm ghcr.io/marmot-protocol/transponder:latest \
  generate-keys --output /dev/stdout > secrets/transponder-server.key
```

The command prints the hex-encoded private key. It also prints the
corresponding **npub** (Nostr public key) — save this value. You will need
to embed it in the Sonar app build configuration so clients can encrypt
their device tokens to it (MIP-05 spec).

### 2. Provision APNS credentials

1. Sign in to the [Apple Developer portal](https://developer.apple.com/account).
2. Go to **Certificates, Identifiers & Profiles > Keys**.
3. Create a new key with **Apple Push Notifications service (APNs)** enabled.
4. Download the `.p8` file and note the **Key ID** (10-character string).
5. Note your **Team ID** (top-right of the portal).
6. Copy the `.p8` file to `secrets/apns.p8`.
7. Fill in the transponder config (`transponder/config/production.toml`):
   - `key_id` = your 10-character APNS key ID
   - `team_id` = your Apple Developer team ID
   - `bundle_id` = your Sonar iOS bundle ID (e.g. `chat.bitchat.sonar`)

### 3. Provision FCM credentials

1. Go to the [Firebase Console](https://console.firebase.google.com).
2. Select (or create) the Firebase project for Sonar.
3. Go to **Project Settings > Service Accounts**.
4. Click **Generate new private key** and download the JSON file.
5. Copy it to `secrets/firebase.json`.
6. Fill in `project_id` in `transponder/config/production.toml`.

Both servers share this same `firebase.json` — one Firebase project handles
push delivery for both chat and wallet wakeups.

## Configuration

### Environment (.env)

```sh
cp .env.example .env
```

| Variable | Default | Description |
| --- | --- | --- |
| `RUST_LOG` | `info` | Transponder log level (`trace`, `debug`, `info`, `warn`, `error`) |
| `NOTIFY_EXTERNAL_URL` | *(required)* | Public URL where Breez services can reach the NDS (e.g. `https://notify.sonar.example.com`) |
| `NOTIFY_WORKERS_NUM` | `4` | Number of NDS worker goroutines |
| `NDS_LISTEN_ADDRESS` | `127.0.0.1:8080` | Host:port the NDS container binds to. Use `0.0.0.0:8080` to expose to the network. |

### Transponder config (transponder/config/production.toml)

The TOML config tells the transponder where to find its key, which relays
to subscribe to, and which APNS/FCM credentials to use. Fields marked
`FILL` must be completed before starting:

| Field | Section | Description |
| --- | --- | --- |
| `key_id` | `[apns]` | 10-character APNS key ID from the Apple Developer portal |
| `team_id` | `[apns]` | Apple Developer team ID |
| `bundle_id` | `[apns]` | Sonar iOS bundle ID (e.g. `chat.bitchat.sonar`) |
| `project_id` | `[fcm]` | Firebase project ID |
| `urls` | `[relays]` | Nostr relay WebSocket URLs the transponder subscribes to |

### Relay selection

The transponder subscribes to the same Nostr relays Sonar clients publish
to. Start with the relays already configured for Marmot traffic. Add
operational fallback relays if needed.

## Deploy

```sh
cd deploy
cp .env.example .env
# Edit .env — fill in NOTIFY_EXTERNAL_URL at minimum
# Edit transponder/config/production.toml — fill in APNS and FCM fields
# Place secrets in secrets/

docker compose up -d
docker compose logs -f
```

## Verify

```sh
# Check both services are healthy
docker compose ps

# Transponder health
docker compose exec transponder transponder health

# NDS health
curl -s http://localhost:8080/health
```

## Sizing

| Server | CPU | Memory | Notes |
| --- | --- | --- | --- |
| Transponder | 2 vCPU | 4 GB | Handles relay subscriptions + push dispatch |
| Breez NDS | 1 vCPU | 512 MB | Stateless webhook-to-push proxy |

Both servers are stateless — no database, no stored tokens, no user data.
Horizontal scaling is possible by running multiple instances behind a load
balancer.

## Key Rotation

The transponder server key is the identity clients encrypt tokens to. To
rotate:

1. Generate a new keypair.
2. Update `secrets/transponder-server.key` and restart the transponder.
3. Ship a Sonar client update with the new npub so new token registrations
   encrypt to the new key.
4. Run both old and new transponder instances in parallel until existing
   token registrations expire or are re-shared.
5. Decommission the old instance.

## Security Notes

- Push payloads are **plaintext-free**. The transponder never sees message
  content — it dispatches silent pushes and the client renders copy locally.
- The Breez NDS never sees wallet keys or payment details — it only forwards
  FCM push tokens received via webhook query parameters.
- Device tokens are encrypted end-to-end to the transponder's public key
  via the MIP-05 spec (ECDH + HKDF-SHA256 + ChaCha20-Poly1305).
- Never commit `secrets/`, `.env`, or any credential file.
