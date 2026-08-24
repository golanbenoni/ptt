import { base64UrlToBytes, bytesToBase64Url, isUuid, randomSecret, sha256Hex, uuid } from "./crypto";
import { authenticate, now, requireMembership } from "./db";
import { ApiError, arrayField, body, integerField, json, stringField } from "./http";

export async function uploadPrekeys(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const value = await body(request);
  const bundle = stringField(value, "opaqueBundle", 90_000);
  try { base64UrlToBytes(bundle, 32, 65_536); } catch { throw new ApiError(400, "INVALID_PREKEY_BUNDLE"); }
  const keys = arrayField(value, "oneTimePrekeys", 256).map((item) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) throw new ApiError(400, "INVALID_PREKEY");
    const record = item as Record<string, unknown>;
    const kind = stringField(record, "kind", 16);
    const keyId = integerField(record, "keyId", 1, 2_147_483_647);
    const publicKey = stringField(record, "publicKey", 90_000);
    if (kind !== "x25519" && kind !== "kyber") throw new ApiError(400, "INVALID_PREKEY_KIND");
    try { base64UrlToBytes(publicKey, 16, 65_536); } catch { throw new ApiError(400, "INVALID_PREKEY"); }
    return { kind, keyId, publicKey };
  });
  const updatedAt = now();
  const statements: D1PreparedStatement[] = [
    env.DB.prepare(
      `INSERT INTO prekey_bundles(aci,device_id,opaque_bundle,updated_at) VALUES(?,?,?,?)
       ON CONFLICT(aci,device_id) DO UPDATE SET opaque_bundle=excluded.opaque_bundle,updated_at=excluded.updated_at`,
    ).bind(authenticated.aci, authenticated.deviceId, bundle, updatedAt),
  ];
  for (const key of keys) {
    const existing = await env.DB.prepare(
      "SELECT public_key AS publicKey FROM one_time_prekeys WHERE aci=? AND device_id=? AND kind=? AND key_id=?",
    ).bind(authenticated.aci, authenticated.deviceId, key.kind, key.keyId).first<{ publicKey: string }>();
    if (existing && existing.publicKey !== key.publicKey) throw new ApiError(409, "PREKEY_ID_REUSED");
    if (!existing) statements.push(env.DB.prepare(
      "INSERT INTO one_time_prekeys(aci,device_id,kind,key_id,public_key,created_at) VALUES(?,?,?,?,?,?)",
    ).bind(authenticated.aci, authenticated.deviceId, key.kind, key.keyId, key.publicKey, updatedAt));
  }
  await env.DB.batch(statements);
  return json({ accepted: true });
}

export async function fetchPrekeys(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const value = await body(request);
  const devices = arrayField(value, "devices", 128);
  if (devices.length === 0) throw new ApiError(400, "INVALID_PREKEY_BATCH");
  const response: unknown[] = [];
  for (const item of devices) {
    if (!item || typeof item !== "object" || Array.isArray(item)) throw new ApiError(400, "INVALID_DEVICE");
    const record = item as Record<string, unknown>;
    const aci = stringField(record, "aci", 64);
    const deviceId = integerField(record, "deviceId", 1, 2);
    if (!isUuid(aci)) throw new ApiError(400, "INVALID_ACI");
    if (aci !== authenticated.aci) {
      const shared = await env.DB.prepare(
        `SELECT 1 AS present FROM memberships mine JOIN memberships theirs ON theirs.channel_id=mine.channel_id
          WHERE mine.aci=? AND theirs.aci=? AND mine.left_epoch IS NULL AND theirs.left_epoch IS NULL LIMIT 1`,
      ).bind(authenticated.aci, aci).first();
      if (!shared) throw new ApiError(403, "FORBIDDEN");
    }
    const bundle = await env.DB.prepare(
      `SELECT p.opaque_bundle AS opaqueBundle FROM prekey_bundles p JOIN devices d ON d.aci=p.aci AND d.device_id=p.device_id
        WHERE p.aci=? AND p.device_id=? AND d.status='active'`,
    ).bind(aci, deviceId).first<{ opaqueBundle: string }>();
    if (!bundle) continue;
    const oneTimePrekeys: unknown[] = [];
    for (const kind of ["x25519", "kyber"] as const) {
      const key = await env.DB.prepare(
        "SELECT id,key_id AS keyId,public_key AS publicKey FROM one_time_prekeys WHERE aci=? AND device_id=? AND kind=? AND consumed_at IS NULL ORDER BY id LIMIT 1",
      ).bind(aci, deviceId, kind).first<{ id: number; keyId: number; publicKey: string }>();
      if (key) {
        await env.DB.prepare("UPDATE one_time_prekeys SET consumed_at=? WHERE id=? AND consumed_at IS NULL").bind(now(), key.id).run();
        oneTimePrekeys.push({ kind, keyId: key.keyId, publicKey: key.publicKey });
      }
    }
    response.push({ aci, deviceId, opaqueBundle: bundle.opaqueBundle, oneTimePrekeys });
  }
  return json(response);
}

