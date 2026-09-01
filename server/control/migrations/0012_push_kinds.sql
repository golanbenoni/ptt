ALTER TABLE push_outbox
    ADD COLUMN kind text NOT NULL DEFAULT 'mailbox'
    CHECK (kind IN ('mailbox', 'voice'));

-- Prior releases incorrectly used PTT registrations for mailbox notifications.
-- Discard those stale jobs while standard APNs/FCM mailbox jobs remain intact.
DELETE FROM push_outbox
WHERE provider IN ('apns-ptt', 'apns-ptt-sandbox');
