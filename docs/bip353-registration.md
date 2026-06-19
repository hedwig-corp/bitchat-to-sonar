# BIP-353 Payment Address Registration

Sonar users can claim a human-readable payment address like
`alice@sonarprivacy.xyz` that resolves to their BOLT12 offer via DNS.

This uses the existing
[bip353-registrar](https://github.com/hedwig-corp/bitvault-pay/tree/main/services/bip353-registrar)
Worker from bitvault-pay, deployed for the `sonarprivacy.xyz` domain.

## How It Works

1. User picks a handle (e.g. `alice`) in the Sonar app.
2. The app creates a BOLT12 offer via the Breez SDK.
3. The app signs a Nostr event (kind 23353) with the user's identity key.
4. The app POSTs the signed event to the registrar.
5. The registrar verifies the signature, publishes a DNS TXT record at
   `alice.user._bitcoin-payment.sonarprivacy.xyz` containing
   `bitcoin:?lno=<offer>`.
6. Anyone can now pay `alice@sonarprivacy.xyz` — their wallet resolves the
   BIP-353 address via DNS, gets the BOLT12 offer, and pays directly.

No accounts, no tokens, no stored secrets. The user's Nostr identity key
(derived from the same seed as the wallet) is the authentication. Restoring
the 12-word mnemonic restores handle ownership.

## Deploying the Registrar for sonarprivacy.xyz

The registrar is a Cloudflare Worker + Durable Object. It's already
parameterized by domain — deploy it with `sonarprivacy.xyz` config.

### Prerequisites

- Cloudflare account with `sonarprivacy.xyz` zone
- DNSSEC enabled on the zone
- Cloudflare API token with `Zone.DNS:Edit` and `DNSSEC:Read` permissions

### Setup in bitvault-pay repo

Add a wrangler environment for Sonar. In
`services/bip353-registrar/wrangler.jsonc`:

```jsonc
{
  // ... existing config ...
  "env": {
    "sonar": {
      "name": "bip353-registrar-sonar",
      "vars": {
        "BIP353_DOMAIN": "sonarprivacy.xyz",
        "ZONE_ID": "<cloudflare-zone-id-for-sonarprivacy.xyz>"
      },
      "durable_objects": {
        "bindings": [
          {
            "name": "HANDLE_REGISTRY",
            "class_name": "HandleRegistry"
          }
        ]
      }
    }
  }
}
```

### Deploy

```sh
cd services/bip353-registrar
npm install

# Set the Cloudflare DNS API token as a secret
npx wrangler secret put CF_DNS_TOKEN --env sonar

# Optional: set a registration secret for closed pilot
npx wrangler secret put REGISTER_SECRET --env sonar

# Deploy
npx wrangler deploy --env sonar
```

### Verify

```sh
# Check the Worker is running
curl https://bip353-registrar-sonar.<your-workers-subdomain>.workers.dev/v1

# After a registration, verify DNS resolution
curl "https://bip353-registrar-sonar.<your-workers-subdomain>.workers.dev/v1/resolve/alice"
```

## Client Integration

### Registration Event Format

The registrar expects a POST to `/v1/register` with a JSON body that is a
signed Nostr event:

```json
{
  "id": "<sha256 hash>",
  "pubkey": "<32-byte hex pubkey>",
  "created_at": 1719849600,
  "kind": 23353,
  "tags": [],
  "content": "{\"domain\":\"sonarprivacy.xyz\",\"handle\":\"alice\",\"offer\":\"lno1...\"}",
  "sig": "<64-byte hex schnorr signature>"
}
```

- `kind`: 23353 (ephemeral range, BIP-353 registration)
- `content`: JSON with `domain`, `handle`, and `offer` fields
- `pubkey`: the user's Nostr public key (hex, not npub)
- `sig`: BIP-340 schnorr signature over the event hash

The event hash is SHA256 of:
`[0, pubkey, created_at, kind, tags, content]` (NIP-01 serialization).

### Anti-Abuse

- Per-IP rate limit (5 requests / 60 seconds)
- Handle-to-pubkey binding: first registration binds, updates require same key
- Freshness window: `created_at` must be within +-600s of server time
- Monotonic `created_at`: replays rejected (must be > last registration)
- Domain binding: `content.domain` must match the Worker's `BIP353_DOMAIN`

### Response

Success (200):
```json
{
  "address": "alice@sonarprivacy.xyz",
  "record": "alice.user._bitcoin-payment.sonarprivacy.xyz",
  "owner_pubkey": "<hex>",
  "dnssec": { "enabled": true, "status": "active" }
}
```

### Resolution

`GET /v1/resolve/<handle>` returns:
```json
{
  "address": "alice@sonarprivacy.xyz",
  "found": true,
  "dnssec_validated": true,
  "uri": "bitcoin:?lno=lno1..."
}
```

## Compose Integration

The registration flow lives in common code so it works on Android, Desktop,
and (eventually) iOS via KMP.

### SonarBip353.kt (commonMain)

```kotlin
package chat.bitchat.sonar

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * BIP-353 self-service registration client.
 * Signs a kind:23353 Nostr event and POSTs it to the registrar.
 */
object SonarBip353 {

    // Registrar URL — read from build config or hardcode for now.
    private const val REGISTRAR_URL = "https://bip353.sonarprivacy.xyz"
    private const val DOMAIN = "sonarprivacy.xyz"

    @Serializable
    data class RegisterContent(
        val domain: String,
        val handle: String,
        val offer: String,
    )

    @Serializable
    data class RegisterResponse(
        val address: String,
        val record: String,
        val owner_pubkey: String,
    )

    /**
     * Register (or update) a BIP-353 handle.
     *
     * @param handle The desired handle (e.g. "alice")
     * @param offer  The user's BOLT12 offer string
     * @return The registered address (e.g. "alice@sonarprivacy.xyz")
     * @throws Exception on network error, 409 (handle taken), or 4xx/5xx
     */
    suspend fun register(handle: String, offer: String): String {
        val content = Json.encodeToString(
            RegisterContent.serializer(),
            RegisterContent(DOMAIN, handle.lowercase().trim(), offer),
        )

        // Sign a kind:23353 Nostr event with the user's identity key.
        // SonarCore.identityNsec() returns the nsec1... key.
        //
        // TODO: Add a signNostrEvent(kind, content) method to SonarCore FFI,
        //       or implement client-side schnorr signing using the nsec.
        //
        // val event = SonarCore.signNostrEvent(kind = 23353, content = content)
        // val response = httpPost("$REGISTRAR_URL/v1/register", event.toJson())
        // val result = Json.decodeFromString(RegisterResponse.serializer(), response)
        // return result.address

        TODO("Wire SonarCore.signNostrEvent or client-side schnorr signing")
    }

    /**
     * Resolve a handle to its BOLT12 offer via the registrar.
     */
    suspend fun resolve(handle: String): String? {
        // GET $REGISTRAR_URL/v1/resolve/$handle
        // Parse response, return offer if found
        TODO("Wire HTTP client")
    }
}
```

### Integration with SonarAppState

In `SonarAppState.kt`, the existing `setBip353()` writes the address to
local storage. The registration flow extends this:

```kotlin
fun registerBip353(handle: String) {
    scope.launch {
        val offer = WalletBridge.createOffer()
        val address = SonarBip353.register(handle, offer)
        setBip353(address)
    }
}
```

The profile screen already has a text field for `bip353`. Replace (or
augment) the manual text field with a "Claim handle" flow:
1. User types just the handle part (e.g. "alice")
2. App shows preview: `alice@sonarprivacy.xyz`
3. User confirms → app calls `registerBip353("alice")`
4. On success, the address is saved and broadcast via BLE

### iOS Integration

The iOS app (`SonarAppStore.swift`) has the same `setBip353()` and manual
text field. The registration flow is identical — sign the event, POST to
the registrar, save the address:

```swift
func registerBip353(handle: String) async throws {
    // 1. Create a BOLT12 offer
    let offer = try await walletService.createOffer()

    // 2. Build the kind:23353 event content
    let content = """
    {"domain":"sonarprivacy.xyz","handle":"\(handle)","offer":"\(offer)"}
    """

    // 3. Sign the Nostr event with the user's identity key
    // TODO: Use the nsec to sign a kind:23353 event (BIP-340 schnorr).
    //       The existing SonarIdentity has the key but no generic sign method.

    // 4. POST to registrar
    // let response = try await post(url: registrarURL + "/v1/register", body: event)

    // 5. Save the address locally
    // setBip353(response.address)
}
```

## What Needs to Happen

### In bitvault-pay repo (one-time setup)
1. Add `sonar` wrangler environment with `BIP353_DOMAIN=sonarprivacy.xyz`
2. Deploy with `npx wrangler deploy --env sonar`
3. Set `CF_DNS_TOKEN` secret for the sonarprivacy.xyz zone

### In sonar-core (Rust FFI)
1. Add `sign_nostr_event(kind: u32, content: String) -> SignedEvent` to the
   FFI surface. This is the missing piece — the identity key exists but
   there's no generic event signing method exposed to the apps.
   Alternatively, export `identity_secret_key_hex()` and do client-side
   signing, but that leaks the raw key to Kotlin/Swift which is worse.

### In Sonar apps
1. Add `SonarBip353.register()` / `SonarBip353.resolve()` (Compose common)
2. Mirror on iOS
3. Replace the manual BIP-353 text field with a "Claim handle" UI flow
4. Auto-register on wallet setup (if the user opts in)
5. Re-register on BOLT12 offer rotation
