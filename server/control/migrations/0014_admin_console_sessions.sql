CREATE TABLE admin_console_handoffs (
    token_sha256 bytea PRIMARY KEY CHECK (octet_length(token_sha256) = 32),
    aci uuid NOT NULL,
    device_id integer NOT NULL,
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (aci, device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE
);

CREATE INDEX admin_console_handoffs_expiry
    ON admin_console_handoffs (expires_at);

CREATE TABLE admin_console_sessions (
    token_sha256 bytea PRIMARY KEY CHECK (octet_length(token_sha256) = 32),
    aci uuid NOT NULL,
    device_id integer NOT NULL,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (aci, device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE
);

CREATE INDEX admin_console_sessions_expiry
    ON admin_console_sessions (expires_at);
