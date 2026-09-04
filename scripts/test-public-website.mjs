#!/usr/bin/env node
import { chromium } from "../qa/promptfoo/node_modules/playwright/index.mjs";

const origin = process.env.PTT_PUBLIC_SITE_ORIGIN ?? "https://ptttalk.app";
const pages = ["/", "/deployment", "/privacy"];
const widths = [390, 768, 1440];
const requiredHeaders = {
  "content-security-policy": "frame-ancestors 'none'",
  "cross-origin-opener-policy": "same-origin",
  "permissions-policy": "camera=()",
  "referrer-policy": "no-referrer",
  "strict-transport-security": "max-age=",
  "x-content-type-options": "nosniff",
  "x-frame-options": "DENY",
};

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

for (const pathname of pages) {
  const response = await fetch(new URL(pathname, origin), { redirect: "error" });
  requireValue(response.ok, `${pathname} returned ${response.status}`);
  for (const [name, expected] of Object.entries(requiredHeaders)) {
    requireValue((response.headers.get(name) || "").includes(expected), `${pathname} is missing ${name}: ${expected}`);
  }
}

const browser = await chromium.launch({ headless: true });
try {
  const checkedLinks = new Set();
  for (const width of widths) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    const failedAssets = [];
    const pageErrors = [];
    page.on("requestfailed", (request) => failedAssets.push(request.url()));
    page.on("pageerror", (error) => pageErrors.push(error.message));

    for (const pathname of pages) {
      const response = await page.goto(new URL(pathname, origin).href, { waitUntil: "networkidle" });
      requireValue(response?.ok(), `${pathname} did not render at ${width}px`);
      requireValue(await page.locator("h1").count() === 1, `${pathname} must expose exactly one h1`);
      const horizontalScroll = await page.evaluate(() => {
        window.scrollTo(10_000, window.scrollY);
        const value = window.scrollX;
        window.scrollTo(0, window.scrollY);
        return value;
      });
      requireValue(horizontalScroll === 0, `${pathname} allowed ${horizontalScroll}px of page-level horizontal scrolling at ${width}px`);
      const unnamedLinks = await page.locator("a[href]").evaluateAll((nodes) => nodes.filter((node) => !(node.textContent || "").trim() && !node.getAttribute("aria-label") && !node.querySelector("img[alt]")).length);
      requireValue(unnamedLinks === 0, `${pathname} has ${unnamedLinks} unnamed links`);
      const missingAlt = await page.locator("img").evaluateAll((nodes) => nodes.filter((node) => !node.hasAttribute("alt")).length);
      requireValue(missingAlt === 0, `${pathname} has ${missingAlt} images without alt text`);
      const analyticsScripts = await page.locator('script[src*="cloudflareinsights"], script[src*="analytics"]').count();
      requireValue(analyticsScripts === 0, `${pathname} contains an analytics script despite the public privacy promise`);

      if (width === widths[0]) {
        const links = await page.locator("a[href]").evaluateAll((nodes) => nodes.map((node) => node.href));
        for (const href of links) {
          const url = new URL(href);
          requireValue(url.protocol === "https:", `${pathname} contains a non-HTTPS link to ${url.hostname}`);
          checkedLinks.add(`${url.origin}${url.pathname}${url.search}`);
        }
      }
    }

    requireValue(failedAssets.length === 0, `failed browser assets: ${failedAssets.join(", ")}`);
    requireValue(pageErrors.length === 0, `public pages emitted errors: ${pageErrors.join("; ")}`);
    await page.close();
  }

  for (const href of [...checkedLinks].sort()) {
    const response = await fetch(href, { redirect: "follow" });
    requireValue(response.ok, `link ${new URL(href).hostname}${new URL(href).pathname} returned ${response.status}`);
  }
} finally {
  await browser.close();
}

process.stdout.write(`Public website passed headers, assets, internal links, accessible naming, and responsive layouts at ${widths.join("/")}px.\n`);
process.exit(0);
