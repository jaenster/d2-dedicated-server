import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";

// The realmd binary @embedFile's the build output, so we need ONE self-contained
// file: viteSingleFile inlines all JS/CSS/assets into dist/index.html. The Zig
// build (-Dwebui=true) copies that single file into the binary.
//
// In dev, `npm run dev` proxies the admin API to a locally-running realmd on its
// health port (8080 by default; override with REALMD_HEALTH_PORT).
const adminTarget = `http://localhost:${process.env.REALMD_HEALTH_PORT ?? 8080}`;

export default defineConfig({
  plugins: [react(), viteSingleFile()],
  build: {
    target: "es2020",
    cssCodeSplit: false,
    assetsInlineLimit: 100_000_000,
    chunkSizeWarningLimit: 100_000,
  },
  server: {
    proxy: {
      "/admin": { target: adminTarget, changeOrigin: true },
      "/healthz": { target: adminTarget, changeOrigin: true },
      "/readyz": { target: adminTarget, changeOrigin: true },
    },
  },
});
