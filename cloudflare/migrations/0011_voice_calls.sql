PRAGMA foreign_keys = ON;

CREATE TABLE call_sessions (
  call_id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
  host_aci TEXT NOT NULL REFERENCES accounts(aci),
  state TEXT NOT NULL CHECK (state IN ('ringing', 'connecting', 'active', 'ended')),
  call_epoch INTEGER NOT NULL DEFAULT 1 CHECK (call_epoch > 0),
  participant_limit INTEGER NOT NULL DEFAULT 8 CHECK (participant_limit BETWEEN 2 AND 8),
  idempotency_key_hash TEXT NOT NULL,
  livekit_room_name TEXT NOT NULL UNIQUE CHECK (length(livekit_room_name) BETWEEN 32 AND 128),
  created_at TEXT NOT NULL,
  ringing_expires_at TEXT NOT NULL,
  last_key_rotation_at TEXT NOT NULL,
  activated_at TEXT,
  ended_at TEXT,
  coordination_expires_at TEXT NOT NULL,
  end_reason TEXT CHECK (end_reason IS NULL OR end_reason IN (
    'completed', 'declined', 'missed', 'cancelled', 'host_ended',
    'sos_preempted', 'safety_limit', 'media_failed'
  )),
  UNIQUE (host_aci, idempotency_key_hash)
);
CREATE INDEX call_sessions_conversation_created ON call_sessions(conversation_id, created_at DESC);
CREATE INDEX call_sessions_active ON call_sessions(state, ringing_expires_at) WHERE state <> 'ended';

CREATE TABLE call_participants (
  call_id TEXT NOT NULL REFERENCES call_sessions(call_id) ON DELETE CASCADE,
  aci TEXT NOT NULL REFERENCES accounts(aci) ON DELETE CASCADE,
  claimed_device_id INTEGER,
  livekit_identity TEXT UNIQUE CHECK (livekit_identity IS NULL OR length(livekit_identity) BETWEEN 32 AND 128),
  state TEXT NOT NULL CHECK (state IN (
    'invited', 'ringing', 'connecting', 'joined', 'declined', 'left',
    'removed', 'answered_elsewhere', 'missed', 'failed'
  )),
  join_order INTEGER NOT NULL CHECK (join_order > 0),
  invited_by TEXT NOT NULL REFERENCES accounts(aci),
  invited_at TEXT NOT NULL,
  answered_at TEXT,
  joined_at TEXT,
  left_at TEXT,
  PRIMARY KEY (call_id, aci),
  UNIQUE (call_id, join_order),
  CHECK (claimed_device_id IS NULL OR claimed_device_id BETWEEN 1 AND 2)
);
CREATE UNIQUE INDEX call_participants_one_live_account_seat
  ON call_participants(aci) WHERE state IN ('connecting', 'joined');

CREATE TABLE call_coordination_events (
  event_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  call_id TEXT NOT NULL REFERENCES call_sessions(call_id) ON DELETE CASCADE,
  recipient_aci TEXT REFERENCES accounts(aci) ON DELETE CASCADE,
  event_type TEXT NOT NULL CHECK (event_type IN ('ringing', 'roster_changed', 'answered', 'cancelled', 'ended')),
  created_at TEXT NOT NULL
);
CREATE INDEX call_coordination_events_recipient ON call_coordination_events(recipient_aci, event_sequence);

CREATE TABLE livekit_webhook_events (
  event_id TEXT PRIMARY KEY CHECK (length(event_id) BETWEEN 8 AND 128),
  call_id TEXT NOT NULL REFERENCES call_sessions(call_id) ON DELETE CASCADE,
  received_at TEXT NOT NULL
);

CREATE TABLE push_registrations_v3 (
  aci TEXT NOT NULL,
  device_id INTEGER NOT NULL,
  provider TEXT NOT NULL CHECK (provider IN (
    'fcm', 'apns', 'apns-ptt', 'apns-voip',
    'apns-sandbox', 'apns-ptt-sandbox', 'apns-voip-sandbox'
  )),
  token TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  channel_id TEXT REFERENCES channels(channel_id) ON DELETE CASCADE,
  PRIMARY KEY (aci, device_id, provider),
  UNIQUE (provider, token),
  FOREIGN KEY (aci, device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE
);
INSERT INTO push_registrations_v3(aci,device_id,provider,token,updated_at,channel_id)
SELECT aci,device_id,provider,token,updated_at,channel_id FROM push_registrations;

CREATE TABLE push_outbox_v3 (
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL,
  aci TEXT NOT NULL,
  device_id INTEGER NOT NULL,
  provider TEXT NOT NULL CHECK (provider IN (
    'fcm', 'apns', 'apns-ptt', 'apns-voip',
    'apns-sandbox', 'apns-ptt-sandbox', 'apns-voip-sandbox'
  )),
  kind TEXT NOT NULL CHECK (kind IN ('mailbox', 'voice', 'call')),
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  sent_at TEXT,
  created_at TEXT NOT NULL,
  UNIQUE (message_id, aci, device_id, provider),
  FOREIGN KEY (aci, device_id, provider) REFERENCES push_registrations_v3(aci, device_id, provider) ON DELETE CASCADE
);
INSERT INTO push_outbox_v3(id,message_id,aci,device_id,provider,kind,attempts,last_error,sent_at,created_at)
SELECT id,message_id,aci,device_id,provider,kind,attempts,last_error,sent_at,created_at FROM push_outbox;
DROP TABLE push_outbox;
DROP TABLE push_registrations;
ALTER TABLE push_registrations_v3 RENAME TO push_registrations;
ALTER TABLE push_outbox_v3 RENAME TO push_outbox;
CREATE INDEX push_registrations_voice_channel ON push_registrations(channel_id,provider) WHERE channel_id IS NOT NULL;
CREATE INDEX push_outbox_pending ON push_outbox(created_at) WHERE sent_at IS NULL;
