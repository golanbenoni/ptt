import { describe, expect, it } from "vitest";
import { base64UrlToBytes, bytesToBase64Url, randomSecret, secretsEqual, sha256Hex } from "../src/crypto";

describe("crypto helpers", () => {
  it("round trips unpadded base64url", () => {
    const bytes = Uint8Array.from([0, 1, 2, 127, 128, 254, 255]);
    expect(base64UrlToBytes(bytesToBase64Url(bytes))).toEqual(bytes);
  });

  it("issues unpredictable fixed-size secrets and compares safely", async () => {
    const first = randomSecret(32);
    const second = randomSecret(32);
    expect(base64UrlToBytes(first)).toHaveLength(32);
    expect(first).not.toBe(second);
    expect(await secretsEqual(first, first)).toBe(true);
    expect(await secretsEqual(first, second)).toBe(false);
  });

  it("matches the standard SHA-256 vector", async () => {
    expect(await sha256Hex("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  });
});
