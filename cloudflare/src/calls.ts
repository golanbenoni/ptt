import { arrayField, body, ApiError, json, stringField } from "./http";
import { authenticate, now, requireMembership } from "./db";
import { sha256Hex } from "./crypto";
import type { CallEventCoordinator } from "./call-events";

type CallsEnvironment = Env & {
  CALL_EVENTS: DurableObjectNamespace<CallEventCoordinator>;
  LIVEKIT_URL?: string;
  LIVEKIT_API_KEY?: string;
  LIVEKIT_API_SECRET?: string;
};

type CallRow = {
  callId: string;
  conversationId: string;
  hostAci: string;
  state: "ringing" | "connecting" | "active" | "ended";
  callEpoch: number;
  participantLimit: number;
  createdAt: string;
  ringingExpiresAt: string;
  activatedAt: string | null;
  endedAt: string | null;
  endReason: string | null;
  livekitRoomName: string;
};

type ParticipantRow = {
  aci: string;
  claimedDeviceId: number | null;
  livekitIdentity: string | null;
  state: string;
  joinOrder: number;
  invitedAt: string;
  answeredAt: string | null;
  joinedAt: string | null;
  leftAt: string | null;
};

type MediaActionRow = {
  actionId: string;
  actionType: "remove_participant" | "delete_room";
  livekitRoomName: string;
  livekitIdentity: string;
  attempts: number;
};

const CALL_RING_SECONDS = 45;
const CALL_COORDINATION_SECONDS = 32 * 60 * 60;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;

export async function callCapabilities(env: Env): Promise<Response> {
  const settings = liveKitSettings(env as CallsEnvironment);
  const ready = settings !== null && await mediaReady(settings);
  return json({
    callProtocol: { major: 1, minor: 0 }, enabled: ready,
    maximumParticipants: 8, mediaReady: ready,
    mediaProvider: "livekit-self-hosted",
    features: ["e2ee", "group-calls", "first-answer-wins", "sos-preemption"],
  });
}

export async function createCall(request: Request, env: Env): Promise<Response> {
  const callsEnv = env as CallsEnvironment;
  const settings = liveKitSettings(callsEnv);
  if (!settings || !await mediaReady(settings)) throw new ApiError(503, "CALL_MEDIA_NOT_READY");
  const principal = await authenticate(request, env);
  const value = await body(request);
  const idempotencyKey = stringField(value, "idempotencyKey", 128);
  if (idempotencyKey.length < 16) throw new ApiError(400, "INVALID_IDEMPOTENCY_KEY");
  const conversationId = uuidField(value, "conversationId");
  const invitees = uniqueUuidArray(arrayField(value, "invitees", 7), "invitees");
  if (invitees.length < 1 || invitees.includes(principal.aci)) throw new ApiError(400, "INVALID_INVITEES");
  await requireMembership(env, principal.aci, conversationId);
  const conversation = await env.DB.prepare("SELECT kind FROM channels WHERE channel_id=?")
    .bind(conversationId).first<{ kind: string }>();
  if (!conversation || (conversation.kind === "direct" && invitees.length !== 1) ||
      (conversation.kind !== "direct" && invitees.length < 2)) {
    throw new ApiError(400, "INVALID_CALL_PARTICIPANTS");
  }
  const keyHash = await sha256Hex(idempotencyKey);
  const existing = await env.DB.prepare(callSelect("WHERE host_aci=? AND idempotency_key_hash=?"))
    .bind(principal.aci, keyHash).first<CallRow>();
  if (existing) return callResponse(env, existing, principal.aci);
  const busy = await env.DB.prepare(
    "SELECT 1 AS busy FROM call_participants WHERE aci=? AND state IN ('connecting','joined') LIMIT 1",
  ).bind(principal.aci).first<{ busy: number }>();
  if (busy) throw new ApiError(409, "ACCOUNT_ALREADY_IN_CALL");

  const placeholders = invitees.map(() => "?").join(",");
  const eligible = await env.DB.prepare(
    `SELECT aci FROM memberships WHERE channel_id=? AND left_epoch IS NULL AND aci IN (${placeholders})`,
  ).bind(conversationId, ...invitees).all<{ aci: string }>();
  if (eligible.results.length !== invitees.length) throw new ApiError(403, "CALL_INVITEE_NOT_ELIGIBLE");

  const callId = crypto.randomUUID();
  const createdAt = new Date();
  const ringingExpiresAt = new Date(createdAt.getTime() + CALL_RING_SECONDS * 1_000);
  const coordinationExpiresAt = new Date(createdAt.getTime() + CALL_COORDINATION_SECONDS * 1_000);
  const statements = [env.DB.prepare(
    `INSERT INTO call_sessions(call_id,conversation_id,host_aci,state,call_epoch,participant_limit,
      idempotency_key_hash,livekit_room_name,created_at,ringing_expires_at,last_key_rotation_at,coordination_expires_at)
     VALUES(?,?,?,'ringing',1,8,?,?,?,?,?,?)`,
  ).bind(callId, conversationId, principal.aci, keyHash, randomOpaqueId(), createdAt.toISOString(),
    ringingExpiresAt.toISOString(), createdAt.toISOString(), coordinationExpiresAt.toISOString()),
  env.DB.prepare(
    `INSERT INTO call_participants(call_id,aci,claimed_device_id,livekit_identity,state,join_order,
      invited_by,invited_at,answered_at) VALUES(?,?,?,?,'connecting',1,?,?,?)`,
  ).bind(callId, principal.aci, principal.deviceId, randomOpaqueId(), principal.aci,
    createdAt.toISOString(), createdAt.toISOString())];
  invitees.forEach((aci, index) => statements.push(env.DB.prepare(
    `INSERT INTO call_participants(call_id,aci,state,join_order,invited_by,invited_at)
     VALUES(?,?,'ringing',?,?,?)`,
  ).bind(callId, aci, index + 2, principal.aci, createdAt.toISOString())));
  statements.push(env.DB.prepare(
    "INSERT INTO call_coordination_events(call_id,recipient_aci,event_type,created_at) VALUES(?,NULL,'ringing',?)",
  ).bind(callId, createdAt.toISOString()));
  try {
    await env.DB.batch(statements);
  } catch (error) {
    if (isCallSeatConflict(error)) throw new ApiError(409, "ACCOUNT_ALREADY_IN_CALL");
    throw error;
  }
  await Promise.all(invitees.map((aci) => notifyAccount(callsEnv, aci, callId, "ringing")));
  await enqueueCallPushes(env, callId, invitees);
  return callResponse(env, await loadCall(env, callId), principal.aci, 201);
}

