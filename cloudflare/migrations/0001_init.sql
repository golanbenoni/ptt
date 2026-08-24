PRAGMA foreign_keys = ON;

CREATE TABLE accounts (
  aci TEXT PRIMARY KEY,
  email TEXT NOT NULL UNIQUE COLLATE NOCASE,
  is_admin INTEGER NOT NULL DEFAULT 0 CHECK (is_admin IN (0, 1)),
  created_at TEXT NOT NULL,
  disabled_at TEXT
);

CREATE TABLE devices (
  aci TEXT NOT NULL REFERENCES accounts(aci) ON DELETE CASCADE,
  device_id INTEGER NOT NULL CHECK (device_id BETWEEN 1 AND 2),
  mailbox_id TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 80),
  identity_key TEXT NOT NULL,
  access_token_hash TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL CHECK (status IN ('pending', 'active', 'revoked')),
  linked_at TEXT NOT NULL,
  revoked_at TEXT,
  PRIMARY KEY (aci, device_id)
);

CREATE TABLE invitations (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL COLLATE NOCASE,
  token_hash TEXT NOT NULL UNIQUE,
  grants_admin INTEGER NOT NULL DEFAULT 0 CHECK (grants_admin IN (0, 1)),
  expires_at TEXT NOT NULL,
  consumed_at TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE magic_links (
  id TEXT PRIMARY KEY,
  invitation_id TEXT REFERENCES invitations(id) ON DELETE CASCADE,
  email TEXT NOT NULL COLLATE NOCASE,
  token_hash TEXT NOT NULL UNIQUE,
  purpose TEXT NOT NULL CHECK (purpose IN ('enroll', 'recover')),
  grants_admin INTEGER NOT NULL DEFAULT 0 CHECK (grants_admin IN (0, 1)),
  expires_at TEXT NOT NULL,
  consumed_at TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE channels (
  channel_id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 80),
  kind TEXT NOT NULL CHECK (kind IN ('team', 'duty', 'adhoc', 'direct')),
  membership_epoch INTEGER NOT NULL DEFAULT 1 CHECK (membership_epoch > 0),
  distribution_id TEXT NOT NULL,
  retention_days INTEGER NOT NULL DEFAULT 30 CHECK (retention_days BETWEEN 1 AND 365),
  created_at TEXT NOT NULL
);

CREATE TABLE memberships (
  channel_id TEXT NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
  aci TEXT NOT NULL REFERENCES accounts(aci) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('talk', 'listen', 'barge', 'dispatch', 'emergency-target')),
  joined_epoch INTEGER NOT NULL,
  left_epoch INTEGER,
  created_at TEXT NOT NULL,
  PRIMARY KEY (channel_id, aci)
);
CREATE INDEX memberships_active_account ON memberships(aci, channel_id) WHERE left_epoch IS NULL;

