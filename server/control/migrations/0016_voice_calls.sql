CREATE TABLE call_sessions (
    call_id uuid PRIMARY KEY,
    conversation_id uuid NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
    host_aci uuid NOT NULL REFERENCES accounts(aci),
    state text NOT NULL CHECK (state IN ('ringing', 'connecting', 'active', 'ended')),
    call_epoch integer NOT NULL DEFAULT 1 CHECK (call_epoch > 0),
    participant_limit integer NOT NULL DEFAULT 8 CHECK (participant_limit BETWEEN 2 AND 8),
    idempotency_key_sha256 bytea NOT NULL CHECK (octet_length(idempotency_key_sha256) = 32),
    livekit_room_name text NOT NULL UNIQUE CHECK (char_length(livekit_room_name) BETWEEN 32 AND 128),
    created_at timestamptz NOT NULL DEFAULT now(),
    ringing_expires_at timestamptz NOT NULL,
    last_key_rotation_at timestamptz NOT NULL DEFAULT now(),
    activated_at timestamptz,
    ended_at timestamptz,
    coordination_expires_at timestamptz NOT NULL,
    end_reason text CHECK (end_reason IS NULL OR end_reason IN (
        'completed', 'declined', 'missed', 'cancelled', 'host_ended',
        'sos_preempted', 'safety_limit', 'media_failed'
    )),
    UNIQUE (host_aci, idempotency_key_sha256),
    CHECK (ringing_expires_at <= created_at + interval '45 seconds')
);

CREATE INDEX call_sessions_conversation_created
    ON call_sessions(conversation_id, created_at DESC);
CREATE INDEX call_sessions_active
    ON call_sessions(state, ringing_expires_at)
    WHERE state <> 'ended';

CREATE TABLE call_participants (
    call_id uuid NOT NULL REFERENCES call_sessions(call_id) ON DELETE CASCADE,
    aci uuid NOT NULL REFERENCES accounts(aci) ON DELETE CASCADE,
    claimed_device_id integer,
    livekit_identity text UNIQUE CHECK (livekit_identity IS NULL OR char_length(livekit_identity) BETWEEN 32 AND 128),
    state text NOT NULL CHECK (state IN (
        'invited', 'ringing', 'connecting', 'joined', 'declined', 'left',
        'removed', 'answered_elsewhere', 'missed', 'failed'
    )),
    join_order integer NOT NULL CHECK (join_order > 0),
    invited_by uuid NOT NULL REFERENCES accounts(aci),
    invited_at timestamptz NOT NULL DEFAULT now(),
    answered_at timestamptz,
    joined_at timestamptz,
    left_at timestamptz,
    PRIMARY KEY (call_id, aci),
    UNIQUE (call_id, join_order),
    CHECK (claimed_device_id IS NULL OR claimed_device_id BETWEEN 1 AND 2)
);

CREATE UNIQUE INDEX call_participants_one_live_account_seat
    ON call_participants(aci)
    WHERE state IN ('connecting', 'joined');

CREATE TABLE call_coordination_events (
    event_sequence bigserial PRIMARY KEY,
    call_id uuid NOT NULL REFERENCES call_sessions(call_id) ON DELETE CASCADE,
    recipient_aci uuid REFERENCES accounts(aci) ON DELETE CASCADE,
    event_type text NOT NULL CHECK (event_type IN (
        'ringing', 'roster_changed', 'answered', 'cancelled', 'ended'
    )),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX call_coordination_events_recipient
    ON call_coordination_events(recipient_aci, event_sequence);

-- LiveKit webhooks are at-least-once. Persist the opaque event identifier so
-- participant transitions are idempotent across retries and server replicas.
CREATE TABLE livekit_webhook_events (
    event_id text PRIMARY KEY CHECK (char_length(event_id) BETWEEN 8 AND 128),
    call_id uuid NOT NULL REFERENCES call_sessions(call_id) ON DELETE CASCADE,
    received_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE push_registrations DROP CONSTRAINT IF EXISTS push_registrations_provider_check;
ALTER TABLE push_registrations ADD CONSTRAINT push_registrations_provider_check CHECK (
    provider IN (
        'fcm', 'apns', 'apns-ptt', 'apns-voip',
        'apns-sandbox', 'apns-ptt-sandbox', 'apns-voip-sandbox'
    )
);

ALTER TABLE push_outbox DROP CONSTRAINT IF EXISTS push_outbox_kind_check;
ALTER TABLE push_outbox ADD CONSTRAINT push_outbox_kind_check
    CHECK (kind IN ('mailbox', 'voice', 'call'));

ALTER TABLE push_outbox DROP CONSTRAINT IF EXISTS push_outbox_provider_check;
ALTER TABLE push_outbox ADD CONSTRAINT push_outbox_provider_check CHECK (
    provider IN (
        'fcm', 'apns', 'apns-ptt', 'apns-voip',
        'apns-sandbox', 'apns-ptt-sandbox', 'apns-voip-sandbox'
    )
);
