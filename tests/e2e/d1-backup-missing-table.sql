PRAGMA foreign_keys=ON;
CREATE TABLE d1_migrations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT UNIQUE NOT NULL,
  applied_at TEXT NOT NULL
);
INSERT INTO d1_migrations (name, applied_at)
VALUES ('0001_fixture.sql', '2026-01-01T00:00:00Z');
CREATE TABLE accounts (aci TEXT PRIMARY KEY);
CREATE TABLE devices (device_id TEXT PRIMARY KEY, aci TEXT REFERENCES accounts(aci));
CREATE TABLE channels (channel_id TEXT PRIMARY KEY);
CREATE TABLE memberships (
  aci TEXT REFERENCES accounts(aci),
  channel_id TEXT REFERENCES channels(channel_id)
);
CREATE TABLE chat_items (message_id TEXT PRIMARY KEY);
CREATE TABLE chat_attachments (attachment_id TEXT PRIMARY KEY);
CREATE TABLE push_registrations (registration_id TEXT PRIMARY KEY);
