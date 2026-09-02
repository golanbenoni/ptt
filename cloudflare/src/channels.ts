import { isUuid, uuid } from "./crypto";
import { audit, authenticate, now, requireAdmin } from "./db";
import { ApiError, arrayField, body, integerField, json, stringField } from "./http";
import { notifyChannelMembershipChanged } from "./relay-state";

const roles = new Set(["talk", "listen", "barge", "dispatch", "emergency-target"]);
const kinds = new Set(["team", "duty", "adhoc", "direct"]);

export async function deviceChannels(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env, "post");
  const rows = await env.DB.prepare(
    `SELECT c.channel_id AS channelId,c.display_name AS displayName,c.kind,c.topic,
            c.is_announcement AS isAnnouncement,c.archived_at AS archivedAt,c.distribution_id AS distributionId,
            c.membership_epoch AS membershipEpoch,c.retention_days AS retentionDays,m.role,
            (SELECT count(*) FROM memberships active WHERE active.channel_id=c.channel_id AND active.left_epoch IS NULL) AS activeMembers
       FROM memberships m JOIN channels c ON c.channel_id=m.channel_id
      WHERE m.aci=? AND m.left_epoch IS NULL AND c.archived_at IS NULL ORDER BY lower(c.display_name)`,
  ).bind(authenticated.aci).all();
  return json(rows.results);
}

export async function teamDirectory(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const rows = await env.DB.prepare(
    `SELECT aci,display_name AS displayName,account_kind AS accountKind,is_admin AS isAdmin
       FROM accounts WHERE disabled_at IS NULL AND aci<>? AND account_kind IN ('member','guest')
        AND (guest_expires_at IS NULL OR guest_expires_at>?)
      ORDER BY lower(display_name),aci`,
  ).bind(authenticated.aci, now()).all();
  return json(rows.results);
}

export async function updateProfile(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const value = await body(request);
  const displayName = stringField(value, "displayName", 80).trim();
  if (!displayName) throw new ApiError(400, "INVALID_DISPLAY_NAME");
  await env.DB.prepare("UPDATE accounts SET display_name=? WHERE aci=?")
    .bind(displayName, authenticated.aci).run();
  const member = await env.DB.prepare(
    "SELECT aci,display_name AS displayName,account_kind AS accountKind,is_admin AS isAdmin FROM accounts WHERE aci=?",
  ).bind(authenticated.aci).first();
  return json(member);
}

