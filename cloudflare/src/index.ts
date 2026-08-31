import { ChannelCoordinator } from "./coordinator";
import {
  approveDeviceLink, bootstrap, claimDeviceLink, consumeMagicLink, consumeRecovery, deleteAccount,
  deviceLinkStatus, issueMagicLink, listDevices, recoveryStatus, requestMagicLink, requestRecovery,
  revokeDevice, startDeviceLink,
} from "./auth";
import {
  adminAudit, adminDevices, adminMembers, adminOperations, adminRecoveries, adminRevokeDevice,
  adminSummary, createInvitation, decideRecovery,
} from "./admin";
import {
  consumeAdminConsoleSession, revokeAdminConsoleSession, startAdminConsoleSession,
} from "./admin-session";
import {
  adminChannelMembers, adminChannels, channelDevices, createChannel, deviceChannels,
  updateChannelConfig, updateMembership,
} from "./channels";
import {
  acknowledgeChat, acknowledgeMailbox, downloadChatAttachment, downloadHistory, enqueueChat,
  enqueueMailbox, fetchPrekeys, listHistory, mediaTunnel, pollChat, pollMailbox,
  cancelChatAttachmentUpload, completeChatAttachmentUpload, createChatAttachmentUpload,
  pushRegistration, relayCredentials, releaseFloor, requestFloor, setPresence,
  uploadChatAttachment, uploadChatAttachmentPart, uploadHistory, uploadPrekeys,
} from "./delivery";
import type { DeliveryJob } from "./db";
import { ApiError, errorResponse, json } from "./http";
import { dispatchPush, pushConfiguration } from "./push";
import { runMaintenance } from "./maintenance";

export { ChannelCoordinator };

export const PROTOCOL_MAJOR = 1;
export const PROTOCOL_MINOR = 1;
export const MINIMUM_CLIENT_MAJOR = 1;
export const MINIMUM_CLIENT_MINOR = 0;
export const PROTOCOL_CAPABILITIES = [
  "chat-attachments-v1",
  "chat-encrypted-thumbnails-v1",
  "chat-resumable-transfers-v1",
  "media-tls-v1",
  "media-floor-control-v1",
  "push-wake-v1",
] as const;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const requestId = crypto.randomUUID();
    const started = Date.now();
    try {
      const requestUrl = new URL(request.url);
      const redirect = httpsRedirect(requestUrl, requestId);
      if (redirect) return redirect;
      const routed = await route(request, env);
      const response = routed.webSocket
        ? new Response(null, {
          status: routed.status,
          statusText: routed.statusText,
          headers: routed.headers,
          webSocket: routed.webSocket,
        })
        : new Response(routed.body, routed);
      response.headers.set("X-Request-Id", requestId);
      applySecurityHeaders(response, requestUrl.pathname);
      console.log(JSON.stringify({
        level: "info", message: "request complete", requestId,
        method: request.method, path: new URL(request.url).pathname,
        status: response.status, durationMs: Date.now() - started,
      }));
      return response;
    } catch (error) {
      const response = errorResponse(error);
      response.headers.set("X-Request-Id", requestId);
      applySecurityHeaders(response, new URL(request.url).pathname);
      return response;
    }
  },

  async queue(batch: MessageBatch<DeliveryJob>, env: Env): Promise<void> {
    for (const message of batch.messages) {
      try {
        if (message.body.kind === "push") {
          const result = await dispatchPush(env, message.body);
          if (result.retry) message.retry({ delaySeconds: result.delaySeconds });
          else message.ack();
          continue;
        }
        if (!env.EMAIL_FROM.trim()) {
          await env.DB.prepare("UPDATE email_outbox SET last_error='SENDER_DOMAIN_PENDING' WHERE id=?")
            .bind(message.body.outboxId).run();
          message.ack();
          continue;
        }
        const title = message.body.template === "recovery_link" ? "Recover PTT Talk" : "Join PTT Talk";
        const action = message.body.template === "recovery_link" ? "Continue recovery" : "Join PTT Talk";
        await env.EMAIL.send({
          to: message.body.recipient,
          from: { email: env.EMAIL_FROM, name: "PTT Talk" },
          subject: title,
          text: `${action}: ${message.body.url}\n\nThis private link expires in ${message.body.expiresMinutes} minutes and can be used once.`,
          html: emailHtml(title, action, message.body.url, message.body.expiresMinutes),
          headers: { "X-Entity-Ref-ID": message.body.outboxId },
        });
        await env.DB.prepare("UPDATE email_outbox SET status='sent',sent_at=?,attempts=attempts+1,last_error=NULL WHERE id=?")
          .bind(new Date().toISOString(), message.body.outboxId).run();
        await env.DB.prepare("UPDATE email_outbox SET payload=? WHERE id=?")
          .bind(JSON.stringify({ redacted: true, template: message.body.template }), message.body.outboxId).run();
        message.ack();
      } catch (error) {
        const messageText = error instanceof Error ? error.message.slice(0, 200) : "EMAIL_SEND_FAILED";
        await env.DB.prepare("UPDATE email_outbox SET attempts=attempts+1,last_error=? WHERE id=?")
          .bind(messageText, message.body.outboxId).run();
        message.retry();
      }
    }
  },

  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(runMaintenance(env));
  },
} satisfies ExportedHandler<Env, DeliveryJob>;

