import { isUuid, uuid } from "./crypto";
import { revokeDeviceFor } from "./auth";
import { audit, requireAdmin, validEmail } from "./db";
import { ApiError, body, booleanField, integerField, json, stringField } from "./http";
import { pushConfiguration } from "./push";
import { notifyChannelsMembershipChanged } from "./relay-state";

export async function adminSummary(request: Request, env: Env): Promise<Response> {
  await requireAdmin(request, env);
  const row = await env.DB.prepare(
    `SELECT
      (SELECT count(*) FROM accounts WHERE disabled_at IS NULL) AS accounts,
      (SELECT count(*) FROM devices WHERE status='active') AS activeDevices,
      (SELECT count(*) FROM channels) AS channels,
      (SELECT count(*) FROM email_outbox WHERE status<>'sent') AS pendingEmail,
      (SELECT count(*) FROM recovery_requests WHERE status='pending_admin' AND expires_at>?) AS pendingRecoveries`,
  ).bind(new Date().toISOString()).first();
  return json(row);
}

export async function adminMembers(request: Request, env: Env): Promise<Response> {
  await requireAdmin(request, env);
  const rows = await env.DB.prepare(
    `SELECT a.aci,a.email,a.is_admin=1 AS isAdmin,count(d.device_id) FILTER (WHERE d.status='active') AS activeDevices
       FROM accounts a LEFT JOIN devices d ON d.aci=a.aci WHERE a.disabled_at IS NULL
      GROUP BY a.aci ORDER BY lower(a.email)`,
  ).all();
  return json(rows.results);
}

export async function adminDevices(request: Request, env: Env): Promise<Response> {
  await requireAdmin(request, env);
  const rows = await env.DB.prepare(
    `SELECT d.aci,a.email,d.device_id AS deviceId,d.display_name AS displayName,d.status,
            d.linked_at AS linkedAt,d.revoked_at AS revokedAt
       FROM devices d JOIN accounts a ON a.aci=d.aci WHERE a.disabled_at IS NULL
      ORDER BY lower(a.email),d.device_id`,
  ).all();
  return json(rows.results);
}

export async function adminRevokeDevice(request: Request, env: Env): Promise<Response> {
  const actor = await requireAdmin(request, env);
  const value = await body(request);
  const aci = stringField(value, "aci", 64);
  const deviceId = integerField(value, "deviceId", 1, 2);
  if (!isUuid(aci)) throw new ApiError(400, "INVALID_ACI");
  await revokeDeviceFor(env, actor.aci, aci, deviceId);
  return json({ accepted: true });
}

export async function adminAudit(request: Request, env: Env): Promise<Response> {
  await requireAdmin(request, env);
  const limit = Number(new URL(request.url).searchParams.get("limit") ?? "100");
  if (!Number.isInteger(limit) || limit < 1 || limit > 500) throw new ApiError(400, "INVALID_LIMIT");
  const rows = await env.DB.prepare(
    "SELECT event_id AS eventId,action,subject_hash AS subjectHash,detail,created_at AS createdAt FROM audit_events ORDER BY event_id DESC LIMIT ?",
  ).bind(limit).all<{ eventId: number; action: string; subjectHash: string | null; detail: string; createdAt: string }>();
  return json(rows.results.map((row) => ({ ...row, detail: JSON.parse(row.detail) as unknown })));
}

export async function adminOperations(request: Request, env: Env): Promise<Response> {
  await requireAdmin(request, env);
  const row = await env.DB.prepare(
    `SELECT
      (SELECT count(*) FROM relay_leases WHERE expires_at>?) AS activeRelayLeases,
      (SELECT count(*) FROM push_outbox WHERE sent_at IS NULL) AS pendingPush,
      (SELECT count(*) FROM push_outbox WHERE sent_at IS NULL AND attempts>0) AS failedPush,
      (SELECT count(*) FROM history_objects) AS historyObjects`,
  ).bind(new Date().toISOString()).first<Record<string, number>>();
  return json({
    ...row,
    ...pushConfiguration(env),
    backupConfigured: true,
    backupSchedule: "Cloudflare D1 Time Travel + R2 durability",
    configurationFingerprint: `cf-${env.ENVIRONMENT}-v1`,
  });
}

