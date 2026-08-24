ALTER TABLE relay_leases
    ADD COLUMN demux_token bytea CHECK (demux_token IS NULL OR octet_length(demux_token) = 32);

-- Existing short-lived leases remain valid for UDP until expiry. Clients obtain
-- a refreshed credential before using the TLS media tunnel.
