# Kimi PR Review

Automated code review on every PR (and every push to a PR), powered by the Kimi
model via the Moonshot API, using Goose's native `goose review` over the in-repo
review skill (`.agents/`).

## How it works

- Review logic lives in-repo:
  - `.agents/REVIEW.md` — Sonar-specific rules injected into the main review pass
    (Local Secrets, Account Key Durability, Signal-comparable local-first perf,
    cross-platform parity, Rust error propagation, crypto/payment care).
  - `.agents/checks/secrets-and-keys.md` — dedicated check subagent for
    secret/key/signing-material leakage and unsafe account-key persistence.
- CI (`.github/workflows/pr-review.yml`) installs Goose, wires the Moonshot
  provider from a secret, runs `goose review origin/<base>...HEAD --provider
  moonshot --override-model <kimi>`, and posts the verdict + inline comments via
  `gh`.
- Verdict: clean -> **approve**; findings with no high/critical -> inline comments
  + summary comment; any high/critical -> inline comments + **request changes**.
  Findings outside the diff are folded into the summary (no API 422s).

## Setup

1. Create a repository **Actions secret** named `MOONSHOT_API_KEY` with your
   Moonshot platform key (https://platform.moonshot.ai). It is never committed.
2. (Optional) set repository **Variables**:
   - `KIMI_REVIEW_MODEL` — model id, default `moonshot-v1-128k`. If your Moonshot
     account has Kimi K2, set this to e.g. `kimi-k2-0905-preview`.
   - `KIMI_REVIEW_SEVERITY` — minimum severity to report, default `low`
     (`low` | `medium` | `high`).

That's it — the workflow runs on `pull_request` (opened / synchronize / reopened).

## Run the same review locally (any model)

The review logic is model-agnostic, so you can review a branch before pushing:

```sh
goose review main...HEAD                  # default provider/model
goose review main...HEAD --provider moonshot --override-model moonshot-v1-128k
goose review main...HEAD --severity low -i "this is a refactor, flag behavior changes"
```

Local runs print the same NDJSON findings the CI posts. Add `--dry-run` to see the
assembled prompt and discovered checks without calling the model.

## Editing the review rules

- `.agents/REVIEW.md` — change what the main pass focuses on.
- `.agents/checks/*.md` — add a new check by dropping another markdown file with a
  `name:` frontmatter; each check runs as its own subagent. Keep checks focused;
  more checks = more model calls.

## Notes

- The bot does not gate merges (no required status check). It is advisory. Add a
  required status check on `Kimi PR Review` later if you want to gate on it.
- Large diffs are bounded by Moonshot's 128k context. If a PR exceeds it, consider
  `--files` to scope a check; full per-file chunking is a follow-up.
- Bot-authored PRs (dependabot, github-actions) are skipped.