export async function getCall(request: Request, env: Env, callId: string): Promise<Response> {
  const principal = await authenticate(request, env);
  return callResponse(env, await authorizedCall(env, callId, principal.aci), principal.aci);
}

export async function answerCall(request: Request, env: Env, callId: string): Promise<Response> {
  const callsEnv = env as CallsEnvironment;
  const settings = liveKitSettings(callsEnv);
  if (!settings || !await mediaReady(settings)) throw new ApiError(503, "CALL_MEDIA_NOT_READY");
  const principal = await authenticate(request, env);
  const call = await authorizedCall(env, callId, principal.aci);
  if (call.state === "ended") throw new ApiError(409, "CALL_ENDED");
  if (Date.parse(call.ringingExpiresAt) <= Date.now() && call.activatedAt === null) {
    await finishCall(env, callId, "missed");
    throw new ApiError(410, "CALL_EXPIRED");
  }
  const participant = await loadParticipant(env, callId, principal.aci);
  if (participant.claimedDeviceId !== null && participant.claimedDeviceId !== principal.deviceId) {
    throw new ApiError(409, "CALL_ANSWERED_ELSEWHERE");
  }
  let identity = participant.livekitIdentity;
  const claimedNow = participant.claimedDeviceId === null;
  if (claimedNow && participant.state !== "invited" && participant.state !== "ringing") {
    throw new ApiError(409, "CALL_PARTICIPANT_NOT_ELIGIBLE");
  }
  const rejoining = participant.claimedDeviceId === principal.deviceId
    && (participant.state === "left" || participant.state === "failed");
  if (!claimedNow && !rejoining && participant.state !== "connecting" && participant.state !== "joined") {
    throw new ApiError(409, "CALL_PARTICIPANT_NOT_ELIGIBLE");
  }
  if (claimedNow) {
    identity = randomOpaqueId();
    let update: D1Result;
    try {
      update = await env.DB.prepare(
        `UPDATE call_participants SET claimed_device_id=?,livekit_identity=?,state='connecting',answered_at=?
         WHERE call_id=? AND aci=? AND claimed_device_id IS NULL AND state IN ('invited','ringing')`,
      ).bind(principal.deviceId, identity, now(), callId, principal.aci).run();
    } catch (error) {
      if (isCallSeatConflict(error)) throw new ApiError(409, "ACCOUNT_ALREADY_IN_CALL");
      throw error;
    }
    if ((update.meta.changes ?? 0) !== 1) throw new ApiError(409, "CALL_ANSWERED_ELSEWHERE");
  } else if (rejoining) {
    let update: D1Result;
    try {
      update = await env.DB.prepare(
        `UPDATE call_participants SET state='connecting',answered_at=?,joined_at=NULL,left_at=NULL
         WHERE call_id=? AND aci=? AND claimed_device_id=? AND state IN ('left','failed')`,
      ).bind(now(), callId, principal.aci, principal.deviceId).run();
    } catch (error) {
      if (isCallSeatConflict(error)) throw new ApiError(409, "ACCOUNT_ALREADY_IN_CALL");
      throw error;
    }
    if ((update.meta.changes ?? 0) !== 1) throw new ApiError(409, "CALL_PARTICIPANT_NOT_ELIGIBLE");
  }
  const updates = [env.DB.prepare(
    "UPDATE call_sessions SET state=CASE WHEN state='ringing' THEN 'connecting' ELSE state END WHERE call_id=? AND state<>'ended'",
  ).bind(callId)];
  if (claimedNow) updates.push(env.DB.prepare(
    "INSERT INTO call_coordination_events(call_id,recipient_aci,event_type,created_at) VALUES(?,NULL,'answered',?)",
  ).bind(callId, now()));
  await env.DB.batch(updates);
  if (claimedNow || rejoining) await rotateEpoch(env, callId);
  if (claimedNow || rejoining) {
    await notifyRoster(callsEnv, env, callId, claimedNow ? "answered" : "roster_changed");
  }
  const current = await loadCall(env, callId);
  return json({
    callId, serverUrl: settings.url, participantIdentity: identity,
    joinToken: await liveKitToken(settings, call.livekitRoomName, identity ?? ""),
    expiresInSeconds: 300, e2eeRequired: true, callEpoch: current.callEpoch,
  });
}

export async function declineCall(request: Request, env: Env, callId: string): Promise<Response> {
  return participantExit(request, env, callId, "declined");
}

export async function leaveCall(request: Request, env: Env, callId: string): Promise<Response> {
  return participantExit(request, env, callId, "left");
}

export async function endCall(request: Request, env: Env, callId: string): Promise<Response> {
  const callsEnv = env as CallsEnvironment;
  const principal = await authenticate(request, env);
  const call = await authorizedCall(env, callId, principal.aci);
  if (call.state === "ended") return json({ accepted: true });
  await requireActiveCallSeat(env, callId, principal);
  const value = await body(request);
  const reason = value.reason === "sos_preempted"
    ? "sos_preempted" : call.activatedAt === null ? "cancelled" : "host_ended";
  if (reason !== "sos_preempted" && call.hostAci !== principal.aci) {
    throw new ApiError(403, "CALL_HOST_REQUIRED");
  }
  await finishCall(env, callId, reason);
  await notifyRoster(callsEnv, env, callId, "ended");
  return json({ accepted: true });
}

