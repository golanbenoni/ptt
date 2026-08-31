CREATE TABLE chat_items (
    item_id uuid PRIMARY KEY,
    message_id uuid NOT NULL,
    channel_id uuid NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
    membership_epoch integer NOT NULL CHECK (membership_epoch > 0),
    recipient_aci uuid NOT NULL,
    recipient_device_id integer NOT NULL CHECK (recipient_device_id BETWEEN 1 AND 2),
    envelope bytea NOT NULL CHECK (octet_length(envelope) BETWEEN 1 AND 131072),
    expires_at timestamptz NOT NULL,
    delivered_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(recipient_aci, recipient_device_id, message_id),
    FOREIGN KEY(recipient_aci, recipient_device_id)
        REFERENCES devices(aci, device_id) ON DELETE CASCADE
);
CREATE INDEX chat_items_pending ON chat_items(recipient_aci, recipient_device_id, created_at)
    WHERE delivered_at IS NULL;

CREATE TABLE chat_attachments (
    attachment_id uuid PRIMARY KEY,
    channel_id uuid NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
    membership_epoch integer NOT NULL CHECK (membership_epoch > 0),
    uploader_aci uuid NOT NULL,
    uploader_device_id integer NOT NULL CHECK (uploader_device_id BETWEEN 1 AND 2),
    storage_key text NOT NULL UNIQUE,
    ciphertext_bytes bigint NOT NULL CHECK (ciphertext_bytes BETWEEN 1 AND 26214464),
    ciphertext_sha256 bytea NOT NULL CHECK (octet_length(ciphertext_sha256) = 32),
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    -- Device recovery/revocation must not delete ciphertext that other channel
    -- members are still entitled to receive during retention.
    FOREIGN KEY(uploader_aci) REFERENCES accounts(aci)
);
CREATE INDEX chat_attachments_expiry ON chat_attachments(expires_at);
