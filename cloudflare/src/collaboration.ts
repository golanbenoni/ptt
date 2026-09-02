import { base64UrlToBytes, isUuid, sha256Hex, uuid } from "./crypto";
import { audit, authenticate, now, requireAdmin, requireMembership } from "./db";
import { ApiError, arrayField, body, booleanField, integerField, json, stringField } from "./http";
import { notifyChannelMembershipChanged } from "./relay-state";

const roles = new Set(["talk", "listen", "barge", "dispatch", "emergency-target"]);
const severities = new Set(["routine", "priority", "critical"]);
const operationStatuses = new Set(["active", "monitoring", "resolved", "archived"]);

export async function adminTemplates(request: Request, env: Env): Promise<Response> {
  const actor = await requireAdmin(request, env);
  if (request.method === "GET") {
    const rows = await env.DB.prepare(
      `SELECT template_id AS templateId,display_name AS displayName,channel_kind AS channelKind,topic,
              retention_days AS retentionDays,default_role AS defaultRole,is_announcement AS isAnnouncement,
              created_at AS createdAt,updated_at AS updatedAt
         FROM channel_templates ORDER BY lower(display_name)`,
    ).all();
    return json(rows.results);
  }
  const value = await body(request);
  const displayName = stringField(value, "displayName", 80).trim();
  const channelKind = stringField(value, "channelKind", 16);
  const defaultRole = stringField(value, "defaultRole", 32);
  const retentionDays = integerField(value, "retentionDays", 1, 365);
  const topic = typeof value.topic === "string" ? value.topic.trim() : "";
  const isAnnouncement = value.isAnnouncement === true;
  if (!displayName || !["team", "duty", "adhoc"].includes(channelKind) || !roles.has(defaultRole) || topic.length > 280) {
    throw new ApiError(400, "INVALID_CHANNEL_TEMPLATE");
  }
  const templateId = uuid();
  const timestamp = now();
  await env.DB.prepare(
    `INSERT INTO channel_templates(template_id,display_name,channel_kind,topic,retention_days,default_role,
       is_announcement,created_by,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)`,
  ).bind(templateId, displayName, channelKind, topic, retentionDays, defaultRole, isAnnouncement ? 1 : 0,
    actor.aci, timestamp, timestamp).run();
  await audit(env, "channel_template.created", actor.aci, templateId, { channelKind, isAnnouncement });
  return json({ templateId, displayName, channelKind, topic, retentionDays, defaultRole, isAnnouncement, createdAt: timestamp, updatedAt: timestamp });
}

export async function adminUserGroups(request: Request, env: Env): Promise<Response> {
  const actor = await requireAdmin(request, env);
  if (request.method === "GET") {
    const rows = await env.DB.prepare(
      `SELECT g.group_id AS groupId,g.display_name AS displayName,g.handle,g.created_at AS createdAt,
              count(gm.aci) AS memberCount
         FROM user_groups g LEFT JOIN user_group_members gm ON gm.group_id=g.group_id
        GROUP BY g.group_id ORDER BY lower(g.display_name)`,
    ).all();
    return json(rows.results);
  }
  const value = await body(request);
  const displayName = stringField(value, "displayName", 80).trim();
  const handle = stringField(value, "handle", 32).trim().toLowerCase();
  const memberAcis = [...new Set(arrayField(value, "memberAcis", 256).map((item) => {
    if (typeof item !== "string" || !isUuid(item)) throw new ApiError(400, "INVALID_GROUP_MEMBERS");
    return item;
  }))];
  if (!displayName || !/^[a-z0-9][a-z0-9_-]{1,31}$/u.test(handle)) throw new ApiError(400, "INVALID_USER_GROUP");
  if (memberAcis.length > 0) {
    const memberChecks = await env.DB.batch(memberAcis.map((aci) => env.DB.prepare(
      "SELECT 1 AS present FROM accounts WHERE aci=? AND disabled_at IS NULL AND account_kind IN ('member','guest')",
    ).bind(aci)));
    if (memberChecks.some((result) => result.results.length !== 1)) throw new ApiError(400, "UNKNOWN_MEMBER");
  }
  const groupId = uuid();
  const timestamp = now();
  await env.DB.batch([
    env.DB.prepare("INSERT INTO user_groups(group_id,display_name,handle,created_by,created_at) VALUES(?,?,?,?,?)")
      .bind(groupId, displayName, handle, actor.aci, timestamp),
    ...memberAcis.map((aci) => env.DB.prepare(
      `INSERT INTO user_group_members(group_id,aci) SELECT ?,aci FROM accounts
        WHERE aci=? AND disabled_at IS NULL AND account_kind IN ('member','guest')`,
    ).bind(groupId, aci)),
  ]);
  await audit(env, "user_group.created", actor.aci, groupId, { members: memberAcis.length });
  return json({ groupId, displayName, handle, memberCount: memberAcis.length, createdAt: timestamp });
}

