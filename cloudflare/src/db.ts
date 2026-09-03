import { ApiError } from "./http";
import { sha256Hex } from "./crypto";

export type AuthenticatedDevice = {
  aci: string;
  deviceId: number;
  isAdmin: boolean;
  accountKind: string;
  integrationCapabilities: string[];
};

export type EmailJob = {
  kind: "email";
  outboxId: string;
  recipient: string;
  template: "enrollment_link" | "recovery_link";
  url: string;
  expiresMinutes: number;
};

export type PushJob = {
  kind: "push";
  outboxId: string;
};

export type DeliveryJob = EmailJob | PushJob;

export function now(): string {
  return new Date().toISOString();
}

export async function authenticate(request: Request, env: Env, integrationCapability?: string): Promise<AuthenticatedDevice> {
  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ") || authorization.length > 4_103) {
    throw new ApiError(401, "UNAUTHENTICATED");
  }
  const token = authorization.slice(7);
  const hash = await sha256Hex(token);
  const row = await env.DB.prepare(
    `SELECT d.aci AS aci,d.device_id AS deviceId,a.is_admin AS isAdmin,a.account_kind AS accountKind,
            coalesce((SELECT i.capabilities FROM channel_integrations i WHERE i.aci=a.aci AND i.revoked_at IS NULL
              AND (i.expires_at IS NULL OR i.expires_at>?)),'[]') AS integrationCapabilities
       FROM devices d JOIN accounts a ON a.aci=d.aci
      WHERE d.access_token_hash=? AND d.status='active' AND a.disabled_at IS NULL
        AND (a.guest_expires_at IS NULL OR a.guest_expires_at>?)
        AND (a.account_kind<>'integration' OR EXISTS(
          SELECT 1 FROM channel_integrations i WHERE i.aci=a.aci AND i.revoked_at IS NULL
            AND (i.expires_at IS NULL OR i.expires_at>?)))`,
  ).bind(now(), hash, now(), now()).first<{ aci: string; deviceId: number; isAdmin: number; accountKind: string; integrationCapabilities: string }>();
  if (!row) throw new ApiError(401, "UNAUTHENTICATED");
  const integrationCapabilities = JSON.parse(row.integrationCapabilities) as string[];
  if (row.accountKind === "integration" && (!integrationCapability || !integrationCapabilities.includes(integrationCapability))) {
    throw new ApiError(403, "INTEGRATION_SCOPE_FORBIDDEN");
  }
  return { aci: row.aci, deviceId: row.deviceId, isAdmin: row.isAdmin === 1, accountKind: row.accountKind, integrationCapabilities };
}

export async function requireAdmin(request: Request, env: Env): Promise<AuthenticatedDevice> {
  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ") || authorization.length > 4_103) {
    throw new ApiError(401, "UNAUTHENTICATED");
  }
  const hash = await sha256Hex(authorization.slice(7));
  const row = await env.DB.prepare(
    `SELECT aci,deviceId,isAdmin FROM (
       SELECT d.aci AS aci,d.device_id AS deviceId,a.is_admin AS isAdmin,0 AS preference
         FROM devices d JOIN accounts a ON a.aci=d.aci
        WHERE d.access_token_hash=? AND d.status='active' AND a.disabled_at IS NULL
       UNION ALL
       SELECT s.aci AS aci,s.device_id AS deviceId,a.is_admin AS isAdmin,1 AS preference
         FROM admin_console_sessions s
         JOIN devices d ON d.aci=s.aci AND d.device_id=s.device_id
         JOIN accounts a ON a.aci=s.aci
        WHERE s.token_hash=? AND s.revoked_at IS NULL AND s.expires_at>?
          AND d.status='active' AND a.disabled_at IS NULL
     ) ORDER BY preference LIMIT 1`,
  ).bind(hash, hash, now()).first<{ aci: string; deviceId: number; isAdmin: number }>();
  if (!row) throw new ApiError(401, "UNAUTHENTICATED");
  if (row.isAdmin !== 1) throw new ApiError(403, "FORBIDDEN");
  return { aci: row.aci, deviceId: row.deviceId, isAdmin: true, accountKind: "member", integrationCapabilities: [] };
}

