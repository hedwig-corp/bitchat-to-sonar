# Hermes GitHub Bot

A dedicated GitHub App that Hermes controls from authenticated Sonar DMs through
an MCP server. Hermes remains the only reasoning agent. This service holds the
GitHub App credentials, exposes typed GitHub tools, provides isolated coding
workspaces, and records durable audit/confirmation state. It has no webhook
trigger and no internal LLM.

```text
Sonar DM -> Hermes gateway -> stdio MCP -> GitHub App API
                                      \-> isolated Docker workspace
```

## Capabilities

- read repositories, issues, pull requests, changed files, and checks;
- create/update/reopen/comment on issues;
- comment on and submit COMMENT/APPROVE/REQUEST_CHANGES PR reviews;
- let Hermes inspect, patch, validate, commit, and normal-push code in a
  network-off sandbox, then open a draft PR;
- close issues and merge PRs only through short-lived, single-use confirmation
  tokens bound to the Sonar sender and exact target; merge tokens are also bound
  to the current head SHA and merge method;
- never expose installation tokens to Hermes, never force-push, and never delete
  branches or rewrite history.

See [Architecture](docs/ARCHITECTURE.md), [Security](docs/SECURITY.md), and the
[GitHub App setup](docs/GITHUB_APP_SETUP.md).

## Connect Hermes

1. Create and install the GitHub App.
2. Copy `.env.example` to `.env`, set an exact repository allowlist and the
   authenticated Sonar sender IDs allowed to operate the bot.
3. Build the MCP and sandbox images:

   ```sh
   docker compose build
   docker compose up -d postgres
   ```

4. Add the example from [`examples/hermes-config.yaml`](examples/hermes-config.yaml)
   to `~/.hermes/config.yaml`, replacing the absolute project directory.
5. Install [`hermes/SKILL.md`](hermes/SKILL.md) in the Hermes agent's skill
   directory so it follows the read/write and confirmation protocol.
6. Configure the Hermes Sonar gateway's own sender allowlist to the same or a
   stricter set; the MCP allowlist is defense in depth, not a replacement.

The MCP transport is stdio. Its logs go only to stderr so they cannot corrupt
JSON-RPC on stdout. GitHub sees actions as `your-app-name[bot]`, not as the
human running Hermes.

## Development checks

```sh
cargo fmt --all --check
cargo check --workspace --all-targets
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace

# Disposable PostgreSQL required:
cargo test -p coding-bot-store --test postgres_state -- --ignored
```

This is backend/operator tooling, not a Sonar app-surface feature; it does not
add iOS or Compose UI.
