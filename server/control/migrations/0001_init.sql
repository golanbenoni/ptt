CREATE TABLE accounts (
    aci uuid PRIMARY KEY,
    email text NOT NULL UNIQUE CHECK (email = lower(email)),
    is_admin boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    disabled_at timestamptz
);

CREATE TYPE device_status AS ENUM ('pending', 'active', 'revoked');

CREATE TABLE devices (
    aci uuid NOT NULL REFERENCES accounts(aci) ON DELETE CASCADE,
    device_id integer NOT NULL CHECK (device_id BETWEEN 1 AND 2),
    mailbox_id uuid NOT NULL UNIQUE,
    display_name text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 80),
    identity_key bytea NOT NULL,
    access_token_sha256 bytea NOT NULL UNIQUE CHECK (octet_length(access_token_sha256) = 32),
    status device_status NOT NULL,
    linked_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    PRIMARY KEY (aci, device_id)
);

CREATE UNIQUE INDEX devices_two_active_guard
    ON devices (aci, device_id) WHERE status = 'active';

CREATE TABLE invitations (
    id uuid PRIMARY KEY,
    email text NOT NULL CHECK (email = lower(email)),
    token_sha256 bytea NOT NULL UNIQUE CHECK (octet_length(token_sha256) = 32),
    grants_admin boolean NOT NULL DEFAULT false,
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE magic_links (
    id uuid PRIMARY KEY,
    invitation_id uuid REFERENCES invitations(id) ON DELETE CASCADE,
    email text NOT NULL CHECK (email = lower(email)),
    token_sha256 bytea NOT NULL UNIQUE CHECK (octet_length(token_sha256) = 32),
    purpose text NOT NULL CHECK (purpose IN ('enroll', 'link_device', 'recover')),
    grants_admin boolean NOT NULL DEFAULT false,
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE channels (
    channel_id uuid PRIMARY KEY,
    display_name text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 80),
    title_ciphertext bytea,
    kind text NOT NULL CHECK (kind IN ('team', 'duty', 'adhoc', 'direct')),
    membership_epoch integer NOT NULL DEFAULT 1 CHECK (membership_epoch > 0),
    distribution_id uuid NOT NULL,
    retention_days integer NOT NULL DEFAULT 30 CHECK (retention_days BETWEEN 1 AND 365),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE memberships (
    channel_id uuid NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
    aci uuid NOT NULL REFERENCES accounts(aci) ON DELETE CASCADE,
    role text NOT NULL CHECK (role IN ('talk', 'listen', 'barge', 'dispatch', 'emergency-target')),
    joined_epoch integer NOT NULL CHECK (joined_epoch > 0),
    left_epoch integer,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, aci)
);

CREATE TABLE prekey_bundles (
    aci uuid NOT NULL,
    device_id integer NOT NULL,
    opaque_bundle bytea NOT NULL CHECK (octet_length(opaque_bundle) BETWEEN 32 AND 65536),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (aci, device_id),
    FOREIGN KEY (aci, device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE
);

CREATE TABLE one_time_prekeys (
    id bigserial PRIMARY KEY,
    aci uuid NOT NULL,
    device_id integer NOT NULL,
    kind text NOT NULL CHECK (kind IN ('x25519', 'kyber')),
    public_key bytea NOT NULL,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (aci, device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE
);

CREATE INDEX one_time_prekeys_available
    ON one_time_prekeys (aci, device_id, kind, id) WHERE consumed_at IS NULL;

CREATE TABLE device_link_requests (
    request_id uuid PRIMARY KEY,
    aci uuid NOT NULL,
    initiator_device_id integer NOT NULL,
    qr_token_sha256 bytea NOT NULL UNIQUE CHECK (octet_length(qr_token_sha256) = 32),
    expires_at timestamptz NOT NULL,
    claimed_device_id integer,
    approved_at timestamptz,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (aci, initiator_device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE,
    FOREIGN KEY (aci, claimed_device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE,
    CHECK (claimed_device_id IS NULL OR claimed_device_id BETWEEN 1 AND 2)
);

CREATE TABLE mailbox_items (
    item_id uuid PRIMARY KEY,
    mailbox_id uuid NOT NULL REFERENCES devices(mailbox_id) ON DELETE CASCADE,
    envelope bytea NOT NULL,
    expires_at timestamptz NOT NULL,
    delivered_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX mailbox_items_pending ON mailbox_items (mailbox_id, created_at)
    WHERE delivered_at IS NULL;

CREATE TABLE history_objects (
    object_id uuid PRIMARY KEY,
    channel_id uuid NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
    talk_id uuid NOT NULL,
    membership_epoch integer NOT NULL,
    media_kid numeric(20, 0) NOT NULL,
    storage_key text NOT NULL UNIQUE,
    ciphertext_bytes bigint NOT NULL CHECK (ciphertext_bytes > 0),
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (channel_id, talk_id)
);

CREATE TABLE push_registrations (
    aci uuid NOT NULL,
    device_id integer NOT NULL,
    provider text NOT NULL CHECK (provider IN ('fcm', 'apns', 'apns-ptt')),
    token bytea NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (aci, device_id, provider),
    FOREIGN KEY (aci, device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE
);

CREATE TABLE email_outbox (
    id uuid PRIMARY KEY,
    recipient text NOT NULL,
    template text NOT NULL,
    payload jsonb NOT NULL,
    attempts integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    sent_at timestamptz,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE audit_events (
    event_id bigserial PRIMARY KEY,
    actor_aci uuid,
    action text NOT NULL,
    subject_hash bytea,
    detail jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX audit_events_created_at ON audit_events (created_at DESC);

CREATE TABLE relay_leases (
    channel_id uuid NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
    sender_demux bigint NOT NULL CHECK (sender_demux BETWEEN 1 AND 4294967295),
    aci uuid NOT NULL,
    device_id integer NOT NULL,
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (channel_id, sender_demux),
    UNIQUE (channel_id, aci, device_id),
    FOREIGN KEY (aci, device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE
);
