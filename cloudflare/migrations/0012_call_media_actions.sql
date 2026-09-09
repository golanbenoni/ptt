PRAGMA foreign_keys = ON;

-- Durable LiveKit administration. Authorization changes are committed first,
-- scheduled maintenance retries media eviction until LiveKit acknowledges it.
CREATE TABLE call_media_actions (
  action_id TEXT PRIMARY KEY,
  call_id TEXT NOT NULL REFERENCES call_sessions(call_id) ON DELETE CASCADE,
  action_type TEXT NOT NULL CHECK (action_type IN ('remove_participant', 'delete_room')),
  livekit_identity TEXT NOT NULL DEFAULT '',
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_attempt_at TEXT NOT NULL,
  completed_at TEXT,
  last_error TEXT,
  created_at TEXT NOT NULL,
  UNIQUE (call_id, action_type, livekit_identity),
  CHECK (
    (action_type = 'delete_room' AND livekit_identity = '') OR
    (action_type = 'remove_participant' AND length(livekit_identity) BETWEEN 32 AND 128)
  )
);

CREATE INDEX call_media_actions_pending
  ON call_media_actions(next_attempt_at, created_at)
  WHERE completed_at IS NULL;
