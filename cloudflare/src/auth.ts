import { base64UrlToBytes, isoAfter, randomSecret, secretsEqual, sha256Hex, uuid } from "./crypto";
import { audit, authenticate, enforceRateLimit, now, publicBaseUrl, queueEmail, validEmail } from "./db";
import { ApiError, body, json, stringField } from "./http";

const MAGIC_LINK_TTL_MS = 15 * 60 * 1000;

export async function bootstrap(request: Request, env: Env): Promise<Response> {
  const value = await body(request);
  const email = validEmail(stringField(value, "email", 254));
  const bootstrapToken = stringField(value, "bootstrapToken");
  const bootstrapSecret = (env as Env & { BOOTSTRAP_TOKEN: string }).BOOTSTRAP_TOKEN;
  if (!bootstrapSecret || !(await secretsEqual(bootstrapToken, bootstrapSecret))) throw new ApiError(403, "FORBIDDEN");
  const existing = await env.DB.prepare(
    `SELECT (SELECT count(*) FROM accounts WHERE is_admin=1 AND disabled_at IS NULL) +
            (SELECT count(*) FROM invitations WHERE grants_admin=1 AND consumed_at IS NULL AND expires_at>?) AS count`,
  ).bind(now()).first<{ count: number }>();
  if ((existing?.count ?? 0) > 0) throw new ApiError(409, "INSTANCE_ALREADY_BOOTSTRAPPED");
  const invitationId = uuid();
  const invitationCode = randomSecret();
  const expiresAt = isoAfter(24 * 60 * 60 * 1000);
  await env.DB.prepare(
    "INSERT INTO invitations(id,email,token_hash,grants_admin,expires_at,created_at) VALUES(?,?,?,?,?,?)",
  ).bind(invitationId, email, await sha256Hex(invitationCode), 1, expiresAt, now()).run();
  await issueMagicLink(request, env, invitationId, email, true);
  return json({ invitationCode, expiresAt });
}

export async function requestMagicLink(request: Request, env: Env): Promise<Response> {
  const value = await body(request);
  const email = validEmail(stringField(value, "email", 254));
  const invitationCode = stringField(value, "invitationCode");
  await enforceRateLimit(env, "magic-link", email, 5, 3600);
  const invitation = await env.DB.prepare(
    `SELECT id,email,grants_admin AS grantsAdmin FROM invitations
      WHERE token_hash=? AND consumed_at IS NULL AND expires_at>?`,
  ).bind(await sha256Hex(invitationCode), now()).first<{ id: string; email: string; grantsAdmin: number }>();
  if (invitation && invitation.email.toLowerCase() === email) {
    await issueMagicLink(request, env, invitation.id, invitation.email, invitation.grantsAdmin === 1);
  }
  return json({ accepted: true }, 202);
}

export async function consumeMagicLink(request: Request, env: Env): Promise<Response> {
  const value = await body(request);
  const token = stringField(value, "token");
  const deviceName = stringField(value, "deviceName", 80).trim();
  const identityKey = stringField(value, "identityKey", 6000);
  try { base64UrlToBytes(identityKey, 32, 4096); } catch { throw new ApiError(400, "INVALID_IDENTITY_KEY"); }
  const tokenHash = await sha256Hex(token);
  const link = await env.DB.prepare(
    `SELECT l.id,l.invitation_id AS invitationId,l.email,l.grants_admin AS grantsAdmin
       FROM magic_links l
      WHERE l.token_hash=? AND l.purpose='enroll' AND l.consumed_at IS NULL AND l.expires_at>?`,
  ).bind(tokenHash, now()).first<{ id: string; invitationId: string; email: string; grantsAdmin: number }>();
  if (!link) return resumeEnrollment(env, tokenHash, identityKey);
  const existing = await env.DB.prepare("SELECT aci FROM accounts WHERE email=? COLLATE NOCASE").bind(link.email).first();
  if (existing) throw new ApiError(409, "ACCOUNT_ALREADY_EXISTS");
  const aci = uuid();
  const mailboxId = uuid();
  const accessToken = randomSecret();
  const createdAt = now();
  const results = await env.DB.batch([
    env.DB.prepare("INSERT INTO accounts(aci,email,is_admin,created_at) VALUES(?,?,?,?)")
      .bind(aci, link.email.toLowerCase(), link.grantsAdmin, createdAt),
    env.DB.prepare(
      "INSERT INTO devices(aci,device_id,mailbox_id,display_name,identity_key,access_token_hash,status,linked_at) VALUES(?,?,?,?,?,?,'active',?)",
    ).bind(aci, 1, mailboxId, deviceName, identityKey, await sha256Hex(accessToken), createdAt),
    env.DB.prepare("UPDATE magic_links SET consumed_at=? WHERE id=? AND consumed_at IS NULL").bind(createdAt, link.id),
    env.DB.prepare("UPDATE invitations SET consumed_at=? WHERE id=? AND consumed_at IS NULL").bind(createdAt, link.invitationId),
  ]);
  if (results.some((result) => !result.success)) return resumeEnrollment(env, tokenHash, identityKey);
  await audit(env, "account.enrolled", aci, link.email, { deviceId: 1, administrator: link.grantsAdmin === 1 });
  return json({ aci, deviceId: 1, mailboxId, accessToken });
}

