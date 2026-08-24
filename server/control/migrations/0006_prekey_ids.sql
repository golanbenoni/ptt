ALTER TABLE one_time_prekeys ADD COLUMN key_id integer;

-- Early development rows predate explicit libsignal key IDs. Preserve their
-- uniqueness for upgrades, but they remain consumable only as opaque legacy rows.
UPDATE one_time_prekeys SET key_id = (id % 2147483646)::integer + 1 WHERE key_id IS NULL;
ALTER TABLE one_time_prekeys ALTER COLUMN key_id SET NOT NULL;
ALTER TABLE one_time_prekeys ADD CONSTRAINT one_time_prekeys_key_id_positive CHECK (key_id > 0);
ALTER TABLE one_time_prekeys ADD CONSTRAINT one_time_prekeys_device_key_id UNIQUE (aci, device_id, kind, key_id);

