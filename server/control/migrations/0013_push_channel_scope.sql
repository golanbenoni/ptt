ALTER TABLE push_registrations
    ADD COLUMN channel_id uuid REFERENCES channels(channel_id) ON DELETE CASCADE;

CREATE INDEX push_registrations_voice_channel
    ON push_registrations(channel_id,provider)
    WHERE channel_id IS NOT NULL;
