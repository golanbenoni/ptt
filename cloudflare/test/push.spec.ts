import { describe, expect, it } from "vitest";
import { apnsProviderConfiguration, pushConfiguration } from "../src/push";

const validFcm = JSON.stringify({
  project_id: "ptt-talk",
  private_key: "-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----\n",
  client_email: "push@ptt-talk.iam.gserviceaccount.com",
  token_uri: "https://oauth2.googleapis.com/token",
});

const validApns = {
  APNS_PRODUCTION_KEY_ID: "ABCDEFGHIJ",
  APNS_SANDBOX_KEY_ID: "KLMNOPQRST",
  APNS_TEAM_ID: "M2M4752Z6K",
  APNS_BUNDLE_ID: "app.ptt.talk",
  APNS_PRODUCTION_PRIVATE_KEY: "-----BEGIN PRIVATE KEY-----\nproduction\n-----END PRIVATE KEY-----\n",
  APNS_SANDBOX_PRIVATE_KEY: "-----BEGIN PRIVATE KEY-----\nsandbox\n-----END PRIVATE KEY-----\n",
};

describe("production push readiness", () => {
  it("keeps production and sandbox APNs routes and topics distinct", () => {
    expect(apnsProviderConfiguration("apns", "app.ptt.talk")).toEqual({
      host: "api.push.apple.com",
      isPtt: false,
      topic: "app.ptt.talk",
    });
    expect(apnsProviderConfiguration("apns-ptt-sandbox", "app.ptt.talk")).toEqual({
      host: "api.sandbox.push.apple.com",
      isPtt: true,
      topic: "app.ptt.talk.voip-ptt",
    });
  });

  it("requires structurally valid credentials for both providers", () => {
    expect(pushConfiguration({
      FCM_SERVICE_ACCOUNT_JSON: validFcm,
      ...validApns,
    } as unknown as Env)).toEqual({
      fcmConfigured: true,
      apnsConfigured: true,
      apnsProductionConfigured: true,
      apnsSandboxConfigured: true,
      apnsCredentialsSeparated: true,
    });
  });

  it("rejects malformed or misleading provider configuration", () => {
    expect(pushConfiguration({
      FCM_SERVICE_ACCOUNT_JSON: "not-json",
      ...validApns,
      APNS_BUNDLE_ID: "app.attacker.talk",
    } as unknown as Env)).toEqual({
      fcmConfigured: false,
      apnsConfigured: false,
      apnsProductionConfigured: false,
      apnsSandboxConfigured: false,
      apnsCredentialsSeparated: false,
    });

    expect(pushConfiguration({
      FCM_SERVICE_ACCOUNT_JSON: JSON.stringify({
        ...JSON.parse(validFcm) as Record<string, unknown>,
        token_uri: "https://attacker.example/token",
      }),
      ...validApns,
      APNS_SANDBOX_PRIVATE_KEY: "invalid",
    } as unknown as Env)).toEqual({
      fcmConfigured: false,
      apnsConfigured: false,
      apnsProductionConfigured: true,
      apnsSandboxConfigured: false,
      apnsCredentialsSeparated: false,
    });
  });

  it("rejects one APNs signing key reused across production and sandbox", () => {
    expect(pushConfiguration({
      FCM_SERVICE_ACCOUNT_JSON: validFcm,
      ...validApns,
      APNS_SANDBOX_KEY_ID: validApns.APNS_PRODUCTION_KEY_ID,
    } as unknown as Env)).toEqual({
      fcmConfigured: true,
      apnsConfigured: false,
      apnsProductionConfigured: true,
      apnsSandboxConfigured: true,
      apnsCredentialsSeparated: false,
    });
    expect(pushConfiguration({
      FCM_SERVICE_ACCOUNT_JSON: validFcm,
      ...validApns,
      APNS_SANDBOX_PRIVATE_KEY: validApns.APNS_PRODUCTION_PRIVATE_KEY,
    } as unknown as Env).apnsCredentialsSeparated).toBe(false);
  });
});