export async function applyUserGroup(request: Request, env: Env): Promise<Response> {
  const actor = await requireAdmin(request, env);
  const value = await body(request);
  const groupId = stringField(value, "groupId", 64);
  const channelId = stringField(value, "channelId", 64);
  const role = stringField(value, "role", 32);
  if (!isUuid(groupId) || !isUuid(channelId) || !roles.has(role)) throw new ApiError(400, "INVALID_GROUP_ASSIGNMENT");
  const channel = await env.DB.prepare(
    "SELECT kind,membership_epoch AS membershipEpoch FROM channels WHERE channel_id=?",
  ).bind(channelId).first<{ kind: string; membershipEpoch: number }>();
  if (!channel) throw new ApiError(400, "UNKNOWN_CHANNEL");
  if (channel.kind === "direct") throw new ApiError(400, "GROUP_NOT_ALLOWED_FOR_DIRECT");
  const group = await env.DB.prepare("SELECT 1 AS present FROM user_groups WHERE group_id=?")
    .bind(groupId).first<{ present: number }>();
  if (!group) throw new ApiError(404, "USER_GROUP_NOT_FOUND");
  const members = await env.DB.prepare(
    "SELECT gm.aci FROM user_group_members gm JOIN accounts a ON a.aci=gm.aci WHERE gm.group_id=? AND a.disabled_at IS NULL",
  ).bind(groupId).all<{ aci: string }>();
  const existing = await env.DB.prepare("SELECT aci FROM memberships WHERE channel_id=? AND left_epoch IS NULL")
    .bind(channelId).all<{ aci: string }>();
  if (new Set([...existing.results.map((item) => item.aci), ...members.results.map((item) => item.aci)]).size > 64) {
    throw new ApiError(409, "CHANNEL_MEMBER_LIMIT");
  }
  const nextEpoch = channel.membershipEpoch + 1;
  await env.DB.batch([
    ...members.results.map((member) => env.DB.prepare(
      `INSERT INTO memberships(channel_id,aci,role,joined_epoch,left_epoch,created_at) VALUES(?,?,?,?,NULL,?)
       ON CONFLICT(channel_id,aci) DO UPDATE SET role=excluded.role,
         joined_epoch=CASE WHEN memberships.left_epoch IS NULL THEN memberships.joined_epoch ELSE excluded.joined_epoch END,left_epoch=NULL`,
    ).bind(channelId, member.aci, role, nextEpoch, now())),
    env.DB.prepare("UPDATE channels SET membership_epoch=?,distribution_id=? WHERE channel_id=?")
      .bind(nextEpoch, uuid(), channelId),
  ]);
  await notifyChannelMembershipChanged(env, channelId, nextEpoch);
  await audit(env, "user_group.applied", actor.aci, groupId, { channelId, role, epoch: nextEpoch });
  return json({ accepted: true });
}

