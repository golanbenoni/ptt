CREATE TYPE recovery_status AS ENUM ('pending_admin', 'approved', 'denied', 'expired');

CREATE TABLE recovery_requests (
    request_id uuid PRIMARY KEY,
    link_id uuid NOT NULL UNIQUE REFERENCES magic_links(id) ON DELETE CASCADE,
    aci uuid NOT NULL REFERENCES accounts(aci) ON DELETE CASCADE,
    mailbox_id uuid NOT NULL UNIQUE,
    device_name text NOT NULL CHECK (char_length(device_name) BETWEEN 1 AND 80),
    identity_key bytea NOT NULL CHECK (octet_length(identity_key) BETWEEN 32 AND 4096),
    access_token_sha256 bytea NOT NULL UNIQUE CHECK (octet_length(access_token_sha256) = 32),
    status recovery_status NOT NULL DEFAULT 'pending_admin',
    expires_at timestamptz NOT NULL,
    approved_by uuid REFERENCES accounts(aci),
    decided_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX recovery_requests_pending
    ON recovery_requests (created_at) WHERE status = 'pending_admin';
