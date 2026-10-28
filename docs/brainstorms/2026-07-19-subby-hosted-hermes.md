# Subby hosted Hermes (MyClaw-shaped) — clarified problem statement

## Clarified Problem Statement

**Goal:** Offer each Sonar user a personal always-on Subby agent (Hermes on Hedwig-hosted infra), reachable as a normal Sonar DM, with a web console to pair their npub and attach allowlisted MCP servers — without putting agent/tool work on the chat critical path or trusting arbitrary tools.

**Decisions locked in:**
- Product shape: **per-user** hosted Hermes; Subby is the default name/skin (not one shared public bot).
- Web console v1: **login + pair npub + configure MCP**; not self-serve “deploy a VM” UI yet.
- Hosting: **Hedwig/Sonar infra only** (no BYO Hermes host in v1).
- Tools: user may point at MCP servers, but only **allowlisted tools** may run.
- Account link: previously undecided → **recommendation below**.

**Account-link recommendation (Q5):** use **Sonar identity first** — web login via npub ownership proof (NIP-98-style HTTP auth challenge, or signed one-time challenge), then bind that npub to a provisioned Subby tenant. Do **not** invent a separate email/OAuth account as the primary key in v1; optional email can be added later for billing/support only. Rationale: the chat side already is the npub; dual accounts create link/orphan bugs and weaken “the DM is the product.”

**Constraints:**
- Cross-platform: in-app “open Subby” / deep link must work on `ios/` and `apps/sonar/` (or document gap).
- Signal-local-first: opening Subby is opening a local conversation; Hermes connect/reply must not block first paint, send queue, or other chats.
- Never embed Hermes/LLM inside `sonarffi` or the mobile binary.
- Transport stays Marmot/Nostr via existing `sonar-cli` ↔ Hermes gateway contract (`docs/HERMES-AGENT.md`).
- Tool policy is deny-by-default; MCP servers and tool names are allowlisted per tenant.
- Subby must never present tool output as protocol/relay truth; clear “AI agent” labeling.
- No payment/key export/wipe actions via tools in v1.
- Secrets (model keys, MCP tokens, tenant nsecs) stay in host config / secret store — never in the website bake or client logs.

**Non-goals (v1):**
- Self-serve multi-cloud deploy UI / “one-click MyClaw clone” marketplace.
- Full OpenClaw-style unrestricted browse/code/file agent.
- Replacing Sonar support staff or becoming the only onboarding path.
- Shipping Subby art/mascot kit (can proceed in parallel; not required for agent MVP).

**Success criteria:**
- Invite-only users each get a distinct Subby agent identity (npub) they can DM from Sonar.
- Web console: prove npub → see pairing status → add MCP endpoint → only allowlisted tools execute.
- Abuse controls: per-tenant rate limits, kill switch, and revoke MCP/pairing without app release.
- Chat open/send/sync benchmarks unchanged for non-Subby conversations; Subby replies arrive as normal message invalidation.
- Written threat model: prompt injection → tool call, cross-tenant isolation, MCP credential theft.

---

## Approaches Considered

### Approach A: Invite-only manual tenants + thin web console (recommended)
- **Sketch:** Ops provisions N Hermes gateways (or N isolated configs on one host) with one Sonar agent identity each. Web app (`web/`) does npub challenge login, stores `npub → tenant_id`, exposes pairing (`authorized_senders`) and MCP allowlist editors that write into a small control API the host agents read. In-app: “Message Subby” opens/creates the DM to that user’s agent npub (local-first pending row if needed).
- **Affected files / systems:** `web/src/routes/` (console); new small control API + secret store (likely outside this repo or `web` + worker); host Hermes/`sonar-cli` config per `docs/HERMES-AGENT.md`; iOS + Compose entry to open agent DM; docs/threat model.
- **Tradeoffs:** Proves the real product loop with real isolation before automation. Slow to scale (manual provision). Lowest chance of cross-tenant blowups.
- **Effort:** M–L (console + control plane + ops), not a weekend mascot patch.

### Approach B: Automated multi-tenant platform in one shot
- **Sketch:** Build MyClaw-like orchestration: auto-create container/VM per user, auto-issue agent nsec, billing, MCP marketplace, in-app onboarding wizard.
- **Affected files:** new platform codebase + infra-as-code; deep web + app changes; ops/SRE.
- **Tradeoffs:** Matches long-term vision; unsafe to start here — isolation, key custody, and tool allowlists are the whole product risk surface.
- **Effort:** L / multi-quarter.

### Approach C: Shared Subby bot first, fake per-user later
- **Sketch:** One Hermes identity for everyone; web page only allowlists senders + global MCP. Relabel as “per-user” later.
- **Affected files:** mostly Hermes host + pairing list; minimal web.
- **Tradeoffs:** Contradicts decision **1B**. Faster demo, but wrong isolation model and painful migration when users expect private memory/tools.
- **Effort:** S — reject for this goal.

---

## Recommendation

**Approach A.** You chose per-user hosting on your infra with pair + allowlisted MCP — that is a control-plane product, not a sticker. Start invite-only with manually provisioned tenants, npub-challenge web login, and a deny-by-default tool policy. Automate provisioning (Approach B) only after the threat model and kill switches are boring.

**Safe v1 policy pack (non-negotiable):**
1. Deny-by-default MCP tools; explicit allowlist per tenant (server URL + tool name).
2. Pairing required: agent ignores DMs from unpaired npubs.
3. No tools that can spend money, export nsec, or wipe device data.
4. Per-tenant rate limit + global kill switch.
5. Agent memory/tools isolated per tenant (separate `SONAR_CLI_HOME` / Hermes state).
6. Prompt-injection assumption: untrusted DM/MCP content never expands the allowlist.
7. Subby chat is a normal Marmot DM — no special sync path in the apps.

## Open questions

- Tenant key custody: Hedwig holds agent nsec, or generate-and-escrow with user export?
- MCP transport: streamable HTTP MCP only, or SSE/stdio bridges on the host?
- Invite mechanism: TestFlight-style codes, allowlisted npubs, or staff dashboard only?
- Pricing: free alpha vs paid before public?
- Where does the control API live — this monorepo `web/` + Worker, or a separate `subby-host` repo?
- Does “Message Subby” appear for all users or only provisioned tenants?
