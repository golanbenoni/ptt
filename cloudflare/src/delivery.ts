import { base64UrlToBytes, bytesToBase64Url, isUuid, randomSecret, sha256Hex, uuid } from "./crypto";
import { authenticate, enforceRateLimit, now, requireMembership } from "./db";
import { ApiError, arrayField, body, integerField, json, stringField } from "./http";

export async function uploadPrekeys(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  await deviceRate(env, "prekeys-upload", authenticated, 60, 60);
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
  let newKeyCount = 0;
  for (const key of keys) {
    const existing = await env.DB.prepare(
      "SELECT public_key AS publicKey FROM one_time_prekeys WHERE aci=? AND device_id=? AND kind=? AND key_id=?",
    ).bind(authenticated.aci, authenticated.deviceId, key.kind, key.keyId).first<{ publicKey: string }>();
    if (existing && existing.publicKey !== key.publicKey) throw new ApiError(409, "PREKEY_ID_REUSED");
    if (!existing) {
      newKeyCount += 1;
      statements.push(env.DB.prepare(
        "INSERT INTO one_time_prekeys(aci,device_id,kind,key_id,public_key,created_at) VALUES(?,?,?,?,?,?)",
      ).bind(authenticated.aci, authenticated.deviceId, key.kind, key.keyId, key.publicKey, updatedAt));
    }
  }
  const available = await env.DB.prepare(
    "SELECT count(*) AS count FROM one_time_prekeys WHERE aci=? AND device_id=? AND consumed_at IS NULL",
  ).bind(authenticated.aci, authenticated.deviceId).first<{ count: number }>();
  if ((available?.count ?? 0) + newKeyCount > 1_000) throw new ApiError(429, "PREKEY_QUOTA_EXCEEDED");
  await env.DB.batch(statements);
  return json({ accepted: true });
}

