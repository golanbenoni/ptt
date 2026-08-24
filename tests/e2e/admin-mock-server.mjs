import { createServer } from "node:http";

const port = Number(process.env.PTT_ADMIN_MOCK_PORT ?? "39090");
const token = "fake-admin-token";
const channelId = "11111111-1111-4111-8111-111111111111";
const memberAci = "22222222-2222-4222-8222-222222222222";

function send(response, status, body) {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(body));
}

createServer((request, response) => {
  if (request.headers.authorization !== `Bearer ${token}`) {
    send(response, 401, { message: "Administrator authentication failed." });
    return;
  }

  const path = new URL(request.url ?? "/", "http://localhost").pathname;
  const fixtures = {
    "/v1/admin/summary": { accounts: 2, activeDevices: 3, channels: 1, pendingEmail: 0, pendingRecoveries: 1 },
    "/v1/admin/members": [
      { aci: memberAci, email: "teammate@example.test", isAdmin: false, activeDevices: 2 },
    ],
    "/v1/admin/channels": [
      { channelId, displayName: "Operations", kind: "team", membershipEpoch: 3, retentionDays: 30, activeMembers: 2 },
    ],
    "/v1/admin/channels/members": [
      { channelId, aci: memberAci, email: "teammate@example.test", role: "talk", joinedEpoch: 1 },
    ],
    "/v1/admin/recoveries": [
      { requestId: "33333333-3333-4333-8333-333333333333", email: "recovery@example.test", deviceName: "Replacement", status: "pending", expiresAt: "2026-08-25T00:00:00Z", createdAt: "2026-08-24T00:00:00Z" },
    ],
    "/v1/admin/devices": [
      { aci: memberAci, email: "teammate@example.test", deviceId: 1, displayName: "Radio one", status: "active", linkedAt: "2026-08-24T00:00:00Z", revokedAt: null },
    ],
    "/v1/admin/audit": [
      { eventId: 7, action: "channel.membership.updated", subjectHash: "8a4b0d", detail: { role: "talk" }, createdAt: "2026-08-24T00:00:00Z" },
    ],
    "/v1/admin/operations": { activeRelayLeases: 2, pendingPush: 0, failedPush: 0, historyObjects: 12, fcmConfigured: true, apnsConfigured: true, backupConfigured: true, backupSchedule: "0 2 * * *", configurationFingerprint: "a1b2c3d4" },
  };

  if (request.method === "GET" && fixtures[path]) {
    send(response, 200, fixtures[path]);
    return;
  }
  if (request.method === "POST" && path === "/v1/admin/invitations") {
    send(response, 200, { invitationCode: "TEST-CODE", expiresAt: "2026-08-25T00:00:00Z" });
    return;
  }
  if (request.method === "POST") {
    send(response, 200, { accepted: true });
    return;
  }
  send(response, 404, { message: "Not found." });
}).listen(port, "127.0.0.1", () => {
  process.stdout.write(`admin mock listening on http://127.0.0.1:${port}\n`);
});
