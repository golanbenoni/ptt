ALTER TABLE push_registrations
    ADD CONSTRAINT push_registrations_provider_token UNIQUE (provider, token);

CREATE TABLE push_outbox (
    id uuid PRIMARY KEY,
    message_id uuid NOT NULL,
    aci uuid NOT NULL,
    device_id integer NOT NULL,
    provider text NOT NULL CHECK (provider IN ('fcm', 'apns', 'apns-ptt')),
    attempts integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    sent_at timestamptz,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (message_id, aci, device_id, provider),
    FOREIGN KEY (aci, device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE
);

CREATE INDEX push_outbox_pending
    ON push_outbox (next_attempt_at, created_at)
    WHERE sent_at IS NULL;
