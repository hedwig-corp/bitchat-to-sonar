CREATE TABLE coding_jobs (
    id UUID PRIMARY KEY,
    repository_id BIGINT NOT NULL CHECK (repository_id > 0),
    repository_owner TEXT NOT NULL,
    repository_name TEXT NOT NULL,
    issue_number BIGINT NOT NULL CHECK (issue_number > 0),
    installation_id BIGINT NOT NULL CHECK (installation_id > 0),
    base_branch TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'succeeded', 'failed', 'cancelled')),
    attempt INTEGER NOT NULL DEFAULT 0 CHECK (attempt >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    lease_expires_at TIMESTAMPTZ,
    cancel_requested BOOLEAN NOT NULL DEFAULT FALSE,
    error_message TEXT,
    branch_name TEXT,
    pull_request_number BIGINT CHECK (pull_request_number > 0)
);

CREATE UNIQUE INDEX coding_jobs_one_active_issue
    ON coding_jobs (repository_id, issue_number)
    WHERE status IN ('pending', 'running');

CREATE INDEX coding_jobs_claim_order
    ON coding_jobs (status, created_at);
