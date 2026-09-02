ALTER TABLE accounts ADD COLUMN display_name TEXT;
ALTER TABLE accounts ADD COLUMN account_kind TEXT NOT NULL DEFAULT 'member';
ALTER TABLE accounts ADD COLUMN guest_expires_at TEXT;

UPDATE accounts
SET display_name = substr(email, 1, instr(email, '@') - 1)
WHERE display_name IS NULL AND instr(email, '@') > 1;
UPDATE accounts SET display_name = 'Team member' WHERE display_name IS NULL OR display_name = '';

ALTER TABLE channels ADD COLUMN topic TEXT NOT NULL DEFAULT '';
ALTER TABLE channels ADD COLUMN is_announcement INTEGER NOT NULL DEFAULT 0;
ALTER TABLE channels ADD COLUMN archived_at TEXT;
ALTER TABLE channels ADD COLUMN created_by TEXT REFERENCES accounts(aci) ON DELETE SET NULL;

CREATE TABLE channel_templates (
  template_id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 80),
  channel_kind TEXT NOT NULL CHECK (channel_kind IN ('team', 'duty', 'adhoc')),
  topic TEXT NOT NULL DEFAULT '' CHECK (length(topic) <= 280),
  retention_days INTEGER NOT NULL CHECK (retention_days BETWEEN 1 AND 365),
  default_role TEXT NOT NULL CHECK (default_role IN ('talk', 'listen', 'barge', 'dispatch', 'emergency-target')),
  is_announcement INTEGER NOT NULL DEFAULT 0 CHECK (is_announcement IN (0, 1)),
  created_by TEXT REFERENCES accounts(aci) ON DELETE SET NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE user_groups (
  group_id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 80),
  handle TEXT NOT NULL UNIQUE CHECK (length(handle) BETWEEN 2 AND 32),
  created_by TEXT REFERENCES accounts(aci) ON DELETE SET NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE user_group_members (
  group_id TEXT NOT NULL REFERENCES user_groups(group_id) ON DELETE CASCADE,
  aci TEXT NOT NULL REFERENCES accounts(aci) ON DELETE CASCADE,
  PRIMARY KEY (group_id, aci)
);

CREATE TABLE operation_runs (
  run_id TEXT PRIMARY KEY,
  channel_id TEXT NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
  template_id TEXT REFERENCES channel_templates(template_id) ON DELETE SET NULL,
  display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 120),
  severity TEXT NOT NULL CHECK (severity IN ('routine', 'priority', 'critical')),
  status TEXT NOT NULL CHECK (status IN ('active', 'monitoring', 'resolved', 'archived')),
  commander_aci TEXT NOT NULL REFERENCES accounts(aci),
  started_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  resolved_at TEXT
);
CREATE INDEX operation_runs_channel_updated ON operation_runs(channel_id, updated_at DESC);

CREATE TABLE operation_acknowledgements (
  run_id TEXT NOT NULL REFERENCES operation_runs(run_id) ON DELETE CASCADE,
  event_id TEXT NOT NULL,
  aci TEXT NOT NULL REFERENCES accounts(aci) ON DELETE CASCADE,
  acknowledged_at TEXT NOT NULL,
  PRIMARY KEY (run_id, event_id, aci)
);

CREATE TABLE channel_integrations (
  integration_id TEXT PRIMARY KEY,
  aci TEXT NOT NULL UNIQUE REFERENCES accounts(aci) ON DELETE CASCADE,
  channel_id TEXT NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
  display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 80),
  token_hash TEXT NOT NULL UNIQUE,
  identity_key TEXT NOT NULL,
  capabilities TEXT NOT NULL DEFAULT '["post"]',
  created_by TEXT REFERENCES accounts(aci) ON DELETE SET NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT,
  revoked_at TEXT
);
CREATE INDEX channel_integrations_active ON channel_integrations(channel_id) WHERE revoked_at IS NULL;