export async function createConversation(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env);
  const value = await body(request);
  const kind = stringField(value, "kind", 16);
  if (kind !== "direct" && kind !== "group") throw new ApiError(400, "INVALID_CONVERSATION_KIND");
  const requested = arrayField(value, "memberAcis", 8).map((member) => {
    if (typeof member !== "string" || !isUuid(member)) throw new ApiError(400, "INVALID_CONVERSATION_MEMBERS");
    return member.toLowerCase();
  });
  const members = [...new Set([...requested, authenticated.aci.toLowerCase()])].sort();
  if ((kind === "direct" && members.length !== 2) || (kind === "group" && (members.length < 3 || members.length > 8))) {
    throw new ApiError(400, "INVALID_CONVERSATION_MEMBERS");
  }
  for (const aci of members) {
    const account = await env.DB.prepare(
      `SELECT 1 AS present FROM accounts WHERE aci=? AND disabled_at IS NULL
        AND account_kind IN ('member','guest') AND (guest_expires_at IS NULL OR guest_expires_at>?)`,
    ).bind(aci, now()).first();
    if (!account) throw new ApiError(400, "UNKNOWN_MEMBER");
  }
  if (kind === "direct") {
    const other = members.find((aci) => aci !== authenticated.aci.toLowerCase())!;
    const existing = await env.DB.prepare(
      `SELECT c.channel_id AS channelId,c.display_name AS displayName,c.kind,c.topic,
              c.is_announcement AS isAnnouncement,c.archived_at AS archivedAt,c.distribution_id AS distributionId,
              c.membership_epoch AS membershipEpoch,c.retention_days AS retentionDays,m.role,
              (SELECT count(*) FROM memberships active WHERE active.channel_id=c.channel_id AND active.left_epoch IS NULL) AS activeMembers
         FROM channels c JOIN memberships m ON m.channel_id=c.channel_id AND m.aci=? AND m.left_epoch IS NULL
        WHERE c.kind='direct' AND c.archived_at IS NULL
          AND EXISTS(SELECT 1 FROM memberships peer WHERE peer.channel_id=c.channel_id AND peer.aci=? AND peer.left_epoch IS NULL)
          AND (SELECT count(*) FROM memberships active WHERE active.channel_id=c.channel_id AND active.left_epoch IS NULL)=2 LIMIT 1`,
    ).bind(authenticated.aci, other).first();
    if (existing) return json(existing);
  }
  const displayName = kind === "direct"
    ? ((await env.DB.prepare("SELECT display_name AS displayName FROM accounts WHERE aci=?")
      .bind(members.find((aci) => aci !== authenticated.aci.toLowerCase())!).first<{ displayName: string }>())?.displayName ?? "Direct message")
    : stringField(value, "displayName", 80).trim();
  if (!displayName) throw new ApiError(400, "INVALID_CONVERSATION_NAME");
  const channelId = uuid();
  const createdAt = now();
  await env.DB.batch([
    env.DB.prepare(
      "INSERT INTO channels(channel_id,display_name,kind,membership_epoch,distribution_id,retention_days,created_at,created_by) VALUES(?,?,?,1,?,30,?,?)",
    ).bind(channelId, displayName, kind === "direct" ? "direct" : "adhoc", uuid(), createdAt, authenticated.aci),
    ...members.map((aci) => env.DB.prepare(
      "INSERT INTO memberships(channel_id,aci,role,joined_epoch,created_at) VALUES(?,?,'talk',1,?)",
    ).bind(channelId, aci, createdAt)),
  ]);
  await audit(env, "conversation.created", authenticated.aci, channelId, { kind, members: members.length });
  const created = await env.DB.prepare(
    `SELECT c.channel_id AS channelId,c.display_name AS displayName,c.kind,c.topic,
            c.is_announcement AS isAnnouncement,c.archived_at AS archivedAt,c.distribution_id AS distributionId,
            c.membership_epoch AS membershipEpoch,c.retention_days AS retentionDays,m.role,
            (SELECT count(*) FROM memberships active WHERE active.channel_id=c.channel_id AND active.left_epoch IS NULL) AS activeMembers
       FROM channels c JOIN memberships m ON m.channel_id=c.channel_id WHERE c.channel_id=? AND m.aci=?`,
  ).bind(channelId, authenticated.aci).first();
  return json(created);
}

export async function channelDevices(request: Request, env: Env, channelId: string): Promise<Response> {
  const authenticated = await authenticate(request, env, "post");
  await requireActiveMembership(env, authenticated.aci, channelId);
  const rows = await env.DB.prepare(
    `SELECT d.aci,a.display_name AS displayName,a.account_kind AS accountKind,
            d.device_id AS deviceId,d.mailbox_id AS mailboxId,d.identity_key AS identityKey,m.role
       FROM memberships m JOIN devices d ON d.aci=m.aci JOIN accounts a ON a.aci=d.aci
      WHERE m.channel_id=? AND m.left_epoch IS NULL AND d.status='active' AND a.disabled_at IS NULL
      ORDER BY lower(a.display_name),d.aci,d.device_id`,
  ).bind(channelId).all();
  return json(rows.results);
}

export async function adminChannels(request: Request, env: Env): Promise<Response> {
  await requireAdmin(request, env);
  const rows = await env.DB.prepare(
    `SELECT c.channel_id AS channelId,c.display_name AS displayName,c.kind,c.topic,
            c.is_announcement AS isAnnouncement,c.archived_at AS archivedAt,c.membership_epoch AS membershipEpoch,
            c.retention_days AS retentionDays,count(m.aci) FILTER (WHERE m.left_epoch IS NULL) AS activeMembers
       FROM channels c LEFT JOIN memberships m ON m.channel_id=c.channel_id
      GROUP BY c.channel_id ORDER BY (c.archived_at IS NOT NULL),lower(c.display_name)`,
  ).all();
  return json(rows.results);
}

