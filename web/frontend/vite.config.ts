import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// `npm run dev` serves the UI on :5173 and passes /api to the backend on :8080 (`python -m rackoon.app`).
// The Host header is kept, so the backend's same-origin check sees the page's own origin.
export default defineConfig({
  plugins: [react()],
  server: { proxy: { "/api": { target: "http://127.0.0.1:8080", changeOrigin: false } } },
  build: { outDir: "dist", sourcemap: false },
});