export async function addCallParticipants(request: Request, env: Env, callId: string): Promise<Response> {
  const callsEnv = env as CallsEnvironment;
  const principal = await authenticate(request, env);
  const call = await authorizedCall(env, callId, principal.aci);
  if (call.hostAci !== principal.aci || call.state === "ended") throw new ApiError(403, "CALL_HOST_REQUIRED");
  await requireActiveCallSeat(env, callId, principal);
  const value = await body(request);
  const invitees = uniqueUuidArray(arrayField(value, "invitees", 7), "invitees");
  if (invitees.length === 0) throw new ApiError(400, "INVALID_INVITEES");
  const confirmCreatePrivateGroup = value.confirmCreatePrivateGroup === true;
  const requestedName = typeof value.displayName === "string" ? value.displayName.trim() : "";
  if ([...requestedName].length > 80) throw new ApiError(400, "INVALID_CONVERSATION_NAME");
  const count = await env.DB.prepare(
    "SELECT count(*) AS count FROM call_participants WHERE call_id=? AND state IN ('invited','ringing','connecting','joined')",
  )
    .bind(callId).first<{ count: number }>();
  if ((count?.count ?? 8) + invitees.length > 8) throw new ApiError(409, "CALL_PARTICIPANT_LIMIT");
  const presentPlaceholders = invitees.map(() => "?").join(",");
  const alreadyPresent = await env.DB.prepare(
    `SELECT 1 AS present FROM call_participants WHERE call_id=? AND aci IN (${presentPlaceholders})
     AND state IN ('invited','ringing','connecting','joined') LIMIT 1`,
  ).bind(callId, ...invitees).first();
  if (alreadyPresent) throw new ApiError(409, "CALL_PARTICIPANT_ALREADY_PRESENT");
  for (const aci of invitees) {
    const account = await env.DB.prepare(
      `SELECT 1 AS present FROM accounts WHERE aci=? AND disabled_at IS NULL
       AND account_kind IN ('member','guest') AND (guest_expires_at IS NULL OR guest_expires_at>?)`,
    ).bind(aci, now()).first();
    if (!account) throw new ApiError(403, "CALL_INVITEE_NOT_ELIGIBLE");
  }
  const conversation = await env.DB.prepare("SELECT kind FROM channels WHERE channel_id=?")
    .bind(call.conversationId).first<{ kind: string }>();
  if (!conversation) throw new ApiError(404, "CALL_NOT_FOUND");
  const placeholders = invitees.map(() => "?").join(",");
  if (conversation.kind !== "direct" && conversation.kind !== "adhoc") {
    const eligible = await env.DB.prepare(
      `SELECT aci FROM memberships WHERE channel_id=? AND left_epoch IS NULL AND aci IN (${placeholders})`,
    ).bind(call.conversationId, ...invitees).all<{ aci: string }>();
    if (eligible.results.length !== invitees.length) throw new ApiError(403, "CALL_INVITEE_NOT_ELIGIBLE");
  }
  const maximum = await env.DB.prepare("SELECT coalesce(max(join_order),0) AS value FROM call_participants WHERE call_id=?")
    .bind(callId).first<{ value: number }>();
  const statements: D1PreparedStatement[] = [];
  if (conversation.kind === "direct") {
    if (!confirmCreatePrivateGroup) throw new ApiError(409, "CALL_GROUP_CONFIRMATION_REQUIRED");
    const existing = await env.DB.prepare(
      "SELECT aci FROM call_participants WHERE call_id=? AND state IN ('invited','ringing','connecting','joined') ORDER BY join_order",
    )
      .bind(callId).all<{ aci: string }>();
    const members = [...new Set([...existing.results.map((row) => row.aci), ...invitees])];
    if (members.length < 3 || members.length > 8) throw new ApiError(400, "INVALID_CONVERSATION_MEMBERS");
    let displayName = requestedName;
    if (!displayName) {
      const memberPlaceholders = members.map(() => "?").join(",");
      const names = await env.DB.prepare(
        `SELECT display_name AS displayName FROM accounts WHERE aci IN (${memberPlaceholders}) ORDER BY lower(display_name)`,
      ).bind(...members).all<{ displayName: string }>();
      displayName = names.results.map((row) => row.displayName).join(", ").slice(0, 80);
    }
    const groupId = crypto.randomUUID();
    const createdAt = now();
    statements.push(env.DB.prepare(
      "INSERT INTO channels(channel_id,display_name,kind,membership_epoch,distribution_id,retention_days,created_at,created_by) VALUES(?,?,'adhoc',1,?,30,?,?)",
    ).bind(groupId, displayName, crypto.randomUUID(), createdAt, principal.aci));
    members.forEach((aci) => statements.push(env.DB.prepare(
      "INSERT INTO memberships(channel_id,aci,role,joined_epoch,created_at) VALUES(?,?,'talk',1,?)",
    ).bind(groupId, aci, createdAt)));
    statements.push(env.DB.prepare("UPDATE call_sessions SET conversation_id=? WHERE call_id=?")
      .bind(groupId, callId));
  } else if (conversation.kind === "adhoc") {
    statements.push(env.DB.prepare(
      "UPDATE channels SET membership_epoch=membership_epoch+1,distribution_id=? WHERE channel_id=?",
    ).bind(crypto.randomUUID(), call.conversationId));
    invitees.forEach((aci) => statements.push(env.DB.prepare(
      `INSERT INTO memberships(channel_id,aci,role,joined_epoch,left_epoch,created_at)
       VALUES(?,?,'talk',(SELECT membership_epoch FROM channels WHERE channel_id=?),NULL,?)
       ON CONFLICT(channel_id,aci) DO UPDATE SET role='talk',joined_epoch=excluded.joined_epoch,left_epoch=NULL`,
    ).bind(call.conversationId, aci, call.conversationId, now())));
  }
  invitees.forEach((aci, index) => statements.push(env.DB.prepare(
    `INSERT INTO call_participants(call_id,aci,state,join_order,invited_by,invited_at)
     VALUES(?,?,'ringing',?,?,?)
     ON CONFLICT(call_id,aci) DO UPDATE SET claimed_device_id=NULL,livekit_identity=NULL,state='ringing',
       join_order=excluded.join_order,invited_by=excluded.invited_by,invited_at=excluded.invited_at,
       answered_at=NULL,joined_at=NULL,left_at=NULL`,
  ).bind(callId, aci, (maximum?.value ?? 0) + index + 1, principal.aci, now())));
  statements.push(env.DB.prepare(
    "UPDATE call_sessions SET call_epoch=call_epoch+1,last_key_rotation_at=? WHERE call_id=? AND state<>'ended'",
  ).bind(now(), callId));
  statements.push(env.DB.prepare(
    "INSERT INTO call_coordination_events(call_id,recipient_aci,event_type,created_at) VALUES(?,NULL,'roster_changed',?)",
  ).bind(callId, now()));
  await env.DB.batch(statements);
  await Promise.all(invitees.map((aci) => notifyAccount(callsEnv, aci, callId, "ringing")));
  await enqueueCallPushes(env, callId, invitees);
  return callResponse(env, await loadCall(env, callId), principal.aci);
}

