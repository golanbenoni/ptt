CREATE TABLE admin_console_handoffs (
  token_hash TEXT PRIMARY KEY,
  aci TEXT NOT NULL,
  device_id INTEGER NOT NULL,
  expires_at TEXT NOT NULL,
  consumed_at TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY (aci, device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE
);

CREATE INDEX admin_console_handoffs_expiry ON admin_console_handoffs(expires_at);

CREATE TABLE admin_console_sessions (
  token_hash TEXT PRIMARY KEY,
  aci TEXT NOT NULL,
  device_id INTEGER NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY (aci, device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE
);

CREATE INDEX admin_console_sessions_expiry ON admin_console_sessions(expires_at);