export async function createInvitation(request: Request, env: Env, issue: (request: Request, env: Env, invitationId: string, email: string, grantsAdmin: boolean) => Promise<void>): Promise<Response> {
  const actor = await requireAdmin(request, env);
  const value = await body(request);
  const email = validEmail(stringField(value, "email", 254));
  const invitationCode = crypto.randomUUID().replaceAll("-", "") + crypto.randomUUID().replaceAll("-", "");
  const invitationId = uuid();
  const expiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();
  const tokenHash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(invitationCode));
  const tokenHex = Array.from(new Uint8Array(tokenHash), (byte) => byte.toString(16).padStart(2, "0")).join("");
  await env.DB.prepare("INSERT INTO invitations(id,email,token_hash,grants_admin,expires_at,created_at) VALUES(?,?,?,0,?,?)")
    .bind(invitationId, email, tokenHex, expiresAt, new Date().toISOString()).run();
  await issue(request, env, invitationId, email, false);
  await audit(env, "invitation.created", actor.aci, email);
  return json({ invitationCode, expiresAt });
}

export async function adminRecoveries(request: Request, env: Env): Promise<Response> {
  await requireAdmin(request, env);
  await env.DB.prepare("UPDATE recovery_requests SET status='expired' WHERE status='pending_admin' AND expires_at<=?")
    .bind(new Date().toISOString()).run();
  const rows = await env.DB.prepare(
    `SELECT r.request_id AS requestId,a.email,r.device_name AS deviceName,r.status,r.expires_at AS expiresAt,r.created_at AS createdAt
       FROM recovery_requests r JOIN accounts a ON a.aci=r.aci
      WHERE r.status='pending_admin' ORDER BY r.created_at`,
  ).all();
  return json(rows.results);
}

export async function decideRecovery(request: Request, env: Env): Promise<Response> {
  const actor = await requireAdmin(request, env);
  const value = await body(request);
  const requestId = stringField(value, "requestId", 64);
  const approve = booleanField(value, "approve");
  const recovery = await env.DB.prepare(
    `SELECT r.aci,r.mailbox_id AS mailboxId,r.device_name AS deviceName,r.identity_key AS identityKey,
            r.device_access_token_hash AS accessTokenHash
       FROM recovery_requests r JOIN accounts a ON a.aci=r.aci
      WHERE r.request_id=? AND r.status='pending_admin' AND r.expires_at>? AND a.disabled_at IS NULL`,
  ).bind(requestId, new Date().toISOString()).first<{ aci: string; mailboxId: string; deviceName: string; identityKey: string; accessTokenHash: string }>();
  if (!recovery) throw new ApiError(409, "RECOVERY_NOT_PENDING");
  if (recovery.aci === actor.aci) throw new ApiError(403, "SELF_RECOVERY_APPROVAL_FORBIDDEN");
  const statements: D1PreparedStatement[] = [];
  let rotatedChannels = 0;
  if (approve) {
    const channels = await env.DB.prepare("SELECT channel_id AS channelId FROM memberships WHERE aci=? AND left_epoch IS NULL")
      .bind(recovery.aci).all<{ channelId: string }>();
    rotatedChannels = channels.results.length;
    statements.push(env.DB.prepare("DELETE FROM devices WHERE aci=?").bind(recovery.aci));
    statements.push(env.DB.prepare(
      "INSERT INTO devices(aci,device_id,mailbox_id,display_name,identity_key,access_token_hash,status,linked_at) VALUES(?,1,?,?,?,?, 'active', ?)",
    ).bind(recovery.aci, recovery.mailboxId, recovery.deviceName, recovery.identityKey, recovery.accessTokenHash, new Date().toISOString()));
    for (const channel of channels.results) statements.push(
      env.DB.prepare("UPDATE channels SET membership_epoch=membership_epoch+1,distribution_id=? WHERE channel_id=?").bind(uuid(), channel.channelId),
    );
  }
  statements.push(env.DB.prepare("UPDATE recovery_requests SET status=?,approved_by=?,decided_at=? WHERE request_id=?")
    .bind(approve ? "approved" : "denied", actor.aci, new Date().toISOString(), requestId));
  await env.DB.batch(statements);
  if (approve) {
    const changedChannels = await env.DB.prepare(
      "SELECT channel_id AS channelId FROM memberships WHERE aci=? AND left_epoch IS NULL",
    ).bind(recovery.aci).all<{ channelId: string }>();
    await notifyChannelsMembershipChanged(env, changedChannels.results.map((channel) => channel.channelId));
  }
  await audit(env, approve ? "account.recovery_approved" : "account.recovery_denied", actor.aci, recovery.aci, { approved: approve, rotatedChannels });
  return json({ accepted: true });
}