export function httpsRedirect(url: URL, requestId = crypto.randomUUID()): Response | null {
  if (url.protocol !== "http:") return null;
  url.protocol = "https:";
  return new Response(null, {
    status: 308,
    headers: { Location: url.toString(), "Cache-Control": "no-store", "X-Request-Id": requestId },
  });
}

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/$/u, "") || "/";
  const readsDocument = request.method === "GET" || request.method === "HEAD";

  if (readsDocument && path === "/healthz") return json({
    status: "ok",
    protocolMajor: PROTOCOL_MAJOR,
    protocolMinor: PROTOCOL_MINOR,
    minimumClientMajor: MINIMUM_CLIENT_MAJOR,
    minimumClientMinor: MINIMUM_CLIENT_MINOR,
    capabilities: PROTOCOL_CAPABILITIES,
    pushReadiness: pushConfiguration(env),
  });
  if (readsDocument && path === "/readyz") {
    const ready = await env.DB.prepare("SELECT 1 AS ready").first<{ ready: number }>();
    return ready?.ready === 1 ? json({ status: "ready" }) : json({ status: "not_ready" }, 503);
  }
  if (readsDocument && path === "/") {
    return env.ASSETS.fetch(new Request(new URL("/site/index.html", request.url), request));
  }
  if (readsDocument && path.startsWith("/site/")) {
    return env.ASSETS.fetch(new Request(new URL(path, request.url), request));
  }
  if (readsDocument && path === "/privacy") return privacyPage();
  if (readsDocument && (path === "/apple-app-site-association" || path === "/.well-known/apple-app-site-association")) {
    return json({
      applinks: {
        details: [{
          appIDs: ["M2M4752Z6K.app.ptt.talk"],
          components: [{ "/": "/enroll" }, { "/": "/recover" }, { "/": "/link-device" }],
        }],
      },
    });
  }
  if (readsDocument && path === "/.well-known/assetlinks.json") {
    const fingerprints = (env.ANDROID_APP_CERT_SHA256 ?? "")
      .split(",").map((value) => value.trim()).filter(Boolean);
    if (fingerprints.length === 0) return json({ code: "APP_LINKS_NOT_CONFIGURED" }, 503);
    return json([{
      relation: ["delegate_permission/common.handle_all_urls"],
      target: {
        namespace: "android_app",
        package_name: "app.ptt.talk",
        sha256_cert_fingerprints: fingerprints,
      },
    }]);
  }
  if (readsDocument && (path === "/enroll" || path === "/recover" || path === "/link-device")) {
    return appLanding(path === "/enroll" ? "enroll" : path === "/recover" ? "recover" : "link");
  }
  if (readsDocument && (path === "/admin" || path === "/admin/")) {
    return env.ASSETS.fetch(new Request(new URL("/index.html", request.url), request));
  }
  if (readsDocument && path.startsWith("/admin/assets/")) {
    const target = new URL(path.slice("/admin".length), request.url);
    return env.ASSETS.fetch(new Request(target, request));
  }
  if (readsDocument && path.startsWith("/admin/")) {
    return env.ASSETS.fetch(new Request(new URL("/index.html", request.url), request));
  }

  if (request.method === "POST" && path === "/v1/bootstrap") return bootstrap(request, env);
  if (request.method === "POST" && path === "/v1/auth/magic-link/request") return requestMagicLink(request, env);
  if (request.method === "POST" && path === "/v1/auth/magic-link/consume") return consumeMagicLink(request, env);
  if (request.method === "POST" && path === "/v1/auth/recovery/request") return requestRecovery(request, env);
  if (request.method === "POST" && path === "/v1/auth/recovery/consume") return consumeRecovery(request, env);
  if (request.method === "POST" && path === "/v1/auth/recovery/status") return recoveryStatus(request, env);
  if (request.method === "POST" && path === "/v1/admin/session/start") return startAdminConsoleSession(request, env);
  if (request.method === "POST" && path === "/v1/admin/session/consume") return consumeAdminConsoleSession(request, env);
  if (request.method === "POST" && path === "/v1/admin/session/revoke") return revokeAdminConsoleSession(request, env);

  if (request.method === "GET" && path === "/v1/devices") return listDevices(request, env);
  if (request.method === "POST" && path === "/v1/devices/revoke") return revokeDevice(request, env);
  if (request.method === "POST" && path === "/v1/account/delete") return deleteAccount(request, env);
  if (request.method === "POST" && path === "/v1/devices/link/start") return startDeviceLink(request, env);
  if (request.method === "POST" && path === "/v1/devices/link/claim") return claimDeviceLink(request, env);
  if (request.method === "POST" && path === "/v1/devices/link/approve") return approveDeviceLink(request, env);
  if (request.method === "POST" && path === "/v1/devices/link/status") return deviceLinkStatus(request, env);

  if (request.method === "GET" && path === "/v1/channels") return deviceChannels(request, env);
  const channelDeviceMatch = path.match(/^\/v1\/channels\/([^/]+)\/devices$/u);
  if (request.method === "GET" && channelDeviceMatch?.[1]) return channelDevices(request, env, channelDeviceMatch[1]);
  if (request.method === "POST" && path === "/v1/prekeys/upload") return uploadPrekeys(request, env);
  if (request.method === "POST" && path === "/v1/prekeys/fetch") return fetchPrekeys(request, env);
  if (request.method === "POST" && path === "/v1/mailbox/envelopes") return enqueueMailbox(request, env);
  if (request.method === "GET" && path === "/v1/mailbox/items") return pollMailbox(request, env);
  if (request.method === "POST" && path === "/v1/mailbox/ack") return acknowledgeMailbox(request, env);
  if (request.method === "POST" && path === "/v1/chat/messages") return enqueueChat(request, env);
  if (request.method === "GET" && path === "/v1/chat/messages") return pollChat(request, env);
  if (request.method === "POST" && path === "/v1/chat/ack") return acknowledgeChat(request, env);
  const chatAttachmentMatch = path.match(/^\/v1\/chat\/attachments\/([^/]+)$/u);
  if (request.method === "PUT" && chatAttachmentMatch?.[1]) {
    return uploadChatAttachment(request, env, chatAttachmentMatch[1]);
  }
  if (request.method === "GET" && chatAttachmentMatch?.[1]) {
    return downloadChatAttachment(request, env, chatAttachmentMatch[1]);
  }
  const chatUploadMatch = path.match(/^\/v1\/chat\/attachments\/([^/]+)\/uploads$/u);
  if (request.method === "POST" && chatUploadMatch?.[1]) {
    return createChatAttachmentUpload(request, env, chatUploadMatch[1]);
  }
  const chatUploadCompleteMatch = path.match(
    /^\/v1\/chat\/attachments\/([^/]+)\/uploads\/([^/]+)\/complete$/u,
  );
  if (request.method === "POST" && chatUploadCompleteMatch?.[1] && chatUploadCompleteMatch[2]) {
    return completeChatAttachmentUpload(request, env, chatUploadCompleteMatch[1], chatUploadCompleteMatch[2]);
  }
  const chatUploadActionMatch = path.match(/^\/v1\/chat\/attachments\/([^/]+)\/uploads\/([^/]+)$/u);
  if (request.method === "DELETE" && chatUploadActionMatch?.[1] && chatUploadActionMatch[2]) {
    return cancelChatAttachmentUpload(request, env, chatUploadActionMatch[1], chatUploadActionMatch[2]);
  }
  const chatUploadPartMatch = path.match(
    /^\/v1\/chat\/attachments\/([^/]+)\/uploads\/([^/]+)\/parts\/(\d+)$/u,
  );
  if (request.method === "PUT" && chatUploadPartMatch?.[1] && chatUploadPartMatch[2] && chatUploadPartMatch[3]) {
    return uploadChatAttachmentPart(
      request, env, chatUploadPartMatch[1], chatUploadPartMatch[2], Number(chatUploadPartMatch[3]),
    );
  }
  if (path === "/v1/push/registrations" && (request.method === "POST" || request.method === "DELETE")) return pushRegistration(request, env);
  if (request.method === "POST" && path === "/v1/presence") return setPresence(request, env);

  if (path === "/v1/history/objects" && request.method === "POST") return uploadHistory(request, env);
  if (path === "/v1/history/objects" && request.method === "GET") return listHistory(request, env);
  const historyMatch = path.match(/^\/v1\/history\/objects\/([^/]+)$/u);
  if (request.method === "GET" && historyMatch?.[1]) return downloadHistory(request, env, historyMatch[1]);
  if (request.method === "POST" && path === "/v1/relay/credentials") return relayCredentials(request, env);
  if (request.method === "GET" && path === "/v1/media/tunnel") return mediaTunnel(request, env);
  if (request.method === "POST" && path === "/v1/floor/request") return requestFloor(request, env);
  if (request.method === "POST" && path === "/v1/floor/release") return releaseFloor(request, env);

  if (request.method === "GET" && path === "/v1/admin/summary") return adminSummary(request, env);
  if (request.method === "GET" && path === "/v1/admin/members") return adminMembers(request, env);
  if (request.method === "GET" && path === "/v1/admin/devices") return adminDevices(request, env);
  if (request.method === "POST" && path === "/v1/admin/devices/revoke") return adminRevokeDevice(request, env);
  if (request.method === "GET" && path === "/v1/admin/audit") return adminAudit(request, env);
  if (request.method === "GET" && path === "/v1/admin/operations") return adminOperations(request, env);
  if (request.method === "POST" && path === "/v1/admin/invitations") {
    return createInvitation(request, env, issueMagicLink);
  }
  if (request.method === "GET" && path === "/v1/admin/recoveries") return adminRecoveries(request, env);
  if (request.method === "POST" && path === "/v1/admin/recoveries/decision") return decideRecovery(request, env);
  if (request.method === "GET" && path === "/v1/admin/channels") return adminChannels(request, env);
  if (request.method === "POST" && path === "/v1/admin/channels") return createChannel(request, env);
  if (request.method === "GET" && path === "/v1/admin/channels/members") return adminChannelMembers(request, env);
  if (request.method === "POST" && path === "/v1/admin/channels/membership") return updateMembership(request, env);
  if (request.method === "POST" && path === "/v1/admin/channels/config") return updateChannelConfig(request, env);

  throw new ApiError(404, "NOT_FOUND");
}

