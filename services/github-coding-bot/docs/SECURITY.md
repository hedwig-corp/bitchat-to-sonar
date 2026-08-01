# Security model

Sonar messages, GitHub text, repository files, patches, tests, compilers, and
build scripts are untrusted.

## Authorization and credentials

The authenticated Sonar gateway supplies a sender identity that Hermes passes
as `actor`. The service independently checks `SONAR_AUTHORIZED_SENDERS` and
`REPOSITORY_ALLOWLIST` on every call; a sender written inside message text is
not proof of identity. Stdio access must also be limited to the Hermes operator.
The Hermes Sonar gateway must enforce its own authenticated-sender allowlist;
use the MCP `actor` check as a second gate.

The trusted MCP controller owns the GitHub App key, PostgreSQL credentials, and
Docker socket. GitHub installation tokens never enter model context, URLs, Git
config, logs, or the sandbox environment generally. They are process-scoped to
one API session or clone/push command and output is redacted.

The Docker socket is host-privileged. Harden and restrict the MCP image and host;
never mount that socket, secrets, or host paths into a repository sandbox.

## Sandbox

- read-only root and temporary tmpfs worktree;
- all capabilities dropped, `no-new-privileges`, non-root UIDs, CPU/RAM/PID and
  output/time limits;
- UID 10001 handles untrusted files/tests; UID 10002 owns separate Git metadata
  and publication;
- network `none` except controller-owned clone/push windows, which require an
  idle-process check and fail closed if network removal fails;
- no shell-command tool: validation is an exact program+argument allowlist;
- traversal/canonical-path checks, escaping/changed symlink rejection, binary
  rejection, protected-path checks before patch and again on final diff;
- file-count and diff-line limits enforced before publication.

Validation still executes arbitrary repository code. Its safety comes from the
isolation boundary, not the command name.

## Destructive actions

Issue close and PR merge require a durable two-phase confirmation. The database
stores only a SHA-256 token hash. Tokens expire, are single-use, and are bound to
actor/action/repository/target. Merge also binds current head SHA and method, so
a new commit or method change invalidates prior consent. GitHub branch
protection and required checks still apply. There are no force-push, branch
delete, workflow edit, or history-rewrite tools.

Audit records store actors, operations, targets, outcomes, and bounded metadata,
never message bodies, patches, private repository contents, keys, or tokens.