export async function adminChannelMembers(request: Request, env: Env): Promise<Response> {
  await requireAdmin(request, env);
  const channelId = new URL(request.url).searchParams.get("channelId") ?? "";
  if (!isUuid(channelId)) throw new ApiError(400, "INVALID_CHANNEL_ID");
  const rows = await env.DB.prepare(
    `SELECT m.channel_id AS channelId,m.aci,a.email,m.role,m.joined_epoch AS joinedEpoch
       FROM memberships m JOIN accounts a ON a.aci=m.aci
      WHERE m.channel_id=? AND m.left_epoch IS NULL AND a.disabled_at IS NULL ORDER BY lower(a.email)`,
  ).bind(channelId).all();
  return json(rows.results);
}

export async function createChannel(request: Request, env: Env): Promise<Response> {
  const actor = await requireAdmin(request, env);
  const value = await body(request);
  const displayName = stringField(value, "displayName", 80).trim();
  const kind = stringField(value, "kind", 16);
  const retentionDays = integerField(value, "retentionDays", 1, 365);
  const topic = typeof value.topic === "string" ? value.topic.trim() : "";
  const isAnnouncement = value.isAnnouncement === true;
  const members = arrayField(value, "members", 64);
  if (topic.length > 280) throw new ApiError(400, "INVALID_CHANNEL_TOPIC");
  if (!kinds.has(kind)) throw new ApiError(400, "INVALID_CHANNEL_KIND");
  if (members.length === 0 || (kind === "direct" && members.length !== 2)) throw new ApiError(400, "INVALID_MEMBERS");
  const parsed = members.map((item) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) throw new ApiError(400, "INVALID_MEMBERS");
    const record = item as Record<string, unknown>;
    const aci = stringField(record, "aci", 64);
    const role = stringField(record, "role", 32);
    if (!isUuid(aci) || !roles.has(role)) throw new ApiError(400, "INVALID_MEMBERS");
    return { aci, role };
  });
  if (new Set(parsed.map((member) => member.aci)).size !== parsed.length) throw new ApiError(400, "INVALID_MEMBERS");
  for (const member of parsed) {
    const exists = await env.DB.prepare("SELECT 1 AS present FROM accounts WHERE aci=? AND disabled_at IS NULL").bind(member.aci).first();
    if (!exists) throw new ApiError(400, "UNKNOWN_MEMBER");
  }
  const channelId = uuid();
  const distributionId = uuid();
  const createdAt = new Date().toISOString();
  const statements = [
    env.DB.prepare("INSERT INTO channels(channel_id,display_name,kind,membership_epoch,distribution_id,retention_days,created_at,topic,is_announcement,created_by) VALUES(?,?,?,1,?,?,?,?,?,?)")
      .bind(channelId, displayName, kind, distributionId, retentionDays, createdAt, topic, isAnnouncement ? 1 : 0, actor.aci),
    ...parsed.map((member) => env.DB.prepare("INSERT INTO memberships(channel_id,aci,role,joined_epoch,created_at) VALUES(?,?,?,1,?)")
      .bind(channelId, member.aci, member.role, createdAt)),
  ];
  await env.DB.batch(statements);
  await audit(env, "channel.created", actor.aci, channelId, { members: parsed.length });
  return json({
    channelId, displayName, kind, topic, isAnnouncement: isAnnouncement ? 1 : 0,
    archivedAt: null, membershipEpoch: 1, retentionDays, activeMembers: parsed.length,
  });
}

export async function updateChannelConfig(request: Request, env: Env): Promise<Response> {
  const actor = await requireAdmin(request, env);
  const value = await body(request);
  const channelId = stringField(value, "channelId", 64);
  const displayName = stringField(value, "displayName", 80).trim();
  const retentionDays = integerField(value, "retentionDays", 1, 365);
  const topic = typeof value.topic === "string" ? value.topic.trim() : null;
  const isAnnouncement = typeof value.isAnnouncement === "boolean" ? value.isAnnouncement : null;
  if (!isUuid(channelId)) throw new ApiError(400, "INVALID_CHANNEL_ID");
  if (topic !== null && topic.length > 280) throw new ApiError(400, "INVALID_CHANNEL_TOPIC");
  const result = await env.DB.prepare(
    "UPDATE channels SET display_name=?,retention_days=?,topic=coalesce(?,topic),is_announcement=coalesce(?,is_announcement) WHERE channel_id=?",
  ).bind(displayName, retentionDays, topic, isAnnouncement === null ? null : isAnnouncement ? 1 : 0, channelId).run();
  if (result.meta.changes !== 1) throw new ApiError(400, "UNKNOWN_CHANNEL");
  await audit(env, "channel.config_changed", actor.aci, channelId, { retentionDays });
  const row = await env.DB.prepare(
    `SELECT c.channel_id AS channelId,c.display_name AS displayName,c.kind,c.topic,
            c.is_announcement AS isAnnouncement,c.archived_at AS archivedAt,c.membership_epoch AS membershipEpoch,
            c.retention_days AS retentionDays,(SELECT count(*) FROM memberships m WHERE m.channel_id=c.channel_id AND m.left_epoch IS NULL) AS activeMembers
       FROM channels c WHERE c.channel_id=?`,
  ).bind(channelId).first();
  return json(row);
}

