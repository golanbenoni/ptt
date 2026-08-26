import { createHmac, randomBytes } from "node:crypto";
import WebSocket from "ws";

const server = required("PTT_E2E_SERVER").replace(/\/$/u, "");
const channelId = required("PTT_E2E_CHANNEL_ID");
const senderToken = required("PTT_E2E_SENDER_TOKEN");
const receiverToken = required("PTT_E2E_RECEIVER_TOKEN");
const packetCount = Number(process.env.PTT_E2E_PACKET_COUNT ?? "50");
const transmissionCount = Number(process.env.PTT_E2E_TRANSMISSIONS ?? "5");

if (!server.startsWith("https://") && process.env.PTT_E2E_ALLOW_HTTP !== "1") {
  throw new Error("PTT_E2E_SERVER must use HTTPS unless PTT_E2E_ALLOW_HTTP=1");
}
if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(channelId)) {
  throw new Error("PTT_E2E_CHANNEL_ID must be a UUID");
}
if (!Number.isInteger(packetCount) || packetCount < 10 || packetCount > 500) {
  throw new Error("PTT_E2E_PACKET_COUNT must be between 10 and 500");
}
if (!Number.isInteger(transmissionCount) || transmissionCount < 1 || transmissionCount > 20) {
  throw new Error("PTT_E2E_TRANSMISSIONS must be between 1 and 20");
}
if (senderToken === receiverToken) throw new Error("The probe requires two independently authenticated devices");

const senderLease = await post("/v1/relay/credentials", { channelId }, senderToken);
const receiverLease = await post("/v1/relay/credentials", { channelId }, receiverToken);
const channels = await get("/v1/channels", senderToken);
const channel = channels.find((candidate) => candidate.channelId === channelId);
if (!channel) throw new Error("The sender is not an active member of the requested channel");

const wsUrl = new URL("/v1/media/tunnel", server);
wsUrl.protocol = wsUrl.protocol === "https:" ? "wss:" : "ws:";
wsUrl.searchParams.set("channelId", channelId);

const receiver = await openSocket(wsUrl, receiverToken);
const sender = await openSocket(wsUrl, senderToken);
let floorToken;
try {
  const allLatencies = [];
  for (let transmission = 0; transmission < transmissionCount; transmission += 1) {
    floorToken = base64Url(randomBytes(16));
    const floor = await post("/v1/floor/request", {
      channelId,
      requestToken: floorToken,
      senderDemux: senderLease.senderDemux,
      membershipEpoch: channel.membershipEpoch,
      requestedTotMs: Math.max(5_000, packetCount * 30),
      sos: false,
    }, senderToken);
    if (!floor.granted) {
      throw new Error(`Transmission ${transmission + 1} floor was denied: ${floor.reason ?? "unknown"}`);
    }

    const expected = [];
    const sentAt = new Map();
    for (let index = 0; index < packetCount; index += 1) {
      expected.push(authenticatedPacket(
        senderLease.senderDemux,
        senderLease.demuxToken,
        transmission * packetCount + index,
      ));
    }
    const received = receivePackets(receiver, expected, sentAt, transmission + 1);
    for (let index = 0; index < packetCount; index += 1) {
      sentAt.set(index, performance.now());
      sender.send(expected[index], { binary: true });
      await sleep(20);
    }
    allLatencies.push(...await received);
    await post("/v1/floor/release", { channelId, requestToken: floorToken }, senderToken);
    floorToken = undefined;
    await sleep(40);
  }

  const ordered = [...allLatencies].sort((left, right) => left - right);
  const p95 = ordered[Math.min(ordered.length - 1, Math.ceil(ordered.length * 0.95) - 1)];
  const maximum = ordered.at(-1);
  if (!Number.isFinite(p95) || p95 > 1_000) throw new Error(`Relay p95 was too high: ${p95?.toFixed(1)} ms`);
  process.stdout.write(`deployed media probe passed: ${transmissionCount} consecutive transmissions, ${allLatencies.length}/${transmissionCount * packetCount} authenticated packets, p95=${p95.toFixed(1)} ms, max=${maximum.toFixed(1)} ms\n`);
} finally {
  if (floorToken) {
    await post("/v1/floor/release", { channelId, requestToken: floorToken }, senderToken).catch(() => {});
  }
  sender.close(1000, "probe complete");
  receiver.close(1000, "probe complete");
}

function receivePackets(socket, expected, sentAt, transmission) {
  return new Promise((resolve, reject) => {
    const latencies = [];
    const cleanup = () => {
      clearTimeout(timeout);
      socket.off("message", onMessage);
    };
    const fail = (error) => {
      cleanup();
      reject(error);
    };
    const onMessage = (value, isBinary) => {
      if (!isBinary) {
        fail(new Error(`Transmission ${transmission} returned text instead of encrypted binary media`));
        return;
      }
      const packet = Buffer.from(value);
      const index = latencies.length;
      if (!packet.equals(expected[index])) {
        fail(new Error(`Transmission ${transmission} packet ${index} was modified or reordered`));
        return;
      }
      latencies.push(performance.now() - sentAt.get(index));
      if (latencies.length === expected.length) {
        cleanup();
        resolve(latencies);
      }
    };
    const timeout = setTimeout(() => {
      fail(new Error(`Transmission ${transmission} timed out after ${latencies.length}/${expected.length} packets`));
    }, 15_000);
    socket.on("message", onMessage);
  });
}

function authenticatedPacket(senderDemux, demuxToken, sequence) {
  const packet = Buffer.alloc(160);
  packet[0] = 1;
  packet[1] = 0x08;
  packet.writeUInt32BE(senderDemux, 2);
  packet.writeUInt32BE(sequence, 6);
  randomBytes(4).copy(packet, 10);
  // Bytes 14 and 15 are frozen reserved bytes and must remain zero.
  randomBytes(136).copy(packet, 16);
  const tag = createHmac("sha256", base64UrlBytes(demuxToken)).update(packet.subarray(0, 152)).digest();
  tag.copy(packet, 152, 0, 8);
  return packet;
}

async function openSocket(url, token) {
  const socket = new WebSocket(url, { headers: { Authorization: `Bearer ${token}` } });
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Timed out opening the authenticated media tunnel")), 10_000);
    socket.once("open", () => {
      clearTimeout(timeout);
      resolve();
    });
    socket.once("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
  });
  return socket;
}

async function post(path, body, token) {
  return request(path, { method: "POST", body: JSON.stringify(body) }, token);
}

async function get(path, token) {
  return request(path, { method: "GET" }, token);
}

async function request(path, options, token) {
  const response = await fetch(new URL(path, server), {
    ...options,
    headers: {
      Authorization: `Bearer ${token}`,
      ...(options.body ? { "Content-Type": "application/json" } : {}),
    },
    redirect: "error",
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`${options.method} ${path} failed (${response.status}): ${payload.error ?? "unknown"}`);
  return payload;
}

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function base64Url(bytes) {
  return Buffer.from(bytes).toString("base64url");
}

function base64UrlBytes(value) {
  return Buffer.from(value, "base64url");
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
