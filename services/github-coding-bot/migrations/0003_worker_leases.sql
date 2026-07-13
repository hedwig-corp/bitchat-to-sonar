CREATE TABLE worker_heartbeats (
    worker_id TEXT PRIMARY KEY,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    current_job_id UUID REFERENCES coding_jobs(id) ON DELETE SET NULL
);

CREATE INDEX worker_heartbeats_last_seen
    ON worker_heartbeats (last_seen_at);
