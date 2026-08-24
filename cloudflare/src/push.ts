import { base64UrlToBytes, bytesToBase64Url } from "./crypto";
import { now, type PushJob } from "./db";

type PushProvider = "fcm" | "apns" | "apns-ptt";
type PushOutcome = "delivered" | "invalid" | "retry" | "not_configured";

type PushEnvironment = Env & {
  FCM_SERVICE_ACCOUNT_JSON?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_BUNDLE_ID?: string;
  APNS_PRIVATE_KEY?: string;
  APNS_ENVIRONMENT?: string;
};

type PushRow = {
  id: string;
  messageId: string;
  aci: string;
  deviceId: number;
  provider: PushProvider;
  token: string;
  attempts: number;
};

type FcmServiceAccount = {
  project_id: string;
  private_key_id?: string;
  private_key: string;
  client_email: string;
  token_uri: string;
};

export function pushConfiguration(env: Env): { fcmConfigured: boolean; apnsConfigured: boolean } {
  const configured = env as PushEnvironment;
  return {
    fcmConfigured: Boolean(configured.FCM_SERVICE_ACCOUNT_JSON?.trim()),
    apnsConfigured: Boolean(
      configured.APNS_KEY_ID?.trim() && configured.APNS_TEAM_ID?.trim()
      && configured.APNS_BUNDLE_ID?.trim() && configured.APNS_PRIVATE_KEY?.trim(),
    ),
  };
}

export async function dispatchPush(env: Env, job: PushJob): Promise<{ retry: boolean; delaySeconds?: number }> {
  const row = await env.DB.prepare(
    `SELECT o.id,o.message_id AS messageId,o.aci,o.device_id AS deviceId,o.provider,r.token,o.attempts
       FROM push_outbox o
       JOIN push_registrations r ON r.aci=o.aci AND r.device_id=o.device_id AND r.provider=o.provider
       JOIN devices d ON d.aci=o.aci AND d.device_id=o.device_id
      WHERE o.id=? AND o.sent_at IS NULL AND d.status='active'`,
  ).bind(job.outboxId).first<PushRow>();
  if (!row) return { retry: false };

  let outcome: PushOutcome;
  try {
    outcome = row.provider === "fcm"
      ? await sendFcm(env as PushEnvironment, row.token, row.messageId)
      : await sendApns(env as PushEnvironment, row.provider, row.token, row.messageId);
  } catch {
    outcome = "retry";
  }

  if (outcome === "delivered") {
    await env.DB.prepare("UPDATE push_outbox SET sent_at=?,attempts=attempts+1,last_error=NULL WHERE id=?")
      .bind(now(), row.id).run();
    return { retry: false };
  }
  if (outcome === "invalid") {
    await env.DB.prepare("DELETE FROM push_registrations WHERE aci=? AND device_id=? AND provider=?")
      .bind(row.aci, row.deviceId, row.provider).run();
    return { retry: false };
  }

  const delaySeconds = outcome === "not_configured"
    ? 3_600
    : Math.min(5 * (2 ** Math.min(row.attempts, 9)), 3_600);
  await env.DB.prepare("UPDATE push_outbox SET attempts=attempts+1,last_error=? WHERE id=?")
    .bind(outcome === "not_configured" ? "PROVIDER_NOT_CONFIGURED" : "PROVIDER_DELIVERY_FAILED", row.id).run();
  return { retry: true, delaySeconds };
}

