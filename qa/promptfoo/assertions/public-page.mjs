export default function publicPage(output, context) {
  try {
    const page = typeof output === "string" ? JSON.parse(output) : output;
    const expected = context?.vars?.requiredText || [];
    const body = String(page?.body || "");
    const normalizedBody = body.toLocaleLowerCase("en-US");
    const missing = expected.filter((value) => !normalizedBody.includes(String(value).toLocaleLowerCase("en-US")));
    const pass =
      page?.protocol === "https:" &&
      typeof page?.title === "string" &&
      page.title.includes("PTT Talk") &&
      typeof page?.h1 === "string" &&
      page.h1.length > 0 &&
      Number(page?.invalidSameOriginLinks || 0) === 0 &&
      missing.length === 0;
    return {
      pass,
      score: pass ? 1 : 0,
      reason: pass
        ? `${page.title} rendered over HTTPS with required content and valid same-origin navigation`
        : `Public page validation failed; missing=${missing.join(",") || "none"}, invalidLinks=${page?.invalidSameOriginLinks ?? "unknown"}`,
    };
  } catch (error) {
    return { pass: false, score: 0, reason: `Invalid browser evidence: ${error.message}` };
  }
}