async function resumeEnrollment(env: Env, tokenHash: string, identityKey: string): Promise<Response> {
  const enrolled = await env.DB.prepare(
    `SELECT a.aci,d.mailbox_id AS mailboxId,d.identity_key AS identityKey,l.email
       FROM magic_links l
       JOIN accounts a ON a.email=l.email COLLATE NOCASE
       JOIN devices d ON d.aci=a.aci AND d.device_id=1
      WHERE l.token_hash=? AND l.purpose='enroll' AND l.consumed_at IS NOT NULL
        AND l.expires_at>? AND d.status='active'`,
  ).bind(tokenHash, now()).first<{ aci: string; mailboxId: string; identityKey: string; email: string }>();
  if (!enrolled || enrolled.identityKey !== identityKey) throw new ApiError(410, "INVALID_OR_EXPIRED_LINK");

  // A successful D1 commit can outlive a dropped HTTP response. Allow only the
  // same device identity, holding the still-unexpired one-time link, to rotate
  // and recover its access token. A different device must use device linking or
  // administrator-approved recovery.
  const accessToken = randomSecret();
  const updated = await env.DB.prepare(
    "UPDATE devices SET access_token_hash=? WHERE aci=? AND device_id=1 AND identity_key=? AND status='active'",
  ).bind(await sha256Hex(accessToken), enrolled.aci, identityKey).run();
  if (!updated.success || updated.meta.changes !== 1) throw new ApiError(409, "ENROLLMENT_CONFLICT");
  await audit(env, "account.enrollment_resumed", enrolled.aci, enrolled.email, { deviceId: 1 });
  return json({ aci: enrolled.aci, deviceId: 1, mailboxId: enrolled.mailboxId, accessToken });
}

export async function startDeviceLink(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const occupied = await env.DB.prepare(
    "SELECT count(*) AS count FROM devices WHERE aci=? AND status IN ('active','pending')",
  ).bind(authenticated.aci).first<{ count: number }>();
  if ((occupied?.count ?? 0) >= 2) throw new ApiError(409, "DEVICE_LIMIT_REACHED");
  const requestId = uuid();
  const linkCode = randomSecret();
  const expiresAt = isoAfter(10 * 60 * 1000);
  await env.DB.prepare(
    "INSERT INTO device_link_requests(request_id,aci,initiator_device_id,link_code_hash,expires_at,created_at) VALUES(?,?,?,?,?,?)",
  ).bind(requestId, authenticated.aci, authenticated.deviceId, await sha256Hex(linkCode), expiresAt, now()).run();
  return json({ requestId, linkCode, expiresAt });
}

export async function claimDeviceLink(request: Request, env: Env): Promise<Response> {
  const value = await body(request);
  const requestId = stringField(value, "requestId", 64);
  const linkCode = stringField(value, "linkCode");
  const deviceName = stringField(value, "deviceName", 80).trim();
  const identityKey = stringField(value, "identityKey", 6000);
  try { base64UrlToBytes(identityKey, 32, 4096); } catch { throw new ApiError(400, "INVALID_IDENTITY_KEY"); }
  const link = await env.DB.prepare(
    `SELECT aci FROM device_link_requests WHERE request_id=? AND link_code_hash=?
      AND claimed_device_id IS NULL AND consumed_at IS NULL AND expires_at>?`,
  ).bind(requestId, await sha256Hex(linkCode), now()).first<{ aci: string }>();
  if (!link) throw new ApiError(410, "INVALID_OR_EXPIRED_LINK");
  const rows = await env.DB.prepare(
    "SELECT device_id AS deviceId FROM devices WHERE aci=? AND status IN ('active','pending') ORDER BY device_id",
  ).bind(link.aci).all<{ deviceId: number }>();
  const occupied = new Set(rows.results.map((row) => row.deviceId));
  const deviceId = [1, 2].find((candidate) => !occupied.has(candidate));
  if (!deviceId) throw new ApiError(409, "DEVICE_LIMIT_REACHED");
  const mailboxId = uuid();
  const claimToken = randomSecret();
  const claimHash = await sha256Hex(claimToken);
  const claimedAt = now();
  await env.DB.batch([
    env.DB.prepare("DELETE FROM devices WHERE aci=? AND device_id=? AND status='revoked'").bind(link.aci, deviceId),
    env.DB.prepare(
      "INSERT INTO devices(aci,device_id,mailbox_id,display_name,identity_key,access_token_hash,status,linked_at) VALUES(?,?,?,?,?,?,'pending',?)",
    ).bind(link.aci, deviceId, mailboxId, deviceName, identityKey, claimHash, claimedAt),
    env.DB.prepare(
      "UPDATE device_link_requests SET claimed_device_id=?,claim_token_hash=?,consumed_at=? WHERE request_id=? AND claimed_device_id IS NULL",
    ).bind(deviceId, claimHash, claimedAt, requestId),
  ]);
  return json({ aci: link.aci, deviceId, mailboxId, claimToken, status: "pending" });
}

