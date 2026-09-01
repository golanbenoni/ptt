#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 BACKUP.sql [EXPECTED_LAST_MIGRATION]" >&2
  exit 2
fi

backup=$1
expected_last=${2:-}

command -v sqlite3 >/dev/null || {
  echo "sqlite3 is required to verify a D1 backup" >&2
  exit 1
}

test -s "$backup" || {
  echo "D1 backup is missing or empty: $backup" >&2
  exit 1
}

case $backup in
  *"'"*)
    echo "D1 backup paths containing a single quote are unsupported" >&2
    exit 1
    ;;
esac

# Restore into an in-memory SQLite database so verification never mutates the
# source export and leaves no plaintext database artifact behind.
results=$(sqlite3 -batch -bail :memory: <<SQL
.read '$backup'
PRAGMA integrity_check;
SELECT COUNT(*) FROM pragma_foreign_key_check;
SELECT COUNT(*) FROM d1_migrations;
SELECT name FROM d1_migrations ORDER BY id DESC LIMIT 1;
SELECT COUNT(*) FROM sqlite_master
 WHERE type = 'table'
   AND name IN (
     'accounts',
     'devices',
     'channels',
     'memberships',
     'chat_items',
     'chat_attachments',
     'push_registrations',
     'push_outbox'
   );
SQL
)

integrity=$(printf '%s\n' "$results" | sed -n '1p')
foreign_key_errors=$(printf '%s\n' "$results" | sed -n '2p')
migration_count=$(printf '%s\n' "$results" | sed -n '3p')
last_migration=$(printf '%s\n' "$results" | sed -n '4p')
required_tables=$(printf '%s\n' "$results" | sed -n '5p')

test "$integrity" = ok || {
  echo "D1 backup integrity check failed" >&2
  exit 1
}
test "$foreign_key_errors" = 0 || {
  echo "D1 backup contains $foreign_key_errors foreign-key violation(s)" >&2
  exit 1
}
case $migration_count in
  ''|*[!0-9]*)
    echo "D1 backup has an invalid migration ledger" >&2
    exit 1
    ;;
esac
test "$migration_count" -gt 0 || {
  echo "D1 backup migration ledger is empty" >&2
  exit 1
}
test "$required_tables" = 8 || {
  echo "D1 backup is missing one or more required production tables" >&2
  exit 1
}
if [ -n "$expected_last" ] && [ "$last_migration" != "$expected_last" ]; then
  echo "D1 backup ends at $last_migration, expected $expected_last" >&2
  exit 1
fi

echo "D1 backup restore verified through $last_migration ($migration_count migrations)"
