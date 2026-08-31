PRAGMA foreign_keys = ON;

-- Incomplete uploads contain ciphertext only. The short-lived session and its
-- independently addressable chunks let mobile clients resume after a network
-- transition or process death without restarting a 25 MiB transfer.
CREATE TABLE chat_attachment_uploads (
  upload_id TEXT PRIMARY KEY,
  attachment_id TEXT NOT NULL UNIQUE,
  channel_id TEXT NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
  membership_epoch INTEGER NOT NULL CHECK (membership_epoch > 0),
  uploader_aci TEXT NOT NULL,
  uploader_device_id INTEGER NOT NULL CHECK (uploader_device_id BETWEEN 1 AND 2),
  storage_key TEXT NOT NULL UNIQUE,
  ciphertext_bytes INTEGER NOT NULL CHECK (ciphertext_bytes BETWEEN 1 AND 26214464),
  ciphertext_sha256 TEXT NOT NULL CHECK (length(ciphertext_sha256) = 64),
  part_size INTEGER NOT NULL CHECK (part_size = 1048576),
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY (uploader_aci) REFERENCES accounts(aci)
);
CREATE INDEX chat_attachment_uploads_expiry ON chat_attachment_uploads(expires_at);

CREATE TABLE chat_attachment_upload_parts (
  upload_id TEXT NOT NULL REFERENCES chat_attachment_uploads(upload_id) ON DELETE CASCADE,
  part_number INTEGER NOT NULL CHECK (part_number BETWEEN 1 AND 26),
  storage_key TEXT NOT NULL UNIQUE,
  ciphertext_bytes INTEGER NOT NULL CHECK (ciphertext_bytes BETWEEN 1 AND 1048576),
  ciphertext_sha256 TEXT NOT NULL CHECK (length(ciphertext_sha256) = 64),
  created_at TEXT NOT NULL,
  PRIMARY KEY (upload_id, part_number)
);
