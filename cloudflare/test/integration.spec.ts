import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { httpsRedirect } from "../src/index";

type Enrollment = { aci: string; deviceId: number; mailboxId: string; accessToken: string };

describe("PTT Cloudflare API", () => {
  it("serves public documents to GET and HEAD health checks", async () => {
    for (const path of ["/", "/privacy", "/admin/", "/link-device"]) {
      const getResponse = await exports.default.fetch(`https://ptt.test${path}`);
      expect(getResponse.status).toBe(200);
      expect(getResponse.headers.get("strict-transport-security")).toContain("max-age=");
      expect(getResponse.headers.get("x-frame-options")).toBe("DENY");
      const headResponse = await exports.default.fetch(`https://ptt.test${path}`, { method: "HEAD" });
      expect(headResponse.status).toBe(200);
    }
    const homepage = await exports.default.fetch("https://ptt.test/");
    expect(await homepage.text()).toContain("Press. Speak.");
    expect(homepage.headers.get("content-security-policy")).toContain("img-src 'self'");
    const websiteStyles = await exports.default.fetch("https://ptt.test/site/style.css");
    expect(websiteStyles.status).toBe(200);
    expect(websiteStyles.headers.get("content-type")).toContain("text/css");
    const redirect = httpsRedirect(new URL("http://ptt.test/admin/?next=1"));
    expect(redirect?.status).toBe(308);
    expect(redirect?.headers.get("location")).toBe("https://ptt.test/admin/?next=1");
    expect(httpsRedirect(new URL("https://ptt.test/admin/"))).toBeNull();
    const apple = await exports.default.fetch("https://ptt.test/.well-known/apple-app-site-association");
    expect(await apple.json()).toMatchObject({
      applinks: { details: [{ appIDs: ["M2M4752Z6K.app.ptt.talk"], components: expect.arrayContaining([{ "/": "/link-device" }]) }] },
    });
    const android = await exports.default.fetch("https://ptt.test/.well-known/assetlinks.json");
    expect(await android.json()).toMatchObject([{ target: { package_name: "app.ptt.talk" } }]);
  });

  it("exercises enrollment, two devices, encrypted delivery, history, and floor control", async () => {
    const health = await exports.default.fetch("https://ptt.test/healthz");
    expect(health.status).toBe(200);
    expect(await health.json()).toMatchObject({
      status: "ok",
      protocolMajor: 1,
      protocolMinor: 1,
      minimumClientMajor: 1,
      minimumClientMinor: 0,
      capabilities: expect.arrayContaining([
        "chat-encrypted-thumbnails-v1",
        "chat-resumable-transfers-v1",
        "media-tls-v1",
      ]),
    });

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
    const resumeSecret = base64Url(new Uint8Array(32).fill(9));
    const enrollment = await post("/v1/auth/magic-link/consume", {
      token,
      deviceName: "Test iPhone",
      identityKey,
      resumeSecret,
    });
    expect(enrollment.status).toBe(200);
    const initialSession = await enrollment.json<Enrollment>();
    expect(initialSession).toMatchObject({ deviceId: 1 });

    const stolenRetry = await post("/v1/auth/magic-link/consume", {
      token,
      deviceName: "Test iPhone",
      identityKey,
      resumeSecret: base64Url(new Uint8Array(32).fill(10)),
    });
    expect(stolenRetry.status).toBe(410);
    expect((await get("/v1/admin/members", initialSession.accessToken)).status).toBe(200);

    // If the HTTP response is lost after D1 commits, the same phone can retry
    // the still-valid link with its original identity key and recover safely.
    const resumedEnrollment = await post("/v1/auth/magic-link/consume", {
      token,
      deviceName: "Test iPhone",
      identityKey,
      resumeSecret,
    });
    expect(resumedEnrollment.status).toBe(200);
    const session = await resumedEnrollment.json<Enrollment>();
    expect(session).toMatchObject({
      aci: initialSession.aci,
      deviceId: initialSession.deviceId,
      mailboxId: initialSession.mailboxId,
    });
    expect(session.accessToken).not.toBe(initialSession.accessToken);
    expect((await get("/v1/admin/members", initialSession.accessToken)).status).toBe(401);

    const otherDeviceRetry = await post("/v1/auth/magic-link/consume", {
      token,
      deviceName: "Other iPhone",
      identityKey: base64Url(new Uint8Array(32).fill(8)),
      resumeSecret: base64Url(new Uint8Array(32).fill(10)),
    });
    expect(otherDeviceRetry.status).toBe(410);

    const members = await get("/v1/admin/members", session.accessToken);
    expect(members.status).toBe(200);
    expect(await members.json()).toMatchObject([{ email: "admin@example.com", isAdmin: 1 }]);

    const handoffResponse = await post("/v1/admin/session/start", {}, session.accessToken);
    expect(handoffResponse.status).toBe(200);
    const handoff = await handoffResponse.json<{ adminUrl: string; handoffCode: string; expiresAt: string }>();
    expect(new URL(handoff.adminUrl).hash).toBe(`#handoff=${handoff.handoffCode}`);
    expect(new Date(handoff.expiresAt).getTime()).toBeGreaterThan(Date.now());
    const browserSessionResponse = await post("/v1/admin/session/consume", { handoffCode: handoff.handoffCode });
    expect(browserSessionResponse.status).toBe(200);
    const browserSession = await browserSessionResponse.json<{ sessionToken: string; expiresAt: string }>();
    expect((await get("/v1/admin/members", browserSession.sessionToken)).status).toBe(200);
    expect((await get("/v1/devices", browserSession.sessionToken)).status).toBe(401);
    expect((await post("/v1/admin/session/consume", { handoffCode: handoff.handoffCode })).status).toBe(410);

    const channel = await post("/v1/admin/channels", {
      displayName: "Operations",
      kind: "team",
      retentionDays: 30,
      members: [{ aci: session.aci, role: "talk" }],
    }, browserSession.sessionToken);
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
      resumeSecret: base64Url(new Uint8Array(32).fill(14)),
    });
    expect(operatorEnrollment.status).toBe(200);
    const operator = await operatorEnrollment.json<Enrollment>();
    expect((await post("/v1/admin/session/start", {}, operator.accessToken)).status).toBe(403);

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
    expect((await post("/v1/prekeys/upload", {
      opaqueBundle: base64Url(new Uint8Array(64).fill(21)),
      oneTimePrekeys: [
        { kind: "x25519", keyId: 303, publicKey: base64Url(new Uint8Array(32).fill(24)) },
      ],
    }, operator.accessToken)).status).toBe(200);
    const concurrent = await Promise.all([
      post("/v1/prekeys/fetch", { devices: [{ aci: operator.aci, deviceId: 1 }] }, session.accessToken),
      post("/v1/prekeys/fetch", { devices: [{ aci: operator.aci, deviceId: 1 }] }, session.accessToken),
    ]);
    const concurrentKeys = (await Promise.all(concurrent.map((response) =>
      response.json<Array<{ oneTimePrekeys: { keyId: number }[] }>>(),
    )))
      .flatMap((response) => response[0]?.oneTimePrekeys ?? [])
      .filter((key) => key.keyId === 303);
    expect(concurrentKeys).toHaveLength(1);

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

    const chatMessageId = crypto.randomUUID();
    const chatEnvelope = base64Url(new Uint8Array([80, 84, 84, 67, 1, 4, 3, 2, 1]));
    const chatPut = await post("/v1/chat/messages", {
      messageId: chatMessageId,
      channelId: channelValue.channelId,
      membershipEpoch: activeChannel?.membershipEpoch,
      expiresAt: new Date(Date.now() + 60_000).toISOString(),
      recipients: [{ aci: operator.aci, deviceId: 2, envelope: chatEnvelope }],
    }, operator.accessToken);
    expect(chatPut.status).toBe(200);
    expect(await chatPut.json()).toEqual({ acceptedRecipients: 1 });
    const chatPoll = await get("/v1/chat/messages", linkedDevice.accessToken);
    const chatItems = await chatPoll.json<Array<{ itemId: string; messageId: string; envelope: string }>>();
    expect(chatItems).toMatchObject([{ messageId: chatMessageId, envelope: chatEnvelope }]);
    expect((await post("/v1/chat/ack", { itemIds: [chatItems[0]?.itemId] }, linkedDevice.accessToken)).status).toBe(200);
    expect(await (await get("/v1/chat/messages", linkedDevice.accessToken)).json()).toEqual([]);

    const attachmentId = crypto.randomUUID();
    const attachmentCiphertext = new Uint8Array([80, 84, 84, 65, 1, 9, 8, 7, 6, 5, 4, 3, 2, 1]);
    const attachmentDigest = await sha256(attachmentCiphertext);
    const attachmentUpload = await exports.default.fetch(
      `https://ptt.test/v1/chat/attachments/${attachmentId}?channelId=${channelValue.channelId}&membershipEpoch=${activeChannel?.membershipEpoch}`,
      {
        method: "PUT",
        headers: {
          Authorization: `Bearer ${operator.accessToken}`,
          "Content-Type": "application/octet-stream",
          "Content-Length": String(attachmentCiphertext.byteLength),
          "X-Ciphertext-SHA256": attachmentDigest,
        },
        body: attachmentCiphertext,
      },
    );
    expect(attachmentUpload.status).toBe(200);
    const attachmentRetry = await exports.default.fetch(
      `https://ptt.test/v1/chat/attachments/${attachmentId}?channelId=${channelValue.channelId}&membershipEpoch=${activeChannel?.membershipEpoch}`,
      {
        method: "PUT",
        headers: {
          Authorization: `Bearer ${operator.accessToken}`,
          "Content-Type": "application/octet-stream",
          "Content-Length": String(attachmentCiphertext.byteLength),
          "X-Ciphertext-SHA256": attachmentDigest,
        },
        body: attachmentCiphertext,
      },
    );
    expect(attachmentRetry.status).toBe(200);
    const attachmentDownload = await get(`/v1/chat/attachments/${attachmentId}`, linkedDevice.accessToken);
    expect(attachmentDownload.status).toBe(200);
    expect(attachmentDownload.headers.get("x-ciphertext-sha256")).toBe(attachmentDigest);
    expect(new Uint8Array(await attachmentDownload.arrayBuffer())).toEqual(attachmentCiphertext);

    const resumableAttachmentId = crypto.randomUUID();
    const resumableCiphertext = new Uint8Array(1_048_576 + 17);
    resumableCiphertext.forEach((_value, index) => { resumableCiphertext[index] = index % 251; });
    const resumableDigest = await sha256(resumableCiphertext);
    const resumableCreate = await post(`/v1/chat/attachments/${resumableAttachmentId}/uploads`, {
      channelId: channelValue.channelId,
      membershipEpoch: activeChannel?.membershipEpoch,
      ciphertextBytes: resumableCiphertext.byteLength,
      ciphertextSha256: resumableDigest,
    }, operator.accessToken);
    expect(resumableCreate.status).toBe(200);
    const resumable = await resumableCreate.json<{
      state: string; uploadId: string; partSize: number; uploadedParts: unknown[];
    }>();
    expect(resumable).toMatchObject({ state: "uploading", partSize: 1_048_576, uploadedParts: [] });
    const firstPart = resumableCiphertext.slice(0, resumable.partSize);
    const firstPartDigest = await sha256(firstPart);
    const firstPartUpload = await exports.default.fetch(
      `https://ptt.test/v1/chat/attachments/${resumableAttachmentId}/uploads/${resumable.uploadId}/parts/1`,
      {
        method: "PUT",
        headers: {
          Authorization: `Bearer ${operator.accessToken}`,
          "Content-Type": "application/octet-stream",
          "Content-Length": String(firstPart.byteLength),
          "X-Ciphertext-SHA256": firstPartDigest,
        },
        body: firstPart,
      },
    );
    expect(firstPartUpload.status).toBe(200);
    const resumed = await post(`/v1/chat/attachments/${resumableAttachmentId}/uploads`, {
      channelId: channelValue.channelId,
      membershipEpoch: activeChannel?.membershipEpoch,
      ciphertextBytes: resumableCiphertext.byteLength,
      ciphertextSha256: resumableDigest,
    }, operator.accessToken);
    expect(await resumed.json()).toMatchObject({
      state: "uploading",
      uploadId: resumable.uploadId,
      uploadedParts: [{ partNumber: 1, ciphertextBytes: firstPart.byteLength, ciphertextSha256: firstPartDigest }],
    });
    const secondPart = resumableCiphertext.slice(resumable.partSize);
    const secondPartDigest = await sha256(secondPart);
    const secondPartUpload = await exports.default.fetch(
      `https://ptt.test/v1/chat/attachments/${resumableAttachmentId}/uploads/${resumable.uploadId}/parts/2`,
      {
        method: "PUT",
        headers: {
          Authorization: `Bearer ${operator.accessToken}`,
          "Content-Type": "application/octet-stream",
          "Content-Length": String(secondPart.byteLength),
          "X-Ciphertext-SHA256": secondPartDigest,
        },
        body: secondPart,
      },
    );
    expect(secondPartUpload.status).toBe(200);
    const resumableComplete = await post(
      `/v1/chat/attachments/${resumableAttachmentId}/uploads/${resumable.uploadId}/complete`,
      {}, operator.accessToken,
    );
    expect(resumableComplete.status).toBe(200);
    expect(await resumableComplete.json()).toMatchObject({
      state: "complete", attachmentId: resumableAttachmentId,
      ciphertextBytes: resumableCiphertext.byteLength, ciphertextSha256: resumableDigest,
    });
    const resumableDownload = await get(
      `/v1/chat/attachments/${resumableAttachmentId}`, linkedDevice.accessToken,
    );
    expect(new Uint8Array(await resumableDownload.arrayBuffer())).toEqual(resumableCiphertext);
    const resumedDownload = await exports.default.fetch(
      `https://ptt.test/v1/chat/attachments/${resumableAttachmentId}`,
      { headers: { Authorization: `Bearer ${linkedDevice.accessToken}`, Range: "bytes=1048576-" } },
    );
    expect(resumedDownload.status).toBe(206);
    expect(resumedDownload.headers.get("content-range")).toBe("bytes 1048576-1048592/1048593");
    expect(new Uint8Array(await resumedDownload.arrayBuffer())).toEqual(resumableCiphertext.slice(1_048_576));

    const cancelledAttachmentId = crypto.randomUUID();
    const cancelledCreate = await post(`/v1/chat/attachments/${cancelledAttachmentId}/uploads`, {
      channelId: channelValue.channelId,
      membershipEpoch: activeChannel?.membershipEpoch,
      ciphertextBytes: attachmentCiphertext.byteLength,
      ciphertextSha256: attachmentDigest,
    }, operator.accessToken);
    const cancelled = await cancelledCreate.json<{ uploadId: string }>();
    const cancelResponse = await exports.default.fetch(
      `https://ptt.test/v1/chat/attachments/${cancelledAttachmentId}/uploads/${cancelled.uploadId}`,
      { method: "DELETE", headers: { Authorization: `Bearer ${operator.accessToken}` } },
    );
    expect(cancelResponse.status).toBe(200);
    expect(await cancelResponse.json()).toMatchObject({ cancelled: true, attachmentId: cancelledAttachmentId });
    expect(await env.DB.prepare("SELECT count(*) AS count FROM chat_attachment_uploads WHERE upload_id=?")
      .bind(cancelled.uploadId).first<{ count: number }>()).toMatchObject({ count: 0 });

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
    const mediaPacket = await authenticatedMediaPacket(relayOne.senderDemux, relayOne.demuxToken);
    const rejectedSocketResponse = await openMedia(channelValue.channelId, operator.accessToken);
    const rejectedSocket = rejectedSocketResponse.webSocket;
    rejectedSocket?.accept();
    const rejected = new Promise<CloseEvent>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("Timed out waiting for floor enforcement")), 1_000);
      rejectedSocket?.addEventListener("close", (event) => {
        clearTimeout(timeout);
        resolve(event);
      }, { once: true });
    });
    rejectedSocket?.send(mediaPacket);
    expect((await rejected).reason).toBe("FLOOR_NOT_HELD");

    const mediaFloorToken = base64Url(new Uint8Array(16).fill(19));
    const mediaFloor = await post("/v1/floor/request", {
      channelId: channelValue.channelId,
      requestToken: mediaFloorToken,
      senderDemux: relayOne.senderDemux,
      membershipEpoch: activeChannel?.membershipEpoch,
      requestedTotMs: 10_000,
      sos: false,
    }, operator.accessToken);
    expect(mediaFloor.status).toBe(200);
    expect(await mediaFloor.json()).toMatchObject({ granted: true });

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
    expect((await post("/v1/admin/session/revoke", {}, browserSession.sessionToken)).status).toBe(200);
    expect((await get("/v1/admin/members", browserSession.sessionToken)).status).toBe(401);
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

async function sha256(value: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", value));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