export async function enqueueMailbox(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const value = await body(request);
  const messageId = stringField(value, "messageId", 64);
  const expiresAt = stringField(value, "expiresAt", 64);
  if (!isUuid(messageId) || !validFutureDate(expiresAt, 31 * 24 * 60 * 60 * 1000)) throw new ApiError(400, "INVALID_MAILBOX_EXPIRY");
  const recipients = arrayField(value, "recipients", 256);
  if (recipients.length === 0) throw new ApiError(400, "INVALID_RECIPIENTS");
  const statements: D1PreparedStatement[] = [];
  const recipientAddresses: Array<{ aci: string; deviceId: number }> = [];
  for (const item of recipients) {
    if (!item || typeof item !== "object" || Array.isArray(item)) throw new ApiError(400, "INVALID_RECIPIENT");
    const record = item as Record<string, unknown>;
    const aci = stringField(record, "aci", 64);
    const deviceId = integerField(record, "deviceId", 1, 2);
    const envelope = stringField(record, "envelope", 200_000);
    try { base64UrlToBytes(envelope, 1, 131_072); } catch { throw new ApiError(400, "INVALID_ENVELOPE"); }
    if (aci !== authenticated.aci) {
      const shared = await env.DB.prepare(
        `SELECT 1 AS present FROM memberships mine JOIN memberships theirs ON theirs.channel_id=mine.channel_id
          WHERE mine.aci=? AND theirs.aci=? AND mine.left_epoch IS NULL AND theirs.left_epoch IS NULL LIMIT 1`,
      ).bind(authenticated.aci, aci).first();
      if (!shared) throw new ApiError(403, "FORBIDDEN");
    }
    const device = await env.DB.prepare("SELECT mailbox_id AS mailboxId FROM devices WHERE aci=? AND device_id=? AND status='active'")
      .bind(aci, deviceId).first<{ mailboxId: string }>();
    if (!device) throw new ApiError(403, "FORBIDDEN");
    statements.push(env.DB.prepare(
      `INSERT INTO mailbox_items(item_id,message_id,mailbox_id,envelope,expires_at,created_at) VALUES(?,?,?,?,?,?)
       ON CONFLICT(mailbox_id,message_id) DO NOTHING`,
    ).bind(uuid(), messageId, device.mailboxId, envelope, expiresAt, now()));
    recipientAddresses.push({ aci, deviceId });
  }
  const inserted = await env.DB.batch(statements);
  let acceptedRecipients = 0;
  for (let index = 0; index < inserted.length; index += 1) {
    if ((inserted[index]?.meta.changes ?? 0) === 0) continue;
    acceptedRecipients += 1;
    const address = recipientAddresses[index];
    if (!address) continue;
    const registrations = await env.DB.prepare(
      "SELECT provider FROM push_registrations WHERE aci=? AND device_id=?",
    ).bind(address.aci, address.deviceId).all<{ provider: string }>();
    for (const registration of registrations.results) {
      const outboxId = uuid();
      const result = await env.DB.prepare(
        `INSERT INTO push_outbox(id,message_id,aci,device_id,provider,created_at)
         VALUES(?,?,?,?,?,?) ON CONFLICT(message_id,aci,device_id,provider) DO NOTHING`,
      ).bind(outboxId, messageId, address.aci, address.deviceId, registration.provider, now()).run();
      if (result.meta.changes === 1) await env.PUSH_QUEUE.send({ kind: "push", outboxId });
    }
  }
  return json({ acceptedRecipients });
}

export async function pollMailbox(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const limit = Number(new URL(request.url).searchParams.get("limit") ?? "100");
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new ApiError(400, "INVALID_LIMIT");
  const device = await env.DB.prepare("SELECT mailbox_id AS mailboxId FROM devices WHERE aci=? AND device_id=? AND status='active'")
    .bind(authenticated.aci, authenticated.deviceId).first<{ mailboxId: string }>();
  if (!device) throw new ApiError(401, "UNAUTHENTICATED");
  await env.DB.prepare("DELETE FROM mailbox_items WHERE mailbox_id=? AND expires_at<=?").bind(device.mailboxId, now()).run();
  const rows = await env.DB.prepare(
    `SELECT item_id AS itemId,message_id AS messageId,envelope FROM mailbox_items
      WHERE mailbox_id=? AND delivered_at IS NULL AND expires_at>? ORDER BY created_at LIMIT ?`,
  ).bind(device.mailboxId, now(), limit).all();
  return json(rows.results);
}