export async function approveDeviceLink(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const value = await body(request);
  const requestId = stringField(value, "requestId", 64);
  const link = await env.DB.prepare(
    `SELECT claimed_device_id AS deviceId FROM device_link_requests
      WHERE request_id=? AND aci=? AND initiator_device_id=? AND claimed_device_id IS NOT NULL
        AND approved_at IS NULL AND expires_at>?`,
  ).bind(requestId, authenticated.aci, authenticated.deviceId, now()).first<{ deviceId: number }>();
  if (!link) throw new ApiError(410, "INVALID_OR_EXPIRED_LINK");
  const channels = await env.DB.prepare(
    "SELECT channel_id AS channelId FROM memberships WHERE aci=? AND left_epoch IS NULL",
  ).bind(authenticated.aci).all<{ channelId: string }>();
  const approvedAt = now();
  const statements: D1PreparedStatement[] = [
    env.DB.prepare("UPDATE devices SET status='active',linked_at=? WHERE aci=? AND device_id=? AND status='pending'")
      .bind(approvedAt, authenticated.aci, link.deviceId),
    env.DB.prepare("UPDATE device_link_requests SET approved_at=? WHERE request_id=?").bind(approvedAt, requestId),
  ];
  for (const channel of channels.results) {
    statements.push(env.DB.prepare("UPDATE channels SET membership_epoch=membership_epoch+1,distribution_id=? WHERE channel_id=?")
      .bind(uuid(), channel.channelId));
  }
  await env.DB.batch(statements);
  await audit(env, "device.linked", authenticated.aci, `${authenticated.aci}:${link.deviceId}`, { deviceId: link.deviceId, rotatedChannels: channels.results.length });
  return json({ accepted: true });
}

export async function deviceLinkStatus(request: Request, env: Env): Promise<Response> {
  const value = await body(request);
  const claimToken = stringField(value, "claimToken");
  const row = await env.DB.prepare(
    `SELECT d.aci,d.device_id AS deviceId,d.mailbox_id AS mailboxId,d.status
       FROM devices d WHERE d.access_token_hash=? AND
       (d.status='active' OR (d.status='pending' AND EXISTS(
          SELECT 1 FROM device_link_requests r WHERE r.aci=d.aci AND r.claimed_device_id=d.device_id
          AND r.approved_at IS NULL AND r.expires_at>?)))`,
  ).bind(await sha256Hex(claimToken), now()).first<{ aci: string; deviceId: number; mailboxId: string; status: string }>();
  if (!row) throw new ApiError(410, "INVALID_OR_EXPIRED_LINK");
  return json({ ...row, ...(row.status === "active" ? { accessToken: claimToken } : {}) });
}

export async function listDevices(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const rows = await env.DB.prepare(
    "SELECT device_id AS deviceId,mailbox_id AS mailboxId,display_name AS displayName,status,linked_at AS linkedAt,revoked_at AS revokedAt FROM devices WHERE aci=? ORDER BY device_id",
  ).bind(authenticated.aci).all();
  return json(rows.results);
}

export async function revokeDevice(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const value = await body(request);
  const deviceId = value.deviceId;
  if (!Number.isInteger(deviceId) || (deviceId !== 1 && deviceId !== 2)) throw new ApiError(400, "INVALID_DEVICE_ID");
  await revokeDeviceFor(env, authenticated.aci, authenticated.aci, deviceId as number);
  return json({ accepted: true });
}

