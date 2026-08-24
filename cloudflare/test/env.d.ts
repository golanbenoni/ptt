declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {}
}

declare global {
  interface Env {
    BOOTSTRAP_TOKEN: string;
    TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
  }

  namespace Cloudflare {
    interface Env {
      BOOTSTRAP_TOKEN: string;
      TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
    }
  }
}

export {};
