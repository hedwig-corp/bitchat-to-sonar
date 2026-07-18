# Subby mascot — clarified problem statement

## Clarified Problem Statement

**Goal:** Introduce Subby, a quiet submarine mascot, so people recognize Sonar’s character without changing chat performance or protocol trust.

**Constraints:**
- Cross-platform: any in-app surface must land on `ios/` and `apps/sonar/` together (or document a tracked gap).
- Tone: quiet / utilitarian — almost never speaks; no cute error copy.
- Must never interrupt chat open, send, sync, or scroll; decoration and optional opt-in surfaces only.
- Must never speak for the protocol or imply network/relay trust.
- Must never replace real error/status copy with shrugs.
- v1 ships an art system plus **one** surface (in-app or web), not every empty state at once.
- Success metric for v1 is brand recognition (“that’s Subby / Sonar”), not engagement metrics.

**Non-goals (v1):**
- Replacing Hermes / `sonar-cli` agent ops with a productized in-app AI.
- Making Subby a required onboarding narrator or help system.
- Redesigning the app icon / wordmark away from existing `sonar/brand` marks unless Subby is clearly a companion, not a replacement.
- Shipping a dedicated always-on AI server as a hard dependency for the consumer apps.

**Success criteria:**
- Subby has a small, reusable art kit (static poses + optional simple motion) shared by web and apps.
- At least one high-visibility surface shows Subby (website hero **or** one empty state **or** About).
- Users/testers can name Subby as Sonar’s mascot without reading a blog post.
- Chat cold-open / send / sync paths unchanged (no Subby work on the critical path).

**Inferences from answers (correct if wrong):**
- Job is still open; AI bot was floated as a possible *later* role, not the v1 definition.
- Prefer brand recognition over “Subby helps me do X” for the first ship.
- Quiet tone means captions, if any, are rare and short.

---

## Approaches Considered

### Approach A: Brand kit + one quiet surface (recommended for v1)
- **Sketch:** Define Subby as visual identity only: a small asset pack (idle, “listening,” optional wordmark lockup). Ship the kit on the website (hero / about / blog) **and** one in-app quiet surface (e.g. Home empty chats or About/Settings). No dialogue system, no network calls for Subby.
- **Affected files:** `design/handoff/project/sonar/brand/` (new Subby assets); `web/src/routes/` (one marketing surface); `ios/.../SNEmptyState` or Settings/About; Compose mirror empty/about; short note in `docs/` or design handoff.
- **Tradeoffs:** Gains recognition with lowest risk to Signal-local-first rules. Does not give Subby a “job” beyond presence. Easy to layer stickers or an opt-in bot later without rewriting identity.
- **Effort:** S–M (art is the long pole; code wiring is small).

### Approach B: Official Subby sticker pack
- **Sketch:** Publish a Sonar-authored sticker pack (`docs/SONAR-STICKERS.md` / kind `30031`) featuring Subby poses; install by default or offer once in picker. Recognition comes from chat composition, not chrome.
- **Affected files:** sticker pack authoring via `sonar-cli post` + Blossom assets; pack metadata; optional default-install in iOS + Compose sticker UX; `/stickers` web viewer already exists.
- **Tradeoffs:** Users *use* Subby in messages (stronger ownership). Requires pack hosting, prefetch/perf care (`sticker_*` benches), and doesn’t fix cold empty-state brand unless combined with A. Still quiet if stickers are wordless.
- **Effort:** M.

### Approach C: Subby as opt-in AI companion on a dedicated host
- **Sketch:** Run a dedicated Marmot identity (“Subby”) on a server using the existing Hermes ↔ `sonar-cli` bridge (`docs/HERMES-AGENT.md`, `docs/RELAY-SMOKE-AGENTS.md`). Users opt in (QR / npub / “Message Subby”) to a normal DM; Subby never sits on the chat-open critical path. Personality stays short and utilitarian.
- **Affected files:** ops/config outside the app (Hermes gateway + `sonar-cli listen`); optional in-app deep link / “Talk to Subby” entry on iOS + Compose; docs for the public npub and rate limits; **not** embedding an LLM in `sonarffi`.
- **Tradeoffs:** Gives Subby a concrete job and matches the “AI bot on a dedicated server” idea. Costs: ops, abuse, privacy expectations, support burden, and brand risk if answers are wrong. Conflicts with quiet tone unless replies are tightly scoped (FAQ / status only). Larger than brand recognition; should not gate mascot v1.
- **Effort:** L (product + ops + safety), even if transport glue already exists.

---

## Recommendation

**Ship Approach A first.** Your success criterion is recognition and your tone is quiet; a brand kit plus one surface delivers that without inventing a product role under pressure. Treat **B** as a natural second step once art exists (stickers reuse the same poses). Treat **C** as a separate product decision: the repo already has Hermes-over-Sonar for agents, so Subby-as-bot is “brand a dedicated agent identity,” not a new protocol — but it should stay opt-in and out of the critical path, and should not define Subby until A (and ideally B) exist.

If you later want C, constrain it hard: FAQ/help only, no payment advice, no “relay is fine” claims, clear “experimental bot” labeling, and no blocking of local chat.

## Open questions

- Exact first surface: website hero vs Home empty state vs About?
- Who owns Subby art (in-house vs contractor), and what license for stickers reuse?
- Should the app icon stay the current sonar mark, with Subby only as companion art?
- For a future Subby bot: public npub for everyone, or invite-only / rate-limited demo?
- Any locales: wordless art only in v1, or short English caption strings that need i18n?
