declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {}
}

declare global {
interface Env {
  ANDROID_APP_CERT_SHA256?: string;
    BOOTSTRAP_TOKEN: string;
    TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
  }

  namespace Cloudflare {
    interface Env {
      ANDROID_APP_CERT_SHA256?: string;
      BOOTSTRAP_TOKEN: string;
      TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
    }
  }
}

export {};
