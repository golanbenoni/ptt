ALTER TABLE magic_links
    ADD COLUMN resume_secret_sha256 bytea
    CHECK (resume_secret_sha256 IS NULL OR octet_length(resume_secret_sha256) = 32);

