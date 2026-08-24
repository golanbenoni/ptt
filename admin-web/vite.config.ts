import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig(({ mode }) => {
  const environment = loadEnv(mode, process.cwd(), "PTT_");
  return {
    base: "/admin/",
    plugins: [react()],
    server: {
      proxy: {
        "/v1": {
          target: environment.PTT_CONTROL_ORIGIN ?? "http://127.0.0.1:8080",
          changeOrigin: false,
        },
      },
    },
  };
});