export async function removeCallParticipant(request: Request, env: Env, callId: string, participantAci: string): Promise<Response> {
  const callsEnv = env as CallsEnvironment;
  const principal = await authenticate(request, env);
  const call = await authorizedCall(env, callId, principal.aci);
  if (call.hostAci !== principal.aci || call.state === "ended") throw new ApiError(403, "CALL_HOST_REQUIRED");
  await requireActiveCallSeat(env, callId, principal);
  if (!UUID.test(participantAci) || participantAci === principal.aci) throw new ApiError(400, "INVALID_PARTICIPANT");
  const participant = await loadParticipant(env, callId, participantAci);
  if (new Set(["removed", "left", "declined", "missed"]).has(participant.state)) {
    throw new ApiError(404, "CALL_PARTICIPANT_NOT_FOUND");
  }
  const removedAt = now();
  const statements = [env.DB.prepare(
    "UPDATE call_participants SET state='removed',left_at=? WHERE call_id=? AND aci=? AND state NOT IN ('removed','left','declined','missed')",
  ).bind(removedAt, callId, participantAci),
  env.DB.prepare(
    `UPDATE call_sessions SET call_epoch=call_epoch+1,last_key_rotation_at=? WHERE call_id=? AND state<>'ended'
      AND EXISTS(SELECT 1 FROM call_participants WHERE call_id=? AND aci=? AND state='removed' AND left_at=?)`,
  ).bind(removedAt, callId, callId, participantAci, removedAt),
  env.DB.prepare(
    `INSERT INTO call_coordination_events(call_id,recipient_aci,event_type,created_at)
     SELECT ?,NULL,'roster_changed',? WHERE EXISTS(
       SELECT 1 FROM call_participants WHERE call_id=? AND aci=? AND state='removed' AND left_at=?)`,
  ).bind(callId, removedAt, callId, participantAci, removedAt)];
  if (participant.livekitIdentity) {
    statements.push(conditionalMediaActionStatement(
      env, callId, "remove_participant", participant.livekitIdentity,
      "EXISTS(SELECT 1 FROM call_participants WHERE call_id=? AND aci=? AND state='removed' AND left_at=?)",
      [callId, participantAci, removedAt],
    ));
  }
  const results = await env.DB.batch(statements);
  if ((results[0]?.meta.changes ?? 0) !== 1) throw new ApiError(404, "CALL_PARTICIPANT_NOT_FOUND");
  await processMediaActions(env as CallsEnvironment, 10);
  await notifyRoster(callsEnv, env, callId, "roster_changed");
  return json({ accepted: true });
}

export async function callEvents(request: Request, env: Env): Promise<Response> {
  const callsEnv = env as CallsEnvironment;
  const principal = await authenticate(request, env);
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") throw new ApiError(426, "WEBSOCKET_REQUIRED");
  const object = callsEnv.CALL_EVENTS.get(callsEnv.CALL_EVENTS.idFromName(principal.aci));
  const headers = new Headers(request.headers);
  headers.set("X-PTT-Aci", principal.aci);
  headers.set("X-PTT-Device", String(principal.deviceId));
  return object.fetch(new Request(request, { headers }));
}

/** LiveKit authenticates the raw body digest inside an HS256 webhook JWT. */
export async function liveKitWebhook(request: Request, env: Env): Promise<Response> {
  const callsEnv = env as CallsEnvironment;
  const settings = liveKitSettings(callsEnv);
  if (!settings) throw new ApiError(503, "CALL_MEDIA_NOT_READY");
  const contentType = request.headers.get("Content-Type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("application/webhook+json")) {
    throw new ApiError(400, "INVALID_WEBHOOK_CONTENT_TYPE");
  }
  const raw = await request.text();
  if (raw.length === 0 || new TextEncoder().encode(raw).byteLength > 256 * 1024) {
    throw new ApiError(400, "INVALID_WEBHOOK_BODY");
  }
  await verifyLiveKitWebhook(settings, request.headers.get("Authorization") ?? "", raw);
  let event: Record<string, unknown>;
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!isRecord(parsed)) throw new Error("not an object");
    event = parsed;
  } catch {
    throw new ApiError(400, "INVALID_WEBHOOK_BODY");
  }
  const eventId = typeof event.id === "string" ? event.id : "";
  const eventType = typeof event.event === "string" ? event.event : "";
  const roomName = isRecord(event.room) && typeof event.room.name === "string" ? event.room.name : "";
  if (eventId.length < 8 || eventId.length > 128) throw new ApiError(400, "INVALID_WEBHOOK_EVENT");
  if (!roomName) return json({ accepted: true });
  const call = await env.DB.prepare("SELECT call_id AS callId,host_aci AS hostAci FROM call_sessions WHERE livekit_room_name=?")
    .bind(roomName).first<{ callId: string; hostAci: string }>();
  if (!call) return json({ accepted: true });
  const inserted = await env.DB.prepare(
    "INSERT OR IGNORE INTO livekit_webhook_events(event_id,call_id,received_at) VALUES(?,?,?)",
  ).bind(eventId, call.callId, now()).run();
  if ((inserted.meta.changes ?? 0) === 0) return json({ accepted: true });

  let changed = false;
  if (eventType === "participant_joined") {
    const identity = webhookParticipantIdentity(event);
    const result = await env.DB.prepare(
      "UPDATE call_participants SET state='joined',joined_at=coalesce(joined_at,?) WHERE call_id=? AND livekit_identity=? AND state='connecting'",
    ).bind(now(), call.callId, identity).run();
    changed = (result.meta.changes ?? 0) === 1;
    if (changed) {
      const count = await env.DB.prepare("SELECT count(*) AS count FROM call_participants WHERE call_id=? AND state='joined'")
        .bind(call.callId).first<{ count: number }>();
      if ((count?.count ?? 0) >= 2) {
        await env.DB.prepare(
          "UPDATE call_sessions SET state='active',activated_at=coalesce(activated_at,?),last_key_rotation_at=? WHERE call_id=? AND state IN ('ringing','connecting')",
        ).bind(now(), now(), call.callId).run();
      }
    }
  } else if (eventType === "participant_left" || eventType === "participant_connection_aborted") {
    const identity = webhookParticipantIdentity(event);
    const participant = await env.DB.prepare(
      "SELECT aci FROM call_participants WHERE call_id=? AND livekit_identity=? AND state IN ('connecting','joined')",
    ).bind(call.callId, identity).first<{ aci: string }>();
    if (participant) {
      await env.DB.prepare(
        "UPDATE call_participants SET state=?,left_at=coalesce(left_at,?) WHERE call_id=? AND livekit_identity=? AND state IN ('connecting','joined')",
      ).bind(eventType === "participant_connection_aborted" ? "failed" : "left", now(), call.callId, identity).run();
      await rotateEpoch(env, call.callId);
      if (participant.aci === call.hostAci) await transferHostOrEnd(env, call.callId);
      await finishIfEmpty(env, call.callId);
      changed = true;
    }
  } else if (eventType === "room_finished") {
    await finishCall(env, call.callId, "completed");
    changed = true;
  }
  if (changed) await notifyRoster(callsEnv, env, call.callId, eventType === "room_finished" ? "ended" : "roster_changed");
  return json({ accepted: true });
}