async function sendFcm(env: PushEnvironment, encodedRegistration: string, messageId: string): Promise<PushOutcome> {
  if (!env.FCM_SERVICE_ACCOUNT_JSON?.trim()) return "not_configured";
  const account = JSON.parse(env.FCM_SERVICE_ACCOUNT_JSON) as Partial<FcmServiceAccount>;
  if (!account.project_id || !account.private_key || !account.client_email || !account.token_uri) return "not_configured";
  const tokenUrl = new URL(account.token_uri);
  if (tokenUrl.protocol !== "https:" || tokenUrl.hostname !== "oauth2.googleapis.com") return "not_configured";
  const registration = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false })
    .decode(base64UrlToBytes(encodedRegistration, 16, 4096));
  const issuedAt = Math.floor(Date.now() / 1000);
  const assertion = await signJwt(
    { alg: "RS256", typ: "JWT", ...(account.private_key_id ? { kid: account.private_key_id } : {}) },
    {
      iss: account.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: account.token_uri,
      iat: issuedAt,
      exp: issuedAt + 3_600,
    },
    account.private_key,
    "RSA",
  );
  const tokenResponse = await fetch(tokenUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
    redirect: "error",
  });
  if (!tokenResponse.ok) return classifyStatus(tokenResponse.status);
  const tokenValue = await tokenResponse.json<{ access_token?: string }>();
  if (!tokenValue.access_token) return "retry";
  const response = await fetch(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(account.project_id)}/messages:send`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${tokenValue.access_token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      message: {
        token: registration,
        data: { kind: "mailbox", messageId },
        android: { priority: "high" },
      },
    }),
    redirect: "error",
  });
  return classifyStatus(response.status);
}

async function sendApns(
  env: PushEnvironment,
  provider: "apns" | "apns-ptt",
  encodedRegistration: string,
  messageId: string,
): Promise<PushOutcome> {
  if (!env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_BUNDLE_ID || !env.APNS_PRIVATE_KEY) return "not_configured";
  if (!/^[A-Z0-9]{10}$/u.test(env.APNS_KEY_ID) || !/^[A-Z0-9]{10}$/u.test(env.APNS_TEAM_ID)) return "not_configured";
  const deviceToken = Array.from(base64UrlToBytes(encodedRegistration, 16, 256), (byte) => byte.toString(16).padStart(2, "0")).join("");
  const issuedAt = Math.floor(Date.now() / 1000);
  const providerToken = await signJwt(
    { alg: "ES256", kid: env.APNS_KEY_ID, typ: "JWT" },
    { iss: env.APNS_TEAM_ID, iat: issuedAt },
    env.APNS_PRIVATE_KEY,
    "EC",
  );
  const host = String(env.APNS_ENVIRONMENT) === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const isPtt = provider === "apns-ptt";
  const payload = isPtt
    ? { kind: "mailbox", messageId }
    : { aps: { "content-available": 1 }, kind: "mailbox", messageId };
  const response = await fetch(`https://${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${providerToken}`,
      "Content-Type": "application/json",
      "apns-topic": isPtt ? `${env.APNS_BUNDLE_ID}.voip-ptt` : env.APNS_BUNDLE_ID,
      "apns-push-type": isPtt ? "pushtotalk" : "background",
      "apns-priority": isPtt ? "10" : "5",
      "apns-expiration": "0",
    },
    body: JSON.stringify(payload),
    redirect: "error",
  });
  return classifyStatus(response.status);
}

async function signJwt(
  header: Record<string, unknown>,
  claims: Record<string, unknown>,
  pem: string,
  kind: "RSA" | "EC",
): Promise<string> {
  const signingInput = `${jsonBase64Url(header)}.${jsonBase64Url(claims)}`;
  const algorithm = kind === "RSA"
    ? { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }
    : { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" };
  const key = await crypto.subtle.importKey("pkcs8", pemBytes(pem), algorithm, false, ["sign"]);
  const signature = await crypto.subtle.sign(
    kind === "RSA" ? { name: "RSASSA-PKCS1-v1_5" } : { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${bytesToBase64Url(new Uint8Array(signature))}`;
}

function jsonBase64Url(value: Record<string, unknown>): string {
  return bytesToBase64Url(new TextEncoder().encode(JSON.stringify(value)));
}

function pemBytes(value: string): Uint8Array {
  const body = value.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/gu, "");
  if (!body || /[^A-Za-z0-9+/=]/u.test(body)) throw new Error("Invalid private key");
  return Uint8Array.from(atob(body), (character) => character.charCodeAt(0));
}

function classifyStatus(status: number): PushOutcome {
  if (status >= 200 && status < 300) return "delivered";
  if (status === 400 || status === 404 || status === 410) return "invalid";
  return "retry";
}
