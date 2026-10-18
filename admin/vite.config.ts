/// <reference types="vitest/config" />
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// The server hosts the built panel at /admin. In development, Vite proxies the
// API to a server running locally (python -m hive serve).
const server = process.env.HIVE_SERVER ?? "http://127.0.0.1:8443";

export default defineConfig({
  base: "/admin/",
  plugins: [react()],
  server: {
    port: 5173,
    proxy: { "/api": { target: server, changeOrigin: false, secure: false } },
  },
  build: { outDir: "dist", emptyOutDir: true, sourcemap: true },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
    include: ["src/**/*.test.{ts,tsx}"],
    css: false,
  },
});