function appLanding(action: "enroll" | "recover" | "link"): Response {
  const nonce = crypto.randomUUID().replaceAll("-", "");
  const title = action === "enroll" ? "Join PTT Talk" : action === "recover" ? "Recover PTT Talk" : "Add this device";
  const description = action === "enroll"
    ? "Open PTT Talk to finish secure device enrollment."
    : action === "recover"
      ? "Open PTT Talk to request independent administrator approval."
      : "Open this private, one-time setup link in PTT Talk. Your current device must still approve the new device.";
  const button = action === "link" ? "Open PTT Talk" : "Copy one-time code";
  const copied = action === "link"
    ? "Setup link copied. Send it privately to the device you want to add."
    : "Code copied. Open PTT Talk and choose manual setup.";
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><meta name="color-scheme" content="light"><title>${title}</title><style nonce="${nonce}">${pageStyles()}</style></head><body><main><div class="mark">PTT</div><p class="eyebrow">Private team voice</p><h1>${title}</h1><p>${description}</p><button id="continue" type="button">${button}</button><button id="copy" type="button" hidden>Copy setup link instead</button><p id="copied" hidden>${copied}</p><p id="error" hidden>This link is incomplete or expired. Create a new setup link on your active device.</p><small>${action === "link" ? "If the app does not open, install or update PTT Talk, then return to the original setup link." : "If PTT Talk is installed, return to the email and tap its button again. Verified app links open the app directly without exposing the code to another application."}</small></main><script nonce="${nonce}">const raw=location.hash.slice(1);const p=new URLSearchParams(raw);const t=p.get('token');const request=p.get('requestId');const code=p.get('code');const link=${action === "link"};const valid=link?(request&&code):(t);const original=location.origin+location.pathname+'#'+raw;history.replaceState(null,'',location.pathname);const a=document.getElementById('continue');const c=document.getElementById('copy');if(valid){if(link){a.onclick=()=>{location.href='ptttalk://link-device#'+raw};c.hidden=false;c.onclick=async()=>{await navigator.clipboard.writeText(original);document.getElementById('copied').hidden=false}}else{a.onclick=async()=>{await navigator.clipboard.writeText(t);document.getElementById('copied').hidden=false}}}else{a.hidden=true;c.hidden=true;document.getElementById('error').hidden=false}</script></body></html>`;
  return htmlResponse(html, nonce);
}

function privacyPage(): Response {
  const nonce = crypto.randomUUID().replaceAll("-", "");
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><title>Privacy Policy · PTT Talk</title><style nonce="${nonce}">${pageStyles()}main.policy{width:min(100%,760px)}.policy h1{font-size:clamp(34px,7vw,48px)}.policy h2{margin:32px 0 8px;font-size:22px;letter-spacing:-.02em}.policy li{margin:9px 0;color:#49655d;line-height:1.6}.policy a.text-link{display:inline;margin:0;padding:0;background:none;color:#08755c;text-align:left;text-decoration:underline}.policy small{margin-top:28px}</style></head><body><main class="policy"><div class="mark">PTT</div><p class="eyebrow">Privacy policy</p><h1>Private communication stays private.</h1><p><strong>Effective August 31, 2026.</strong> PTT Talk is a private, end-to-end encrypted push-to-talk and channel messaging service for teams. It does not use advertising, analytics, cross-app tracking, or profiling, and it does not sell personal data.</p><p>PTT Talk is self-hosted. The organization operating the instance you join controls its service records, infrastructure providers, and retention settings.</p><h2>Data handled</h2><ul><li>Account and team data: email address, invitation and recovery state, roles, channel memberships, device names, and random service identifiers.</li><li>Security data: public identity keys and prekeys, hashed tokens, key epochs, device status, and security audit events. Private encryption keys remain in protected storage on your device.</li><li>Delivery data: privacy-minimized Apple or Google push tokens and encrypted mailbox and chat envelopes. Push notifications contain no voice, email address, channel name, message text, filename, or caption.</li><li>Voice, chat, and attachments: the microphone is used only while you transmit or record a voice note. Text, files, voice notes, video, and live voice are encrypted on the sending device; relays and object storage receive ciphertext, not plaintext or decryption keys.</li><li>Operational data: network addresses, source tuples, timestamps, floor and authentication events, rate limits, ciphertext sizes, and service health needed to securely operate the service.</li></ul><h2>Use, storage, and recipients</h2><p>Data is used to authenticate invited members, link or revoke up to two devices, deliver encrypted voice, chat, attachments, and history, enforce channel membership and floor control, send privacy-minimized notifications, recover accounts with administrator approval, prevent abuse, and maintain security. It is disclosed only to the instance operator and necessary hosting, storage, email, backup, network, Apple, or Google providers, plus authorized member devices.</p><p>Server history and encrypted attachments use the operator-selected channel retention period from 1 to 365 days. Local encrypted history and attachment caches are limited to 30 days and 1 GB per device. Newly linked devices receive future communications only and cannot retrieve earlier attachments or history.</p><h2 id="deletion">Your choices and deletion</h2><p>You may disable microphone access, photo access, or notifications in system settings and revoke a linked device in the app. You can request account deletion from the Device section or from your instance administrator. Deletion revokes devices, removes memberships, de-identifies the email address, deletes delivery and key material, and rotates affected channel key epochs. Security audit records, encrypted content already delivered to authorized teammates, legal records, and backups may remain for their applicable retention periods.</p><h2>Security and children</h2><p>PTT Talk uses end-to-end encryption, protected key storage, authenticated transport, access controls, and replay and source validation. No security measure is perfect. PTT Talk is intended for private organizations and is not directed to children under 13.</p><h2>Contact and changes</h2><p>Contact your instance administrator about privacy, deletion, or suspected compromise. Software-level privacy and security questions can be opened at <a class="text-link" href="https://github.com/golanbenoni/ptt/issues">github.com/golanbenoni/ptt/issues</a>. This policy may change as the product or applicable requirements change; the effective date identifies the current version.</p><small><a class="text-link" href="/">Back to PTT Talk</a></small></main></body></html>`;
  return htmlResponse(html, nonce);
}