export async function revokeDeviceFor(env: Env, actorAci: string, aci: string, deviceId: number): Promise<void> {
  const target = await env.DB.prepare("SELECT status FROM devices WHERE aci=? AND device_id=?").bind(aci, deviceId).first<{ status: string }>();
  if (!target || target.status !== "active") throw new ApiError(409, "DEVICE_NOT_ACTIVE");
  const active = await env.DB.prepare("SELECT count(*) AS count FROM devices WHERE aci=? AND status='active'").bind(aci).first<{ count: number }>();
  if ((active?.count ?? 0) <= 1) throw new ApiError(409, "LAST_DEVICE");
  const channels = await env.DB.prepare("SELECT channel_id AS channelId FROM memberships WHERE aci=? AND left_epoch IS NULL").bind(aci).all<{ channelId: string }>();
  const revokedAt = now();
  const statements: D1PreparedStatement[] = [
    env.DB.prepare("UPDATE devices SET status='revoked',revoked_at=? WHERE aci=? AND device_id=? AND status='active'").bind(revokedAt, aci, deviceId),
    env.DB.prepare("DELETE FROM relay_leases WHERE aci=? AND device_id=?").bind(aci, deviceId),
  ];
  for (const channel of channels.results) statements.push(
    env.DB.prepare("UPDATE channels SET membership_epoch=membership_epoch+1,distribution_id=? WHERE channel_id=?").bind(uuid(), channel.channelId),
  );
  await env.DB.batch(statements);
  await audit(env, "device.revoked", actorAci, `${aci}:${deviceId}`, { deviceId, rotatedChannels: channels.results.length });
}

export async function deleteAccount(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const value = await body(request);
  if (value.confirmation !== "DELETE") throw new ApiError(400, "CONFIRMATION_REQUIRED");
  if (authenticated.isAdmin) {
    const otherAdmins = await env.DB.prepare(
      `SELECT count(*) AS count FROM devices d JOIN accounts a ON a.aci=d.aci
        WHERE a.is_admin=1 AND a.disabled_at IS NULL AND d.status='active' AND a.aci<>?`,
    ).bind(authenticated.aci).first<{ count: number }>();
    if ((otherAdmins?.count ?? 0) === 0) throw new ApiError(409, "LAST_ADMIN");
  }
  const channels = await env.DB.prepare(
    `SELECT c.channel_id AS channelId,c.membership_epoch AS membershipEpoch
       FROM memberships m JOIN channels c ON c.channel_id=m.channel_id
      WHERE m.aci=? AND m.left_epoch IS NULL`,
  ).bind(authenticated.aci).all<{ channelId: string; membershipEpoch: number }>();
  const deletedAt = now();
  const statements: D1PreparedStatement[] = [
    env.DB.prepare("UPDATE accounts SET email=?,is_admin=0,disabled_at=? WHERE aci=?")
      .bind(`deleted+${authenticated.aci}@invalid.local`, deletedAt, authenticated.aci),
    env.DB.prepare("DELETE FROM devices WHERE aci=?").bind(authenticated.aci),
    env.DB.prepare("DELETE FROM relay_leases WHERE aci=?").bind(authenticated.aci),
  ];
  for (const channel of channels.results) {
    const nextEpoch = channel.membershipEpoch + 1;
    statements.push(
      env.DB.prepare("UPDATE memberships SET left_epoch=? WHERE channel_id=? AND aci=? AND left_epoch IS NULL")
        .bind(nextEpoch, channel.channelId, authenticated.aci),
      env.DB.prepare("UPDATE channels SET membership_epoch=?,distribution_id=? WHERE channel_id=?")
        .bind(nextEpoch, uuid(), channel.channelId),
    );
  }
  await env.DB.batch(statements);
  await audit(env, "account.deleted", null, authenticated.aci, { rotatedChannels: channels.results.length });
  return json({ accepted: true });
}

export async function requestRecovery(request: Request, env: Env): Promise<Response> {
  const value = await body(request);
  const email = validEmail(stringField(value, "email", 254));
  await enforceRateLimit(env, "recovery", email, 5, 3600);
  const account = await env.DB.prepare("SELECT aci,email FROM accounts WHERE email=? COLLATE NOCASE AND disabled_at IS NULL").bind(email).first<{ aci: string; email: string }>();
  if (account) {
    await env.DB.prepare("UPDATE magic_links SET consumed_at=? WHERE email=? COLLATE NOCASE AND purpose='recover' AND consumed_at IS NULL").bind(now(), account.email).run();
    const token = randomSecret();
    const linkId = uuid();
    const expiresAt = isoAfter(MAGIC_LINK_TTL_MS);
    await env.DB.prepare(
      "INSERT INTO magic_links(id,email,token_hash,purpose,grants_admin,expires_at,created_at) VALUES(?,?,?,'recover',0,?,?)",
    ).bind(linkId, account.email, await sha256Hex(token), expiresAt, now()).run();
    const job = { kind: "email" as const, outboxId: uuid(), recipient: account.email, template: "recovery_link" as const, url: `${publicBaseUrl(request, env)}/recover#token=${token}`, expiresMinutes: 15 };
    await queueEmail(env, job);
    await audit(env, "account.recovery_requested", null, account.email, { aciHash: await sha256Hex(account.aci) });
  }
  return json({ accepted: true }, 202);
}