async function participantExit(request: Request, env: Env, callId: string, next: "declined" | "left"): Promise<Response> {
  const callsEnv = env as CallsEnvironment;
  const principal = await authenticate(request, env);
  const call = await authorizedCall(env, callId, principal.aci);
  const participant = await loadParticipant(env, callId, principal.aci);
  if (next === "left") {
    if (participant.claimedDeviceId !== principal.deviceId) {
      throw new ApiError(409, "CALL_ACTIVE_DEVICE_REQUIRED");
    }
    if (participant.state === "left") return json({ accepted: true });
    if (!new Set(["connecting", "joined", "failed"]).has(participant.state)) {
      throw new ApiError(409, "INVALID_CALL_TRANSITION");
    }
  } else {
    if (participant.state === "declined") return json({ accepted: true });
    if (participant.claimedDeviceId !== null || !new Set(["invited", "ringing"]).has(participant.state)) {
      throw new ApiError(409, "INVALID_CALL_TRANSITION");
    }
  }
  const result = await env.DB.prepare(
    "UPDATE call_participants SET state=?,left_at=? WHERE call_id=? AND aci=? AND state NOT IN ('declined','left','removed','missed')",
  ).bind(next, now(), callId, principal.aci).run();
  if ((result.meta.changes ?? 0) > 0) await rotateEpoch(env, callId);
  if (call.hostAci === principal.aci && next === "left") await transferHostOrEnd(env, callId);
  if (next === "declined" && call.activatedAt === null) {
    const remaining = await env.DB.prepare(
      `SELECT count(*) AS count FROM call_participants
        WHERE call_id=? AND aci<>? AND state IN ('invited','ringing','connecting','joined')`,
    ).bind(callId, call.hostAci).first<{ count: number }>();
    if ((remaining?.count ?? 0) === 0) await finishCall(env, callId, "declined");
  }
  await finishIfEmpty(env, callId);
  await notifyRoster(callsEnv, env, callId, "roster_changed");
  return json({ accepted: true });
}

async function authorizedCall(env: Env, callId: string, aci: string): Promise<CallRow> {
  if (!UUID.test(callId)) throw new ApiError(400, "INVALID_CALL_ID");
  const participant = await env.DB.prepare(
    "SELECT 1 AS present FROM call_participants WHERE call_id=? AND aci=? AND state<>'removed'",
  )
    .bind(callId, aci).first<{ present: number }>();
  if (!participant) throw new ApiError(404, "CALL_NOT_FOUND");
  return loadCall(env, callId);
}

async function loadCall(env: Env, callId: string): Promise<CallRow> {
  const row = await env.DB.prepare(callSelect("WHERE call_id=?")).bind(callId).first<CallRow>();
  if (!row) throw new ApiError(404, "CALL_NOT_FOUND");
  return row;
}

function callSelect(where: string): string {
  return `SELECT call_id AS callId,conversation_id AS conversationId,host_aci AS hostAci,state,
    call_epoch AS callEpoch,participant_limit AS participantLimit,created_at AS createdAt,
    ringing_expires_at AS ringingExpiresAt,activated_at AS activatedAt,ended_at AS endedAt,
    end_reason AS endReason,livekit_room_name AS livekitRoomName FROM call_sessions ${where}`;
}

async function loadParticipant(env: Env, callId: string, aci: string): Promise<ParticipantRow> {
  const row = await env.DB.prepare(
    `SELECT aci,claimed_device_id AS claimedDeviceId,livekit_identity AS livekitIdentity,state,
      join_order AS joinOrder,invited_at AS invitedAt,answered_at AS answeredAt,
      joined_at AS joinedAt,left_at AS leftAt FROM call_participants WHERE call_id=? AND aci=?`,
  ).bind(callId, aci).first<ParticipantRow>();
  if (!row) throw new ApiError(404, "CALL_NOT_FOUND");
  return row;
}

async function requireActiveCallSeat(
  env: Env,
  callId: string,
  principal: { aci: string; deviceId: number },
): Promise<void> {
  const active = await env.DB.prepare(
    `SELECT 1 AS active FROM call_participants
      WHERE call_id=? AND aci=? AND claimed_device_id=? AND state IN ('connecting','joined')`,
  ).bind(callId, principal.aci, principal.deviceId).first<{ active: number }>();
  if (!active) throw new ApiError(409, "CALL_ACTIVE_DEVICE_REQUIRED");
}

async function callResponse(env: Env, call: CallRow, requesterAci: string, status = 200): Promise<Response> {
  const roster = await env.DB.prepare(
    `SELECT aci,claimed_device_id AS claimedDeviceId,state,join_order AS joinOrder,
      invited_at AS invitedAt,answered_at AS answeredAt,joined_at AS joinedAt,left_at AS leftAt
      FROM call_participants WHERE call_id=? ORDER BY join_order`,
  ).bind(call.callId).all<Omit<ParticipantRow, "livekitIdentity">>();
  return json({
    callId: call.callId, conversationId: call.conversationId, hostAci: call.hostAci,
    state: call.state, callEpoch: call.callEpoch, participantLimit: call.participantLimit,
    createdAt: call.createdAt, ringingExpiresAt: call.ringingExpiresAt,
    activatedAt: call.activatedAt, endedAt: call.endedAt, endReason: call.endReason,
    requesterIsHost: call.hostAci === requesterAci, participants: roster.results, e2eeRequired: true,
  }, status);
}

async function rotateEpoch(env: Env, callId: string): Promise<void> {
  await env.DB.batch([
    env.DB.prepare("UPDATE call_sessions SET call_epoch=call_epoch+1,last_key_rotation_at=? WHERE call_id=? AND state<>'ended'").bind(now(), callId),
    env.DB.prepare("INSERT INTO call_coordination_events(call_id,recipient_aci,event_type,created_at) VALUES(?,NULL,'roster_changed',?)").bind(callId, now()),
  ]);
}