export async function acknowledgeMailbox(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const value = await body(request);
  const itemIds = arrayField(value, "itemIds", 100);
  if (itemIds.length === 0 || itemIds.some((item) => !isUuid(item))) throw new ApiError(400, "INVALID_ITEM_IDS");
  const device = await env.DB.prepare("SELECT mailbox_id AS mailboxId FROM devices WHERE aci=? AND device_id=?").bind(authenticated.aci, authenticated.deviceId).first<{ mailboxId: string }>();
  let acknowledged = 0;
  for (const itemId of itemIds as string[]) {
    const result = await env.DB.prepare("UPDATE mailbox_items SET delivered_at=? WHERE item_id=? AND mailbox_id=? AND delivered_at IS NULL")
      .bind(now(), itemId, device?.mailboxId ?? "").run();
    acknowledged += result.meta.changes;
  }
  return json({ acknowledged });
}

export async function uploadHistory(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const value = await body(request);
  const talkId = stringField(value, "talkId", 64);
  const channelId = stringField(value, "channelId", 64);
  const membershipEpoch = integerField(value, "membershipEpoch", 1, 2_147_483_647);
  const mediaKid = stringField(value, "mediaKid", 24);
  const startedAt = stringField(value, "startedAt", 64);
  const durationMs = integerField(value, "durationMs", 1, 30_000);
  const encoded = stringField(value, "ciphertext", 2_800_000);
  if (!isUuid(talkId) || !isUuid(channelId) || !/^\d{1,20}$/u.test(mediaKid) || !validDate(startedAt)) throw new ApiError(400, "INVALID_HISTORY_METADATA");
  const membership = await requireMembership(env, authenticated.aci, channelId);
  if (membership.membershipEpoch !== membershipEpoch) throw new ApiError(409, "MEMBERSHIP_EPOCH_MISMATCH");
  let ciphertext: Uint8Array;
  try { ciphertext = base64UrlToBytes(encoded, 1, 2_000_000); } catch { throw new ApiError(400, "INVALID_CIPHERTEXT"); }
  const existing = await env.DB.prepare("SELECT object_id FROM history_objects WHERE channel_id=? AND talk_id=?").bind(channelId, talkId).first();
  if (existing) throw new ApiError(409, "HISTORY_ALREADY_EXISTS");
  const objectId = uuid();
  const storageKey = `channels/${channelId}/${objectId}.sframe`;
  const expiresAt = new Date(Date.now() + membership.retentionDays * 24 * 60 * 60 * 1000).toISOString();
  const digest = await sha256Hex(ciphertext);
  await env.HISTORY.put(storageKey, ciphertext, {
    httpMetadata: { contentType: "application/octet-stream" },
    customMetadata: { sha256: digest, channelId, membershipEpoch: String(membershipEpoch) },
  });
  try {
    await env.DB.prepare(
      `INSERT INTO history_objects(object_id,channel_id,talk_id,membership_epoch,media_kid,storage_key,ciphertext_bytes,ciphertext_sha256,started_at,duration_ms,expires_at,created_at)
       VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`,
    ).bind(objectId, channelId, talkId, membershipEpoch, mediaKid, storageKey, ciphertext.length, digest, startedAt, durationMs, expiresAt, now()).run();
  } catch (error) {
    await env.HISTORY.delete(storageKey);
    throw error;
  }
  return json(historyMetadata({ objectId, talkId, channelId, membershipEpoch, mediaKid, startedAt, durationMs, expiresAt, ciphertextBytes: ciphertext.length }));
}

export async function listHistory(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const url = new URL(request.url);
  const channelId = url.searchParams.get("channelId") ?? "";
  const limit = Number(url.searchParams.get("limit") ?? "100");
  if (!isUuid(channelId) || !Number.isInteger(limit) || limit < 1 || limit > 100) throw new ApiError(400, "INVALID_HISTORY_QUERY");
  await requireMembership(env, authenticated.aci, channelId);
  const rows = await env.DB.prepare(
    `SELECT object_id AS objectId,talk_id AS talkId,channel_id AS channelId,membership_epoch AS membershipEpoch,
            media_kid AS mediaKid,started_at AS startedAt,duration_ms AS durationMs,expires_at AS expiresAt,ciphertext_bytes AS ciphertextBytes
       FROM history_objects WHERE channel_id=? AND expires_at>? ORDER BY created_at DESC LIMIT ?`,
  ).bind(channelId, now(), limit).all();
  return json(rows.results.map(historyMetadata));
}

