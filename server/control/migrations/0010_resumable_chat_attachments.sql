CREATE TABLE chat_attachment_uploads (
    upload_id uuid PRIMARY KEY,
    attachment_id uuid NOT NULL UNIQUE,
    channel_id uuid NOT NULL REFERENCES channels(channel_id) ON DELETE CASCADE,
    membership_epoch integer NOT NULL CHECK (membership_epoch > 0),
    uploader_aci uuid NOT NULL REFERENCES accounts(aci),
    uploader_device_id integer NOT NULL CHECK (uploader_device_id BETWEEN 1 AND 2),
    storage_key text NOT NULL UNIQUE,
    ciphertext_bytes bigint NOT NULL CHECK (ciphertext_bytes BETWEEN 1 AND 26214464),
    ciphertext_sha256 bytea NOT NULL CHECK (octet_length(ciphertext_sha256) = 32),
    part_size integer NOT NULL CHECK (part_size = 1048576),
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX chat_attachment_uploads_expiry ON chat_attachment_uploads(expires_at);

CREATE TABLE chat_attachment_upload_parts (
    upload_id uuid NOT NULL REFERENCES chat_attachment_uploads(upload_id) ON DELETE CASCADE,
    part_number integer NOT NULL CHECK (part_number BETWEEN 1 AND 26),
    storage_key text NOT NULL UNIQUE,
    ciphertext_bytes integer NOT NULL CHECK (ciphertext_bytes BETWEEN 1 AND 1048576),
    ciphertext_sha256 bytea NOT NULL CHECK (octet_length(ciphertext_sha256) = 32),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(upload_id, part_number)
);
