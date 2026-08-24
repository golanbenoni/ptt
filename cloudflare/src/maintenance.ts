import { now } from "./db";

const HISTORY_BATCH = 500;

export async function runMaintenance(env: Env): Promise<void> {
  const timestamp = now();
  await env.DB.batch([
    env.DB.prepare("UPDATE recovery_requests SET status='expired' WHERE status='pending_admin' AND expires_at<=?").bind(timestamp),
    env.DB.prepare("DELETE FROM mailbox_items WHERE expires_at<=?").bind(timestamp),
    env.DB.prepare("DELETE FROM relay_leases WHERE expires_at<=?").bind(timestamp),
    env.DB.prepare("DELETE FROM invitations WHERE expires_at<=? AND (consumed_at IS NULL OR created_at<?)")
      .bind(timestamp, new Date(Date.now() - 30 * 86_400_000).toISOString()),
    env.DB.prepare(
      `DELETE FROM magic_links WHERE expires_at<=?
       AND NOT EXISTS(SELECT 1 FROM recovery_requests r WHERE r.link_id=magic_links.id)`,
    ).bind(timestamp),
    env.DB.prepare("DELETE FROM rate_limits WHERE window_start<?").bind(Math.floor(Date.now() / 1000) - 86_400),
    env.DB.prepare("DELETE FROM one_time_prekeys WHERE consumed_at IS NOT NULL AND consumed_at<?")
      .bind(new Date(Date.now() - 7 * 86_400_000).toISOString()),
    env.DB.prepare("UPDATE email_outbox SET payload=json_object('redacted',true,'template',template) WHERE created_at<? AND payload NOT LIKE '%\"redacted\":true%'")
      .bind(new Date(Date.now() - 60 * 60_000).toISOString()),
    env.DB.prepare("DELETE FROM email_outbox WHERE sent_at IS NOT NULL AND sent_at<?")
      .bind(new Date(Date.now() - 30 * 86_400_000).toISOString()),
    env.DB.prepare("DELETE FROM push_outbox WHERE sent_at IS NOT NULL AND sent_at<?")
      .bind(new Date(Date.now() - 86_400_000).toISOString()),
    env.DB.prepare("DELETE FROM admin_console_handoffs WHERE expires_at<=?").bind(timestamp),
    env.DB.prepare("DELETE FROM admin_console_sessions WHERE expires_at<=? OR revoked_at IS NOT NULL").bind(timestamp),
  ]);

  const expired = await env.DB.prepare(
    "SELECT object_id AS objectId,storage_key AS storageKey FROM history_objects WHERE expires_at<=? LIMIT ?",
  ).bind(timestamp, HISTORY_BATCH).all<{ objectId: string; storageKey: string }>();
  for (const object of expired.results) {
    await env.HISTORY.delete(object.storageKey);
    await env.DB.prepare("DELETE FROM history_objects WHERE object_id=? AND expires_at<=?")
      .bind(object.objectId, timestamp).run();
  }
}
