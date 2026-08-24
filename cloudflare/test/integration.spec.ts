import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

type Enrollment = { aci: string; deviceId: number; mailboxId: string; accessToken: string };

describe("PTT Cloudflare API", () => {
  it("serves public documents to GET and HEAD health checks", async () => {
    for (const path of ["/", "/privacy", "/admin/"]) {
      const getResponse = await exports.default.fetch(`https://ptt.test${path}`);
      expect(getResponse.status).toBe(200);
      const headResponse = await exports.default.fetch(`https://ptt.test${path}`, { method: "HEAD" });
      expect(headResponse.status).toBe(200);
    }
  });

  it("exercises enrollment, two devices, encrypted delivery, history, and floor control", async () => {
    const health = await exports.default.fetch("https://ptt.test/healthz");
    expect(health.status).toBe(200);
    expect(await health.json()).toMatchObject({ status: "ok", protocolMajor: 1 });

    const bootstrap = await post("/v1/bootstrap", {
      email: "admin@example.com",
      bootstrapToken: "local-test-bootstrap",
    });
    expect(bootstrap.status).toBe(200);

    const queued = await env.DB.prepare("SELECT payload FROM email_outbox WHERE recipient=?")
      .bind("admin@example.com").first<{ payload: string }>();
    expect(queued).not.toBeNull();
    const payload = JSON.parse(queued?.payload ?? "{}") as { url?: string };
    const token = new URL(payload.url ?? "https://invalid/#").hash.match(/token=([^&]+)/u)?.[1];
    expect(token).toBeTruthy();

    const identityKey = base64Url(new Uint8Array(32).fill(7));
    const enrollment = await post("/v1/auth/magic-link/consume", {
      token,
      deviceName: "Test iPhone",
      identityKey,
    });
    expect(enrollment.status).toBe(200);
    const session = await enrollment.json<Enrollment>();
    expect(session).toMatchObject({ deviceId: 1 });

    const members = await get("/v1/admin/members", session.accessToken);
    expect(members.status).toBe(200);
    expect(await members.json()).toMatchObject([{ email: "admin@example.com", isAdmin: 1 }]);

    const channel = await post("/v1/admin/channels", {
      displayName: "Operations",
      kind: "team",
      retentionDays: 30,
      members: [{ aci: session.aci, role: "talk" }],
    }, session.accessToken);
    expect(channel.status).toBe(200);
    const channelValue = await channel.json<{ channelId: string; membershipEpoch: number }>();

    const credential = await post("/v1/relay/credentials", { channelId: channelValue.channelId }, session.accessToken);
    expect(credential.status).toBe(200);
    const relay = await credential.json<{ senderDemux: number; relayAddress: string }>();
    expect(relay.relayAddress).toBe("tls-only://cloudflare");

    const requestToken = base64Url(new Uint8Array(16).fill(11));
    const floor = await post("/v1/floor/request", {
      channelId: channelValue.channelId,
      requestToken,
      senderDemux: relay.senderDemux,
      membershipEpoch: channelValue.membershipEpoch,
      requestedTotMs: 10_000,
      sos: false,
    }, session.accessToken);
    expect(floor.status).toBe(200);
    expect(await floor.json()).toMatchObject({ granted: true, requestToken, grantedTotMs: 10_000 });

    const released = await post("/v1/floor/release", { channelId: channelValue.channelId, requestToken }, session.accessToken);
    expect(released.status).toBe(200);

    const invitation = await post("/v1/admin/invitations", { email: "operator@example.com" }, session.accessToken);
    expect(invitation.status).toBe(200);
    const operatorToken = await latestEmailToken("operator@example.com");
    const operatorEnrollment = await post("/v1/auth/magic-link/consume", {
      token: operatorToken,
      deviceName: "Operator Pixel",
      identityKey: base64Url(new Uint8Array(32).fill(13)),
    });
    expect(operatorEnrollment.status).toBe(200);
    const operator = await operatorEnrollment.json<Enrollment>();

    const membership = await post("/v1/admin/channels/membership", {
      channelId: channelValue.channelId,
      aci: operator.aci,
      role: "talk",
    }, session.accessToken);
    expect(membership.status).toBe(200);

    const prekeyUpload = await post("/v1/prekeys/upload", {
      opaqueBundle: base64Url(new Uint8Array(64).fill(21)),
      oneTimePrekeys: [
        { kind: "x25519", keyId: 101, publicKey: base64Url(new Uint8Array(32).fill(22)) },
        { kind: "kyber", keyId: 202, publicKey: base64Url(new Uint8Array(64).fill(23)) },
      ],
    }, operator.accessToken);
    expect(prekeyUpload.status).toBe(200);
    const prekeys = await post("/v1/prekeys/fetch", {
      devices: [{ aci: operator.aci, deviceId: 1 }],
    }, session.accessToken);
    expect(prekeys.status).toBe(200);
    expect(await prekeys.json()).toMatchObject([{
      aci: operator.aci,
      deviceId: 1,
      oneTimePrekeys: [{ kind: "x25519", keyId: 101 }, { kind: "kyber", keyId: 202 }],
    }]);

    const linkStart = await post("/v1/devices/link/start", {}, operator.accessToken);
    expect(linkStart.status).toBe(200);
    const link = await linkStart.json<{ requestId: string; linkCode: string }>();
    const linkClaim = await post("/v1/devices/link/claim", {
      ...link,
      deviceName: "Operator iPad",
      identityKey: base64Url(new Uint8Array(32).fill(31)),
    });
    expect(linkClaim.status).toBe(200);
    const claim = await linkClaim.json<{ claimToken: string; deviceId: number; mailboxId: string }>();
    expect(claim.deviceId).toBe(2);
    expect(await (await post("/v1/devices/link/status", { claimToken: claim.claimToken })).json())
      .toMatchObject({ status: "pending", deviceId: 2 });
    expect((await post("/v1/devices/link/approve", { requestId: link.requestId }, operator.accessToken)).status).toBe(200);
    const linked = await post("/v1/devices/link/status", { claimToken: claim.claimToken });
    expect(linked.status).toBe(200);
    const linkedDevice = await linked.json<Enrollment & { status: string }>();
    expect(linkedDevice).toMatchObject({ status: "active", accessToken: claim.claimToken, deviceId: 2 });
    expect(await (await get("/v1/devices", operator.accessToken)).json()).toHaveLength(2);

    const fcmToken = base64Url(new TextEncoder().encode("fcm-test-registration-token-123456"));
    expect((await post("/v1/push/registrations", { provider: "fcm", token: fcmToken }, linkedDevice.accessToken)).status).toBe(200);
    expect((await post("/v1/push/registrations", { provider: "fcm", token: fcmToken }, session.accessToken)).status).toBe(409);

    const messageId = crypto.randomUUID();
    const envelope = base64Url(new Uint8Array([8, 6, 7, 5, 3, 0, 9]));
    const mailboxPut = await post("/v1/mailbox/envelopes", {
      messageId,
      expiresAt: new Date(Date.now() + 60_000).toISOString(),
      recipients: [{ aci: operator.aci, deviceId: 2, envelope }],
    }, session.accessToken);
    expect(mailboxPut.status).toBe(200);
    expect(await env.DB.prepare("SELECT count(*) AS count FROM push_outbox WHERE message_id=?")
      .bind(messageId).first<{ count: number }>()).toMatchObject({ count: 1 });
    const mailbox = await get("/v1/mailbox/items", linkedDevice.accessToken);
    expect(mailbox.status).toBe(200);
    const items = await mailbox.json<Array<{ itemId: string; messageId: string; envelope: string }>>();
    expect(items).toMatchObject([{ messageId, envelope }]);
    expect((await post("/v1/mailbox/ack", { itemIds: [items[0]?.itemId] }, linkedDevice.accessToken)).status).toBe(200);
    expect(await (await get("/v1/mailbox/items", linkedDevice.accessToken)).json()).toEqual([]);

    const channels = await get("/v1/channels", session.accessToken);
    const activeChannel = (await channels.json<Array<{ channelId: string; membershipEpoch: number }>>())
      .find((candidate) => candidate.channelId === channelValue.channelId);
    expect(activeChannel?.membershipEpoch).toBe(3);
    const talkId = crypto.randomUUID();
    const ciphertext = base64Url(new Uint8Array(384).fill(44));
    const historyPut = await post("/v1/history/objects", {
      talkId,
      channelId: channelValue.channelId,
      membershipEpoch: activeChannel?.membershipEpoch,
      mediaKid: "42",
      startedAt: new Date().toISOString(),
      durationMs: 2_000,
      ciphertext,
    }, operator.accessToken);
    expect(historyPut.status).toBe(200);
    const historyMetadata = await historyPut.json<{ objectId: string; ciphertextBytes: number }>();
    expect(historyMetadata.ciphertextBytes).toBe(384);
    const historyList = await get(`/v1/history/objects?channelId=${channelValue.channelId}`, linkedDevice.accessToken);
    expect(await historyList.json()).toMatchObject([{ objectId: historyMetadata.objectId, talkId }]);
    const historyDownload = await get(`/v1/history/objects/${historyMetadata.objectId}`, linkedDevice.accessToken);
    expect(await historyDownload.json()).toMatchObject({ ciphertext });

    const relayOneResponse = await post("/v1/relay/credentials", { channelId: channelValue.channelId }, operator.accessToken);
    const relayTwoResponse = await post("/v1/relay/credentials", { channelId: channelValue.channelId }, linkedDevice.accessToken);
    const relayOne = await relayOneResponse.json<{ senderDemux: number; demuxToken: string }>();
    const relayTwo = await relayTwoResponse.json<{ senderDemux: number; demuxToken: string }>();
    const socketOneResponse = await openMedia(channelValue.channelId, operator.accessToken);
    const socketTwoResponse = await openMedia(channelValue.channelId, linkedDevice.accessToken);
    expect(socketOneResponse.status).toBe(101);
    expect(socketTwoResponse.status).toBe(101);
    const socketOne = socketOneResponse.webSocket;
    const socketTwo = socketTwoResponse.webSocket;
    expect(socketOne).not.toBeNull();
    expect(socketTwo).not.toBeNull();
    socketOne?.accept();
    socketTwo?.accept();
    const mediaPacket = await authenticatedMediaPacket(relayOne.senderDemux, relayOne.demuxToken);
    const received = new Promise<ArrayBuffer>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("Timed out waiting for relayed media")), 1_000);
      socketTwo?.addEventListener("message", (event) => {
        clearTimeout(timeout);
        if (typeof event.data === "string") reject(new Error("Expected binary relayed media"));
        else new Response(event.data).arrayBuffer().then(resolve, reject);
      }, { once: true });
    });
    socketOne?.send(mediaPacket);
    expect(new Uint8Array(await received)).toEqual(new Uint8Array(mediaPacket));
    socketOne?.close(1000, "done");
    socketTwo?.close(1000, "done");

    expect(relayTwo.senderDemux).not.toBe(relayOne.senderDemux);

    expect((await post("/v1/devices/revoke", { deviceId: 2 }, operator.accessToken)).status).toBe(200);
    expect((await get("/v1/devices", linkedDevice.accessToken)).status).toBe(401);
    const channelsAfterRevocation = await get("/v1/channels", operator.accessToken);
    expect(await channelsAfterRevocation.json()).toMatchObject([{ channelId: channelValue.channelId, membershipEpoch: 4 }]);
  });

  it("does not disclose unknown recovery accounts", async () => {
    const response = await post("/v1/auth/recovery/request", { email: "missing@example.com" });
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({ accepted: true });
  });

  it("rejects malformed media before opening a coordinator", async () => {
    const response = await exports.default.fetch("https://ptt.test/v1/media/tunnel?channelId=bad", {
      headers: { Upgrade: "websocket" },
    });
    expect(response.status).toBe(401);
  });
});