export async function configureMember(request: Request, env: Env): Promise<Response> {
  const actor = await requireAdmin(request, env);
  const value = await body(request);
  const aci = stringField(value, "aci", 64);
  const displayName = stringField(value, "displayName", 80).trim();
  const accountKind = stringField(value, "accountKind", 16);
  const isAdmin = booleanField(value, "isAdmin");
  const guestExpiresAt = typeof value.guestExpiresAt === "string" && value.guestExpiresAt ? value.guestExpiresAt : null;
  if (!isUuid(aci) || !displayName || !["member", "guest"].includes(accountKind)) throw new ApiError(400, "INVALID_MEMBER_CONFIG");
  if (accountKind === "guest" && (!guestExpiresAt || !Number.isFinite(Date.parse(guestExpiresAt)) || Date.parse(guestExpiresAt) <= Date.now())) {
    throw new ApiError(400, "INVALID_GUEST_EXPIRY");
  }
  if (aci === actor.aci && (accountKind !== "member" || !isAdmin)) throw new ApiError(409, "CANNOT_RESTRICT_ACTIVE_ADMIN");
  const updated = await env.DB.prepare(
    `UPDATE accounts SET display_name=?,account_kind=?,guest_expires_at=?,is_admin=?
      WHERE aci=? AND disabled_at IS NULL`,
  ).bind(displayName, accountKind, accountKind === "guest" ? guestExpiresAt : null, isAdmin ? 1 : 0, aci).run();
  if (updated.meta.changes !== 1) throw new ApiError(404, "MEMBER_NOT_FOUND");
  await audit(env, "member.configured", actor.aci, aci, { accountKind, isAdmin, guestExpiresAt });
  return json({ accepted: true });
}

export async function listOperations(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env, "acknowledge");
  const rows = await env.DB.prepare(
    `SELECT r.run_id AS runId,r.channel_id AS channelId,r.template_id AS templateId,r.display_name AS displayName,
            r.severity,r.status,r.commander_aci AS commanderAci,r.started_at AS startedAt,r.updated_at AS updatedAt,
            r.resolved_at AS resolvedAt,
            (SELECT count(*) FROM operation_acknowledgements a WHERE a.run_id=r.run_id) AS acknowledgementCount
       FROM operation_runs r JOIN memberships m ON m.channel_id=r.channel_id
      WHERE m.aci=? AND m.left_epoch IS NULL AND r.status<>'archived' ORDER BY r.updated_at DESC`,
  ).bind(authenticated.aci).all();
  return json(rows.results);
}

export async function startOperation(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env, "start-operation");
  const value = await body(request);
  const channelId = stringField(value, "channelId", 64);
  const displayName = stringField(value, "displayName", 120).trim();
  const severity = stringField(value, "severity", 16);
  if (!isUuid(channelId) || !displayName || !severities.has(severity)) throw new ApiError(400, "INVALID_OPERATION");
  const membership = await requireMembership(env, authenticated.aci, channelId);
  if (!authenticated.isAdmin && !["dispatch", "barge"].includes(membership.role)) throw new ApiError(403, "OPERATION_CONTROL_FORBIDDEN");
  const templateId = typeof value.templateId === "string" && isUuid(value.templateId) ? value.templateId : null;
  const runId = uuid();
  const timestamp = now();
  await env.DB.prepare(
    `INSERT INTO operation_runs(run_id,channel_id,template_id,display_name,severity,status,commander_aci,started_at,updated_at)
     VALUES(?,?,?,?,?,'active',?,?,?)`,
  ).bind(runId, channelId, templateId, displayName, severity, authenticated.aci, timestamp, timestamp).run();
  await audit(env, "operation.started", authenticated.aci, runId, { channelId: await sha256Hex(channelId), severity });
  return json({ runId, channelId, templateId, displayName, severity, status: "active", commanderAci: authenticated.aci, startedAt: timestamp, updatedAt: timestamp, resolvedAt: null, acknowledgementCount: 0 });
}

export async function updateOperation(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env, "start-operation");
  const value = await body(request);
  const runId = stringField(value, "runId", 64);
  const status = stringField(value, "status", 16);
  const commanderAci = typeof value.commanderAci === "string" ? value.commanderAci : authenticated.aci;
  if (!isUuid(runId) || !operationStatuses.has(status) || !isUuid(commanderAci)) throw new ApiError(400, "INVALID_OPERATION_UPDATE");
  const run = await env.DB.prepare("SELECT channel_id AS channelId,commander_aci AS commanderAci FROM operation_runs WHERE run_id=?")
    .bind(runId).first<{ channelId: string; commanderAci: string }>();
  if (!run) throw new ApiError(404, "OPERATION_NOT_FOUND");
  const membership = await requireMembership(env, authenticated.aci, run.channelId);
  if (!authenticated.isAdmin && run.commanderAci !== authenticated.aci && !["dispatch", "barge"].includes(membership.role)) {
    throw new ApiError(403, "OPERATION_CONTROL_FORBIDDEN");
  }
  await requireMembership(env, commanderAci, run.channelId);
  const timestamp = now();
  await env.DB.prepare(
    `UPDATE operation_runs SET status=?,commander_aci=?,updated_at=?,resolved_at=CASE WHEN ?='resolved' THEN ? ELSE resolved_at END
      WHERE run_id=?`,
  ).bind(status, commanderAci, timestamp, status, timestamp, runId).run();
  await audit(env, "operation.updated", authenticated.aci, runId, { status, handoff: commanderAci !== run.commanderAci });
  return json({ accepted: true });
}