export async function updateMembership(request: Request, env: Env): Promise<Response> {
  const actor = await requireAdmin(request, env);
  const value = await body(request);
  const channelId = stringField(value, "channelId", 64);
  const aci = stringField(value, "aci", 64);
  const remove = value.remove === true;
  const role = typeof value.role === "string" ? value.role : null;
  if (!isUuid(channelId) || !isUuid(aci) || (remove === (role !== null)) || (role !== null && !roles.has(role))) {
    throw new ApiError(400, "INVALID_MEMBERSHIP_CHANGE");
  }
  const channel = await env.DB.prepare("SELECT membership_epoch AS epoch,kind FROM channels WHERE channel_id=?").bind(channelId).first<{ epoch: number; kind: string }>();
  if (!channel) throw new ApiError(400, "UNKNOWN_CHANNEL");
  const nextEpoch = channel.epoch + 1;
  if (remove) {
    const changed = await env.DB.prepare("UPDATE memberships SET left_epoch=? WHERE channel_id=? AND aci=? AND left_epoch IS NULL")
      .bind(nextEpoch, channelId, aci).run();
    if (changed.meta.changes !== 1) throw new ApiError(400, "UNKNOWN_MEMBERSHIP");
  } else {
    const account = await env.DB.prepare("SELECT 1 AS present FROM accounts WHERE aci=? AND disabled_at IS NULL").bind(aci).first();
    if (!account) throw new ApiError(400, "UNKNOWN_MEMBER");
    const count = await env.DB.prepare("SELECT count(*) AS count FROM memberships WHERE channel_id=? AND left_epoch IS NULL").bind(channelId).first<{ count: number }>();
    const active = await env.DB.prepare("SELECT 1 AS present FROM memberships WHERE channel_id=? AND aci=? AND left_epoch IS NULL").bind(channelId, aci).first();
    if (!active && (count?.count ?? 0) >= (channel.kind === "direct" ? 2 : 64)) throw new ApiError(409, "CHANNEL_MEMBER_LIMIT");
    await env.DB.prepare(
      `INSERT INTO memberships(channel_id,aci,role,joined_epoch,left_epoch,created_at) VALUES(?,?,?,?,NULL,?)
       ON CONFLICT(channel_id,aci) DO UPDATE SET role=excluded.role,
         joined_epoch=CASE WHEN memberships.left_epoch IS NULL THEN memberships.joined_epoch ELSE excluded.joined_epoch END,left_epoch=NULL`,
    ).bind(channelId, aci, role, nextEpoch, new Date().toISOString()).run();
  }
  await env.DB.prepare("UPDATE channels SET membership_epoch=?,distribution_id=? WHERE channel_id=?")
    .bind(nextEpoch, uuid(), channelId).run();
  await notifyChannelMembershipChanged(env, channelId, nextEpoch);
  await audit(env, "channel.membership_changed", actor.aci, `${channelId}:${aci}`, { epoch: nextEpoch, removed: remove });
  return json({ accepted: true });
}

async function requireActiveMembership(env: Env, aci: string, channelId: string): Promise<void> {
  if (!isUuid(channelId)) throw new ApiError(400, "INVALID_CHANNEL_ID");
  const row = await env.DB.prepare("SELECT 1 AS present FROM memberships WHERE channel_id=? AND aci=? AND left_epoch IS NULL")
    .bind(channelId, aci).first();
  if (!row) throw new ApiError(403, "FORBIDDEN");
}
