CREATE TABLE push_registrations_v2 (
  aci TEXT NOT NULL,
  device_id INTEGER NOT NULL,
  provider TEXT NOT NULL CHECK (provider IN ('fcm', 'apns', 'apns-ptt', 'apns-sandbox', 'apns-ptt-sandbox')),
  token TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (aci, device_id, provider),
  UNIQUE (provider, token),
  FOREIGN KEY (aci, device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE
);

INSERT INTO push_registrations_v2(aci,device_id,provider,token,updated_at)
SELECT aci,device_id,provider,token,updated_at FROM push_registrations;

CREATE TABLE push_outbox_v2 (
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL,
  aci TEXT NOT NULL,
  device_id INTEGER NOT NULL,
  provider TEXT NOT NULL CHECK (provider IN ('fcm', 'apns', 'apns-ptt', 'apns-sandbox', 'apns-ptt-sandbox')),
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  sent_at TEXT,
  created_at TEXT NOT NULL,
  UNIQUE (message_id, aci, device_id, provider),
  FOREIGN KEY (aci, device_id, provider)
    REFERENCES push_registrations_v2(aci, device_id, provider) ON DELETE CASCADE
);

INSERT INTO push_outbox_v2(id,message_id,aci,device_id,provider,attempts,last_error,sent_at,created_at)
SELECT id,message_id,aci,device_id,provider,attempts,last_error,sent_at,created_at FROM push_outbox;

DROP TABLE push_outbox;
DROP TABLE push_registrations;
ALTER TABLE push_registrations_v2 RENAME TO push_registrations;
ALTER TABLE push_outbox_v2 RENAME TO push_outbox;
CREATE INDEX push_outbox_pending ON push_outbox(created_at) WHERE sent_at IS NULL;
