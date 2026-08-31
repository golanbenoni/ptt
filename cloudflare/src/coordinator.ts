import { DurableObject } from "cloudflare:workers";
import { base64UrlToBytes } from "./crypto";
import { now } from "./db";
import { ApiError } from "./http";

type SocketAttachment = {
  aci: string;
  accessTokenHash: string;
  channelId: string;
  deviceId: number;
  demuxToken: string;
  senderDemux: number;
};

type FloorState = {
  owner: string;
  requestToken: string;
  priority: number;
  senderDemux: number;
  expiresAt: number;
  grantedTotMs: number;
};

export type FloorResult = {
  granted: boolean;
  requestToken: string;
  grantedTotMs: number;
  priority: number;
  reason?: string;
};

const MEDIA_BYTES = 160;
const AUTHENTICATED_BYTES = 152;

export class ChannelCoordinator extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async requestFloor(
    owner: string,
    requestToken: string,
    senderDemux: number,
    requestedTotMs: number,
    priority: number,
  ): Promise<FloorResult> {
    const now = Date.now();
    const current = await this.ctx.storage.get<FloorState>("floor");
    if (current && current.expiresAt > now && current.owner !== owner && current.priority >= priority) {
      return {
        granted: false,
        requestToken,
        grantedTotMs: current.grantedTotMs,
        priority: current.priority,
        reason: "FLOOR_BUSY",
      };
    }
    const grantedTotMs = Math.min(Math.max(requestedTotMs, 1_000), 30_000);
    const next: FloorState = {
      owner,
      requestToken,
      priority,
      senderDemux,
      grantedTotMs,
      expiresAt: now + grantedTotMs,
    };
    await this.ctx.storage.put("floor", next);
    await this.ctx.storage.setAlarm(next.expiresAt);
    return { granted: true, requestToken, grantedTotMs, priority };
  }

  async releaseFloor(owner: string, requestToken: string): Promise<boolean> {
    const current = await this.ctx.storage.get<FloorState>("floor");
    if (!current || current.owner !== owner || current.requestToken !== requestToken) return false;
    await this.ctx.storage.delete("floor");
    await this.ctx.storage.deleteAlarm();
    return true;
  }

  override async alarm(): Promise<void> {
    const current = await this.ctx.storage.get<FloorState>("floor");
    if (current && current.expiresAt <= Date.now()) await this.ctx.storage.delete("floor");
  }

  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("WebSocket required", { status: 426 });
    }
    const attachment: SocketAttachment = {
      aci: requiredHeader(request, "X-PTT-Aci"),
      accessTokenHash: requiredHexHeader(request, "X-PTT-Access-Hash", 64),
      channelId: requiredHeader(request, "X-PTT-Channel"),
      deviceId: positiveIntegerHeader(request, "X-PTT-Device"),
      demuxToken: requiredHeader(request, "X-PTT-Demux-Token"),
      senderDemux: positiveIntegerHeader(request, "X-PTT-Sender-Demux"),
    };
    base64UrlToBytes(attachment.demuxToken, 32, 32);
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.serializeAttachment(attachment);
    this.ctx.acceptWebSocket(server);
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message === "string") {
      await this.handleControlMessage(socket, message);
      return;
    }
    if (!(message instanceof ArrayBuffer) || message.byteLength !== MEDIA_BYTES) {
      socket.close(1003, "INVALID_MEDIA_DATAGRAM");
      return;
    }
    const attachment = socket.deserializeAttachment() as SocketAttachment | null;
    if (!attachment || !(await validPacket(new Uint8Array(message), attachment))) {
      socket.close(1008, "MEDIA_AUTHENTICATION_FAILED");
      return;
    }
    const floor = await this.ctx.storage.get<FloorState>("floor");
    const owner = `${attachment.aci}:${attachment.deviceId}`;
    if (
      !floor || floor.expiresAt <= Date.now() || floor.owner !== owner
      || floor.senderDemux !== attachment.senderDemux
    ) {
      socket.close(1008, "FLOOR_NOT_HELD");
      return;
    }
    for (const peer of this.ctx.getWebSockets()) {
      if (peer === socket) continue;
      const other = peer.deserializeAttachment() as SocketAttachment | null;
      if (other?.aci === attachment.aci && other.deviceId === attachment.deviceId) continue;
      try {
        peer.send(message);
      } catch {
        peer.close(1011, "DELIVERY_FAILED");
      }
    }
  }

  private async handleControlMessage(socket: WebSocket, message: string): Promise<void> {
    if (message.length > 512) {
      socket.close(1003, "INVALID_CONTROL_MESSAGE");
      return;
    }
    let value: unknown;
    try { value = JSON.parse(message); }
    catch {
      socket.close(1003, "INVALID_CONTROL_MESSAGE");
      return;
    }
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      socket.close(1003, "INVALID_CONTROL_MESSAGE");
      return;
    }
    const record = value as Record<string, unknown>;
    const requestToken = record.requestToken;
    if (
      record.type !== "floor.request" || typeof requestToken !== "string"
      || requestToken.length > 64 || !Number.isSafeInteger(record.membershipEpoch)
      || (record.membershipEpoch as number) < 1
      || (record.membershipEpoch as number) > 2_147_483_647
      || !Number.isSafeInteger(record.requestedTotMs)
      || (record.requestedTotMs as number) < 1_000 || (record.requestedTotMs as number) > 30_000
      || typeof record.sos !== "boolean"
    ) {
      socket.close(1003, "INVALID_CONTROL_MESSAGE");
      return;
    }
    try { base64UrlToBytes(requestToken, 16, 16); }
    catch {
      socket.close(1003, "INVALID_CONTROL_MESSAGE");
      return;
    }
    const attachment = socket.deserializeAttachment() as SocketAttachment | null;
    if (!attachment) {
      socket.close(1008, "MEDIA_AUTHENTICATION_FAILED");
      return;
    }
    try {
      const [authorized] = await Promise.all([
        this.env.DB.prepare(
          `SELECT m.role AS role,c.membership_epoch AS membershipEpoch
             FROM devices d
             JOIN accounts a ON a.aci=d.aci
             JOIN memberships m ON m.aci=d.aci AND m.channel_id=? AND m.left_epoch IS NULL
             JOIN channels c ON c.channel_id=m.channel_id
             JOIN relay_leases r ON r.channel_id=m.channel_id AND r.aci=d.aci
               AND r.device_id=d.device_id AND r.sender_demux=? AND r.expires_at>?
            WHERE d.aci=? AND d.device_id=? AND d.access_token_hash=?
              AND d.status='active' AND a.disabled_at IS NULL
            LIMIT 1`,
        ).bind(
          attachment.channelId, attachment.senderDemux, now(), attachment.aci,
          attachment.deviceId, attachment.accessTokenHash,
        ).first<{ role: string; membershipEpoch: number }>(),
        this.enforceFloorRate(attachment.accessTokenHash),
      ]);
      if (!authorized) throw new ApiError(401, "UNAUTHENTICATED");
      if (authorized.membershipEpoch !== record.membershipEpoch) {
        throw new ApiError(409, "MEMBERSHIP_EPOCH_MISMATCH");
      }
      if (authorized.role === "listen") throw new ApiError(403, "TALK_NOT_PERMITTED");
      const priority = record.sos === true ? 100
        : (authorized.role === "barge" || authorized.role === "dispatch" ? 20 : 10);
      const result = await this.requestFloor(
        `${attachment.aci}:${attachment.deviceId}`,
        requestToken,
        attachment.senderDemux,
        record.requestedTotMs as number,
        priority,
      );
      socket.send(JSON.stringify({ type: "floor.result", ...result }));
    } catch (error) {
      const code = error instanceof ApiError ? error.code : "INTERNAL";
      socket.send(JSON.stringify({ type: "floor.error", requestToken, code }));
    }
  }

  private async enforceFloorRate(accessTokenHash: string): Promise<void> {
    const windowStart = Math.floor(Date.now() / 60_000);
    const key = `floor-rate:${accessTokenHash}`;
    const current = await this.ctx.storage.get<{ windowStart: number; attempts: number }>(key);
    const next = current?.windowStart === windowStart
      ? { windowStart, attempts: current.attempts + 1 }
      : { windowStart, attempts: 1 };
    await this.ctx.storage.put(key, next);
    if (next.attempts > 600) throw new ApiError(429, "RATE_LIMITED");
  }

  override webSocketError(socket: WebSocket): void {
    socket.close(1011, "MEDIA_SOCKET_ERROR");
  }
}