export async function fetchPrekeys(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  await deviceRate(env, "prekeys-fetch", authenticated, 300, 60);
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
        `UPDATE one_time_prekeys SET consumed_at=? WHERE id=(
           SELECT id FROM one_time_prekeys WHERE aci=? AND device_id=? AND kind=? AND consumed_at IS NULL ORDER BY id LIMIT 1
         ) AND consumed_at IS NULL RETURNING key_id AS keyId,public_key AS publicKey`,
      ).bind(now(), aci, deviceId, kind).first<{ keyId: number; publicKey: string }>();
      if (key) {
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
  const recipientEnvelopes: string[] = [];
  for (const item of recipients) {
    if (!item || typeof item !== "object" || Array.isArray(item)) throw new ApiError(400, "INVALID_RECIPIENT");
    const record = item as Record<string, unknown>;
    const aci = stringField(record, "aci", 64);
    const deviceId = integerField(record, "deviceId", 1, 2);
    const envelope = stringField(record, "envelope", 200_000);
    try { base64UrlToBytes(envelope, 1, 131_072); } catch { throw new ApiError(400, "INVALID_ENVELOPE"); }
    recipientAddresses.push({ aci, deviceId });
    recipientEnvelopes.push(envelope);
  }

  const checkedAt = now();
  const [, validation] = await Promise.all([
    deviceRate(env, "mailbox-enqueue", authenticated, 120, 60),
    env.DB.batch(recipientAddresses.map(({ aci, deviceId }) => env.DB.prepare(
      `SELECT d.mailbox_id AS mailboxId,
              CASE WHEN d.aci=? OR EXISTS(
                SELECT 1 FROM memberships mine
                JOIN memberships theirs ON theirs.channel_id=mine.channel_id
                 WHERE mine.aci=? AND theirs.aci=d.aci
                   AND mine.left_epoch IS NULL AND theirs.left_epoch IS NULL
              ) THEN 1 ELSE 0 END AS allowed,
              (SELECT count(*) FROM mailbox_items q
                WHERE q.mailbox_id=d.mailbox_id AND q.delivered_at IS NULL AND q.expires_at>?) AS queued
         FROM devices d JOIN accounts a ON a.aci=d.aci
        WHERE d.aci=? AND d.device_id=? AND d.status='active' AND a.disabled_at IS NULL`,
    ).bind(aci, authenticated.aci, checkedAt, aci, deviceId))),
  ]);
  for (let index = 0; index < recipientAddresses.length; index += 1) {
    const checked = validation[index]?.results[0] as {
      mailboxId: string; allowed: number; queued: number;
    } | undefined;
    if (!checked || checked.allowed !== 1) throw new ApiError(403, "FORBIDDEN");
    if (checked.queued >= 1_000) throw new ApiError(429, "MAILBOX_QUOTA_EXCEEDED");
    const envelope = recipientEnvelopes[index];
    if (!envelope) throw new ApiError(400, "INVALID_RECIPIENT");
    statements.push(env.DB.prepare(
      `INSERT INTO mailbox_items(item_id,message_id,mailbox_id,envelope,expires_at,created_at) VALUES(?,?,?,?,?,?)
       ON CONFLICT(mailbox_id,message_id) DO NOTHING`,
    ).bind(uuid(), messageId, checked.mailboxId, envelope, expiresAt, checkedAt));
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

// The encrypted PTTA container adds a fixed header, nonce, and GCM tag. Keep a
// small allowance above the 25 MiB plaintext product limit without accepting
// materially larger uploads.
const maximumChatAttachmentBytes = 25 * 1024 * 1024 + 64;

export async function enqueueChat(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  await deviceRate(env, "chat-enqueue", authenticated, 120, 60);
  const value = await body(request);
  const messageId = stringField(value, "messageId", 64);
  const channelId = stringField(value, "channelId", 64);
  const membershipEpoch = integerField(value, "membershipEpoch", 1, 2_147_483_647);
  const expiresAt = stringField(value, "expiresAt", 64);
  if (!isUuid(messageId) || !isUuid(channelId) || !validFutureDate(expiresAt, 31 * 24 * 60 * 60 * 1000)) {
    throw new ApiError(400, "INVALID_CHAT_MESSAGE");
  }
  const membership = await requireMembership(env, authenticated.aci, channelId);
  if (membership.membershipEpoch !== membershipEpoch) throw new ApiError(409, "MEMBERSHIP_EPOCH_MISMATCH");
  const recipients = arrayField(value, "recipients", 128);
  if (recipients.length === 0) throw new ApiError(400, "INVALID_RECIPIENTS");

  const statements: D1PreparedStatement[] = [];
  const addresses: Array<{ aci: string; deviceId: number }> = [];
  const seen = new Set<string>();
  for (const item of recipients) {
    if (!item || typeof item !== "object" || Array.isArray(item)) throw new ApiError(400, "INVALID_RECIPIENT");
    const record = item as Record<string, unknown>;
    const aci = stringField(record, "aci", 64);
    const deviceId = integerField(record, "deviceId", 1, 2);
    const envelope = stringField(record, "envelope", 200_000);
    if (!isUuid(aci)) throw new ApiError(400, "INVALID_RECIPIENT");
    try { base64UrlToBytes(envelope, 1, 131_072); } catch { throw new ApiError(400, "INVALID_ENVELOPE"); }
    const address = `${aci}:${deviceId}`;
    if (seen.has(address)) throw new ApiError(400, "DUPLICATE_RECIPIENT");
    seen.add(address);
    const allowed = await env.DB.prepare(
      `SELECT 1 AS allowed FROM devices d
         JOIN memberships m ON m.aci=d.aci
         JOIN accounts a ON a.aci=d.aci
        WHERE d.aci=? AND d.device_id=? AND d.status='active' AND a.disabled_at IS NULL
          AND m.channel_id=? AND m.left_epoch IS NULL`,
    ).bind(aci, deviceId, channelId).first();
    if (!allowed) throw new ApiError(403, "FORBIDDEN");
    const queued = await env.DB.prepare(
      `SELECT count(*) AS count FROM chat_items
        WHERE recipient_aci=? AND recipient_device_id=? AND delivered_at IS NULL AND expires_at>?`,
    ).bind(aci, deviceId, now()).first<{ count: number }>();
    if ((queued?.count ?? 0) >= 1_000) throw new ApiError(429, "CHAT_QUOTA_EXCEEDED");
    statements.push(env.DB.prepare(
      `INSERT INTO chat_items(item_id,message_id,channel_id,membership_epoch,recipient_aci,recipient_device_id,envelope,expires_at,created_at)
       VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(recipient_aci,recipient_device_id,message_id) DO NOTHING`,
    ).bind(uuid(), messageId, channelId, membershipEpoch, aci, deviceId, envelope, expiresAt, now()));
    addresses.push({ aci, deviceId });
  }
  const inserted = await env.DB.batch(statements);
  let acceptedRecipients = 0;
  for (let index = 0; index < inserted.length; index += 1) {
    if ((inserted[index]?.meta.changes ?? 0) === 0) continue;
    acceptedRecipients += 1;
    const address = addresses[index];
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

export async function pollChat(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const limit = Number(new URL(request.url).searchParams.get("limit") ?? "100");
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new ApiError(400, "INVALID_LIMIT");
  await env.DB.prepare(
    "DELETE FROM chat_items WHERE recipient_aci=? AND recipient_device_id=? AND expires_at<=?",
  ).bind(authenticated.aci, authenticated.deviceId, now()).run();
  const rows = await env.DB.prepare(
    `SELECT item_id AS itemId,message_id AS messageId,channel_id AS channelId,
            membership_epoch AS membershipEpoch,envelope
       FROM chat_items WHERE recipient_aci=? AND recipient_device_id=?
        AND delivered_at IS NULL AND expires_at>? ORDER BY created_at LIMIT ?`,
  ).bind(authenticated.aci, authenticated.deviceId, now(), limit).all();
  return json(rows.results);
}

export async function acknowledgeChat(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const value = await body(request);
  const itemIds = arrayField(value, "itemIds", 100);
  if (itemIds.length === 0 || itemIds.some((item) => !isUuid(item))) throw new ApiError(400, "INVALID_ITEM_IDS");
  let acknowledged = 0;
  for (const itemId of itemIds as string[]) {
    const result = await env.DB.prepare(
      `UPDATE chat_items SET delivered_at=? WHERE item_id=? AND recipient_aci=?
        AND recipient_device_id=? AND delivered_at IS NULL`,
    ).bind(now(), itemId, authenticated.aci, authenticated.deviceId).run();
    acknowledged += result.meta.changes;
  }
  return json({ acknowledged });
}

export async function uploadChatAttachment(
  request: Request,
  env: Env,
  attachmentId: string,
): Promise<Response> {
  const authenticated = await authenticate(request, env);
  await deviceRate(env, "chat-attachment-upload", authenticated, 30, 3_600);
  const url = new URL(request.url);
  const channelId = url.searchParams.get("channelId") ?? "";
  const membershipEpoch = Number(url.searchParams.get("membershipEpoch") ?? "0");
  const digest = (request.headers.get("X-Ciphertext-SHA256") ?? "").toLowerCase();
  const declaredLength = Number(request.headers.get("Content-Length") ?? "0");
  if (!isUuid(attachmentId) || !isUuid(channelId) || !Number.isInteger(membershipEpoch) ||
      !/^[0-9a-f]{64}$/u.test(digest) || !Number.isInteger(declaredLength) ||
      declaredLength < 1 || declaredLength > maximumChatAttachmentBytes || !request.body) {
    throw new ApiError(400, "INVALID_CHAT_ATTACHMENT");
  }
  const membership = await requireMembership(env, authenticated.aci, channelId);
  if (membership.membershipEpoch !== membershipEpoch) throw new ApiError(409, "MEMBERSHIP_EPOCH_MISMATCH");
  const existing = await env.DB.prepare(
    `SELECT channel_id AS channelId,membership_epoch AS membershipEpoch,uploader_aci AS uploaderAci,
            uploader_device_id AS uploaderDeviceId,ciphertext_bytes AS ciphertextBytes,
            ciphertext_sha256 AS ciphertextSha256,expires_at AS expiresAt,storage_key AS storageKey
       FROM chat_attachments WHERE attachment_id=?`,
  ).bind(attachmentId).first<{
    channelId: string; membershipEpoch: number; uploaderAci: string; uploaderDeviceId: number;
    ciphertextBytes: number; ciphertextSha256: string; expiresAt: string; storageKey: string;
  }>();
  if (existing) {
    const sameUpload = existing.channelId === channelId && existing.membershipEpoch === membershipEpoch &&
      existing.uploaderAci === authenticated.aci && existing.uploaderDeviceId === authenticated.deviceId &&
      existing.ciphertextBytes === declaredLength && existing.ciphertextSha256 === digest;
    if (!sameUpload) throw new ApiError(409, "ATTACHMENT_ID_REUSED");
    const object = await env.HISTORY.head(existing.storageKey);
    if (!object || object.size !== existing.ciphertextBytes) throw new ApiError(503, "ATTACHMENT_UNAVAILABLE");
    return json({ attachmentId, ciphertextBytes: existing.ciphertextBytes,
      ciphertextSha256: existing.ciphertextSha256, expiresAt: existing.expiresAt });
  }
  const storageKey = `chat/${channelId}/${attachmentId}.ciphertext`;
  const stored = await env.HISTORY.put(storageKey, request.body, {
    onlyIf: { etagDoesNotMatch: "*" },
    httpMetadata: { contentType: "application/octet-stream", cacheControl: "no-store" },
    customMetadata: { ciphertextSha256: digest },
  });
  if (!stored) throw new ApiError(409, "ATTACHMENT_ALREADY_EXISTS");
  if (stored.size !== declaredLength || stored.size > maximumChatAttachmentBytes) {
    await env.HISTORY.delete(storageKey);
    throw new ApiError(400, "ATTACHMENT_SIZE_MISMATCH");
  }
  const createdAt = now();
  const expiresAt = new Date(Date.now() + membership.retentionDays * 24 * 60 * 60 * 1_000).toISOString();
  try {
    await env.DB.prepare(
      `INSERT INTO chat_attachments(attachment_id,channel_id,membership_epoch,uploader_aci,uploader_device_id,
        storage_key,ciphertext_bytes,ciphertext_sha256,expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)`,
    ).bind(attachmentId, channelId, membershipEpoch, authenticated.aci, authenticated.deviceId,
      storageKey, stored.size, digest, expiresAt, createdAt).run();
  } catch (error) {
    await env.HISTORY.delete(storageKey);
    throw error;
  }
  return json({ attachmentId, ciphertextBytes: stored.size, ciphertextSha256: digest, expiresAt });
}

const chatAttachmentPartSize = 1_048_576;

type ChatAttachmentUploadRow = {
  uploadId: string;
  attachmentId: string;
  channelId: string;
  membershipEpoch: number;
  uploaderAci: string;
  uploaderDeviceId: number;
  storageKey: string;
  ciphertextBytes: number;
  ciphertextSha256: string;
  partSize: number;
  expiresAt: string;
};

export async function createChatAttachmentUpload(
  request: Request,
  env: Env,
  attachmentId: string,
): Promise<Response> {
  const authenticated = await authenticate(request, env);
  await deviceRate(env, "chat-attachment-upload-create", authenticated, 60, 3_600);
  const value = await body(request);
  const channelId = stringField(value, "channelId", 64);
  const membershipEpoch = integerField(value, "membershipEpoch", 1, 2_147_483_647);
  const ciphertextBytes = integerField(value, "ciphertextBytes", 1, maximumChatAttachmentBytes);
  const ciphertextSha256 = stringField(value, "ciphertextSha256", 64).toLowerCase();
  if (!isUuid(attachmentId) || !isUuid(channelId) || !/^[0-9a-f]{64}$/u.test(ciphertextSha256)) {
    throw new ApiError(400, "INVALID_CHAT_ATTACHMENT");
  }
  const membership = await requireMembership(env, authenticated.aci, channelId);
  if (membership.membershipEpoch !== membershipEpoch) throw new ApiError(409, "MEMBERSHIP_EPOCH_MISMATCH");

  const complete = await env.DB.prepare(
    `SELECT channel_id AS channelId,membership_epoch AS membershipEpoch,uploader_aci AS uploaderAci,
            uploader_device_id AS uploaderDeviceId,ciphertext_bytes AS ciphertextBytes,
            ciphertext_sha256 AS ciphertextSha256,expires_at AS expiresAt,storage_key AS storageKey
       FROM chat_attachments WHERE attachment_id=?`,
  ).bind(attachmentId).first<{
    channelId: string; membershipEpoch: number; uploaderAci: string; uploaderDeviceId: number;
    ciphertextBytes: number; ciphertextSha256: string; expiresAt: string; storageKey: string;
  }>();
  if (complete) {
    const matches = complete.channelId === channelId && complete.membershipEpoch === membershipEpoch &&
      complete.uploaderAci === authenticated.aci && complete.uploaderDeviceId === authenticated.deviceId &&
      complete.ciphertextBytes === ciphertextBytes && complete.ciphertextSha256 === ciphertextSha256;
    if (!matches) throw new ApiError(409, "ATTACHMENT_ID_REUSED");
    const object = await env.HISTORY.head(complete.storageKey);
    if (!object || object.size !== ciphertextBytes) throw new ApiError(503, "ATTACHMENT_UNAVAILABLE");
    return json({ state: "complete", attachmentId, ciphertextBytes, ciphertextSha256, expiresAt: complete.expiresAt });
  }

  const existing = await env.DB.prepare(
    `SELECT upload_id AS uploadId,attachment_id AS attachmentId,channel_id AS channelId,
            membership_epoch AS membershipEpoch,uploader_aci AS uploaderAci,
            uploader_device_id AS uploaderDeviceId,storage_key AS storageKey,
            ciphertext_bytes AS ciphertextBytes,ciphertext_sha256 AS ciphertextSha256,
            part_size AS partSize,expires_at AS expiresAt
       FROM chat_attachment_uploads WHERE attachment_id=?`,
  ).bind(attachmentId).first<ChatAttachmentUploadRow>();
  if (existing) {
    const matches = existing.channelId === channelId && existing.membershipEpoch === membershipEpoch &&
      existing.uploaderAci === authenticated.aci && existing.uploaderDeviceId === authenticated.deviceId &&
      existing.ciphertextBytes === ciphertextBytes && existing.ciphertextSha256 === ciphertextSha256;
    if (!matches) throw new ApiError(409, "ATTACHMENT_ID_REUSED");
    if (existing.expiresAt <= now()) throw new ApiError(410, "UPLOAD_EXPIRED");
    return uploadState(env, existing);
  }

  const uploadId = uuid();
  const createdAt = now();
  const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1_000).toISOString();
  const storageKey = `chat/${channelId}/${attachmentId}.ciphertext`;
  await env.DB.prepare(
    `INSERT INTO chat_attachment_uploads(upload_id,attachment_id,channel_id,membership_epoch,
      uploader_aci,uploader_device_id,storage_key,ciphertext_bytes,ciphertext_sha256,part_size,
      expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`,
  ).bind(uploadId, attachmentId, channelId, membershipEpoch, authenticated.aci, authenticated.deviceId,
    storageKey, ciphertextBytes, ciphertextSha256, chatAttachmentPartSize, expiresAt, createdAt).run();
  return json({
    state: "uploading", uploadId, attachmentId, ciphertextBytes, ciphertextSha256,
    partSize: chatAttachmentPartSize, uploadedParts: [], expiresAt,
  });
}

export async function uploadChatAttachmentPart(
  request: Request,
  env: Env,
  attachmentId: string,
  uploadId: string,
  partNumber: number,
): Promise<Response> {
  const authenticated = await authenticate(request, env);
  await deviceRate(env, "chat-attachment-upload-part", authenticated, 512, 3_600);
  if (!isUuid(attachmentId) || !isUuid(uploadId) || !Number.isInteger(partNumber) || partNumber < 1) {
    throw new ApiError(400, "INVALID_UPLOAD_PART");
  }
  const upload = await requireChatAttachmentUpload(env, attachmentId, uploadId, authenticated);
  const partCount = Math.ceil(upload.ciphertextBytes / upload.partSize);
  if (partNumber > partCount) throw new ApiError(400, "INVALID_UPLOAD_PART");
  const expectedBytes = partNumber === partCount
    ? upload.ciphertextBytes - upload.partSize * (partCount - 1)
    : upload.partSize;
  const declaredLength = Number(request.headers.get("Content-Length") ?? "0");
  const digest = (request.headers.get("X-Ciphertext-SHA256") ?? "").toLowerCase();
  if (declaredLength !== expectedBytes || !/^[0-9a-f]{64}$/u.test(digest) || !request.body) {
    throw new ApiError(400, "INVALID_UPLOAD_PART");
  }
  const existing = await env.DB.prepare(
    `SELECT storage_key AS storageKey,ciphertext_bytes AS ciphertextBytes,
            ciphertext_sha256 AS ciphertextSha256
       FROM chat_attachment_upload_parts WHERE upload_id=? AND part_number=?`,
  ).bind(uploadId, partNumber).first<{
    storageKey: string; ciphertextBytes: number; ciphertextSha256: string;
  }>();
  if (existing) {
    if (existing.ciphertextBytes !== expectedBytes || existing.ciphertextSha256 !== digest) {
      throw new ApiError(409, "UPLOAD_PART_REUSED");
    }
    const object = await env.HISTORY.head(existing.storageKey);
    if (!object || object.size !== expectedBytes) throw new ApiError(503, "UPLOAD_PART_UNAVAILABLE");
    return json({ uploadId, partNumber, ciphertextBytes: expectedBytes, ciphertextSha256: digest });
  }
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength !== expectedBytes || await sha256Hex(bytes) !== digest) {
    throw new ApiError(400, "UPLOAD_PART_INTEGRITY_FAILED");
  }
  const storageKey = `chat-parts/${uploadId}/${partNumber}.ciphertext`;
  const stored = await env.HISTORY.put(storageKey, bytes, {
    onlyIf: { etagDoesNotMatch: "*" },
    httpMetadata: { contentType: "application/octet-stream", cacheControl: "no-store" },
    customMetadata: { ciphertextSha256: digest },
    sha256: digest,
  });
  if (!stored) throw new ApiError(409, "UPLOAD_PART_ALREADY_EXISTS");
  try {
    await env.DB.prepare(
      `INSERT INTO chat_attachment_upload_parts(upload_id,part_number,storage_key,ciphertext_bytes,
        ciphertext_sha256,created_at) VALUES(?,?,?,?,?,?)`,
    ).bind(uploadId, partNumber, storageKey, stored.size, digest, now()).run();
  } catch (error) {
    await env.HISTORY.delete(storageKey);
    throw error;
  }
  return json({ uploadId, partNumber, ciphertextBytes: stored.size, ciphertextSha256: digest });
}

export async function completeChatAttachmentUpload(
  request: Request,
  env: Env,
  attachmentId: string,
  uploadId: string,
): Promise<Response> {
  const authenticated = await authenticate(request, env);
  await deviceRate(env, "chat-attachment-upload-complete", authenticated, 60, 3_600);
  const upload = await requireChatAttachmentUpload(env, attachmentId, uploadId, authenticated);
  const membership = await requireMembership(env, authenticated.aci, upload.channelId);
  if (membership.membershipEpoch !== upload.membershipEpoch) throw new ApiError(409, "MEMBERSHIP_EPOCH_MISMATCH");
  const rows = await env.DB.prepare(
    `SELECT part_number AS partNumber,storage_key AS storageKey,ciphertext_bytes AS ciphertextBytes,
            ciphertext_sha256 AS ciphertextSha256
       FROM chat_attachment_upload_parts WHERE upload_id=? ORDER BY part_number`,
  ).bind(uploadId).all<{
    partNumber: number; storageKey: string; ciphertextBytes: number; ciphertextSha256: string;
  }>();
  const partCount = Math.ceil(upload.ciphertextBytes / upload.partSize);
  if (rows.results.length !== partCount || rows.results.some((part, index) => part.partNumber !== index + 1)) {
    throw new ApiError(409, "UPLOAD_INCOMPLETE");
  }
  const ciphertext = new Uint8Array(upload.ciphertextBytes);
  let offset = 0;
  for (const part of rows.results) {
    const object = await env.HISTORY.get(part.storageKey);
    if (!object || object.size !== part.ciphertextBytes) throw new ApiError(503, "UPLOAD_PART_UNAVAILABLE");
    const bytes = new Uint8Array(await object.arrayBuffer());
    if (await sha256Hex(bytes) !== part.ciphertextSha256 || offset + bytes.byteLength > ciphertext.byteLength) {
      throw new ApiError(503, "UPLOAD_PART_INTEGRITY_FAILED");
    }
    ciphertext.set(bytes, offset);
    offset += bytes.byteLength;
  }
  if (offset !== ciphertext.byteLength || await sha256Hex(ciphertext) !== upload.ciphertextSha256) {
    throw new ApiError(400, "ATTACHMENT_INTEGRITY_FAILED");
  }
  const stored = await env.HISTORY.put(upload.storageKey, ciphertext, {
    onlyIf: { etagDoesNotMatch: "*" },
    httpMetadata: { contentType: "application/octet-stream", cacheControl: "no-store" },
    customMetadata: { ciphertextSha256: upload.ciphertextSha256 },
    sha256: upload.ciphertextSha256,
  });
  const finalObject = stored ?? await env.HISTORY.head(upload.storageKey);
  if (!finalObject || finalObject.size !== upload.ciphertextBytes ||
      finalObject.customMetadata?.ciphertextSha256 !== upload.ciphertextSha256) {
    throw new ApiError(409, "ATTACHMENT_ALREADY_EXISTS");
  }
  const expiresAt = new Date(Date.now() + membership.retentionDays * 24 * 60 * 60 * 1_000).toISOString();
  try {
    await env.DB.prepare(
      `INSERT INTO chat_attachments(attachment_id,channel_id,membership_epoch,uploader_aci,uploader_device_id,
        storage_key,ciphertext_bytes,ciphertext_sha256,expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)`,
    ).bind(attachmentId, upload.channelId, upload.membershipEpoch, authenticated.aci, authenticated.deviceId,
      upload.storageKey, upload.ciphertextBytes, upload.ciphertextSha256, expiresAt, now()).run();
  } catch (error) {
    const complete = await env.DB.prepare(
      "SELECT ciphertext_bytes AS ciphertextBytes,ciphertext_sha256 AS ciphertextSha256 FROM chat_attachments WHERE attachment_id=?",
    ).bind(attachmentId).first<{ ciphertextBytes: number; ciphertextSha256: string }>();
    if (!complete || complete.ciphertextBytes !== upload.ciphertextBytes ||
        complete.ciphertextSha256 !== upload.ciphertextSha256) throw error;
  }
  if (rows.results.length > 0) await env.HISTORY.delete(rows.results.map((part) => part.storageKey));
  await env.DB.prepare("DELETE FROM chat_attachment_uploads WHERE upload_id=?").bind(uploadId).run();
  return json({
    state: "complete", attachmentId, ciphertextBytes: upload.ciphertextBytes,
    ciphertextSha256: upload.ciphertextSha256, expiresAt,
  });
}

export async function cancelChatAttachmentUpload(
  request: Request,
  env: Env,
  attachmentId: string,
  uploadId: string,
): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const upload = await requireChatAttachmentUpload(env, attachmentId, uploadId, authenticated);
  const parts = await env.DB.prepare(
    "SELECT storage_key AS storageKey FROM chat_attachment_upload_parts WHERE upload_id=?",
  ).bind(upload.uploadId).all<{ storageKey: string }>();
  if (parts.results.length > 0) await env.HISTORY.delete(parts.results.map((part) => part.storageKey));
  await env.DB.prepare("DELETE FROM chat_attachment_uploads WHERE upload_id=?").bind(upload.uploadId).run();
  return json({ cancelled: true, attachmentId, uploadId });
}

async function requireChatAttachmentUpload(
  env: Env,
  attachmentId: string,
  uploadId: string,
  authenticated: { aci: string; deviceId: number },
): Promise<ChatAttachmentUploadRow> {
  if (!isUuid(attachmentId) || !isUuid(uploadId)) throw new ApiError(400, "INVALID_UPLOAD_ID");
  const upload = await env.DB.prepare(
    `SELECT upload_id AS uploadId,attachment_id AS attachmentId,channel_id AS channelId,
            membership_epoch AS membershipEpoch,uploader_aci AS uploaderAci,
            uploader_device_id AS uploaderDeviceId,storage_key AS storageKey,
            ciphertext_bytes AS ciphertextBytes,ciphertext_sha256 AS ciphertextSha256,
            part_size AS partSize,expires_at AS expiresAt
       FROM chat_attachment_uploads WHERE upload_id=? AND attachment_id=?`,
  ).bind(uploadId, attachmentId).first<ChatAttachmentUploadRow>();
  if (!upload) throw new ApiError(404, "UPLOAD_NOT_FOUND");
  if (upload.uploaderAci !== authenticated.aci || upload.uploaderDeviceId !== authenticated.deviceId) {
    throw new ApiError(403, "FORBIDDEN");
  }
  if (upload.expiresAt <= now()) throw new ApiError(410, "UPLOAD_EXPIRED");
  return upload;
}

async function uploadState(env: Env, upload: ChatAttachmentUploadRow): Promise<Response> {
  const parts = await env.DB.prepare(
    `SELECT part_number AS partNumber,ciphertext_bytes AS ciphertextBytes,
            ciphertext_sha256 AS ciphertextSha256
       FROM chat_attachment_upload_parts WHERE upload_id=? ORDER BY part_number`,
  ).bind(upload.uploadId).all<{
    partNumber: number; ciphertextBytes: number; ciphertextSha256: string;
  }>();
  return json({
    state: "uploading", uploadId: upload.uploadId, attachmentId: upload.attachmentId,
    ciphertextBytes: upload.ciphertextBytes, ciphertextSha256: upload.ciphertextSha256,
    partSize: upload.partSize, uploadedParts: parts.results, expiresAt: upload.expiresAt,
  });
}

export async function downloadChatAttachment(
  request: Request,
  env: Env,
  attachmentId: string,
): Promise<Response> {
  const authenticated = await authenticate(request, env);
  if (!isUuid(attachmentId)) throw new ApiError(400, "INVALID_ATTACHMENT_ID");
  const row = await env.DB.prepare(
    `SELECT x.storage_key AS storageKey,x.ciphertext_bytes AS ciphertextBytes,
            x.ciphertext_sha256 AS ciphertextSha256
       FROM chat_attachments x
       JOIN memberships m ON m.channel_id=x.channel_id AND m.aci=?
       JOIN devices d ON d.aci=? AND d.device_id=?
      WHERE x.attachment_id=? AND x.expires_at>? AND m.left_epoch IS NULL
        AND m.joined_epoch<=x.membership_epoch AND d.status='active' AND d.linked_at<=x.created_at`,
  ).bind(authenticated.aci, authenticated.aci, authenticated.deviceId, attachmentId, now())
    .first<{ storageKey: string; ciphertextBytes: number; ciphertextSha256: string }>();
  if (!row) throw new ApiError(404, "ATTACHMENT_NOT_FOUND");
  const range = parseByteRange(request.headers.get("Range"), row.ciphertextBytes);
  const object = await env.HISTORY.get(
    row.storageKey,
    range ? { range: { offset: range.start, length: range.end - range.start + 1 } } : undefined,
  );
  if (!object || object.size !== row.ciphertextBytes) throw new ApiError(503, "ATTACHMENT_UNAVAILABLE");
  const responseBytes = range ? range.end - range.start + 1 : row.ciphertextBytes;
  return new Response(object.body, {
    status: range ? 206 : 200,
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Length": String(responseBytes),
      "Accept-Ranges": "bytes",
      ...(range ? { "Content-Range": `bytes ${range.start}-${range.end}/${row.ciphertextBytes}` } : {}),
      "Cache-Control": "private, no-store",
      "X-Ciphertext-SHA256": row.ciphertextSha256,
    },
  });
}