export async function downloadHistory(request: Request, env: Env, objectId: string): Promise<Response> {
  const authenticated = await authenticate(request, env);
  if (!isUuid(objectId)) throw new ApiError(400, "INVALID_OBJECT_ID");
  const row = await env.DB.prepare(
    `SELECT object_id AS objectId,talk_id AS talkId,channel_id AS channelId,membership_epoch AS membershipEpoch,
            media_kid AS mediaKid,started_at AS startedAt,duration_ms AS durationMs,expires_at AS expiresAt,
            ciphertext_bytes AS ciphertextBytes,storage_key AS storageKey,ciphertext_sha256 AS ciphertextSha256
       FROM history_objects WHERE object_id=? AND expires_at>?`,
  ).bind(objectId, now()).first<Record<string, string | number>>();
  if (!row) throw new ApiError(404, "HISTORY_NOT_FOUND");
  await requireMembership(env, authenticated.aci, String(row.channelId));
  const object = await env.HISTORY.get(String(row.storageKey));
  if (!object) throw new ApiError(503, "HISTORY_UNAVAILABLE");
  const bytes = new Uint8Array(await object.arrayBuffer());
  if (bytes.length !== row.ciphertextBytes || await sha256Hex(bytes) !== row.ciphertextSha256) throw new ApiError(503, "HISTORY_INTEGRITY_FAILED");
  return json({ metadata: historyMetadata(row), ciphertext: bytesToBase64Url(bytes) });
}

export async function relayCredentials(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const value = await body(request);
  const channelId = stringField(value, "channelId", 64);
  if (!isUuid(channelId)) throw new ApiError(400, "INVALID_CHANNEL_ID");
  await requireMembership(env, authenticated.aci, channelId);
  const senderDemux = randomUint32();
  const demuxToken = randomSecret(32);
  const ticket = randomSecret(32);
  const expiresAt = new Date(Date.now() + 10 * 60 * 1000).toISOString();
  await env.DB.prepare(
    `INSERT INTO relay_leases(channel_id,sender_demux,aci,device_id,demux_token,expires_at) VALUES(?,?,?,?,?,?)
     ON CONFLICT(channel_id,aci,device_id) DO UPDATE SET sender_demux=excluded.sender_demux,demux_token=excluded.demux_token,expires_at=excluded.expires_at`,
  ).bind(channelId, senderDemux, authenticated.aci, authenticated.deviceId, demuxToken, expiresAt).run();
  return json({ relayAddress: "tls-only://cloudflare", ticket, demuxToken, senderDemux, expiresAt });
}

export async function requestFloor(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const value = await body(request);
  const channelId = stringField(value, "channelId", 64);
  const requestToken = stringField(value, "requestToken", 64);
  const senderDemux = integerField(value, "senderDemux", 1, 4_294_967_295);
  const membershipEpoch = integerField(value, "membershipEpoch", 1, 2_147_483_647);
  const requestedTotMs = integerField(value, "requestedTotMs", 1_000, 30_000);
  const sos = value.sos === true;
  try { base64UrlToBytes(requestToken, 16, 16); } catch { throw new ApiError(400, "INVALID_REQUEST_TOKEN"); }
  const membership = await requireMembership(env, authenticated.aci, channelId);
  if (membership.membershipEpoch !== membershipEpoch) throw new ApiError(409, "MEMBERSHIP_EPOCH_MISMATCH");
  if (membership.role === "listen") throw new ApiError(403, "TALK_NOT_PERMITTED");
  const lease = await env.DB.prepare(
    "SELECT 1 AS present FROM relay_leases WHERE channel_id=? AND aci=? AND device_id=? AND sender_demux=? AND expires_at>?",
  ).bind(channelId, authenticated.aci, authenticated.deviceId, senderDemux, now()).first();
  if (!lease) throw new ApiError(403, "RELAY_LEASE_REQUIRED");
  const priority = sos ? 100 : (membership.role === "barge" || membership.role === "dispatch" ? 20 : 10);
  const stub = env.CHANNELS.getByName(channelId, { locationHint: "enam" });
  const result = await stub.requestFloor(`${authenticated.aci}:${authenticated.deviceId}`, requestToken, senderDemux, requestedTotMs, priority);
  return json(result);
}

