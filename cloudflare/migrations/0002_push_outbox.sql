CREATE TABLE push_outbox (
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL,
  aci TEXT NOT NULL,
  device_id INTEGER NOT NULL,
  provider TEXT NOT NULL CHECK (provider IN ('fcm', 'apns', 'apns-ptt')),
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  sent_at TEXT,
  created_at TEXT NOT NULL,
  UNIQUE (message_id, aci, device_id, provider),
  FOREIGN KEY (aci, device_id, provider)
    REFERENCES push_registrations(aci, device_id, provider) ON DELETE CASCADE
);

CREATE INDEX push_outbox_pending ON push_outbox(created_at) WHERE sent_at IS NULL;