export async function requireMembership(env: Env, aci: string, channelId: string): Promise<{ role: string; membershipEpoch: number; retentionDays: number; isAnnouncement: number }> {
  const row = await env.DB.prepare(
    `SELECT m.role AS role, c.membership_epoch AS membershipEpoch, c.retention_days AS retentionDays,
            c.is_announcement AS isAnnouncement
       FROM memberships m JOIN channels c ON c.channel_id=m.channel_id
      WHERE m.channel_id=? AND m.aci=? AND m.left_epoch IS NULL`,
  ).bind(channelId, aci).first<{ role: string; membershipEpoch: number; retentionDays: number; isAnnouncement: number }>();
  if (!row) throw new ApiError(403, "FORBIDDEN");
  return row;
}

export async function audit(env: Env, action: string, actorAci: string | null, subject: string | null, detail: Record<string, unknown> = {}): Promise<void> {
  const subjectHash = subject ? await sha256Hex(subject) : null;
  await env.DB.prepare(
    "INSERT INTO audit_events(actor_aci,action,subject_hash,detail,created_at) VALUES(?,?,?,?,?)",
  ).bind(actorAci, action, subjectHash, JSON.stringify(detail), now()).run();
}

export async function enforceRateLimit(env: Env, scope: string, discriminator: string, maximum: number, windowSeconds: number): Promise<void> {
  const discriminatorHash = await sha256Hex(discriminator.toLowerCase());
  const windowStart = Math.floor(Date.now() / (windowSeconds * 1000)) * windowSeconds;
  const [, selected] = await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO rate_limits(scope,discriminator_hash,window_start,attempts) VALUES(?,?,?,1)
       ON CONFLICT(scope,discriminator_hash) DO UPDATE SET
         attempts=CASE WHEN window_start=excluded.window_start THEN attempts+1 ELSE 1 END,
         window_start=excluded.window_start`,
    ).bind(scope, discriminatorHash, windowStart),
    env.DB.prepare(
      "SELECT attempts FROM rate_limits WHERE scope=? AND discriminator_hash=?",
    ).bind(scope, discriminatorHash),
  ]);
  const attempts = Number((selected?.results[0] as Record<string, unknown> | undefined)?.attempts ?? 0);
  if (attempts > maximum) throw new ApiError(429, "RATE_LIMITED");
}

export async function queueEmail(env: Env, job: EmailJob): Promise<void> {
  await env.DB.prepare(
    "INSERT INTO email_outbox(id,recipient,template,payload,status,created_at) VALUES(?,?,?,?, 'queued', ?)",
  ).bind(job.outboxId, job.recipient, job.template, JSON.stringify(job), now()).run();
  await env.EMAIL_QUEUE.send(job);
}

export function validEmail(email: string): string {
  const normalized = email.trim().toLowerCase();
  if (normalized.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(normalized)) {
    throw new ApiError(400, "INVALID_EMAIL");
  }
  return normalized;
}

export function publicBaseUrl(request: Request, env: Env): string {
  const configured = env.PUBLIC_BASE_URL.trim();
  const environment = (env as unknown as { ENVIRONMENT?: string }).ENVIRONMENT ?? "";
  if (!configured && environment === "production") {
    throw new ApiError(500, "SERVER_MISCONFIGURED", "Server configuration unavailable");
  }
  let url: URL;
  try {
    url = new URL(configured || new URL(request.url).origin);
  } catch {
    throw new ApiError(500, "SERVER_MISCONFIGURED", "Server configuration unavailable");
  }
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash ||
      (url.pathname !== "/" && url.pathname !== "")) {
    throw new ApiError(500, "SERVER_MISCONFIGURED", "Server configuration unavailable");
  }
  return url.origin;
}