CREATE TABLE prekey_bundles (
  aci TEXT NOT NULL,
  device_id INTEGER NOT NULL,
  opaque_bundle TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (aci, device_id),
  FOREIGN KEY (aci, device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE
);

CREATE TABLE one_time_prekeys (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  aci TEXT NOT NULL,
  device_id INTEGER NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('x25519', 'kyber')),
  key_id INTEGER NOT NULL CHECK (key_id > 0),
  public_key TEXT NOT NULL,
  consumed_at TEXT,
  created_at TEXT NOT NULL,
  UNIQUE (aci, device_id, kind, key_id),
  FOREIGN KEY (aci, device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE
);
CREATE INDEX prekeys_available ON one_time_prekeys(aci, device_id, kind, id) WHERE consumed_at IS NULL;

CREATE TABLE device_link_requests (
  request_id TEXT PRIMARY KEY,
  aci TEXT NOT NULL REFERENCES accounts(aci) ON DELETE CASCADE,
  initiator_device_id INTEGER NOT NULL,
  link_code_hash TEXT NOT NULL UNIQUE,
  expires_at TEXT NOT NULL,
  claimed_device_id INTEGER,
  claim_token_hash TEXT,
  approved_at TEXT,
  consumed_at TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE mailbox_items (
  item_id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL,
  mailbox_id TEXT NOT NULL REFERENCES devices(mailbox_id) ON DELETE CASCADE,
  envelope TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  delivered_at TEXT,
  created_at TEXT NOT NULL,
  UNIQUE (mailbox_id, message_id)
);
CREATE INDEX mailbox_pending ON mailbox_items(mailbox_id, created_at) WHERE delivered_at IS NULL;

CREATE TABLE history_objects (
  object_id TEXT PRIMARY KEY,
  channel_id TEXT NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
  talk_id TEXT NOT NULL,
  membership_epoch INTEGER NOT NULL,
  media_kid TEXT NOT NULL,
  storage_key TEXT NOT NULL UNIQUE,
  ciphertext_bytes INTEGER NOT NULL CHECK (ciphertext_bytes > 0),
  ciphertext_sha256 TEXT NOT NULL,
  started_at TEXT NOT NULL,
  duration_ms INTEGER NOT NULL CHECK (duration_ms BETWEEN 1 AND 30000),
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE (channel_id, talk_id)
);
CREATE INDEX history_member_listing ON history_objects(channel_id, created_at DESC);

CREATE TABLE push_registrations (
  aci TEXT NOT NULL,
  device_id INTEGER NOT NULL,
  provider TEXT NOT NULL CHECK (provider IN ('fcm', 'apns', 'apns-ptt')),
  token TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (aci, device_id, provider),
  UNIQUE (provider, token),
  FOREIGN KEY (aci, device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE
);

CREATE TABLE relay_leases (
  channel_id TEXT NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
  sender_demux INTEGER NOT NULL CHECK (sender_demux BETWEEN 1 AND 4294967295),
  aci TEXT NOT NULL,
  device_id INTEGER NOT NULL,
  demux_token TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  PRIMARY KEY (channel_id, sender_demux),
  UNIQUE (channel_id, aci, device_id),
  FOREIGN KEY (aci, device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE
);

CREATE TABLE recovery_requests (
  request_id TEXT PRIMARY KEY,
  link_id TEXT NOT NULL UNIQUE REFERENCES magic_links(id) ON DELETE CASCADE,
  aci TEXT NOT NULL REFERENCES accounts(aci) ON DELETE CASCADE,
  mailbox_id TEXT NOT NULL UNIQUE,
  device_name TEXT NOT NULL,
  identity_key TEXT NOT NULL,
  claim_token_hash TEXT NOT NULL UNIQUE,
  device_access_token_hash TEXT NOT NULL UNIQUE,
  device_access_token_ciphertext TEXT,
  status TEXT NOT NULL DEFAULT 'pending_admin' CHECK (status IN ('pending_admin', 'approved', 'denied', 'expired')),
  expires_at TEXT NOT NULL,
  approved_by TEXT REFERENCES accounts(aci),
  decided_at TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE email_outbox (
  id TEXT PRIMARY KEY,
  recipient TEXT NOT NULL,
  template TEXT NOT NULL,
  payload TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'sent', 'failed')),
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  created_at TEXT NOT NULL,
  sent_at TEXT
);

CREATE TABLE audit_events (
  event_id INTEGER PRIMARY KEY AUTOINCREMENT,
  actor_aci TEXT,
  action TEXT NOT NULL,
  subject_hash TEXT,
  detail TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);
CREATE INDEX audit_created ON audit_events(created_at DESC);

CREATE TABLE presence (
  aci TEXT NOT NULL,
  device_id INTEGER NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('available', 'busy', 'solo', 'standby')),
  updated_at TEXT NOT NULL,
  PRIMARY KEY (aci, device_id),
  FOREIGN KEY (aci, device_id) REFERENCES devices(aci, device_id) ON DELETE CASCADE
);

CREATE TABLE rate_limits (
  scope TEXT NOT NULL,
  discriminator_hash TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  attempts INTEGER NOT NULL,
  PRIMARY KEY (scope, discriminator_hash)
);