export async function consumeRecovery(request: Request, env: Env): Promise<Response> {
  const value = await body(request);
  const token = stringField(value, "token");
  const deviceName = stringField(value, "deviceName", 80).trim();
  const identityKey = stringField(value, "identityKey", 6000);
  try { base64UrlToBytes(identityKey, 32, 4096); } catch { throw new ApiError(400, "INVALID_IDENTITY_KEY"); }
  const link = await env.DB.prepare(
    `SELECT l.id,a.aci FROM magic_links l JOIN accounts a ON a.email=l.email COLLATE NOCASE
      WHERE l.token_hash=? AND l.purpose='recover' AND l.consumed_at IS NULL AND l.expires_at>? AND a.disabled_at IS NULL`,
  ).bind(await sha256Hex(token), now()).first<{ id: string; aci: string }>();
  if (!link) throw new ApiError(410, "INVALID_OR_EXPIRED_LINK");
  const requestId = uuid();
  const mailboxId = uuid();
  const claimToken = randomSecret();
  const expiresAt = isoAfter(24 * 60 * 60 * 1000);
  const createdAt = now();
  const claimHash = await sha256Hex(claimToken);
  await env.DB.batch([
    env.DB.prepare("UPDATE recovery_requests SET status='expired' WHERE aci=? AND status='pending_admin'").bind(link.aci),
    env.DB.prepare(
      `INSERT INTO recovery_requests(request_id,link_id,aci,mailbox_id,device_name,identity_key,claim_token_hash,device_access_token_hash,status,expires_at,created_at)
       VALUES(?,?,?,?,?,?,?,?,'pending_admin',?,?)`,
    ).bind(requestId, link.id, link.aci, mailboxId, deviceName, identityKey, claimHash, claimHash, expiresAt, createdAt),
    env.DB.prepare("UPDATE magic_links SET consumed_at=? WHERE id=?").bind(createdAt, link.id),
  ]);
  return json({ requestId, claimToken, status: "pending_admin", expiresAt });
}

export async function recoveryStatus(request: Request, env: Env): Promise<Response> {
  const value = await body(request);
  const requestId = stringField(value, "requestId", 64);
  const claimToken = stringField(value, "claimToken");
  const claimHash = await sha256Hex(claimToken);
  await env.DB.prepare("UPDATE recovery_requests SET status='expired' WHERE request_id=? AND claim_token_hash=? AND status='pending_admin' AND expires_at<=?")
    .bind(requestId, claimHash, now()).run();
  const row = await env.DB.prepare(
    "SELECT aci,mailbox_id AS mailboxId,status FROM recovery_requests WHERE request_id=? AND claim_token_hash=?",
  ).bind(requestId, claimHash).first<{ aci: string; mailboxId: string; status: string }>();
  if (!row) throw new ApiError(410, "INVALID_OR_EXPIRED_LINK");
  return json(row.status === "approved"
    ? { status: row.status, aci: row.aci, deviceId: 1, mailboxId: row.mailboxId, accessToken: claimToken }
    : { status: row.status });
}

export async function issueMagicLink(request: Request, env: Env, invitationId: string, email: string, grantsAdmin: boolean): Promise<void> {
  await env.DB.prepare("UPDATE magic_links SET consumed_at=? WHERE invitation_id=? AND purpose='enroll' AND consumed_at IS NULL").bind(now(), invitationId).run();
  const token = randomSecret();
  const linkId = uuid();
  const expiresAt = isoAfter(MAGIC_LINK_TTL_MS);
  await env.DB.prepare(
    "INSERT INTO magic_links(id,invitation_id,email,token_hash,purpose,grants_admin,expires_at,created_at) VALUES(?,?,?,?, 'enroll', ?,?,?)",
  ).bind(linkId, invitationId, email.toLowerCase(), await sha256Hex(token), grantsAdmin ? 1 : 0, expiresAt, now()).run();
  await queueEmail(env, {
    kind: "email",
    outboxId: uuid(), recipient: email.toLowerCase(), template: "enrollment_link",
    url: `${publicBaseUrl(request, env)}/enroll#token=${token}`, expiresMinutes: 15,
  });
}
