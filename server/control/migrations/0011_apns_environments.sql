ALTER TABLE push_registrations
    DROP CONSTRAINT IF EXISTS push_registrations_provider_check;
ALTER TABLE push_registrations
    ADD CONSTRAINT push_registrations_provider_check
    CHECK (provider IN ('fcm', 'apns', 'apns-ptt', 'apns-sandbox', 'apns-ptt-sandbox'));

ALTER TABLE push_outbox
    DROP CONSTRAINT IF EXISTS push_outbox_provider_check;
ALTER TABLE push_outbox
    ADD CONSTRAINT push_outbox_provider_check
    CHECK (provider IN ('fcm', 'apns', 'apns-ptt', 'apns-sandbox', 'apns-ptt-sandbox'));
