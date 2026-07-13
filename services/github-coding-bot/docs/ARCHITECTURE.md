# Architecture

## Components

The project is an independent Cargo workspace so its server dependencies do not
enter Sonar's mobile `core/` build graph.

- `domain`: serializable jobs, issue context, model/tool contracts, validation,
  and pull-request reports.
- `config`: typed environment configuration, hard-limit validation, and secret
  redaction.
- `store`: SQLx/PostgreSQL durable queue, migrations, leases, cancellation, and
  readiness heartbeats.
- `github`: webhook HMAC/filtering, GitHub App authentication, installation
  sessions, issue/comments, permission checks, and draft pull requests.
- `agent`: provider-independent `LanguageModel`, OpenAI-compatible provider, tool
  schemas, budget enforcement, and the agent loop.
- `worker`: Docker sandbox lifecycle, path/command policy, Git workflow,
  controller validation, and job orchestration.
- `server`: Axum endpoints, administrative authentication, metrics, startup,
  and API/worker process modes.

## Job sequence

1. Axum reads a bounded raw webhook body and verifies its HMAC.
2. The API filters the event, authenticates the installation, verifies that the
   labeler has write/maintain/admin permission, and transactionally enqueues it.
3. A worker claims one row using `FOR UPDATE SKIP LOCKED` and starts a lease.
4. The trusted controller fetches issue context and creates an ephemeral Docker
   sandbox with networking disabled.
5. Controller-owned Git metadata is initialized on a separate protected tmpfs.
   Networking is connected only while a bounded fetch receives a short-lived
   token through process environment; it is disconnected before agent execution.
6. Root instructions are loaded in `AGENTS.md`, `CLAUDE.md`,
   `CONTRIBUTING.md`, `README.md` order. Bounded nested `AGENTS.md`/`CLAUDE.md`
   files are also supplied, with closer scope taking precedence.
7. The LLM calls only typed tools. Every path, patch, command, output, duration,
   and workspace audit is bounded by controller policy.
8. The controller runs its own project validation plan and re-audits all tracked
   and untracked changes, file modes, symlinks, protected paths, and diff size.
9. After confirming that no untrusted process remains, meaningful changes are
   staged explicitly by a separate publication UID, committed on an
   `ai-fix/issue-*` branch, and pushed to the expected repository URL without
   force using a fresh installation token.
10. The sandbox is destroyed before the controller opens a draft pull request.
11. The job and issue are updated. No code path performs merge operations.

## Queue recovery

`coding_jobs_one_active_issue` prevents concurrent active jobs for the same
numeric repository ID and issue number. Claims increment an attempt fence and
set `lease_expires_at`. A crashed worker's expired job can be reclaimed; a stale
attempt cannot renew or complete it. Cancellation is immediate for pending jobs
and cooperative for running jobs.
