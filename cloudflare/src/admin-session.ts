import { isoAfter, randomSecret, sha256Hex } from "./crypto";
import { audit, authenticate, enforceRateLimit, now, publicBaseUrl, requireAdmin } from "./db";
import { ApiError, body, json, stringField } from "./http";

const HANDOFF_TTL_MS = 2 * 60 * 1000;
const SESSION_TTL_MS = 15 * 60 * 1000;

export async function startAdminConsoleSession(request: Request, env: Env): Promise<Response> {
  const device = await authenticate(request, env);
  if (!device.isAdmin) throw new ApiError(403, "FORBIDDEN");
  await enforceRateLimit(env, "admin-console-start", `${device.aci}:${device.deviceId}`, 10, 300);

  const handoffCode = randomSecret();
  const createdAt = now();
  const expiresAt = isoAfter(HANDOFF_TTL_MS);
  await env.DB.batch([
    env.DB.prepare(
      "UPDATE admin_console_handoffs SET consumed_at=? WHERE aci=? AND device_id=? AND consumed_at IS NULL",
    ).bind(createdAt, device.aci, device.deviceId),
    env.DB.prepare(
      `INSERT INTO admin_console_handoffs(token_hash,aci,device_id,expires_at,created_at)
       VALUES(?,?,?,?,?)`,
    ).bind(await sha256Hex(handoffCode), device.aci, device.deviceId, expiresAt, createdAt),
  ]);
  await audit(env, "admin.console_handoff_created", device.aci, `${device.aci}:${device.deviceId}`, {
    deviceId: device.deviceId,
  });
  const adminUrl = `${publicBaseUrl(request, env)}/admin/#handoff=${encodeURIComponent(handoffCode)}`;
  return json({ adminUrl, handoffCode, expiresAt });
}

export async function consumeAdminConsoleSession(request: Request, env: Env): Promise<Response> {
  const connectingIp = request.headers.get("CF-Connecting-IP") ?? "unknown";
  await enforceRateLimit(env, "admin-console-consume", connectingIp, 20, 300);
  const value = await body(request);
  const handoffCode = stringField(value, "handoffCode", 128).trim();
  const tokenHash = await sha256Hex(handoffCode);
  const timestamp = now();
  const handoff = await env.DB.prepare(
    `SELECT h.aci,h.device_id AS deviceId
       FROM admin_console_handoffs h
       JOIN devices d ON d.aci=h.aci AND d.device_id=h.device_id
       JOIN accounts a ON a.aci=h.aci
      WHERE h.token_hash=? AND h.consumed_at IS NULL AND h.expires_at>?
        AND d.status='active' AND a.is_admin=1 AND a.disabled_at IS NULL`,
  ).bind(tokenHash, timestamp).first<{ aci: string; deviceId: number }>();
  if (!handoff) throw new ApiError(410, "INVALID_OR_EXPIRED_ADMIN_HANDOFF");

  const consumed = await env.DB.prepare(
    "UPDATE admin_console_handoffs SET consumed_at=? WHERE token_hash=? AND consumed_at IS NULL AND expires_at>?",
  ).bind(timestamp, tokenHash, timestamp).run();
  if (!consumed.success || consumed.meta.changes !== 1) {
    throw new ApiError(410, "INVALID_OR_EXPIRED_ADMIN_HANDOFF");
  }

  const sessionToken = randomSecret();
  const expiresAt = isoAfter(SESSION_TTL_MS);
  await env.DB.prepare(
    `INSERT INTO admin_console_sessions(token_hash,aci,device_id,expires_at,created_at)
     VALUES(?,?,?,?,?)`,
  ).bind(await sha256Hex(sessionToken), handoff.aci, handoff.deviceId, expiresAt, timestamp).run();
  await audit(env, "admin.console_session_started", handoff.aci, `${handoff.aci}:${handoff.deviceId}`, {
    deviceId: handoff.deviceId,
  });
  return json({ sessionToken, expiresAt });
}

export async function revokeAdminConsoleSession(request: Request, env: Env): Promise<Response> {
  const actor = await requireAdmin(request, env);
  const authorization = request.headers.get("Authorization") ?? "";
  const token = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
  const revokedAt = now();
  const revoked = await env.DB.prepare(
    "UPDATE admin_console_sessions SET revoked_at=? WHERE token_hash=? AND revoked_at IS NULL",
  ).bind(revokedAt, await sha256Hex(token)).run();
  if (revoked.success && revoked.meta.changes === 1) {
    await audit(env, "admin.console_session_revoked", actor.aci, `${actor.aci}:${actor.deviceId}`, {
      deviceId: actor.deviceId,
    });
  }
  return json({ accepted: true });
}
