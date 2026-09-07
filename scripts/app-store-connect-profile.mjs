#!/usr/bin/env node

import { createPrivateKey, sign } from "node:crypto";
import { writeFile } from "node:fs/promises";

const API_ROOT = "https://api.appstoreconnect.apple.com/v1";
const TRANSIENT_STATUS = new Set([429, 500, 502, 503, 504]);

class AppStoreConnectRequestError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

function requiredEnvironment(name) {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`missing required environment variable: ${name}`);
  }
  return value;
}

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}

function authorizationToken() {
  const keyId = requiredEnvironment("APP_STORE_CONNECT_API_KEY_ID");
  const issuerId = requiredEnvironment("APP_STORE_CONNECT_API_ISSUER_ID");
  const privateKey = requiredEnvironment("APP_STORE_CONNECT_API_PRIVATE_KEY");
  const issuedAt = Math.floor(Date.now() / 1000) - 30;
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
  const payload = base64url(JSON.stringify({
    iss: issuerId,
    iat: issuedAt,
    exp: issuedAt + 600,
    aud: "appstoreconnect-v1",
  }));
  const signingInput = `${header}.${payload}`;
  const signature = sign("sha256", Buffer.from(signingInput), {
    key: createPrivateKey(privateKey),
    dsaEncoding: "ieee-p1363",
  });
  return `${signingInput}.${signature.toString("base64url")}`;
}

function retryable(error) {
  return error instanceof TypeError ||
    (error instanceof AppStoreConnectRequestError && TRANSIENT_STATUS.has(error.status));
}

function wait(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function requestOnce(path, options = {}) {
  const response = await fetch(`${API_ROOT}${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${authorizationToken()}`,
      "Content-Type": "application/json",
      ...options.headers,
    },
  });
  if (!response.ok) {
    const resourcePath = path.split("?", 1)[0];
    const requestId = response.headers.get("x-request-id");
    throw new AppStoreConnectRequestError(
      `App Store Connect ${options.method ?? "GET"} ${resourcePath} failed (${response.status})` +
        (requestId ? `, request ${requestId}` : ""),
      response.status,
    );
  }
  if (response.status === 204) {
    return null;
  }
  return response.json();
}

async function request(path, options = {}) {
  const method = options.method ?? "GET";
  const attempts = method === "GET" || method === "DELETE" ? 4 : 1;
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await requestOnce(path, options);
    } catch (error) {
      if (attempt >= attempts || !retryable(error)) throw error;
      await wait(500 * (2 ** (attempt - 1)));
    }
  }
}

function exactlyOne(resources, description) {
  if (resources.length !== 1) {
    throw new Error(`expected one ${description}; found ${resources.length}`);
  }
  return resources[0];
}

async function createProfile(outputPath, certificateSerial, deviceUdids) {
  if (!outputPath || !certificateSerial || deviceUdids.length < 1) {
    throw new Error("usage: app-store-connect-profile.mjs create OUTPUT CERTIFICATE_SERIAL DEVICE_UDID...");
  }
  const bundleIdentifier = process.env.PTT_IOS_BUNDLE_ID?.trim() || "app.ptt.talk";
  const runId = requiredEnvironment("GITHUB_RUN_ID");
  const runAttempt = process.env.GITHUB_RUN_ATTEMPT?.trim() || "1";
  const profileName = `PTT Physical ${runId}-${runAttempt}`;

  const bundleQuery = new URLSearchParams({
    "filter[identifier]": bundleIdentifier,
    limit: "2",
  });
  const bundle = exactlyOne((await request(`/bundleIds?${bundleQuery}`)).data, `bundle ID ${bundleIdentifier}`);

  const certificates = (await request("/certificates?limit=200")).data;
  const normalizedSerial = certificateSerial.replaceAll(":", "").toUpperCase();
  const certificate = exactlyOne(
    certificates.filter((item) =>
      item.attributes.serialNumber?.replaceAll(":", "").toUpperCase() === normalizedSerial &&
      item.attributes.activated !== false),
    "active distribution certificate matching the isolated signing identity",
  );

  const devices = [];
  for (const udid of [...new Set(deviceUdids)]) {
    const deviceQuery = new URLSearchParams({ "filter[udid]": udid, limit: "2" });
    const device = exactlyOne((await request(`/devices?${deviceQuery}`)).data, "enabled registered Apple device");
    if (device.attributes.status !== "ENABLED") {
      throw new Error("A requested Apple test device is not enabled");
    }
    devices.push({ type: "devices", id: device.id });
  }

  const profileBody = JSON.stringify({
    data: {
      type: "profiles",
      attributes: { name: profileName, profileType: "IOS_APP_ADHOC" },
      relationships: {
        bundleId: { data: { type: "bundleIds", id: bundle.id } },
        certificates: { data: [{ type: "certificates", id: certificate.id }] },
        devices: { data: devices },
      },
    },
  });
  let created;
  for (let attempt = 1; attempt <= 4; attempt += 1) {
    try {
      created = await requestOnce("/profiles", {
        method: "POST",
        body: profileBody,
      });
      break;
    } catch (error) {
      // Apple occasionally returns a transient error after accepting a profile.
      // Recover that exact run-scoped record before retrying the non-idempotent POST.
      if (!retryable(error) && error?.status !== 409) throw error;
      const profiles = (await request("/profiles?limit=200")).data;
      const matching = profiles.filter((item) => item.attributes.name === profileName);
      if (matching.length > 1) {
        throw new Error(`found multiple temporary profiles named ${profileName}`);
      }
      if (matching.length === 1) {
        created = await request(`/profiles/${encodeURIComponent(matching[0].id)}`);
        break;
      }
      if (attempt === 4) throw error;
      await wait(500 * (2 ** (attempt - 1)));
    }
  }
  if (!created) {
    throw new Error("Apple did not return or recover the temporary ad-hoc profile");
  }
  const profileContent = created.data.attributes.profileContent;
  if (!profileContent) {
    throw new Error("Apple created the ad-hoc profile without downloadable content");
  }
  await writeFile(outputPath, Buffer.from(profileContent, "base64"), { mode: 0o600 });

  const githubEnvironment = requiredEnvironment("GITHUB_ENV");
  await writeFile(
    githubEnvironment,
    `PTT_IOS_PROFILE_ID=${created.data.id}\nPTT_IOS_PROFILE_NAME=${profileName}\n`,
    { flag: "a" },
  );
  console.log(`Created temporary Apple ad-hoc profile for ${devices.length} registered device(s).`);
}

async function deleteProfile(profileId) {
  if (!profileId) {
    throw new Error("usage: app-store-connect-profile.mjs delete PROFILE_ID");
  }
  await request(`/profiles/${encodeURIComponent(profileId)}`, { method: "DELETE" });
  console.log("Deleted temporary Apple ad-hoc profile.");
}

async function main() {
  const [operation, ...args] = process.argv.slice(2);
  if (operation === "create") {
    await createProfile(args[0], args[1], args.slice(2));
    return;
  }
  if (operation === "delete") {
    await deleteProfile(args[0]);
    return;
  }
  throw new Error("expected operation: create or delete");
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
