const server = required("PTT_E2E_SERVER").replace(/\/$/u, "");
const aci = required("PTT_E2E_ACI");
const senderToken = required("PTT_E2E_SENDER_TOKEN");
const receiverToken = required("PTT_E2E_RECEIVER_TOKEN");

const senderDrained = await drain(senderToken, 2);
const receiverDrained = await drain(receiverToken, 1);
process.stdout.write(`drained ${senderDrained + receiverDrained} stale automation prekey pairs\n`);

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

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}