function parseByteRange(value: string | null, total: number): { start: number; end: number } | null {
  if (value === null) return null;
  const match = /^bytes=(\d+)-(\d*)$/u.exec(value);
  if (!match?.[1]) throw new ApiError(416, "INVALID_RANGE");
  const start = Number(match[1]);
  const requestedEnd = match[2] ? Number(match[2]) : total - 1;
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(requestedEnd) || start < 0 ||
      start >= total || requestedEnd < start) throw new ApiError(416, "INVALID_RANGE");
  return { start, end: Math.min(requestedEnd, total - 1) };
}

export async function uploadHistory(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  await deviceRate(env, "history-upload", authenticated, 60, 3_600);
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
  const usage = await env.DB.prepare(
    "SELECT coalesce(sum(ciphertext_bytes),0) AS bytes FROM history_objects WHERE channel_id=? AND expires_at>?",
  ).bind(channelId, now()).first<{ bytes: number }>();
  if ((usage?.bytes ?? 0) + ciphertext.length > 1_000_000_000) throw new ApiError(429, "HISTORY_QUOTA_EXCEEDED");
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
  await deviceRate(env, "relay-credentials", authenticated, 120, 3_600);
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
  const value = await body(request);
  const channelId = stringField(value, "channelId", 64);
  const requestToken = stringField(value, "requestToken", 64);
  const senderDemux = integerField(value, "senderDemux", 1, 4_294_967_295);
  const membershipEpoch = integerField(value, "membershipEpoch", 1, 2_147_483_647);
  const requestedTotMs = integerField(value, "requestedTotMs", 1_000, 30_000);
  const sos = value.sos === true;
  if (!isUuid(channelId)) throw new ApiError(400, "INVALID_CHANNEL_ID");
  try { base64UrlToBytes(requestToken, 16, 16); } catch { throw new ApiError(400, "INVALID_REQUEST_TOKEN"); }
  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ") || authorization.length > 4_103) {
    throw new ApiError(401, "UNAUTHENTICATED");
  }
  const accessTokenHash = await sha256Hex(authorization.slice(7));
  // Floor request is the latency-critical control path. Resolve the active
  // device, account, membership, channel epoch, role, and relay lease in one
  // D1 read instead of serial authentication and authorization reads. The
  // rate-limit write is independent and runs in parallel with that read.
  const [authorized] = await Promise.all([
    env.DB.prepare(
      `SELECT d.aci AS aci,d.device_id AS deviceId,m.role AS role,
              c.membership_epoch AS membershipEpoch,
              EXISTS(
                SELECT 1 FROM relay_leases r
                 WHERE r.channel_id=? AND r.aci=d.aci AND r.device_id=d.device_id
                   AND r.sender_demux=? AND r.expires_at>?
              ) AS hasRelayLease
         FROM devices d
         JOIN accounts a ON a.aci=d.aci
         LEFT JOIN memberships m ON m.aci=d.aci AND m.channel_id=? AND m.left_epoch IS NULL
         LEFT JOIN channels c ON c.channel_id=m.channel_id
        WHERE d.access_token_hash=? AND d.status='active' AND a.disabled_at IS NULL
        LIMIT 1`,
    ).bind(channelId, senderDemux, now(), channelId, accessTokenHash).first<{
      aci: string;
      deviceId: number;
      role: string | null;
      membershipEpoch: number | null;
      hasRelayLease: number;
    }>(),
    // The access-token hash is a stable, privacy-safe per-session discriminator.
    // Token rotation starts a new session and invalidates the old token.
    enforceRateLimit(env, "floor-request", accessTokenHash, 600, 60),
  ]);
  if (!authorized) throw new ApiError(401, "UNAUTHENTICATED");
  if (!authorized.role || authorized.membershipEpoch === null) throw new ApiError(403, "FORBIDDEN");
  if (authorized.membershipEpoch !== membershipEpoch) throw new ApiError(409, "MEMBERSHIP_EPOCH_MISMATCH");
  if (authorized.role === "listen") throw new ApiError(403, "TALK_NOT_PERMITTED");
  if (authorized.hasRelayLease !== 1) throw new ApiError(403, "RELAY_LEASE_REQUIRED");
  const priority = sos ? 100 : (authorized.role === "barge" || authorized.role === "dispatch" ? 20 : 10);
  const stub = env.CHANNELS.getByName(channelId, { locationHint: "enam" });
  const result = await stub.requestFloor(`${authorized.aci}:${authorized.deviceId}`, requestToken, senderDemux, requestedTotMs, priority);
  return json(result);
}