export async function acknowledgeOperation(request: Request, env: Env): Promise<Response> {
  const authenticated = await authenticate(request, env, "acknowledge");
  const value = await body(request);
  const runId = stringField(value, "runId", 64);
  const eventId = stringField(value, "eventId", 64);
  if (!isUuid(runId) || !isUuid(eventId)) throw new ApiError(400, "INVALID_ACKNOWLEDGEMENT");
  const run = await env.DB.prepare("SELECT channel_id AS channelId FROM operation_runs WHERE run_id=?")
    .bind(runId).first<{ channelId: string }>();
  if (!run) throw new ApiError(404, "OPERATION_NOT_FOUND");
  await requireMembership(env, authenticated.aci, run.channelId);
  await env.DB.prepare(
    `INSERT INTO operation_acknowledgements(run_id,event_id,aci,acknowledged_at) VALUES(?,?,?,?)
      ON CONFLICT(run_id,event_id,aci) DO NOTHING`,
  ).bind(runId, eventId, authenticated.aci, now()).run();
  await audit(env, "operation.acknowledged", authenticated.aci, runId);
  return json({ accepted: true });
}

export async function adminIntegrations(request: Request, env: Env): Promise<Response> {
  const actor = await requireAdmin(request, env);
  if (request.method === "GET") {
    const rows = await env.DB.prepare(
      `SELECT integration_id AS integrationId,aci,channel_id AS channelId,display_name AS displayName,capabilities,
              created_at AS createdAt,expires_at AS expiresAt,revoked_at AS revokedAt
         FROM channel_integrations ORDER BY created_at DESC`,
    ).all<{ capabilities: string }>();
    return json(rows.results.map((row) => ({ ...row, capabilities: JSON.parse(row.capabilities) as unknown })));
  }
  const value = await body(request);
  const channelId = stringField(value, "channelId", 64);
  const displayName = stringField(value, "displayName", 80).trim();
  const identityKey = stringField(value, "identityKey", 8_192);
  const capabilities = [...new Set(arrayField(value, "capabilities", 3).map(String))];
  const expiresAtValue = typeof value.expiresAt === "string" && value.expiresAt ? value.expiresAt : null;
  if (!isUuid(channelId) || !displayName || !capabilities.includes("post") || capabilities.some((item) => !["post", "acknowledge", "start-operation"].includes(item))) {
    throw new ApiError(400, "INVALID_INTEGRATION");
  }
  if (expiresAtValue !== null && (!Number.isFinite(Date.parse(expiresAtValue)) || Date.parse(expiresAtValue) <= Date.now())) {
    throw new ApiError(400, "INVALID_INTEGRATION_EXPIRY");
  }
  const expiresAt = expiresAtValue === null ? null : new Date(expiresAtValue).toISOString();
  try { base64UrlToBytes(identityKey, 32, 4_096); } catch { throw new ApiError(400, "INVALID_IDENTITY_KEY"); }
  const token = `${crypto.randomUUID().replaceAll("-", "")}${crypto.randomUUID().replaceAll("-", "")}`;
  const integrationId = uuid();
  const aci = uuid();
  const mailboxId = uuid();
  const createdAt = now();
  const channel = await env.DB.prepare(
    `SELECT membership_epoch AS membershipEpoch,kind,
            (SELECT count(*) FROM memberships m WHERE m.channel_id=c.channel_id AND m.left_epoch IS NULL) AS activeMembers
       FROM channels c WHERE channel_id=?`,
  ).bind(channelId).first<{ membershipEpoch: number; kind: string; activeMembers: number }>();
  if (!channel || channel.kind === "direct") throw new ApiError(400, "UNKNOWN_CHANNEL");
  if (channel.activeMembers >= 64) throw new ApiError(409, "CHANNEL_MEMBER_LIMIT");
  const nextEpoch = channel.membershipEpoch + 1;
  const integrationRole = capabilities.includes("start-operation") ? "dispatch" : "talk";
  const tokenHash = await sha256Hex(token);
  await env.DB.batch([
    env.DB.prepare("INSERT INTO accounts(aci,email,is_admin,created_at,display_name,account_kind) VALUES(?,?,0,?,?,'integration')")
      .bind(aci, `integration+${aci}@internal.invalid`, createdAt, displayName),
    env.DB.prepare("INSERT INTO devices(aci,device_id,mailbox_id,display_name,identity_key,access_token_hash,status,linked_at) VALUES(?,1,?,?,?,?, 'active',?)")
      .bind(aci, mailboxId, displayName, identityKey, tokenHash, createdAt),
    env.DB.prepare("INSERT INTO memberships(channel_id,aci,role,joined_epoch,created_at) VALUES(?,?,?,?,?)")
      .bind(channelId, aci, integrationRole, nextEpoch, createdAt),
    env.DB.prepare(
      `INSERT INTO channel_integrations(integration_id,aci,channel_id,display_name,token_hash,identity_key,capabilities,
         created_by,created_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?,?)`,
    ).bind(integrationId, aci, channelId, displayName, tokenHash, identityKey, JSON.stringify(capabilities), actor.aci, createdAt, expiresAt),
    env.DB.prepare("UPDATE channels SET membership_epoch=?,distribution_id=? WHERE channel_id=?")
      .bind(nextEpoch, uuid(), channelId),
  ]);
  await notifyChannelMembershipChanged(env, channelId, nextEpoch);
  await audit(env, "integration.created", actor.aci, integrationId, { capabilities });
  return json({ integrationId, aci, deviceId: 1, mailboxId, channelId, displayName, capabilities, createdAt, expiresAt, token });
}

