# Sonar GitHub Coding Bot

Production-oriented MVP of a self-hosted GitHub App that turns an `ai-fix`
issue label into a bounded coding job and, when a meaningful proposal exists,
a draft pull request. It never merges pull requests.

## What is implemented

- Raw-body `X-Hub-Signature-256` verification and delivery replay protection.
- Allowlisted repositories and trusted-labeler permission checks.
- PostgreSQL queue with an active-issue unique index, `FOR UPDATE SKIP LOCKED`,
  leases, attempt fencing, cancellation, and worker heartbeats.
- GitHub App JWT and short-lived installation-token authentication through
  Octocrab; no personal access tokens.
- OpenAI-compatible chat-completions provider behind the `LanguageModel` trait.
- Explicit agent tools: `list_files`, `search_files`, `read_file`,
  `apply_patch`, `git_diff`, `git_status`, `run_validation_command`, `finish`.
- Hard limits for steps, files, diff lines, commands, job duration, output,
  retries, and LLM tokens.
- Docker-isolated repository execution with a temporary filesystem, non-root
  user, no host mounts, no Docker socket, bounded CPU/RAM/PIDs, read-only root,
  and network disabled except controller-owned clone/push windows.
- Controller-owned final diff validation, validation commands, Git commit/push,
  draft PR reporting, and issue lifecycle comments.
- Optional root `.ai-fix.toml` policy that can only tighten protected paths and
  select exact pre-allowlisted validation commands; see the sample under
  `examples/`.
- Structured tracing and Prometheus metrics.

See [Architecture](docs/ARCHITECTURE.md) and [Security model](docs/SECURITY.md).

## Quick start

1. Follow [GitHub App setup](docs/GITHUB_APP_SETUP.md).
2. Copy `.env.example` to `.env` and replace every placeholder.
3. Set `DOCKER_GID` to the group ID that owns `/var/run/docker.sock` on Linux.
4. Build and start:

   ```sh
   docker compose build
   docker compose up -d
   docker compose ps
   ```

5. Configure the GitHub App webhook URL as
   `https://your-host.example/webhooks/github` and label an allowlisted issue
   `ai-fix` as a trusted maintainer.

The API binds to `127.0.0.1:8080` by default. Put it behind a TLS reverse proxy.

## API

| Method | Path | Authentication | Purpose |
| --- | --- | --- | --- |
| `POST` | `/webhooks/github` | GitHub HMAC | Receive GitHub events |
| `GET` | `/health` | none | Process liveness |
| `GET` | `/ready` | none | Database and worker readiness |
| `GET` | `/metrics` | admin bearer token | Prometheus metrics |
| `GET` | `/jobs/{id}` | admin bearer token | Job status |
| `POST` | `/jobs/{id}/cancel` | admin bearer token | Cooperative cancellation |

Administrative calls use `Authorization: Bearer $ADMIN_API_TOKEN`.

## Validation

From this directory:

```sh
cargo fmt --all --check
cargo check --workspace --all-targets
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace

# Requires a disposable PostgreSQL DATABASE_URL:
cargo test -p coding-bot-store --test postgres_queue -- --ignored
```

Docker and local development details are in [Development](docs/DEVELOPMENT.md).

## MVP limitations

- One OpenAI-compatible chat-completions provider is included; the trait permits
  additional providers.
- The bundled sandbox image covers Rust, Go, Node/npm, Python/pytest, and Make.
  Build a custom image for pnpm or repository-specific native dependencies.
- Validation failures may be published only in a meaningful draft proposal and
  are always reported as failed. An empty proposal is never published.
- A push that succeeds immediately before a GitHub API outage can leave an
  orphan proposal branch. The job remains failed and no merge occurs.
- The trusted controller needs Docker daemon access. Treat it as a privileged
  infrastructure component and never mount the socket into sandbox containers.
