# Development

## Prerequisites

- Rust 1.92+
- PostgreSQL 15+
- Docker Engine and Compose v2
- a test GitHub App and an OpenAI-compatible model endpoint for live smoke tests

## Local Rust checks

```sh
cp .env.example .env
# Edit placeholders; keep this file uncommitted.

cargo fmt --all --check
cargo check --workspace --all-targets
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

Start only PostgreSQL for the ignored queue test:

```sh
docker compose up -d postgres
export DATABASE_URL='postgres://coding_bot:YOUR_PASSWORD@127.0.0.1:5432/coding_bot'
cargo test -p coding-bot-store --test postgres_queue -- --ignored
```

## Run the stack

```sh
docker compose build
docker compose up -d
docker compose logs -f api worker
```

On Linux, set `DOCKER_GID` to the group ID of `/var/run/docker.sock`. The trusted
worker controller needs the socket to create disposable sandboxes; no sandbox
receives it.

The sandbox image intentionally has no dependency-download tools and runs with
network disabled during builds/tests. Repositories must have vendored/cached
dependencies or use a purpose-built worker image populated ahead of execution.

## Live smoke test

1. Install the test App on one allowlisted test repository.
2. Open a small issue with deterministic regression steps.
3. Apply `ai-fix` as a maintainer.
4. Confirm start comment, job state, sandbox creation/removal, validation output,
   and draft PR body.
5. Confirm the PR is draft and no merge action occurred.
6. Remove the label mid-run in a second test and confirm publication is refused.

Never use production credentials or a repository containing sensitive data for
development smoke tests.
