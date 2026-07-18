# Sonar Handle Registrar

Unified handle registrar for `sonarprivacy.xyz`. One claimed handle serves
both identities at once:

- **BIP-353 payment address** — `alice@sonarprivacy.xyz` resolves to the
  user's BOLT12 offer via the DNS TXT record
  `alice.user._bitcoin-payment.sonarprivacy.xyz` (`bitcoin:?lno=<offer>`).
- **NIP-05 Nostr identity** — `alice@sonarprivacy.xyz` verifies against
  `https://sonarprivacy.xyz/.well-known/nostr.json?name=alice`.

This is a self-contained re-implementation (plus NIP-05 extension) of the
bip353-registrar contract described in
[`docs/bip353-registration.md`](../../docs/bip353-registration.md).

No accounts, no tokens, no stored secrets: a BIP-340 signature from the
user's Nostr identity key (same seed as the wallet) is the authentication.
Restoring the 12-word mnemonic restores handle ownership. A user may claim
a chat-only handle first (no offer) and attach the BOLT12 offer with a later
re-register from the same key.

## Architecture

- **Worker** (`src/index.ts`) — routing, CORS, signed-event verification,
  handle/domain validation, pilot secret gate.
- **`HandleRegistry` Durable Object** (`src/registry.ts`) — SQLite-backed
  source of truth for handle→pubkey bindings and per-IP rate counters. A
  single named instance serializes registrations, which makes
  first-come-first-served race-free, and performs the Cloudflare DNS write
  inside the same critical section so a binding is only persisted when its
  DNS state is known.
- **Pure modules** (`src/nostr.ts`, `src/dns.ts`) — crypto/validation and the
  DNS upsert are Workers-runtime-free and unit-tested under plain vitest.

## API

### `POST /v1/register`

Body: a signed Nostr event (kind `23353`, max 8 KB):

```json
{
  "id": "<64-hex sha256 of the NIP-01 serialization>",
  "pubkey": "<64-hex x-only pubkey>",
  "created_at": 1719849600,
  "kind": 23353,
  "tags": [],
  "content": "{\"domain\":\"sonarprivacy.xyz\",\"handle\":\"alice\",\"offer\":\"lno1...\"}",
  "sig": "<128-hex BIP-340 schnorr signature over id>"
}
```

`content.offer` is optional — omit it for a chat-only claim; a later
re-register from the same pubkey adds or rotates the offer (a re-register
without an offer keeps the stored one).

Rules enforced:

- `content.domain` must equal the worker's `BIP353_DOMAIN` (else 403).
- Handle: trimmed + lowercased, must match
  `^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$`, no empty DNS labels, not on
  the reserved list (`admin`, `root`, `support`, `sonar`, `hedwig`, ...).
- `created_at` within ±600 s of server time, and strictly greater than the
  last accepted registration for that handle (replay protection).
- First-come-first-served: first registration binds handle→pubkey; anyone
  else gets `409 {"error":"handle_taken"}`. Same-pubkey re-register is an
  idempotent update. One pubkey may own at most 3 handles.
- Per-IP rate limit: 5 requests / 60 s (429 with `Retry-After`).
- If `REGISTER_SECRET` is configured, the `x-register-secret` header must
  match (else 401).

Success (200):

```json
{
  "address": "alice@sonarprivacy.xyz",
  "record": "alice.user._bitcoin-payment.sonarprivacy.xyz",
  "owner_pubkey": "<hex>",
  "nip05": true,
  "dnssec": { "enabled": true }
}
```

`record` and `dnssec` are `null` for chat-only claims (no offer yet). If the
Cloudflare DNS write fails the request returns
`502 {"error":"dns_update_failed", ...}` and **no state is persisted** — the
registry never claims an offer that DNS doesn't serve.

Errors: `400` validation/replay, `401` missing/wrong pilot secret,
`403 domain_mismatch`, `409 handle_taken`, `429 rate_limited`,
`502 dns_update_failed` / `dns_not_configured`. All errors are
`{"error": "<code>"}`.

