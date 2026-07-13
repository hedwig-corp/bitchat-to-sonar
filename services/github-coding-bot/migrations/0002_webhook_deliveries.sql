CREATE TABLE webhook_deliveries (
    delivery_id TEXT PRIMARY KEY,
    event_name TEXT NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
