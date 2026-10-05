# Brainstorm — Kimi-powered PR Review Skill

Date: 2026-07-05
Status: Clarified — ready for `/ship`

## Clarified Problem Statement

**Goal:** Add an automated code review to Sonar that runs on every PR (and every
new push to a PR), powered by the Kimi model via the Moonshot API, implemented as
a Goose **skill committed inside the repository** so it can also be run locally by
any agent before pushing.

**Constraints (must-have / can't-break):**
- Review logic lives as a Goose skill in-repo (single source of truth), so it is
  runnable both in CI (Kimi) and locally (any agent) before push.
- CI triggers on `pull_request: [opened, synchronize, reopened]` — every PR, every push.
- Model: Kimi via Moonshot API key, stored as a GitHub Actions secret
  (`MOONSHOT_API_KEY`). Never committed (repo *Local Secrets Rule*).
- Scope: the **whole PR diff**.
- Verdict behavior:
  - **Clean** → approve the PR: `gh pr review <n> --approve --body "<short message>"`.
  - **Issues** → inline line comments via `gh api .../pulls/<n>/comments` (one per
    finding, with `path`/`line`/`side=RIGHT`/`commit_id`) **+** one top-level
    summary comment via `gh pr comment`. Use `--request-changes` when a HIGH-severity
    finding exists.
- Must keep the `GITHUB_TOKEN` scope at `pull-requests: write` (and `contents: read`).
- No user-facing app behavior changes → cross-platform rule N/A (tooling/CI only).

**Non-goals:**
- Auto-merging or blocking merges via required status checks (verdict is advisory
  for v1; gating is a later opt-in).
- Reviewing code outside the diff (full-repo analysis).
- A web dashboard / persisted review history.
- Multi-model ensemble review (one model = Kimi in CI).
- Per-platform (iOS vs Android) review rules (generic senior-engineer review for v1).

**Success criteria:**
- Opening a PR triggers the workflow; a review appears within ~1–2 min.
- Pushing a commit to an open PR re-runs the review.
- Clean diffs produce an approval with a short message; no inline spam.
- Diffs with issues produce line-accurate inline comments (lines that actually
  exist in the diff hunk, not 422 errors) plus a human-readable summary comment.
- A developer can run the same review locally (e.g. `/run pr-review --pr 165` or
  against the current branch) before pushing and get the same output shape.

## Affected files (planned)

- `.goose/skills/pr-review/SKILL.md` — the review skill (model-agnostic instructions
  + structured output contract). *(in-repo discovery path to confirm at impl;
  `.goose/skills/` is the standard Goose project-skill location.)*
- `.github/workflows/pr-review.yml` — trigger, install Goose, wire Moonshot provider
  from secret, run skill non-interactively, post verdict.
- 1 GitHub secret: `MOONSHOT_API_KEY`.
- (optional) `docs/review-rubric.md` — the checklist the skill references, so the
  rubric can evolve without touching the skill.

## Approach (chosen: in-repo skill + thin CI wrapper)

The review logic is a Goose skill. CI is a thin wrapper that installs Goose, wires
a Moonshot OpenAI-compatible provider (`base_url: https://api.moonshot.ai/v1`,
engine `openai`, model e.g. `moonshot-v1-128k` or `kimi-k2`), and invokes the
skill non-interactively against the PR. Local devs invoke the identical skill.

### Skill output contract (what the skill must emit)

Structured output the CI can parse (a final fenced JSON block):

```json
{
  "verdict": "APPROVE | COMMENT | REQUEST_CHANGES",
  "summary": "Overall assessment: positives, risks, what to check.",
  "comments": [
    { "path": "src/file.rs", "line": 42, "severity": "HIGH|MED|LOW",
      "body": "Issue + fix. ```suggestion\n...```" }
  ]
}
```

CI then maps:
- `verdict == APPROVE` → `gh pr review --approve`
- else → inline comments (`gh api`) + summary comment (`gh pr comment`);
  `REQUEST_CHANGES` adds `gh pr review --request-changes`.

## Concrete fixes baked in vs. the original pasted workflow

1. **`PATH=$(...)` shadowing** — use a different var name (`FILE_PATH`).
2. **`COMMIT` fetched inside the loop** — fetch `headRefOid` once before the loop.
3. **Inline comment 422s** — each `line` must fall inside a diff hunk on the RIGHT
   side; validate/skip out-of-range lines. Provide `start_line` for multi-line.
4. **Agent ≠ pure JSON** — Goose streams reasoning/tool calls. Either request a
   final fenced JSON block and extract it, or run the skill with structured output
   and capture the last JSON object. Do not assume stdout is pure JSON.
5. **Diff not fetched** — add an explicit step that materializes the PR diff
   (`gh pr diff` or `git diff origin/$BASE...HEAD`) and feeds it to the skill.

## Open questions (non-blocking)

- Confirm Goose's exact in-repo skill discovery path (`.goose/skills/` vs a config
  entry) at implementation time.
- Which Moonshot model id to pin (`moonshot-v1-128k` vs `kimi-k2` availability on
  the direct Moonshot API) — the local setup used `kimi-k2-5` via a localhost proxy
  that won't exist on the runner.
- Token budget on very large diffs (Moonshot 128k context) — cap diff size or
  chunk per file if a PR exceeds it.

## Recommendation

Ship the in-repo Goose skill + the thin CI wrapper. Start advisory (no required
status check); add gating later if the team wants it.