export async function runCallMaintenance(env: Env): Promise<void> {
  const callsEnv = env as CallsEnvironment;
  const timestamp = now();
  const ringing = await env.DB.prepare(
    "SELECT call_id AS callId FROM call_sessions WHERE state IN ('ringing','connecting') AND activated_at IS NULL AND ringing_expires_at<=? LIMIT 100",
  ).bind(timestamp).all<{ callId: string }>();
  const safety = await env.DB.prepare(
    "SELECT call_id AS callId,activated_at AS activatedAt FROM call_sessions WHERE state='active' AND activated_at IS NOT NULL LIMIT 100",
  ).all<{ callId: string; activatedAt: string }>();
  const safetyExpired = safety.results.filter((call) => Date.parse(call.activatedAt) + 8 * 60 * 60_000 <= Date.now());
  for (const call of ringing.results) {
    await finishCall(env, call.callId, "missed");
    await notifyRoster(callsEnv, env, call.callId, "ended");
  }
  for (const call of safetyExpired) {
    await finishCall(env, call.callId, "safety_limit");
    await notifyRoster(callsEnv, env, call.callId, "ended");
  }
  const participantCutoff = new Date(Date.now() - CALL_RING_SECONDS * 1_000).toISOString();
  const missedInvites = await env.DB.prepare(
    `SELECT p.call_id AS callId,p.aci FROM call_participants p
       JOIN call_sessions c ON c.call_id=p.call_id
      WHERE c.state='active' AND p.state IN ('invited','ringing') AND p.invited_at<=? LIMIT 100`,
  ).bind(participantCutoff).all<{ callId: string; aci: string }>();
  const participantChanges = new Set<string>();
  for (const participant of missedInvites.results) {
    const update = await env.DB.prepare(
      "UPDATE call_participants SET state='missed',left_at=? WHERE call_id=? AND aci=? AND state IN ('invited','ringing')",
    ).bind(timestamp, participant.callId, participant.aci).run();
    if ((update.meta.changes ?? 0) === 1) participantChanges.add(participant.callId);
  }
  const failedConnections = await env.DB.prepare(
    `SELECT p.call_id AS callId,p.aci,p.livekit_identity AS livekitIdentity,c.host_aci AS hostAci
       FROM call_participants p JOIN call_sessions c ON c.call_id=p.call_id
      WHERE c.state='active' AND p.state='connecting' AND p.answered_at IS NOT NULL
        AND p.answered_at<=? LIMIT 100`,
  ).bind(participantCutoff).all<{
    callId: string; aci: string; livekitIdentity: string | null; hostAci: string;
  }>();
  const failedByCall = new Map<string, typeof failedConnections.results>();
  for (const participant of failedConnections.results) {
    const update = await env.DB.prepare(
      "UPDATE call_participants SET state='failed',left_at=? WHERE call_id=? AND aci=? AND state='connecting'",
    ).bind(timestamp, participant.callId, participant.aci).run();
    if ((update.meta.changes ?? 0) !== 1) continue;
    const group = failedByCall.get(participant.callId) ?? [];
    group.push(participant);
    failedByCall.set(participant.callId, group);
  }
  for (const [callId, participants] of failedByCall) {
    const statements: D1PreparedStatement[] = [];
    for (const participant of participants) {
      if (participant.livekitIdentity) statements.push(conditionalMediaActionStatement(
        env, callId, "remove_participant", participant.livekitIdentity,
        "EXISTS(SELECT 1 FROM call_participants WHERE call_id=? AND aci=? AND state='failed' AND left_at=?)",
        [callId, participant.aci, timestamp],
      ));
    }
    if (statements.length > 0) await env.DB.batch(statements);
    await rotateEpoch(env, callId);
    if (participants.some((participant) => participant.aci === participant.hostAci)) {
      await transferHostOrEnd(env, callId);
    }
    await finishIfEmpty(env, callId);
    participantChanges.add(callId);
  }
  const rotateBefore = new Date(Date.now() - 30 * 60_000).toISOString();
  const rotate = await env.DB.prepare(
    "SELECT call_id AS callId FROM call_sessions WHERE state='active' AND last_key_rotation_at<=? LIMIT 100",
  ).bind(rotateBefore).all<{ callId: string }>();
  for (const call of rotate.results) {
    await rotateEpoch(env, call.callId);
    await notifyRoster(callsEnv, env, call.callId, "roster_changed");
  }
  for (const callId of participantChanges) {
    await notifyRoster(callsEnv, env, callId, "roster_changed");
  }
  await processMediaActions(callsEnv, 100);
  await env.DB.prepare("DELETE FROM call_sessions WHERE state='ended' AND coordination_expires_at<=?")
    .bind(timestamp).run();
}

async function finishCall(env: Env, callId: string, reason: string): Promise<void> {
  const timestamp = now();
  const coordinationExpiresAt = new Date(Date.now() + 24 * 60 * 60_000).toISOString();
  const results = await env.DB.batch([
    env.DB.prepare(
      "UPDATE call_sessions SET state='ended',end_reason=?,ended_at=?,coordination_expires_at=? WHERE call_id=? AND state<>'ended'",
    ).bind(reason, timestamp, coordinationExpiresAt, callId),
    env.DB.prepare("UPDATE call_participants SET state=CASE WHEN state IN ('ringing','invited') THEN 'missed' WHEN state IN ('joined','connecting') THEN 'left' ELSE state END,left_at=coalesce(left_at,?) WHERE call_id=?").bind(timestamp, callId),
    env.DB.prepare(
      "INSERT INTO call_coordination_events(call_id,recipient_aci,event_type,created_at) SELECT ?,NULL,'ended',? WHERE EXISTS(SELECT 1 FROM call_sessions WHERE call_id=? AND ended_at=?)",
    ).bind(callId, timestamp, callId, timestamp),
    conditionalMediaActionStatement(
      env, callId, "delete_room", "",
      "EXISTS(SELECT 1 FROM call_sessions WHERE call_id=? AND ended_at=?)",
      [callId, timestamp],
    ),
  ]);
  if ((results[0]?.meta.changes ?? 0) === 0) return;
  await processMediaActions(env as CallsEnvironment, 10);
}

async function finishIfEmpty(env: Env, callId: string): Promise<void> {
  const row = await env.DB.prepare("SELECT count(*) AS count FROM call_participants WHERE call_id=? AND state IN ('connecting','joined')")
    .bind(callId).first<{ count: number }>();
  if ((row?.count ?? 0) === 0) await finishCall(env, callId, "completed");
}

async function transferHostOrEnd(env: Env, callId: string): Promise<void> {
  const replacement = await env.DB.prepare("SELECT aci FROM call_participants WHERE call_id=? AND state IN ('connecting','joined') ORDER BY join_order LIMIT 1")
    .bind(callId).first<{ aci: string }>();
  if (replacement) await env.DB.prepare("UPDATE call_sessions SET host_aci=? WHERE call_id=?").bind(replacement.aci, callId).run();
  else await finishCall(env, callId, "completed");
}