export async function revokeIntegration(request: Request, env: Env): Promise<Response> {
  const actor = await requireAdmin(request, env);
  const value = await body(request);
  const integrationId = stringField(value, "integrationId", 64);
  if (!isUuid(integrationId)) throw new ApiError(400, "INVALID_INTEGRATION_ID");
  const integration = await env.DB.prepare("SELECT aci,channel_id AS channelId FROM channel_integrations WHERE integration_id=? AND revoked_at IS NULL")
    .bind(integrationId).first<{ aci: string; channelId: string }>();
  if (!integration) throw new ApiError(404, "INTEGRATION_NOT_FOUND");
  const channel = await env.DB.prepare("SELECT membership_epoch AS membershipEpoch FROM channels WHERE channel_id=?")
    .bind(integration.channelId).first<{ membershipEpoch: number }>();
  if (!channel) throw new ApiError(404, "CHANNEL_NOT_FOUND");
  const timestamp = now();
  const nextEpoch = channel.membershipEpoch + 1;
  await env.DB.batch([
    env.DB.prepare("UPDATE channel_integrations SET revoked_at=? WHERE integration_id=? AND revoked_at IS NULL").bind(timestamp, integrationId),
    env.DB.prepare("UPDATE memberships SET left_epoch=? WHERE channel_id=? AND aci=? AND left_epoch IS NULL")
      .bind(nextEpoch, integration.channelId, integration.aci),
    env.DB.prepare("UPDATE devices SET status='revoked',revoked_at=? WHERE aci=? AND status='active'").bind(timestamp, integration.aci),
    env.DB.prepare("UPDATE accounts SET disabled_at=? WHERE aci=?").bind(timestamp, integration.aci),
    env.DB.prepare("UPDATE channels SET membership_epoch=?,distribution_id=? WHERE channel_id=?")
      .bind(nextEpoch, uuid(), integration.channelId),
  ]);
  await notifyChannelMembershipChanged(env, integration.channelId, nextEpoch);
  await audit(env, "integration.revoked", actor.aci, integrationId);
  return json({ accepted: true });
}
