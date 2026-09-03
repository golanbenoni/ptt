import http from "node:http";

const channel = {
  channelId: "11111111-1111-4111-8111-111111111111",
  displayName: "Device Test",
  kind: "private",
  distributionId: "11111111-1111-4111-8111-111111111111",
  membershipEpoch: 1,
  retentionDays: 30,
  role: "talk",
};

const compatible = {
  protocolMajor: 1,
  protocolMinor: 1,
  minimumClientMajor: 1,
  minimumClientMinor: 1,
  capabilities: [
    "chat-attachments-v1",
    "chat-encrypted-thumbnails-v1",
    "chat-resumable-transfers-v1",
    "conversation-directory-v1",
    "channel-workspace-v1",
    "operations-runs-v1",
    "media-tls-v1",
    "push-wake-v1",
  ],
};

const server = http.createServer((request, response) => {
  const url = new URL(request.url ?? "/", "http://127.0.0.1");
  let body;
  if (url.pathname === "/healthz") {
    body = compatible;
  } else if (url.pathname === "/v1/channels") {
    body = { rows: [channel] };
  } else if (url.pathname === `/v1/channels/${channel.channelId}/devices`) {
    body = { rows: [] };
  } else if (url.pathname === "/v1/devices") {
    body = {
      rows: [
        { deviceId: 1, displayName: "Operations phone", status: "active" },
        { deviceId: 2, displayName: "Field phone", status: "active" },
      ],
    };
  } else if (url.pathname === "/v1/chat/messages") {
    body = { rows: [] };
  } else {
    response.writeHead(404, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ code: "FIXTURE_ROUTE_NOT_FOUND" }));
    return;
  }
  response.writeHead(200, {
    "Cache-Control": "no-store",
    "Content-Type": "application/json",
  });
  response.end(JSON.stringify(body));
});

server.listen(39183, "127.0.0.1", () => {
  process.stdout.write("Android accessibility fixture ready\n");
});