export async function revokeCallSeats(env: Env, aci: string, claimedDeviceId: number | null): Promise<void> {
  const callsEnv = env as CallsEnvironment;
  const calls = await env.DB.prepare(
    `SELECT p.call_id AS callId,c.host_aci=? AS wasHost,p.livekit_identity AS livekitIdentity
       FROM call_participants p JOIN call_sessions c ON c.call_id=p.call_id
      WHERE p.aci=? AND c.state<>'ended' AND p.state IN ('invited','ringing','connecting','joined')
        AND (? IS NULL OR p.claimed_device_id=?)`,
  ).bind(aci, aci, claimedDeviceId, claimedDeviceId).all<{ callId: string; wasHost: number; livekitIdentity: string | null }>();
  for (const call of calls.results) {
    const removedAt = now();
    const statements = [env.DB.prepare(
      "UPDATE call_participants SET state='removed',left_at=? WHERE call_id=? AND aci=? AND state IN ('invited','ringing','connecting','joined')",
    ).bind(removedAt, call.callId, aci),
    env.DB.prepare(
      `UPDATE call_sessions SET call_epoch=call_epoch+1,last_key_rotation_at=? WHERE call_id=? AND state<>'ended'
        AND EXISTS(SELECT 1 FROM call_participants WHERE call_id=? AND aci=? AND state='removed' AND left_at=?)`,
    ).bind(removedAt, call.callId, call.callId, aci, removedAt),
    env.DB.prepare(
      `INSERT INTO call_coordination_events(call_id,recipient_aci,event_type,created_at)
       SELECT ?,NULL,'roster_changed',? WHERE EXISTS(
         SELECT 1 FROM call_participants WHERE call_id=? AND aci=? AND state='removed' AND left_at=?)`,
    ).bind(call.callId, removedAt, call.callId, aci, removedAt)];
    if (call.livekitIdentity) {
      statements.push(conditionalMediaActionStatement(
        env, call.callId, "remove_participant", call.livekitIdentity,
        "EXISTS(SELECT 1 FROM call_participants WHERE call_id=? AND aci=? AND state='removed' AND left_at=?)",
        [call.callId, aci, removedAt],
      ));
    }
    await env.DB.batch(statements);
    if (call.wasHost) await transferHostOrEnd(env, call.callId);
    await finishIfEmpty(env, call.callId);
    await notifyRoster(callsEnv, env, call.callId, "roster_changed");
  }
  await processMediaActions(callsEnv, 25);
}

async function enqueueCallPushes(env: Env, callId: string, invitees: string[]): Promise<void> {
  for (const aci of invitees) {
    await env.DB.prepare("DELETE FROM push_outbox WHERE message_id=? AND aci=? AND kind='call'")
      .bind(callId, aci).run();
    const registrations = await env.DB.prepare("SELECT device_id AS deviceId,provider FROM push_registrations WHERE aci=? AND provider IN ('fcm','apns-voip','apns-voip-sandbox')")
      .bind(aci).all<{ deviceId: number; provider: string }>();
    for (const registration of registrations.results) {
      const outboxId = crypto.randomUUID();
      const inserted = await env.DB.prepare("INSERT OR IGNORE INTO push_outbox(id,message_id,aci,device_id,provider,kind,attempts,created_at) VALUES(?,?,?,?,?,'call',0,?)")
        .bind(outboxId, callId, aci, registration.deviceId, registration.provider, now()).run();
      if ((inserted.meta.changes ?? 0) === 1) await env.PUSH_QUEUE.send({ kind: "push", outboxId });
    }
  }
}

async function notifyRoster(callsEnv: CallsEnvironment, env: Env, callId: string, type: string): Promise<void> {
  const rows = await env.DB.prepare(
    "SELECT aci FROM call_participants WHERE call_id=? AND state<>'removed'",
  ).bind(callId).all<{ aci: string }>();
  await Promise.all(rows.results.map((row) => notifyAccount(callsEnv, row.aci, callId, type)));
}

async function notifyAccount(env: CallsEnvironment, aci: string, callId: string, type: string): Promise<void> {
  const object = env.CALL_EVENTS.get(env.CALL_EVENTS.idFromName(aci));
  await object.publish(JSON.stringify({ protocolVersion: 1, callId, type }));
}

function liveKitSettings(env: CallsEnvironment): { url: string; apiKey: string; apiSecret: string } | null {
  const url = env.LIVEKIT_URL?.trim() ?? "";
  const apiKey = env.LIVEKIT_API_KEY?.trim() ?? "";
  const apiSecret = env.LIVEKIT_API_SECRET?.trim() ?? "";
  if (!url || !apiKey || apiSecret.length < 32) return null;
  let parsed: URL;
  try { parsed = new URL(url); } catch { return null; }
  if (parsed.protocol !== "wss:" || parsed.username || parsed.password || parsed.search || parsed.hash) return null;
  return { url: parsed.toString().replace(/\/$/u, ""), apiKey, apiSecret };
}

function conditionalMediaActionStatement(
  env: Env,
  callId: string,
  actionType: MediaActionRow["actionType"],
  livekitIdentity: string,
  condition: string,
  conditionBindings: string[],
): D1PreparedStatement {
  const timestamp = now();
  return env.DB.prepare(
    `INSERT INTO call_media_actions(action_id,call_id,action_type,livekit_identity,next_attempt_at,created_at)
     SELECT ?,?,?,?,?,? WHERE ${condition}
     ON CONFLICT(call_id,action_type,livekit_identity) DO UPDATE SET
       next_attempt_at=MIN(call_media_actions.next_attempt_at,excluded.next_attempt_at),completed_at=NULL`,
  ).bind(crypto.randomUUID(), callId, actionType, livekitIdentity, timestamp, timestamp, ...conditionBindings);
}

async function processMediaActions(env: CallsEnvironment, limit: number): Promise<number> {
  const settings = liveKitSettings(env);
  if (!settings) return 0;
  const actions = await env.DB.prepare(
    `SELECT a.action_id AS actionId,a.action_type AS actionType,a.livekit_identity AS livekitIdentity,
            a.attempts,c.livekit_room_name AS livekitRoomName
       FROM call_media_actions a JOIN call_sessions c ON c.call_id=a.call_id
      WHERE a.completed_at IS NULL AND a.next_attempt_at<=?
      ORDER BY a.created_at LIMIT ?`,
  ).bind(now(), limit).all<MediaActionRow>();
  let completed = 0;
  for (const action of actions.results) {
    const delaySeconds = Math.min(300, 5 * (2 ** Math.min(action.attempts, 6)));
    const claimed = await env.DB.prepare(
      "UPDATE call_media_actions SET attempts=attempts+1,next_attempt_at=? WHERE action_id=? AND completed_at IS NULL AND next_attempt_at<=?",
    ).bind(new Date(Date.now() + delaySeconds * 1_000).toISOString(), action.actionId, now()).run();
    if ((claimed.meta.changes ?? 0) !== 1) continue;
    const error = await performMediaAction(settings, action);
    if (error === null) {
      await env.DB.prepare("UPDATE call_media_actions SET completed_at=?,last_error=NULL WHERE action_id=?")
        .bind(now(), action.actionId).run();
      completed += 1;
    } else {
      await env.DB.prepare("UPDATE call_media_actions SET last_error=? WHERE action_id=?")
        .bind(error, action.actionId).run();
    }
  }
  return completed;
}

