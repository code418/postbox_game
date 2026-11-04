import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Dev: `npm run dev` here + the API server with --dev (it allows this origin).
// Build: `npm run build` → dist/, which the API server serves itself.
export default defineConfig({
  plugins: [react()],
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
    proxy: {
      "/api": { target: "http://127.0.0.1:8790", changeOrigin: true },
    },
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
  },
});
