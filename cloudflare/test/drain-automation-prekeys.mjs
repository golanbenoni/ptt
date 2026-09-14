const server = required("PTT_E2E_SERVER").replace(/\/$/u, "");
const aci = required("PTT_E2E_ACI");
const senderToken = required("PTT_E2E_SENDER_TOKEN");
const receiverToken = required("PTT_E2E_RECEIVER_TOKEN");

await Promise.all([
  clearPushRegistrations(senderToken),
  clearPushRegistrations(receiverToken),
]);
const senderDrained = await drain(senderToken, 2);
const receiverDrained = await drain(receiverToken, 1);
const queueCounts = await Promise.all([
  drainQueue(senderToken, "/v1/mailbox/items", "/v1/mailbox/ack"),
  drainQueue(receiverToken, "/v1/mailbox/items", "/v1/mailbox/ack"),
  drainQueue(senderToken, "/v1/chat/messages", "/v1/chat/ack"),
  drainQueue(receiverToken, "/v1/chat/messages", "/v1/chat/ack"),
]);
process.stdout.write(
  `cleared stale automation push registrations, drained ${senderDrained + receiverDrained} prekey pairs, ` +
    `and acknowledged ${queueCounts.reduce((total, count) => total + count, 0)} queued envelopes\n`,
);

async function clearPushRegistrations(token) {
  for (const provider of ["apns-ptt-sandbox", "apns-sandbox"]) {
    const response = await fetch(new URL("/v1/push/registrations", server), {
      method: "DELETE",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ provider }),
      redirect: "error",
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(`push registration cleanup failed (${response.status}): ${payload.error ?? "unknown"}`);
    }
  }
}

async function drain(token, deviceId) {
  let consumed = 0;
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const response = await fetch(new URL("/v1/prekeys/fetch", server), {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ devices: [{ aci, deviceId }] }),
      redirect: "error",
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(`prekey drain failed (${response.status}): ${payload.error ?? "unknown"}`);
    const keys = payload[0]?.oneTimePrekeys ?? [];
    if (keys.length === 0) return consumed;
    consumed += 1;
  }
  throw new Error(`prekey drain exceeded its bound for device ${deviceId}`);
}

async function drainQueue(token, listPath, acknowledgePath) {
  let acknowledged = 0;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const response = await fetch(new URL(`${listPath}?limit=100`, server), {
      headers: { Authorization: `Bearer ${token}` },
      redirect: "error",
    });
    const items = await response.json().catch(() => []);
    if (!response.ok) {
      throw new Error(`queue drain failed for ${listPath} (${response.status})`);
    }
    if (!Array.isArray(items)) throw new Error(`queue drain returned invalid data for ${listPath}`);
    if (items.length === 0) return acknowledged;
    const itemIds = items.map((item) => item?.itemId);
    if (itemIds.some((itemId) => typeof itemId !== "string")) {
      throw new Error(`queue drain returned an invalid item for ${listPath}`);
    }
    const ackResponse = await fetch(new URL(acknowledgePath, server), {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ itemIds }),
      redirect: "error",
    });
    const result = await ackResponse.json().catch(() => ({}));
    if (!ackResponse.ok || result.acknowledged !== itemIds.length) {
      throw new Error(`queue acknowledgment failed for ${acknowledgePath} (${ackResponse.status})`);
    }
    acknowledged += itemIds.length;
  }
  throw new Error(`queue drain exceeded its bound for ${listPath}`);
}

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}