function htmlResponse(html: string, nonce: string): Response {
  return new Response(html, { headers: {
    "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY",
    "Content-Security-Policy": `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
  } });
}

function applySecurityHeaders(response: Response, path: string): void {
  response.headers.set("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
  response.headers.set("Referrer-Policy", "no-referrer");
  response.headers.set("X-Content-Type-Options", "nosniff");
  response.headers.set("X-Frame-Options", "DENY");
  response.headers.set("Permissions-Policy", "camera=(), geolocation=(), payment=(), usb=()");
  response.headers.set("Cross-Origin-Opener-Policy", "same-origin");
  response.headers.set("Cross-Origin-Resource-Policy", "same-origin");
  const contentType = response.headers.get("Content-Type") ?? "";
  if (path.startsWith("/admin") && contentType.includes("text/html")) {
    response.headers.set(
      "Content-Security-Policy",
      "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self' wss:; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
    );
    response.headers.set("Cache-Control", "no-store");
  }
  if ((path === "/" || path === "/site/index.html") && contentType.includes("text/html")) {
    response.headers.set(
      "Content-Security-Policy",
      "default-src 'none'; img-src 'self'; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    );
    response.headers.set("Cache-Control", "public, max-age=300");
  }
}

function pageStyles(): string {
  return `:root{font:16px Inter,ui-sans-serif,system-ui,-apple-system,sans-serif;color:#13201c;background:#e9f0ed}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;background:radial-gradient(circle at 20% 0%,#fff 0,transparent 38%),#e9f0ed}main{width:min(100%,520px);padding:clamp(28px,7vw,52px);background:rgba(255,255,255,.94);border:1px solid #cfddd7;border-radius:28px;box-shadow:0 28px 80px rgba(22,61,50,.12)}.mark{display:grid;place-items:center;width:58px;height:58px;border-radius:18px;background:#08755c;color:white;font-weight:900;letter-spacing:-.06em}.eyebrow{margin:24px 0 8px;color:#08755c;font-size:12px;font-weight:800;letter-spacing:.13em;text-transform:uppercase}h1{margin:0 0 14px;font-size:clamp(34px,9vw,54px);line-height:1;letter-spacing:-.055em}p{line-height:1.6;color:#49655d}a,button{display:block;width:100%;margin:28px 0 20px;padding:16px 20px;border:0;text-align:center;border-radius:14px;background:#08755c;color:white;font:inherit;font-weight:800;text-decoration:none;cursor:pointer}a.text-link{display:inline;margin:0;padding:0;background:none;color:#08755c;text-decoration:underline}small{display:block;color:#6b817a;line-height:1.5}`;
}

function emailHtml(title: string, action: string, url: string, expiresMinutes: number): string {
  const safeUrl = url.replaceAll("&", "&amp;").replaceAll("\"", "&quot;").replaceAll("<", "&lt;");
  return `<!doctype html><html><body style="margin:0;background:#edf3f0;color:#13201c;font:16px system-ui,sans-serif"><div style="max-width:560px;margin:0 auto;padding:40px 20px"><div style="background:#fff;border:1px solid #d5e1dc;border-radius:22px;padding:34px"><div style="display:inline-block;background:#08755c;color:#fff;border-radius:12px;padding:11px 13px;font-weight:900">PTT</div><h1 style="margin:24px 0 12px;font-size:34px;letter-spacing:-1px">${title}</h1><p style="color:#49655d;line-height:1.6">This private, one-time link securely connects your device to your team instance.</p><a href="${safeUrl}" style="display:block;margin:26px 0;padding:16px;text-align:center;border-radius:12px;background:#08755c;color:#fff;font-weight:800;text-decoration:none">${action}</a><p style="color:#6b817a;font-size:14px;line-height:1.5">The link expires in ${expiresMinutes} minutes. If you did not expect this email, you can ignore it.</p></div></div></body></html>`;
}
