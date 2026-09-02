import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { MAX_RELAY_CONNECTIONS } from "../src/coordinator";

describe("Cloudflare media relay capacity", () => {
  it("fans one authenticated frame to 255 listeners and rejects connection 257", async () => {
    const channelId = "77777777-7777-4777-8777-777777777777";
    const coordinator = env.CHANNELS.getByName(channelId);
    const sockets: WebSocket[] = [];
    const senderToken = base64Url(new Uint8Array(32).fill(1));

    for (let index = 0; index < MAX_RELAY_CONNECTIONS; index += 1) {
      const response = await coordinator.fetch(mediaRequest(
        channelId,
        index,
        index === 0 ? senderToken : base64Url(new Uint8Array(32).fill((index % 254) + 2)),
      ));
      expect(response.status).toBe(101);
      expect(response.webSocket).not.toBeNull();
      response.webSocket?.accept();
      sockets.push(response.webSocket as WebSocket);
    }

    const overCapacity = await coordinator.fetch(mediaRequest(
      channelId,
      MAX_RELAY_CONNECTIONS,
      base64Url(new Uint8Array(32).fill(255)),
    ));
    expect(overCapacity.status).toBe(503);
    expect(overCapacity.headers.get("retry-after")).toBe("1");
    expect(await overCapacity.json()).toEqual({ code: "RELAY_CAPACITY" });

    const requestToken = base64Url(new Uint8Array(16).fill(7));
    expect(await coordinator.requestFloor(channelId, "load-0:1", requestToken, 1, 10_000, 10))
      .toMatchObject({ granted: true, requestToken });

    const received = sockets.slice(1).map((socket) => nextBinaryMessage(socket));
    const packet = await authenticatedPacket(1, senderToken);
    sockets[0]?.send(packet);
    const frames = await Promise.all(received);
    expect(frames).toHaveLength(MAX_RELAY_CONNECTIONS - 1);
    for (const frame of frames) expect(new Uint8Array(frame)).toEqual(new Uint8Array(packet));

    for (const socket of sockets) socket.close(1000, "capacity-test-complete");
  }, 20_000);

  it("closes authenticated sockets and clears their floor when membership rotates", async () => {
    const channelId = "88888888-8888-4888-8888-888888888888";
    const coordinator = env.CHANNELS.getByName(channelId);
    const response = await coordinator.fetch(mediaRequest(
      channelId, 0, base64Url(new Uint8Array(32).fill(8)), 4,
    ));
    const socket = response.webSocket;
    expect(response.status).toBe(101);
    expect(socket).not.toBeNull();
    socket?.accept();
    const requestToken = base64Url(new Uint8Array(16).fill(9));
    expect(await coordinator.requestFloor(channelId, "load-0:1", requestToken, 1, 10_000, 10))
      .toMatchObject({ granted: true });
    const closed = new Promise<CloseEvent>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("Timed out waiting for membership invalidation")), 1_000);
      socket?.addEventListener("close", (event) => {
        clearTimeout(timeout);
        resolve(event);
      }, { once: true });
    });
    await coordinator.membershipChanged(5);
    expect((await closed).reason).toBe("MEMBERSHIP_CHANGED");
    expect(await coordinator.releaseFloor("load-0:1", requestToken)).toBe(false);
  });

  it("retains the fast-floor rate limit in the hibernation-safe socket attachment", async () => {
    const channelId = "99999999-9999-4999-8999-999999999999";
    const coordinator = env.CHANNELS.getByName(channelId);
    const response = await coordinator.fetch(mediaRequest(
      channelId, 0, base64Url(new Uint8Array(32).fill(9)), 1,
    ));
    const socket = response.webSocket;
    expect(response.status).toBe(101);
    expect(socket).not.toBeNull();
    socket?.accept();
    const requestToken = base64Url(new Uint8Array(16).fill(10));
    const request = JSON.stringify({
      type: "floor.request",
      requestToken,
      membershipEpoch: 1,
      requestedTotMs: 10_000,
      sos: false,
    });
    for (let attempt = 1; attempt <= 600; attempt += 1) {
      const result = nextTextMessage(socket as WebSocket);
      socket?.send(request);
      expect(await result).toMatchObject({ type: "floor.result", granted: true, requestToken });
    }
    const rejected = nextTextMessage(socket as WebSocket);
    socket?.send(request);
    expect(await rejected).toMatchObject({ type: "floor.error", requestToken, code: "RATE_LIMITED" });
    socket?.close(1000, "rate-limit-test-complete");
  });
});

function mediaRequest(channelId: string, index: number, demuxToken: string, membershipEpoch = 1): Request {
  return new Request(`https://ptt.test/v1/media/tunnel?channelId=${channelId}`, {
    headers: {
      Upgrade: "websocket",
      "X-PTT-Aci": `load-${index}`,
      "X-PTT-Access-Hash": index.toString(16).padStart(64, "0"),
      "X-PTT-Channel": channelId,
      "X-PTT-Device": "1",
      "X-PTT-Sender-Demux": String(index + 1),
      "X-PTT-Demux-Token": demuxToken,
      "X-PTT-Membership-Epoch": String(membershipEpoch),
      "X-PTT-Relay-Expires-At": String(Date.now() + 60_000),
      "X-PTT-Role": "talk",
    },
  });
}

function nextBinaryMessage(socket: WebSocket): Promise<ArrayBuffer> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Timed out waiting for relay fan-out")), 5_000);
    socket.addEventListener("message", (event) => {
      clearTimeout(timeout);
      if (typeof event.data === "string") reject(new Error("Expected binary media"));
      else new Response(event.data).arrayBuffer().then(resolve, reject);
    }, { once: true });
  });
}

function nextTextMessage(socket: WebSocket): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Timed out waiting for floor response")), 5_000);
    socket.addEventListener("message", (event) => {
      clearTimeout(timeout);
      if (typeof event.data !== "string") reject(new Error("Expected text floor response"));
      else resolve(JSON.parse(event.data) as Record<string, unknown>);
    }, { once: true });
  });
}

async function authenticatedPacket(senderDemux: number, demuxToken: string): Promise<ArrayBuffer> {
  const packet = new Uint8Array(160);
  packet[0] = 1;
  packet[1] = 0x08;
  new DataView(packet.buffer).setUint32(2, senderDemux, false);
  crypto.getRandomValues(packet.subarray(16, 152));
  const key = await crypto.subtle.importKey(
    "raw",
    base64UrlBytes(demuxToken),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, packet.subarray(0, 152)));
  packet.set(digest.subarray(0, 8), 152);
  return packet.buffer;
}

function base64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function base64UrlBytes(value: string): Uint8Array {
  const padded = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
}