function post(path: string, value: unknown, accessToken?: string): Promise<Response> {
  return exports.default.fetch(`https://ptt.test${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
    },
    body: JSON.stringify(value),
  });
}

function get(path: string, accessToken: string): Promise<Response> {
  return exports.default.fetch(`https://ptt.test${path}`, { headers: { Authorization: `Bearer ${accessToken}` } });
}

function openMedia(channelId: string, accessToken: string): Promise<Response> {
  return exports.default.fetch(`https://ptt.test/v1/media/tunnel?channelId=${channelId}`, {
    headers: { Authorization: `Bearer ${accessToken}`, Upgrade: "websocket" },
  });
}

function base64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

async function latestEmailToken(recipient: string): Promise<string> {
  const queued = await env.DB.prepare(
    "SELECT payload FROM email_outbox WHERE recipient=? ORDER BY created_at DESC LIMIT 1",
  ).bind(recipient).first<{ payload: string }>();
  const payload = JSON.parse(queued?.payload ?? "{}") as { url?: string };
  const token = new URL(payload.url ?? "https://invalid/#").hash.match(/token=([^&]+)/u)?.[1];
  if (!token) throw new Error(`Missing enrollment token for ${recipient}`);
  return token;
}

async function authenticatedMediaPacket(senderDemux: number, demuxToken: string): Promise<ArrayBuffer> {
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

function base64UrlBytes(value: string): Uint8Array {
  const padded = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
}
