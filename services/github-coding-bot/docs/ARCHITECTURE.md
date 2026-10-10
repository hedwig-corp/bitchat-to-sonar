# Architecture

## Ownership

Hermes owns intent, planning, code reasoning, and the conversation with the
Sonar user. The Rust MCP server owns authorization and side effects. It never
calls a model and cannot start work from a GitHub event.

- `server`: typed stdio MCP tools and Sonar-sender authorization;
- `github`: GitHub App JWT, repository-installation lookup, and short-lived
  installation clients;
- `worker`: isolated workspaces, protected Git metadata, bounded reads/patches,
  allowlisted validation, commit, and normal push;
- `store`: append-only audit events, workspace metadata, and atomic single-use
  confirmation challenges;
- `config`/`domain`: validated operator policy and shared types.

## GitHub action flow

Every call includes the exact authenticated Sonar sender ID. The server checks
that ID and `owner/repository` against independent allowlists before requesting
an installation token. GitHub responses and workspace output are bounded before
they enter Hermes context. Mutations are attributed by GitHub to the installed
App's `[bot]` identity and written to the audit log.

Issue close and PR merge are two-phase actions. Prepare reads the current target
and returns a token plus an exact human-readable summary. Confirm atomically
consumes the matching unexpired token. A merge confirmation is bound to actor,
repository, PR number, current head SHA, and merge method; any change requires a
new confirmation. GitHub branch protection remains the final merge policy.

## Code-change flow

1. Hermes calls `workspace_create`; the server resolves the base branch and SHA.
2. A disposable Docker container starts with a read-only root, tmpfs worktree,
   separate controller-owned Git metadata, and network `none`.
3. The controller briefly connects a configured Docker network only for clone,
   injects a short-lived installation token into one Git process, disconnects,
   and verifies the cloned SHA did not move.
4. Hermes reads guidance/files, searches, and applies unified text patches via
   typed MCP calls. It cannot run arbitrary commands or change network state.
5. Validation runs exact controller allowlisted commands in the network-off
   sandbox. Publication always re-runs the full plan and audits protected paths,
   diff/file limits, binary content, and symlinks.
6. A separate publisher UID commits and normal-pushes `hermes/*` with a fresh
   installation token. Force push is not implemented.
7. The workspace is destroyed. Hermes opens the PR with
   `github_pull_request_create`, so a transient PR API failure can be retried
   without repeating or losing the successful branch push.

Workspace state is intentionally process-local while metadata is durable. A
PostgreSQL advisory lock permits one controller per database. At startup that
controller removes any labeled sandbox left by a prior crash, invalidates old
workspace IDs, and expires their database rows.
