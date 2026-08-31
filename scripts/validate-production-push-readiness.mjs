#!/usr/bin/env node

let payload;
try {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
} catch {
  console.error("Release blocked: production health returned malformed JSON.");
  process.exit(1);
}

if (payload?.status !== "ok") {
  console.error("Release blocked: production service is not healthy.");
  process.exit(1);
}

const readiness = payload.pushReadiness;
const missing = [];
if (readiness?.fcmConfigured !== true) missing.push("FCM");
if (readiness?.apnsConfigured !== true) missing.push("APNs");
if (missing.length > 0) {
  console.error(`Release blocked: production push is not configured for ${missing.join(" and ")}.`);
  process.exit(1);
}

console.log("Production push readiness passed: FCM and APNs credentials are structurally valid.");
