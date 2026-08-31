PRAGMA foreign_keys = ON;

-- Chat envelopes are deliberately isolated from the voice-key mailbox. This keeps
-- mixed-version clients from interpreting a text message as a media epoch update.
CREATE TABLE chat_items (
  item_id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL,
  channel_id TEXT NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
  membership_epoch INTEGER NOT NULL CHECK (membership_epoch > 0),
  recipient_aci TEXT NOT NULL,
  recipient_device_id INTEGER NOT NULL CHECK (recipient_device_id BETWEEN 1 AND 2),
  envelope TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  delivered_at TEXT,
  created_at TEXT NOT NULL,
  UNIQUE (recipient_aci, recipient_device_id, message_id),
  FOREIGN KEY (recipient_aci, recipient_device_id)
    REFERENCES devices(aci, device_id) ON DELETE CASCADE
);
CREATE INDEX chat_pending
  ON chat_items(recipient_aci, recipient_device_id, created_at)
  WHERE delivered_at IS NULL;

-- R2 contains only client-encrypted bytes. Names, MIME types, captions, keys, and
-- thumbnails are inside the pairwise-encrypted chat envelope, never in this table.
CREATE TABLE chat_attachments (
  attachment_id TEXT PRIMARY KEY,
  channel_id TEXT NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
  membership_epoch INTEGER NOT NULL CHECK (membership_epoch > 0),
  uploader_aci TEXT NOT NULL,
  uploader_device_id INTEGER NOT NULL CHECK (uploader_device_id BETWEEN 1 AND 2),
  storage_key TEXT NOT NULL UNIQUE,
  ciphertext_bytes INTEGER NOT NULL CHECK (ciphertext_bytes BETWEEN 1 AND 26214464),
  ciphertext_sha256 TEXT NOT NULL CHECK (length(ciphertext_sha256) = 64),
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  -- Device recovery/revocation must not delete ciphertext that other channel
  -- members are still entitled to receive during retention.
  FOREIGN KEY (uploader_aci) REFERENCES accounts(aci)
);
CREATE INDEX chat_attachments_expiry ON chat_attachments(expires_at);
