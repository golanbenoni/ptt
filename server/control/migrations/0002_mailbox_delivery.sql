ALTER TABLE mailbox_items ADD COLUMN message_id uuid;

-- Existing development rows predate client supplied message identifiers. Their
-- item identifier is already unique and is a safe idempotency key for upgrade.
UPDATE mailbox_items SET message_id = item_id WHERE message_id IS NULL;
ALTER TABLE mailbox_items ALTER COLUMN message_id SET NOT NULL;

CREATE UNIQUE INDEX mailbox_items_message_deduplication
    ON mailbox_items (mailbox_id, message_id);

CREATE INDEX mailbox_items_expiration ON mailbox_items (expires_at);