export async function releaseFloor(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const value = await body(request);
  const channelId = stringField(value, "channelId", 64);
  const requestToken = stringField(value, "requestToken", 64);
  const released = await env.CHANNELS.getByName(channelId).releaseFloor(`${authenticated.aci}:${authenticated.deviceId}`, requestToken);
  if (!released) throw new ApiError(409, "FLOOR_NOT_HELD");
  return json({ accepted: true });
}

export async function mediaTunnel(request: Request, env: Env): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") throw new ApiError(426, "WEBSOCKET_REQUIRED");
  const authenticated = await authenticate(request, env);
  const channelId = new URL(request.url).searchParams.get("channelId") ?? "";
  if (!isUuid(channelId)) throw new ApiError(400, "INVALID_CHANNEL_ID");
  await requireMembership(env, authenticated.aci, channelId);
  const lease = await env.DB.prepare(
    `SELECT sender_demux AS senderDemux,demux_token AS demuxToken FROM relay_leases
      WHERE channel_id=? AND aci=? AND device_id=? AND expires_at>?`,
  ).bind(channelId, authenticated.aci, authenticated.deviceId, now()).first<{ senderDemux: number; demuxToken: string }>();
  if (!lease) throw new ApiError(403, "MEDIA_ROUTE_NOT_AUTHORIZED");
  const headers = new Headers(request.headers);
  headers.delete("Authorization");
  headers.set("X-PTT-Aci", authenticated.aci);
  headers.set("X-PTT-Device", String(authenticated.deviceId));
  headers.set("X-PTT-Sender-Demux", String(lease.senderDemux));
  headers.set("X-PTT-Demux-Token", lease.demuxToken);
  return env.CHANNELS.getByName(channelId, { locationHint: "enam" }).fetch(new Request(request.url, { headers }));
}

export async function pushRegistration(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const value = await body(request);
  const provider = stringField(value, "provider", 16);
  if (!new Set(["fcm", "apns", "apns-ptt"]).has(provider)) throw new ApiError(400, "INVALID_PUSH_PROVIDER");
  if (request.method === "DELETE") {
    await env.DB.prepare("DELETE FROM push_registrations WHERE aci=? AND device_id=? AND provider=?")
      .bind(authenticated.aci, authenticated.deviceId, provider).run();
  } else {
    const token = stringField(value, "token", 6000);
    try { base64UrlToBytes(token, 16, 4096); } catch { throw new ApiError(400, "INVALID_PUSH_TOKEN"); }
    const owner = await env.DB.prepare(
      "SELECT aci,device_id AS deviceId FROM push_registrations WHERE provider=? AND token=?",
    ).bind(provider, token).first<{ aci: string; deviceId: number }>();
    if (owner && (owner.aci !== authenticated.aci || owner.deviceId !== authenticated.deviceId)) {
      throw new ApiError(409, "PUSH_TOKEN_IN_USE");
    }
    await env.DB.prepare(
      `INSERT INTO push_registrations(aci,device_id,provider,token,updated_at) VALUES(?,?,?,?,?)
       ON CONFLICT(aci,device_id,provider) DO UPDATE SET token=excluded.token,updated_at=excluded.updated_at`,
    ).bind(authenticated.aci, authenticated.deviceId, provider, token, now()).run();
  }
  return json({ accepted: true });
}

export async function setPresence(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const value = await body(request);
  const mode = stringField(value, "mode", 16);
  if (!new Set(["available", "busy", "solo", "standby"]).has(mode)) throw new ApiError(400, "INVALID_PRESENCE");
  await env.DB.prepare(
    `INSERT INTO presence(aci,device_id,mode,updated_at) VALUES(?,?,?,?)
     ON CONFLICT(aci,device_id) DO UPDATE SET mode=excluded.mode,updated_at=excluded.updated_at`,
  ).bind(authenticated.aci, authenticated.deviceId, mode, now()).run();
  return json({ accepted: true });
}

function historyMetadata(value: Record<string, unknown>): Record<string, unknown> {
  return {
    objectId: value.objectId,
    talkId: value.talkId,
    channelId: value.channelId,
    membershipEpoch: value.membershipEpoch,
    mediaKid: String(value.mediaKid),
    startedAt: value.startedAt,
    durationMs: value.durationMs,
    expiresAt: value.expiresAt,
    ciphertextBytes: value.ciphertextBytes,
  };
}

function validDate(value: string): boolean {
  return Number.isFinite(Date.parse(value));
}

function validFutureDate(value: string, maximumAhead: number): boolean {
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) && timestamp > Date.now() && timestamp <= Date.now() + maximumAhead;
}

function randomUint32(): number {
  const value = new Uint32Array(1);
  do crypto.getRandomValues(value); while (value[0] === 0);
  return value[0] as number;
}