### `GET /.well-known/nostr.json?name=<handle>`

NIP-05 identity lookup. Returns `{"names":{"alice":"<pubkey hex>"}}`, or an
empty `names` object for unknown/malformed names (never an error status, so
NIP-05 clients don't hard-fail). `name=_` serves `ROOT_PUBKEY` when that var
is configured, otherwise nothing. `Access-Control-Allow-Origin: *` (required
by NIP-05), `Cache-Control: max-age=60`.

### `GET /v1/resolve/<handle>`

Registry lookup (the registry is the source of truth; no live DNS query):

```json
{
  "address": "alice@sonarprivacy.xyz",
  "found": true,
  "pubkey": "<hex>",
  "uri": "bitcoin:?lno=lno1..."
}
```

`pubkey`/`uri` are `null` when absent; unknown handles return `found: false`.

### `GET /v1/health`

`{"ok":true,"domain":"sonarprivacy.xyz"}`.

## curl examples

```sh
BASE=https://bip353.sonarprivacy.xyz

# Health
curl "$BASE/v1/health"

# Register (event.json = signed kind-23353 event; see docs/bip353-registration.md)
curl -X POST "$BASE/v1/register" \
  -H 'content-type: application/json' \
  --data @event.json
# Closed pilot: add -H "x-register-secret: $REGISTER_SECRET"

# Resolve a payment handle
curl "$BASE/v1/resolve/alice"

# NIP-05 (served on the bare domain)
curl "https://sonarprivacy.xyz/.well-known/nostr.json?name=alice"

# BIP-353 end-to-end (after DNS propagation)
dig +short TXT alice.user._bitcoin-payment.sonarprivacy.xyz
```

## Deploy

Prerequisites:

- Cloudflare account with the `sonarprivacy.xyz` zone.
- **DNSSEC enabled on the zone.** BIP-353 clients MUST validate DNSSEC —
  without it wallets will reject the TXT answers and payments to
  `user@sonarprivacy.xyz` will fail even though resolution "works".
- An API token scoped to `Zone.DNS:Edit` on `sonarprivacy.xyz` only.

Steps:

```sh
cd services/handle-registrar
npm install

# 1. Fill ZONE_ID in wrangler.jsonc (zone Overview -> API -> Zone ID).

# 2. DNS API token (never committed, never logged):
npx wrangler secret put CF_DNS_TOKEN

# 3. Optional closed-pilot gate:
npx wrangler secret put REGISTER_SECRET

# 4. Deploy (typecheck + tests + deploy):
../../scripts/deploy-handle-registrar.sh
# or dry-run first:
../../scripts/deploy-handle-registrar.sh --check
```

Routes are declared in `wrangler.jsonc`: the API on
`bip353.sonarprivacy.xyz/*` and NIP-05 on
`sonarprivacy.xyz/.well-known/nostr.json*`. `bip353.sonarprivacy.xyz` needs a
DNS record in the zone (a proxied `AAAA 100::` placeholder is enough) so the
route can attach.

## How the app uses it

The Sonar apps sign a kind-23353 event with the user's identity key (see the
client sketch in `docs/bip353-registration.md`) and POST it to
`/v1/register`:

1. Claim the handle at onboarding (chat-only is fine — no offer required).
   The same claim immediately gives the user a NIP-05 identity.
2. When the wallet creates (or rotates) a BOLT12 offer, re-register the same
   handle with the offer; the DNS TXT record is upserted.
3. Peers resolve payment addresses via standard BIP-353 DNS and verify chat
   identities via NIP-05 — both from the single handle.

## Development

```sh
npm install
npm run check   # tsc --noEmit
npm test        # vitest (pure modules: crypto, validation, FCFS decision)
npm run dev     # wrangler dev (local DO + SQLite simulation)
```
