CREATE TABLE confirmation_challenges (
    id UUID PRIMARY KEY,
    token_hash BYTEA NOT NULL UNIQUE,
    actor TEXT NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('close_issue', 'merge_pull_request')),
    owner TEXT NOT NULL,
    repository TEXT NOT NULL,
    target_number BIGINT NOT NULL CHECK (target_number > 0),
    expected_head_sha TEXT,
    qualifier TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ
);

CREATE INDEX confirmation_challenges_expiry_idx
    ON confirmation_challenges (expires_at)
    WHERE consumed_at IS NULL;

CREATE TABLE audit_events (
    id BIGSERIAL PRIMARY KEY,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor TEXT NOT NULL,
    tool TEXT NOT NULL,
    owner TEXT,
    repository TEXT,
    target TEXT,
    outcome TEXT NOT NULL,
    details JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX audit_events_actor_time_idx ON audit_events (actor, occurred_at DESC);
CREATE INDEX audit_events_repo_time_idx ON audit_events (owner, repository, occurred_at DESC);

CREATE TABLE mcp_workspaces (
    id UUID PRIMARY KEY,
    actor TEXT NOT NULL,
    owner TEXT NOT NULL,
    repository TEXT NOT NULL,
    installation_id BIGINT NOT NULL CHECK (installation_id > 0),
    base_ref TEXT NOT NULL,
    base_sha TEXT NOT NULL,
    branch_name TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('active', 'published', 'closed', 'expired', 'failed')),
    created_at TIMESTAMPTZ NOT NULL,
    last_active_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    finished_at TIMESTAMPTZ
);

CREATE INDEX mcp_workspaces_active_expiry_idx
    ON mcp_workspaces (expires_at)
    WHERE status = 'active';
