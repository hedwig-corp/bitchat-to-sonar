# Security model

Repository content, issues, comments, model output, tests, compilers, and build
scripts are untrusted.

## Trust boundaries

The API/controller owns GitHub App, webhook, LLM, database, and administrative
credentials. Sandbox containers receive none of them. The only repository token
is a short-lived installation token injected into one Git process for clone or
push. It is never embedded in a URL, Git config, model context, or log.

The controller has Docker daemon access and is therefore privileged. Compromise
of that container is host-impacting. Restrict its image, operators, network, and
socket; do not expose administrative endpoints publicly. Sandbox containers
never receive the Docker socket or host filesystem mounts.

## Sandbox controls

- temporary Docker tmpfs workspace and read-only root filesystem;
- untrusted tools run as UID 10001 while controller-owned Git metadata and
  publication run as UID 10002; all Linux capabilities are dropped and
  `no-new-privileges` is enabled;
- CPU, memory, PID, output, command, and total-job limits;
- network `none` during all model-driven tools and validation;
- no SSH agent, cloud credentials, production secrets, Docker CLI/socket, curl,
  wget, or privilege-escalation tools;
- fixed executable/argument allowlist with no shell, pipelines, substitution,
  or arbitrary command strings;
- lexical traversal rejection, canonical path checks, escaping-symlink scan,
  and changed-symlink/binary rejection;
- protected path checks both before `git apply` and against the controller-owned
  final diff, including untracked files.

Git metadata lives on a separate tmpfs that UID 10001 can read but cannot
modify. Publication uses the configured repository URL directly rather than an
untrusted `origin` setting. Before either network window, the controller checks
that the sandbox contains only its inert PID 1; any residual process terminates
the sandbox and the job.

An optional repository `.ai-fix.toml` is itself protected. Because repository
content is untrusted, it can only add blocked paths and choose exact commands
from the controller's existing allowlist. It cannot enable a command, remove a
blocked path, add network access, or change a hard limit.

Validation commands still execute arbitrary repository code. Their safety comes
from isolation and resource bounds, not from the command name.

## Prompt injection

Issue and repository text is marked as untrusted data. Policy and tool schemas
are controller-owned. Invalid/repeated calls count against budgets. The model
cannot change network state, request secrets, alter command policy, publish, or
merge. A controller-owned final gate decides whether a proposal may be pushed.

## Webhook and API controls

- SHA-256 HMAC verification covers the exact raw body.
- Delivery IDs are persisted uniquely to reject replay.
- Only `issues:labeled` with exact `ai-fix`, open issue, allowlisted repository,
  non-bot sender, installation ID, and trusted labeler can enqueue.
- Active jobs are unique per numeric repository ID and issue number.
- Administrative bearer tokens are compared through constant-time SHA-256
  digests.
- Request bodies are capped at 1 MiB.

## Secret handling

`.env`, private keys, and `secrets/` are ignored. `Debug` implementations redact
secret values. Logs contain job/repository identifiers and operation results,
but never tokens, keys, LLM credentials, full private repository contents, or
environment dumps.
