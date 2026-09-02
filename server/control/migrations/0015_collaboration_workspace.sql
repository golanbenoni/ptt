ALTER TABLE accounts
    ADD COLUMN display_name text;

UPDATE accounts
SET display_name = left(split_part(email, '@', 1), 80)
WHERE display_name IS NULL;

ALTER TABLE accounts
    ALTER COLUMN display_name SET NOT NULL,
    ADD CONSTRAINT accounts_display_name_length
        CHECK (char_length(display_name) BETWEEN 1 AND 80),
    ADD COLUMN account_kind text NOT NULL DEFAULT 'member'
        CHECK (account_kind IN ('member', 'guest', 'integration')),
    ADD COLUMN guest_expires_at timestamptz;

ALTER TABLE channels
    ADD COLUMN topic text NOT NULL DEFAULT ''
        CHECK (char_length(topic) <= 280),
    ADD COLUMN is_announcement boolean NOT NULL DEFAULT false,
    ADD COLUMN archived_at timestamptz,
    ADD COLUMN created_by uuid REFERENCES accounts(aci) ON DELETE SET NULL;

CREATE TABLE channel_templates (
    template_id uuid PRIMARY KEY,
    display_name text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 80),
    channel_kind text NOT NULL CHECK (channel_kind IN ('team', 'duty', 'adhoc')),
    topic text NOT NULL DEFAULT '' CHECK (char_length(topic) <= 280),
    retention_days integer NOT NULL CHECK (retention_days BETWEEN 1 AND 365),
    default_role text NOT NULL CHECK (
        default_role IN ('talk', 'listen', 'barge', 'dispatch', 'emergency-target')
    ),
    is_announcement boolean NOT NULL DEFAULT false,
    created_by uuid REFERENCES accounts(aci) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE user_groups (
    group_id uuid PRIMARY KEY,
    display_name text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 80),
    handle text NOT NULL UNIQUE CHECK (handle ~ '^[a-z0-9][a-z0-9_-]{1,31}$'),
    created_by uuid REFERENCES accounts(aci) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE user_group_members (
    group_id uuid NOT NULL REFERENCES user_groups(group_id) ON DELETE CASCADE,
    aci uuid NOT NULL REFERENCES accounts(aci) ON DELETE CASCADE,
    PRIMARY KEY (group_id, aci)
);

CREATE TABLE operation_runs (
    run_id uuid PRIMARY KEY,
    channel_id uuid NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
    template_id uuid REFERENCES channel_templates(template_id) ON DELETE SET NULL,
    display_name text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 120),
    severity text NOT NULL CHECK (severity IN ('routine', 'priority', 'critical')),
    status text NOT NULL CHECK (status IN ('active', 'monitoring', 'resolved', 'archived')),
    commander_aci uuid NOT NULL REFERENCES accounts(aci),
    started_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz
);

CREATE INDEX operation_runs_channel_updated
    ON operation_runs(channel_id, updated_at DESC);

CREATE TABLE operation_acknowledgements (
    run_id uuid NOT NULL REFERENCES operation_runs(run_id) ON DELETE CASCADE,
    event_id uuid NOT NULL,
    aci uuid NOT NULL REFERENCES accounts(aci) ON DELETE CASCADE,
    acknowledged_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, event_id, aci)
);

CREATE TABLE channel_integrations (
    integration_id uuid PRIMARY KEY,
    aci uuid NOT NULL UNIQUE REFERENCES accounts(aci) ON DELETE CASCADE,
    channel_id uuid NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
    display_name text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 80),
    token_sha256 bytea NOT NULL UNIQUE CHECK (octet_length(token_sha256) = 32),
    identity_key bytea NOT NULL CHECK (octet_length(identity_key) BETWEEN 32 AND 4096),
    capabilities text[] NOT NULL DEFAULT ARRAY['post']::text[],
    created_by uuid REFERENCES accounts(aci) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz,
    revoked_at timestamptz,
    CHECK (capabilities <@ ARRAY['post', 'acknowledge', 'start-operation']::text[])
);

CREATE INDEX channel_integrations_active
    ON channel_integrations(channel_id)
    WHERE revoked_at IS NULL;
