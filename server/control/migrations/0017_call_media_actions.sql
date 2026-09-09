-- Durable LiveKit administration. Authorization changes are committed first,
-- this outbox guarantees media eviction is retried across process or network
-- failures without ever restoring an ended/removed call seat.
CREATE TABLE call_media_actions (
    action_id uuid PRIMARY KEY,
    call_id uuid NOT NULL REFERENCES call_sessions(call_id) ON DELETE CASCADE,
    action_type text NOT NULL CHECK (action_type IN ('remove_participant', 'delete_room')),
    livekit_identity text NOT NULL DEFAULT '',
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (call_id, action_type, livekit_identity),
    CHECK (
        (action_type = 'delete_room' AND livekit_identity = '') OR
        (action_type = 'remove_participant' AND char_length(livekit_identity) BETWEEN 32 AND 128)
    )
);

CREATE INDEX call_media_actions_pending
    ON call_media_actions(next_attempt_at, created_at)
    WHERE completed_at IS NULL;