export async function releaseFloor(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  await deviceRate(env, "floor-release", authenticated, 600, 60);
  const value = await body(request);
  const channelId = stringField(value, "channelId", 64);
  const requestToken = stringField(value, "requestToken", 64);
  if (!isUuid(channelId)) throw new ApiError(400, "INVALID_CHANNEL_ID");
  try { base64UrlToBytes(requestToken, 16, 16); } catch { throw new ApiError(400, "INVALID_REQUEST_TOKEN"); }
  await requireMembership(env, authenticated.aci, channelId);
  const released = await env.CHANNELS.getByName(channelId).releaseFloor(`${authenticated.aci}:${authenticated.deviceId}`, requestToken);
  if (!released) throw new ApiError(409, "FLOOR_NOT_HELD");
  return json({ accepted: true });
}

export async function mediaTunnel(request: Request, env: Env): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") throw new ApiError(426, "WEBSOCKET_REQUIRED");
  const authorization = request.headers.get("Authorization") ?? "";
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
  headers.set("X-PTT-Access-Hash", await sha256Hex(authorization.slice(7)));
  headers.set("X-PTT-Channel", channelId);
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
  await deviceRate(env, "presence", authenticated, 120, 60);
  const value = await body(request);
  const mode = stringField(value, "mode", 16);
  if (!new Set(["available", "busy", "solo", "standby"]).has(mode)) throw new ApiError(400, "INVALID_PRESENCE");
  await env.DB.prepare(
    `INSERT INTO presence(aci,device_id,mode,updated_at) VALUES(?,?,?,?)
     ON CONFLICT(aci,device_id) DO UPDATE SET mode=excluded.mode,updated_at=excluded.updated_at`,
  ).bind(authenticated.aci, authenticated.deviceId, mode, now()).run();
  return json({ accepted: true });
}

async function deviceRate(
  env: Env,
  scope: string,
  device: { aci: string; deviceId: number },
  maximum: number,
  windowSeconds: number,
): Promise<void> {
  await enforceRateLimit(env, scope, `${device.aci}:${device.deviceId}`, maximum, windowSeconds);
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
