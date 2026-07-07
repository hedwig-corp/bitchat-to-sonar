// Sonar documentation content — ported 1:1 from the Claude Design handoff:
//   design/handoff/project/sonar/docs-content.js
// Keep this file in lockstep with that source; do not edit the prose here.
/**
 * @typedef {{ title: string, gh: string, md: string, blurb?: string, status?: string, kind?: string }} SonarDoc
 * @type {{ groups: { name: string, items: string[] }[], docs: Record<string, SonarDoc> }}
 */
export const SONAR_DOCS = {
  groups: [
    { name: 'Overview', items: ['index'] },
    { name: 'Protocol', items: ['SONAR-DISCOVERY'] },
    { name: 'Money', items: ['SONAR-PAYMENTS', 'bip353-registration'] },
    { name: 'Content', items: ['SONAR-STICKERS'] },
    { name: 'Integrations', items: ['HERMES-AGENT'] },
  ],
  docs: {
    index: {
      title: 'Introduction',
      gh: 'https://github.com/hedwig-corp/bitchat-to-sonar/tree/main/docs',
      blurb: 'what sonar is and how these docs are organized',
      md: `# Sonar documentation

Sonar is a private, offline-capable messenger. It finds people over a **Bluetooth mesh** when they are nearby and reaches anyone else over the **open Nostr network** — with no phone number, no account, and no servers.

These docs describe the protocols and conventions behind the app.

## Where to start

- **[Discovery](SONAR-DISCOVERY.md)** — how peers find each other over BLE and Nostr, and how capabilities are advertised.
- **[Payments](SONAR-PAYMENTS.md)** — direct Bolt12 wallet payments and the in-chat receipt format.
- **[Stickers](SONAR-STICKERS.md)** — the open sticker-pack directory published on Nostr.
- **[Hermes Agent](HERMES-AGENT.md)** — autonomous AI over Sonar DMs via sonar-cli and the Hermes gateway.

## Principles

1. **Local first.** Anything that can work offline, works offline. Online paths are fallbacks, not requirements.
2. **The npub is the identity.** A durable Nostr public key is the account; everything else is discovered from it.
3. **Publish capability, never presence.** Descriptors say what a peer *can* do, never where they are or whether they are online.
4. **No new identifiers.** Sonar rides existing bitchat mesh framing and standard Nostr event kinds.

> These pages are generated from the \`docs/\` folder of the repository. Use **View on GitHub** on any page to read the source.`,
    },

    'SONAR-DISCOVERY': {
      title: 'Discovery',
      status: 'packet v1',
      gh: 'https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/SONAR-DISCOVERY.md',
      blurb: 'ble 0x53 and nostr descriptor peer discovery capabilities',
      md: `# Sonar Discovery

Sonar discovery has two complementary paths:

1. **BLE proximity discovery**: a Sonar-specific \`BitchatPacket\` raw type \`0x53\` is broadcast over the existing bitchat BLE mesh. This works offline and is preferred whenever the peer is in range.
2. **Nostr npub discovery**: a public, npub-signed Sonar descriptor is stored as a Nostr app-data event. This is the online fallback for peers that are no longer in BLE range but whose npub is known.

Sonar does **not** publish live Iroh node addresses in a Nostr profile. It publishes only stable capability and protocol-route metadata in a separate descriptor. Live call addresses stay inside encrypted call offer/answer messages.

## Discovery decision

Sonar treats an \`npub\` as the durable account identity. A user with an npub can be contacted over Marmot/White Noise text messaging if their Marmot KeyPackage exists on relays. Extra Sonar capabilities, such as voice/video calls, must be discovered separately.

The call-discovery rule is:

- If BLE is reachable, prefer the BLE \`0x53\` profile and live mesh route.
- If BLE is not reachable and the app is online, fetch the public Sonar descriptor for the peer's npub.
- If the descriptor exists and advertises a compatible call route, the peer is a Sonar call-capable user.
- If the descriptor is missing, malformed, or incompatible, keep the peer as a White Noise/Marmot contact but do not show or accept Sonar call affordances.

This keeps local/offline behavior fast while still allowing account-level call discovery after the users are no longer nearby.

## Privacy model

The two discovery paths have different visibility:

| Path | Visibility | What it exposes | What it does not expose |
| --- | --- | --- | --- |
| BLE 0x53 | Nearby mesh participants while TTL is alive | npub, optional BIP-353 address, capability bits | nsec, live Iroh addresses, call IDs |
| Nostr descriptor | Public to anyone who can query the user's relays and knows the npub | Sonar app marker, call/media support, signaling and transport names | nsec, live addresses, IPs, call IDs, presence |

The Nostr descriptor is public by design. It is signed by the same account key represented by the npub, so it proves "this npub published these Sonar capabilities". The BLE path separately binds the npub claim to the verified mesh identity via the \`0x53\` packet signature.

## BLE proximity discovery

**Wire type:** \`BitchatPacket\` raw type \`0x53\` (\`'S'\`). bitchat's normal announce tells the app who is nearby, but not how to reach that peer off-mesh. Sonar broadcasts a second packet after the normal announce with the peer's identity, an optional payment address, and a capability bitfield.

\`0x53\` is deliberately not added to bitchat's \`MessageType\` enum; stock bitchat clients hit the unknown-type branch, ignore the payload, and continue relaying by TTL.

### Payload TLV

The payload uses one type byte, one u8 length byte, then \`length\` value bytes.

| TLV | Name | Size | Required | Meaning |
| --- | --- | --- | --- | --- |
| 0x01 | version | 1 byte | yes | payload version (1) |
| 0x02 | npub | 32 bytes | yes | raw x-only Nostr public key |
| 0x03 | bip353 | <=255 bytes | no | UTF-8 BIP-353 address |
| 0x04 | capabilities | 1 byte | yes | bitfield |

Capability bits:

| Bit | Mask | Name | Meaning |
| --- | --- | --- | --- |
| 0 | 0b0000_0001 | marmot-dm | the npub accepts Marmot DMs |
| 1 | 0b0000_0010 | payments | the peer speaks the Sonar payment convention |
| 2 | 0b0000_0100 | calls | the peer supports Sonar voice/video calls |

Current senders advertise Marmot DMs and calls. They advertise payments only when the wallet is configured to receive.

### Validation

Receivers must skip unknown TLV types, reject unknown versions, reject a missing or non-32-byte npub, reject a missing capabilities TLV, only accept a Sonar announce for an already-verified bitchat announce, and verify the \`0x53\` signature against the sender's mesh announce signing key. That signature binds the advertised npub and capability bits to the verified mesh identity — a relay node cannot substitute its own npub without failing verification.

## Nostr descriptor discovery

The online fallback uses a Nostr application-data descriptor based on NIP-78, which defines kind \`30078\` as an addressable app-data event with a \`d\` tag.

| Field | Value |
| --- | --- |
| kind | 30078 |
| d tag | sonar.call.v1 |
| app marker | sonar |
| schema | 1 |
| default signaling | marmot |
| default transport | iroh |

Example descriptor content:

\`\`\`json
{
  "schema": 1,
  "app": "sonar",
  "calls": true,
  "media": ["voice", "video"],
  "signaling": ["marmot"],
  "transports": ["iroh"],
  "call_identity": "iroh-hkdf-sonar-call-iroh-v1"
}
\`\`\`

The descriptor tells a peer that this npub is a Sonar client with compatible call support. It does not contain session-specific reachability data. A missing descriptor means "not confirmed as Sonar call-capable" — it does not mean the npub is invalid.

## Call gating

Voice/video calls are allowed when the conversation has a signaling route and either the BLE Sonar profile has the \`calls\` bit, or the fetched descriptor has \`calls = true\` with \`marmot\` signaling and \`iroh\` transport. Incoming call offers are deferred while descriptor discovery is in flight for an otherwise unknown npub.`,
    },

    'SONAR-PAYMENTS': {
      title: 'Payments',
      status: 'v2 draft',
      gh: 'https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/SONAR-PAYMENTS.md',
      blurb: 'direct bolt12 wallet payments in-chat receipts gold',
      md: `# Sonar Payments

New Sonar clients do not create claimable chat coins when sending money. The receiver publishes public payment metadata in their Sonar descriptor, and the sender pays that wallet destination **directly**.

## Current send path: direct wallet payment

The app publishes two addressable kind \`30078\` descriptor events during migration:

- \`d=sonar.call.v1\`: old call-only schema for old clients.
- \`d=sonar.meta.v1\`: unified Sonar metadata — the preferred schema, carrying direct payment receive metadata.

The payment part of \`sonar.meta.v1\`:

\`\`\`json
{
  "schema": 2,
  "app": "sonar",
  "payments": {
    "receive": [
      {
        "type": "bolt12_offer",
        "offer": "lno1...",
        "network": "bitcoin",
        "proofs": ["preimage"],
        "future_proofs": ["bolt12_payer_proof"]
      }
    ],
    "receipts": ["sonar.payment.receipt.v1"]
  }
}
\`\`\`

Send flow:

\`\`\`text
sender                                receiver
------                                --------
fetch sonar.meta.v1
read payments.receive[bolt12_offer]
record activity: pending
wallet.send(offer, sats) -> preimage
record activity: paid/failed
PAY|1|uuid|sats  ------------------>  record incoming receipt: pending
PAYDONE|2|uuid|preimage  ---------->  mark receipt paid + store preimage
\`\`\`

Direct sends require a valid BOLT12 offer from the peer's Sonar metadata. BLE payment capability bits may show the affordance while the descriptor is being fetched, but sending refuses until the concrete offer is available.

## Chat UX

Money still appears inside the chat. A direct send pays the receiver's wallet, then posts **gold payment receipt bubbles** using the encrypted chat transport. There is no "tap to claim" step for these bubbles.

The wallet sheet lists direct payment activity, newest first: Sonar direct sends, Unify nearby sends to Bluetooth-discovered wallets, and generic incoming wallet payments — with status, amount, peer name, rail, and fee.

## Chat receipt wire format

\`\`\`text
PAY|1|uuid|sats               payment receipt (sender -> receiver)
PAYDONE|2|uuid                settled receipt, no preimage available
PAYDONE|2|uuid|preimage_hex   settled receipt with cryptographic proof
\`\`\`

\`preimage_hex\` is the 32-byte Lightning preimage (64 hex chars). Receivers verify settlement by checking \`SHA256(preimage) == payment_hash\`.

\`PAY\` is a receipt, not a Bitcoin claim primitive. \`PAYDONE\` can race ahead of \`PAY\` on relay-backed transports; clients remember the DONE and mark the matching receipt paid once \`PAY\` arrives. Unknown versions render as plain text.

## Missing offer behavior

When a peer has no direct receive offer, calls can still use \`sonar.call.v1\`, but "Send money" is hidden because there is no destination to pay. This avoids presenting a claimable UX for a payment that now settles directly.`,
    },

    'bip353-registration': {
      title: 'BIP-353 addresses',
      gh: 'https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/bip353-registration.md',
      blurb: 'human readable payment address user domain dns',
      md: `# BIP-353 payment addresses

BIP-353 lets a user hand out a human-readable payment address like \`maya@sonar.app\` instead of a raw Bolt12 offer. Under the hood it resolves to the same offer via a signed DNS record.

## Why Sonar uses it

- A name is easy to say out loud, print, or verify in person.
- The underlying offer can rotate without the user reprinting anything.
- It composes with discovery: the address travels in the BLE \`0x53\` payload and the Nostr descriptor, so nearby and remote peers resolve the same name.

## Resolution

\`\`\`text
maya@sonar.app
   -> DNS TXT at maya.user._bitcoin-payment.sonar.app
   -> bitcoin:?lno=lno1...   (a Bolt12 offer)
   -> wallet.send(offer, sats)
\`\`\`

The client validates the DNSSEC chain before trusting the record. An address that fails validation is treated as "no offer" — the send affordance stays hidden rather than paying an unverified destination.

## In the UI

A resolved address shows on the contact profile under the payment capability, in monospace. The raw offer is never shown as the primary label — the name is the identity, the offer is plumbing.`,
    },

    'SONAR-STICKERS': {
      title: 'Stickers',
      status: 'ship plan',
      kind: 'kind:30030',
      gh: 'https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/SONAR-STICKERS.md',
      blurb: 'sticker packs published on nostr open directory',
      md: `# Sonar Stickers

Sticker packs are published to the open Nostr network as addressable events. There is no store and no gatekeeper: anyone can publish a pack, and any client — or the web directory — can discover it.

## Event model

| Event | Kind | Meaning |
| --- | --- | --- |
| Pack | 30030 | an addressable sticker pack authored by an npub |
| Installed list | 10030 | a user's list of installed packs |

A pack event carries the pack title, author, tags, and an ordered list of sticker references. Each sticker is content-addressed, so a pack cannot be silently altered after you install it.

## Discovery

The [web directory](Sonar%20Stickers.html) indexes public pack events and lets anyone browse, search by tag, and preview a pack before adding it. Because packs are plain Nostr events, the directory is a convenience, not an authority — clients can mirror or replace it.

\`\`\`text
author signs pack (kind 30030)
   -> relays
   -> directory indexes #t tags + title
   -> user taps "Add to Sonar"
   -> client appends to installed list (kind 10030)
\`\`\`

## Ownership

A pack is owned by the npub that signed it, forever. "Verified maker" in the directory means the pack's author key matches a known identity — it does not gate publishing. There is no review queue and no fee.

## In-app picker

The composer sticker picker reads the user's installed list (kind 10030), resolves each pack, and renders recents first. Sending a sticker posts a bubble-less media message so the art is the message — the timestamp and delivery state sit beneath it.`,
    },
    'HERMES-AGENT': {
      title: 'Hermes Agent',
      status: 'integration',
      gh: 'https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/HERMES-AGENT.md',
      blurb: 'autonomous hermes agent over sonar dms via sonar-cli and gateway',
      md: `# Hermes Agent integration

Status: **stable operator guide** (2026-07). This document explains how to run
[Hermes Agent](https://hermes-agent.nousresearch.com/docs) as an autonomous
assistant over Sonar / Marmot encrypted direct messages, using the headless
**\`sonar-cli\`** binary from this repository (\`core/sonar-cli\`).

Hermes is **not** built into Sonar. Integration is a thin contract: Hermes (or
any agent runtime) shells out to \`sonar-cli\` for transport. The recommended
production setup uses the **Hermes gateway Sonar platform plugin** so Sonar DMs
get the same agent loop as Telegram (tools, memory, skills, MCP).

## What belongs where

| **bitchat-to-sonar (this repo)** | **hermes-agent** |
|----------------------------------|------------------|
| \`sonar-cli\` binary, Marmot protocol, apps | \`plugins/platforms/sonar/\` (\`SonarAdapter\`) |
| \`docs/HERMES-AGENT.md\` (this page) | Gateway config, cron \`deliver=sonar\`, skills |
| \`core/sonar-cli/hermes/SKILL.md\` | Optional community skill \`sonar-cli\` / \`sonar-hermes-bridge\` |

Do not fork Sonar protocol logic into Hermes. Do not embed Hermes into
\`sonar-cli\`. Keep the **CLI JSON contract** stable (see below).

---

## Architecture options

Choose **one** inbound listener per agent identity. Running two modes together
duplicate-processes \`sonar-cli listen\` and causes **duplicate replies**.

\`\`\`
                    ┌─────────────────────────────────────┐
  Sonar app ──DM──► │ Nostr relays (Marmot / MLS)         │
                    └─────────────────┬───────────────────┘
                                      │
                    ┌─────────────────▼───────────────────┐
                    │ sonar-cli listen  (JSON lines)      │
                    └─────────────────┬───────────────────┘
          ┌───────────────────────────┼───────────────────────────┐
          │                           │                           │
   ┌──────▼──────┐            ┌───────▼────────┐           ┌──────▼──────┐
   │ A. Gateway  │            │ B. Legacy      │           │ C. Cron     │
   │ SonarAdapter│            │ Python bridge  │           │ listen --once│
   │ (preferred) │            │ hermes chat -q │           │ + terminal  │
   └──────┬──────┘            └───────┬────────┘           └──────┬──────┘
          │                           │                           │
          └───────────────────────────┼───────────────────────────┘
                                      │
                    ┌─────────────────▼───────────────────┐
                    │ Hermes agent (model + tools)        │
                    └─────────────────┬───────────────────┘
                                      │
                    ┌─────────────────▼───────────────────┐
                    │ sonar-cli send --to <npub> …        │
                    └─────────────────────────────────────┘
\`\`\`

| Mode | When to use | Listen style |
|------|-------------|--------------|
| **A. Native gateway** | Always-on DM agent with sessions, voice, cron delivery | Long-lived \`sonar-cli listen\` (subprocess of \`hermes gateway\`) |
| **B. Legacy bridge** | Hermes without gateway plugin; migration | Streaming \`listen\` in a Python service |
| **C. Cron + terminal** | Minimal setup; higher latency | \`listen --once\` on a schedule |

Transport is **relay-only**. \`sonar-cli\` does not drive BLE mesh; peers reach
the agent over Nostr relays when they know the agent \`npub\`.

---

## Prerequisites

- **Hermes Agent** installed with a working model provider and toolsets (at
  minimum \`terminal\` for mode C; full toolsets for A/B).
- **Web search backend** configured in Hermes (\`web.backend\`, e.g. searxng) if
  the agent uses web tools — otherwise subprocesses fail with *"Web tools aren't
  configured"* even when the CLI works.
- Rust toolchain to build \`sonar-cli\`, or a prebuilt binary on \`PATH\`.

### Build \`sonar-cli\`

\`\`\`bash
cd core
cargo build -p sonar-cli --release
install -m 755 target/release/sonar-cli ~/.local/bin/sonar-cli
\`\`\`

**Verify you have Sonar CLI, not crates.io \`nostr-cli\`:**

\`\`\`bash
sonar-cli --help
# Must include: init, identity, publish, send, listen, groups, messages

sonar-cli send --help | grep -E 'file|kind'   # optional: media / voice builds
\`\`\`

### Agent identity (one-time)

Use an isolated home directory — never share with a human Sonar client:

\`\`\`bash
export SONAR_CLI_HOME="$HOME/.sonar-agent"
mkdir -p "$SONAR_CLI_HOME"

# Prefer file or env for nsec — not literal on argv (shell history).
sonar-cli init --nsec-file "$HOME/.secrets/sonar-agent.nsec"
sonar-cli publish
sonar-cli identity    # capture npub — users DM this address
\`\`\`

\`init\` writes \`config.json\` and Marmot state under \`SONAR_CLI_HOME\` with
restricted permissions on Unix. **Back up** this directory before upgrades;
deleting it creates a new identity.

#### Secrets handling

- Use \`init --nsec-file\` or \`--nsec-env\`, not \`init --nsec <literal>\`.
- Keep \`SONAR_CLI_HOME\` and key material **outside** git.
- Same nsec → same npub on any host.

---

## Mode A — Native Hermes gateway (recommended)

Hermes ships a platform plugin: \`hermes-agent/plugins/platforms/sonar/\`. It
spawns \`sonar-cli listen\`, maps inbound JSON to \`MessageEvent\`, runs the normal
gateway agent loop, and replies via \`sonar-cli send\` (and \`send --file --kind
voice\` when supported).

### Enable Sonar platform

\`\`\`bash
hermes config set gateway.platforms.sonar.enabled true
\`\`\`

Example \`~/.hermes/config.yaml\`:

\`\`\`yaml
gateway:
  platforms:
    sonar:
      enabled: true
      extra:
        sonar_cli_home: ~/.sonar-agent
        sonar_cli_path: ~/.local/bin/sonar-cli
        display_name: "Hermes Agent · Sonar"
        max_chunk_chars: 3200
        authorized_senders:
          - npub1YOUR_PEER_HERE
        instant_ack_enabled: false
        typing_indicator_enabled: false
\`\`\`

### Authorization

The gateway enforces who may DM the agent:

1. **\`SONAR_ALLOWED_SENDERS\`** — comma-separated npubs in the gateway process
   environment (e.g. \`~/.hermes/.env\`).
2. **\`authorized_senders\`** in yaml — mirrored into env by the adapter when env
   is empty.
3. **\`hermes pairing approve sonar <npub>\`** when using pairing mode.

For systemd, load env into the gateway unit:

\`\`\`ini
# ~/.config/systemd/user/hermes-gateway.service.d/sonar-env.conf
[Service]
EnvironmentFile=-/home/USER/.hermes/.env
Environment=SONAR_CLI_HOME=/home/USER/.sonar-agent
\`\`\`

\`\`\`bash
hermes gateway install   # if not already
systemctl --user daemon-reload
systemctl --user restart hermes-gateway.service
\`\`\`

### Disable duplicate listeners

If you previously ran a Python bridge or poller:

\`\`\`bash
systemctl --user stop sonar-bridge.service sonar-poller.service 2>/dev/null || true
systemctl --user disable sonar-bridge.service sonar-poller.service 2>/dev/null || true
\`\`\`

Confirm a **single** \`sonar-cli listen\`:

\`\`\`bash
pgrep -af 'sonar-cli listen'
\`\`\`

### Verify

\`\`\`bash
journalctl --user -u hermes-gateway -n 100 --no-pager | grep -i sonar
\`\`\`

From an authorized npub, send a DM to the agent npub from \`sonar-cli identity\`.
Expect a full model reply (tools, memory), not a static ping handler.

### Reply UX on Sonar

- **Plain text** in DMs (no markdown tables or \`**bold**\` — the app is not Telegram).
- Match the user’s language.
- Long answers: split into multiple messages (~3200 chars); optional \`[1/N]\` prefix.
- **Voice outbound:** build with media-capable CLI; prefer AAC \`.m4a\` for iOS;
  gateway may transcode via ffmpeg.

### Cron delivery to Sonar

With the gateway enabled, scheduled jobs may use \`deliver=sonar\` or
\`deliver=sonar:<npub>\` (set \`SONAR_HOME_CHANNEL\` for a default npub).

---

## Mode B — Legacy Python bridge

Use when the gateway Sonar plugin is unavailable. Community automation lives in
the Hermes skill **\`sonar-hermes-bridge\`** (install script, \`bridge_config.json\`,
systemd unit). The bridge:

1. Runs streaming \`sonar-cli listen\`
2. Parses JSON (\`sender\`, \`content\` — not \`from\` / \`text\`)
3. Invokes \`hermes chat -q "..." -Q --yolo --resume <session_id> -t "..."\`
4. Sends reply with \`sonar-cli send --to <sender>\`

**Disable gateway Sonar** before enabling the bridge. Load \`~/.hermes/.env\` into
the bridge subprocess so API keys and web backends match interactive Hermes.

---

## Mode C — Cron-polled \`listen --once\` (minimal)

Original zero-code pattern: Hermes cron runs \`sonar-cli listen --once\` every
~30s, agent handles each line via the \`terminal\` toolset, replies with \`send\`.

\`\`\`bash
SONAR_CLI_HOME="$HOME/.sonar-agent" sonar-cli listen --once
# for each {"type":"message", "sender", "content", ...}:
SONAR_CLI_HOME="$HOME/.sonar-agent" sonar-cli send --to <sender> --text "<reply>"
\`\`\`

Install the skill shipped in this repo:

\`\`\`bash
mkdir -p ~/.hermes/skills/sonar-cli
cp core/sonar-cli/hermes/SKILL.md ~/.hermes/skills/sonar-cli/SKILL.md
\`\`\`

Tune poll interval vs latency. The seen cursor in \`SONAR_CLI_HOME\` prevents
double-processing; \`listen\` does not emit \`mine: true\` lines.

**Never** run bare \`sonar-cli listen\` from a one-shot tool call — it blocks
forever. Use \`--once\` or \`--timeout-secs\`.

---

## Stable CLI contract (do not break without versioning)

Integrators depend on these shapes. If you change field names or semantics, bump
documented version and coordinate with \`hermes-agent\` tests
(\`tests/gateway/test_sonar_platform.py\`).

### Inbound (\`listen\`)

One JSON object per line:

\`\`\`json
{
  "type": "message",
  "group_id": "<hex>",
  "id": "<hex>",
  "sender": "npub1...",
  "content": "plain text",
  "created_at_secs": 1718900000,
  "mine": false
}
\`\`\`

| Field | Notes |
|-------|--------|
| \`sender\` | Reply with \`send --to <sender>\` — **not** \`from\` |
| \`content\` | Body — **not** \`text\` |
| \`id\` | Dedupe key |
| \`mine\` | Integrators must skip when \`true\` |
| \`media\` | Optional on voice/image inbound; text agents may ignore until handled |

### Outbound text

\`\`\`bash
sonar-cli send --home "$SONAR_CLI_HOME" --to npub1... --text "reply"
\`\`\`

Do **not** use \`send --group\` for 1:1 DM replies.

### Outbound media (voice / image / video)

When the binary supports it:

\`\`\`bash
sonar-cli send --to npub1... --file /path/to/audio.m4a --kind voice
\`\`\`

Global flags: \`--home <dir>\` (else \`SONAR_CLI_HOME\`), \`--relay <wss>\` (repeatable).

### Command summary

| Command | Output \`type\` | Purpose |
| --- | --- | --- |
| \`init\` | \`identity\` | Provision identity |
| \`identity\` | \`identity\` | npub, pubkey hex, paths |
| \`publish\` | \`published\` | KeyPackage to relays |
| \`send --to … --text …\` | \`sent\` | DM text |
| \`send --to … --file … --kind voice\` | \`sent_media\` | DM attachment |
| \`listen [--once]\` | \`message\` | Inbound drain |
| \`groups\` | \`group\` | List groups |
| \`messages\` | \`message\` | History (includes \`mine:true\`) |

---

## Known limitations

- **Group replies:** \`send\` targets an npub (1:1 DM). No \`send --group <id>\` for
  multi-member groups; integrators can read group lines from \`listen\` but only
  reply in DMs unless CLI gains group send.
- **No BLE mesh** for the CLI agent — relay path only.
- **Inbound voice** may require integrator support for \`media[]\` when \`content\`
  is empty.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| No reply | Sender not allowlisted | \`SONAR_ALLOWED_SENDERS\` / yaml list |
| Duplicate replies | Gateway + bridge both listening | Stop legacy bridge service |
| Parser drops messages | Wrong JSON fields | Use \`sender\` / \`content\` |
| Wrong binary | \`nostr-cli\` on PATH | Reinstall from this repo |
| Web tools fail in service | \`.env\` not loaded | systemd \`EnvironmentFile\` or bridge \`load_hermes_env\` |
| Voice fails on iOS | Opus OGG or old CLI | Media build + \`.m4a\` / AAC |
| \`listen\` hangs tool | Missing \`--once\` | Cron/tool calls must use \`--once\` |

---

## Smoke test (two temp homes)

\`\`\`bash
A=$(mktemp -d); B=$(mktemp -d)
sonar-cli --home "$A" init >/dev/null; sonar-cli --home "$A" publish >/dev/null
sonar-cli --home "$B" init >/dev/null; sonar-cli --home "$B" publish >/dev/null
NPUB_B=$(sonar-cli --home "$B" identity | python3 -c 'import sys,json;print(json.load(sys.stdin)["npub"])')

sonar-cli --home "$A" send --to "$NPUB_B" --text "ping"
sonar-cli --home "$B" listen --once
sonar-cli --home "$B" listen --once   # should emit nothing (cursor)
\`\`\`

Relay propagation can take a few seconds; retry \`listen --once\` if needed.

---

## Optional: MCP wrapper

For structured tools instead of shell, a thin stdio MCP server can wrap
\`sonar-cli\` and register under \`mcp_servers\` in Hermes. This is optional; modes
A–C do not require it.

---

## Further reading

- Hermes gateway plugin README: \`hermes-agent/plugins/platforms/sonar/README.md\`
- Hermes docs: https://hermes-agent.nousresearch.com/docs
- Agent skill (terminal contract): \`core/sonar-cli/hermes/SKILL.md\``,
    },
  },
};
