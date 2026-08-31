import { describe, expect, it } from "vitest";
import { pushConfiguration } from "../src/push";

const validFcm = JSON.stringify({
  project_id: "ptt-talk",
  private_key: "-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----\n",
  client_email: "push@ptt-talk.iam.gserviceaccount.com",
  token_uri: "https://oauth2.googleapis.com/token",
});

const validApns = {
  APNS_KEY_ID: "ABCDEFGHIJ",
  APNS_TEAM_ID: "M2M4752Z6K",
  APNS_BUNDLE_ID: "app.ptt.talk",
  APNS_PRIVATE_KEY: "-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----\n",
  APNS_ENVIRONMENT: "production",
};

describe("production push readiness", () => {
  it("requires structurally valid credentials for both providers", () => {
    expect(pushConfiguration({
      FCM_SERVICE_ACCOUNT_JSON: validFcm,
      ...validApns,
    } as unknown as Env)).toEqual({ fcmConfigured: true, apnsConfigured: true });
  });

  it("rejects malformed or misleading provider configuration", () => {
    expect(pushConfiguration({
      FCM_SERVICE_ACCOUNT_JSON: "not-json",
      ...validApns,
      APNS_BUNDLE_ID: "app.attacker.talk",
    } as unknown as Env)).toEqual({ fcmConfigured: false, apnsConfigured: false });

    expect(pushConfiguration({
      FCM_SERVICE_ACCOUNT_JSON: JSON.stringify({
        ...JSON.parse(validFcm) as Record<string, unknown>,
        token_uri: "https://attacker.example/token",
      }),
      ...validApns,
      APNS_ENVIRONMENT: "unknown",
    } as unknown as Env)).toEqual({ fcmConfigured: false, apnsConfigured: false });
  });
});
