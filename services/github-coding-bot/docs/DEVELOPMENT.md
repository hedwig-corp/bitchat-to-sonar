# Development

Prerequisites: Rust 1.92+, PostgreSQL 15+, Docker Engine/Compose v2, and a test
GitHub App installed only on disposable test repositories. No model API is
required—the reasoning agent is Hermes.

```sh
cp .env.example .env
# Edit placeholders; .env is gitignored.

cargo fmt --all --check
cargo check --workspace --all-targets
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

Test durable confirmation semantics:

```sh
docker compose up -d postgres
export DATABASE_URL='postgres://hermes_github:YOUR_PASSWORD@127.0.0.1:5432/hermes_github'
cargo test -p coding-bot-store --test postgres_state -- --ignored
```

Build the production images before connecting Hermes:

```sh
docker compose build
docker compose up -d postgres
docker compose run --rm -T mcp
```

The last command speaks MCP JSON-RPC on stdin/stdout and normally appears to
wait. Hermes starts it as a child process. Logs are on stderr.

On Linux, set `DOCKER_GID` to the group that owns `/var/run/docker.sock`. The
trusted MCP controller needs the socket to create disposable sandboxes; no
sandbox receives it. Repository builds have no network, so use vendored/cached
dependencies or a purpose-built sandbox image populated ahead of time.

For a live smoke test, use a dedicated test App/repository and verify read,
comment, review, workspace patch/validation/publish, draft PR creation, stale
merge-token rejection after a new commit, and successful explicit confirmation.
