ALTER TABLE history_objects ADD COLUMN started_at timestamptz;
ALTER TABLE history_objects ADD COLUMN duration_ms integer;
ALTER TABLE history_objects ADD COLUMN ciphertext_sha256 bytea;

UPDATE history_objects
SET started_at = created_at,
    duration_ms = 1
WHERE started_at IS NULL OR duration_ms IS NULL;

ALTER TABLE history_objects ALTER COLUMN started_at SET NOT NULL;
ALTER TABLE history_objects ALTER COLUMN duration_ms SET NOT NULL;
ALTER TABLE history_objects
    ADD CONSTRAINT history_objects_duration
    CHECK (duration_ms BETWEEN 1 AND 30000);
ALTER TABLE history_objects
    ADD CONSTRAINT history_objects_ciphertext_hash
    CHECK (ciphertext_sha256 IS NULL OR octet_length(ciphertext_sha256) = 32);

CREATE INDEX history_objects_member_listing
    ON history_objects (channel_id, created_at DESC)
    WHERE expires_at > created_at;
