export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message = code,
  ) {
    super(message);
  }
}

export function json(value: unknown, status = 200, extraHeaders?: HeadersInit): Response {
  const headers = new Headers(extraHeaders);
  headers.set("Content-Type", "application/json; charset=utf-8");
  headers.set("Cache-Control", "no-store");
  headers.set("X-Content-Type-Options", "nosniff");
  return Response.json(value, { status, headers });
}

export async function body(request: Request): Promise<Record<string, unknown>> {
  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > 3_000_000) throw new ApiError(413, "REQUEST_TOO_LARGE");
  let value: unknown;
  try {
    const bytes = new Uint8Array(await request.arrayBuffer());
    if (bytes.length > 3_000_000) throw new ApiError(413, "REQUEST_TOO_LARGE");
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(400, "INVALID_JSON");
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new ApiError(400, "INVALID_JSON");
  return value as Record<string, unknown>;
}

export function stringField(value: Record<string, unknown>, key: string, maximum = 4096): string {
  const field = value[key];
  if (typeof field !== "string" || field.length === 0 || field.length > maximum) {
    throw new ApiError(400, `INVALID_${key.replaceAll(/([A-Z])/g, "_$1").toUpperCase()}`);
  }
  return field;
}

export function integerField(value: Record<string, unknown>, key: string, minimum: number, maximum: number): number {
  const field = value[key];
  if (!Number.isSafeInteger(field) || (field as number) < minimum || (field as number) > maximum) {
    throw new ApiError(400, `INVALID_${key.replaceAll(/([A-Z])/g, "_$1").toUpperCase()}`);
  }
  return field as number;
}

export function booleanField(value: Record<string, unknown>, key: string): boolean {
  const field = value[key];
  if (typeof field !== "boolean") throw new ApiError(400, `INVALID_${key.toUpperCase()}`);
  return field;
}

export function arrayField(value: Record<string, unknown>, key: string, maximum = 256): unknown[] {
  const field = value[key];
  if (!Array.isArray(field) || field.length > maximum) throw new ApiError(400, `INVALID_${key.toUpperCase()}`);
  return field;
}

export function errorResponse(error: unknown): Response {
  if (error instanceof ApiError) return json({ code: error.code, message: error.message }, error.status);
  // Unexpected exceptions can contain database values, provider responses, or
  // request-derived strings. Keep production logs useful without copying those
  // values into an external observability system.
  const errorType = error instanceof Error && error.name ? error.name.slice(0, 80) : "UnknownError";
  console.error(JSON.stringify({ level: "error", message: "unhandled request error", errorType }));
  return json({ code: "INTERNAL", message: "Internal server error" }, 500);
}