async function performMediaAction(
  settings: { url: string; apiKey: string; apiSecret: string },
  action: MediaActionRow,
): Promise<string | null> {
  const method = action.actionType === "remove_participant" ? "RemoveParticipant" : "DeleteRoom";
  const endpoint = new URL(settings.url);
  endpoint.protocol = "https:";
  endpoint.pathname = `/twirp/livekit.RoomService/${method}`;
  const payload = action.actionType === "remove_participant"
    ? { room: action.livekitRoomName, identity: action.livekitIdentity }
    : { room: action.livekitRoomName };
  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${await liveKitAdminToken(settings, action.livekitRoomName, action.actionType)}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
      redirect: "manual",
      signal: AbortSignal.timeout(2_000),
    });
    if (response.ok || response.status === 404) return null;
    if (response.status === 401 || response.status === 403) return "authorization_failed";
    return "media_api_failed";
  } catch {
    return "transport_failed";
  }
}

async function mediaReady(settings: { url: string }): Promise<boolean> {
  const health = new URL(settings.url);
  health.protocol = "https:";
  health.pathname = "/";
  try {
    const response = await fetch(health, { method: "GET", redirect: "manual", signal: AbortSignal.timeout(2_000) });
    return response.ok;
  } catch {
    return false;
  }
}

async function verifyLiveKitWebhook(
  settings: { apiKey: string; apiSecret: string }, authorization: string, raw: string,
): Promise<void> {
  const token = authorization.startsWith("Bearer ") ? authorization.slice(7) : authorization;
  const parts = token.split(".");
  if (parts.length !== 3 || !parts[0] || !parts[1] || !parts[2]) throw new ApiError(401, "UNAUTHENTICATED");
  let header: Record<string, unknown>;
  let claims: Record<string, unknown>;
  try {
    const parsedHeader: unknown = JSON.parse(new TextDecoder().decode(base64UrlDecode(parts[0])));
    const parsedClaims: unknown = JSON.parse(new TextDecoder().decode(base64UrlDecode(parts[1])));
    if (!isRecord(parsedHeader) || !isRecord(parsedClaims)) throw new Error("invalid jwt");
    header = parsedHeader;
    claims = parsedClaims;
  } catch {
    throw new ApiError(401, "UNAUTHENTICATED");
  }
  const seconds = Math.floor(Date.now() / 1_000);
  if (header.alg !== "HS256" || claims.iss !== settings.apiKey || typeof claims.exp !== "number" ||
      claims.exp < seconds - 10 || (typeof claims.nbf === "number" && claims.nbf > seconds + 10) ||
      typeof claims.sha256 !== "string") throw new ApiError(401, "UNAUTHENTICATED");
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(settings.apiSecret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"],
  );
  const valid = await crypto.subtle.verify(
    "HMAC", key, base64UrlDecode(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  if (!valid) throw new ApiError(401, "UNAUTHENTICATED");
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw)));
  if (!constantTimeEqual(standardBase64(digest), claims.sha256)) throw new ApiError(401, "UNAUTHENTICATED");
}

function webhookParticipantIdentity(event: Record<string, unknown>): string {
  const identity = isRecord(event.participant) && typeof event.participant.identity === "string"
    ? event.participant.identity : "";
  if (!identity) throw new ApiError(400, "INVALID_WEBHOOK_EVENT");
  return identity;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function base64UrlDecode(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/u.test(value)) throw new Error("invalid base64url");
  const padded = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
}

function standardBase64(value: Uint8Array): string {
  let binary = "";
  value.forEach((byte) => { binary += String.fromCharCode(byte); });
  return btoa(binary);
}

function constantTimeEqual(left: string, right: string): boolean {
  const size = Math.max(left.length, right.length);
  let difference = left.length ^ right.length;
  for (let index = 0; index < size; index += 1) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  }
  return difference === 0;
}

async function liveKitToken(settings: { url: string; apiKey: string; apiSecret: string }, room: string, identity: string): Promise<string> {
  if (!identity) throw new ApiError(500, "CALL_IDENTITY_MISSING");
  const issuedAt = Math.floor(Date.now() / 1_000);
  const header = base64UrlJson({ alg: "HS256", typ: "JWT" });
  const payload = base64UrlJson({
    iss: settings.apiKey, sub: identity, aud: settings.url, nbf: issuedAt - 5, exp: issuedAt + 300,
    video: { roomJoin: true, room, canPublish: true, canSubscribe: true, canPublishData: false, roomAdmin: false, roomRecord: false },
  });
  const signingInput = `${header}.${payload}`;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(settings.apiSecret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(signingInput));
  return `${signingInput}.${base64UrlBytes(new Uint8Array(signature))}`;
}

async function liveKitAdminToken(
  settings: { url: string; apiKey: string; apiSecret: string }, room: string,
  actionType: MediaActionRow["actionType"],
): Promise<string> {
  const issuedAt = Math.floor(Date.now() / 1_000);
  const header = base64UrlJson({ alg: "HS256", typ: "JWT" });
  const payload = base64UrlJson({
    iss: settings.apiKey, sub: "ptt-control", aud: settings.url, nbf: issuedAt - 5, exp: issuedAt + 60,
    video: {
      roomJoin: false, room, canPublish: false, canSubscribe: false, canPublishData: false,
      roomCreate: actionType === "delete_room", roomAdmin: actionType === "remove_participant", roomRecord: false,
    },
  });
  const signingInput = `${header}.${payload}`;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(settings.apiSecret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(signingInput));
  return `${signingInput}.${base64UrlBytes(new Uint8Array(signature))}`;
}

function base64UrlJson(value: Record<string, unknown>): string { return base64UrlBytes(new TextEncoder().encode(JSON.stringify(value))); }
function base64UrlBytes(value: Uint8Array): string {
  let binary = "";
  value.forEach((byte) => { binary += String.fromCharCode(byte); });
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}
function randomOpaqueId(): string { return base64UrlBytes(crypto.getRandomValues(new Uint8Array(32))); }
function isCallSeatConflict(error: unknown): boolean {
  return error instanceof Error &&
    error.message.includes("UNIQUE constraint failed: call_participants.aci");
}
function uuidField(value: Record<string, unknown>, key: string): string {
  const field = stringField(value, key, 36);
  if (!UUID.test(field)) throw new ApiError(400, `INVALID_${key.replaceAll(/([A-Z])/g, "_$1").toUpperCase()}`);
  return field.toLowerCase();
}
function uniqueUuidArray(values: unknown[], key: string): string[] {
  const result = values.map((value) => {
    if (typeof value !== "string" || !UUID.test(value)) throw new ApiError(400, `INVALID_${key.toUpperCase()}`);
    return value.toLowerCase();
  });
  if (new Set(result).size !== result.length) throw new ApiError(400, `INVALID_${key.toUpperCase()}`);
  return result;
}