function requiredHeader(request: Request, name: string): string {
  const value = request.headers.get(name);
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}

function positiveIntegerHeader(request: Request, name: string): number {
  const value = Number(requiredHeader(request, name));
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error(`Invalid ${name}`);
  return value;
}

function requiredHexHeader(request: Request, name: string, length: number): string {
  const value = requiredHeader(request, name);
  if (value.length !== length || !/^[0-9a-f]+$/u.test(value)) throw new Error(`Invalid ${name}`);
  return value;
}

async function validPacket(packet: Uint8Array, attachment: SocketAttachment): Promise<boolean> {
  if (
    packet[0] !== 1 ||
    packet[1] === undefined ||
    (packet[1] & 0x08) === 0 ||
    (packet[1] & 0xf0) !== 0 ||
    packet[14] !== 0 ||
    packet[15] !== 0
  ) return false;
  const senderDemux = new DataView(packet.buffer, packet.byteOffset + 2, 4).getUint32(0, false);
  if (senderDemux === 0 || senderDemux !== attachment.senderDemux) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    base64UrlToBytes(attachment.demuxToken, 32, 32),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, packet.subarray(0, AUTHENTICATED_BYTES)));
  return crypto.subtle.timingSafeEqual(digest.subarray(0, 8), packet.subarray(AUTHENTICATED_BYTES));
}
