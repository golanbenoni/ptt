#!/usr/bin/env node
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { chromium } from "../qa/promptfoo/node_modules/playwright/index.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const mockPort = 39090;
const webPort = 39091;
const children = [];

function start(command, args, env = {}) {
  const child = spawn(command, args, {
    cwd: root,
    env: { ...process.env, ...env },
    stdio: ["ignore", "pipe", "pipe"],
  });
  children.push(child);
  return child;
}

async function waitFor(url) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      const response = await fetch(url);
      if (response.ok) return;
    } catch { /* service is still starting */ }
    await delay(100);
  }
  throw new Error(`Timed out waiting for ${url}`);
}

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

let browser;
try {
  start(process.execPath, ["tests/e2e/admin-mock-server.mjs"], { PTT_ADMIN_MOCK_PORT: String(mockPort) });
  start("npm", ["run", "dev", "--prefix", "admin-web", "--", "--host", "127.0.0.1", "--port", String(webPort)], {
    PTT_CONTROL_ORIGIN: `http://127.0.0.1:${mockPort}`,
  });
  await waitFor(`http://127.0.0.1:${webPort}/admin/`);

  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));

  await page.goto(`http://127.0.0.1:${webPort}/admin/#handoff=FAKE-APPROVAL`, { waitUntil: "networkidle" });
  await page.getByRole("heading", { name: "PTT Talk Admin" }).waitFor();
  requireValue(page.url().includes("#") === false, "single-use approval remained in the address bar");
  await page.getByText("Test Teammate").first().waitFor();
  await page.getByText("Delivery and recovery posture").waitFor();

  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  requireValue(overflow <= 1, `admin page overflowed the mobile viewport by ${overflow}px`);
  const unnamedButtons = await page.locator("button").evaluateAll((nodes) => nodes.filter((node) => !(node.textContent || "").trim() && !node.getAttribute("aria-label")).length);
  requireValue(unnamedButtons === 0, `${unnamedButtons} admin buttons lack an accessible name`);

  await page.getByLabel("Email address").fill("browser-user@example.test");
  await page.getByRole("button", { name: "Send invitation" }).click();
  await page.getByText("Invitation sent to browser-user@example.test").waitFor();
  await page.getByText("TEST-CODE").waitFor({ state: "attached" });

  await page.getByRole("button", { name: "Approve and revoke old devices" }).click();
  await page.getByRole("button", { name: "Manage members" }).click();
  await page.getByLabel("Role for teammate@example.test").selectOption("listen");

  page.once("dialog", (dialog) => dialog.accept());
  await page.getByRole("button", { name: "Revoke", exact: true }).click();

  await page.getByRole("button", { name: "Sign out" }).click();
  await page.getByRole("heading", { name: "Instance administration" }).waitFor();
  requireValue(pageErrors.length === 0, `admin browser emitted errors: ${pageErrors.join("; ")}`);

  process.stdout.write("Admin browser approval, invitation, recovery, channel role, revocation, sign-out, accessibility, and responsive journeys passed.\n");
} finally {
  if (browser) await browser.close();
  for (const child of children.reverse()) child.kill("SIGTERM");
}
