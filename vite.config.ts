import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "path";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: { "@": path.resolve(__dirname, "src") },
  },
  server: {
    port: 3006,
    // Fail loudly instead of silently drifting to another port — the
    // predev free-port.sh hook is what should be freeing 3006, not Vite
    // picking a surprise port out from under other tooling/bookmarks.
    strictPort: true,
    proxy: {
      "/api": {
        target: process.env.BACKEND_URL ?? "http://localhost:8080",
        changeOrigin: true,
      },
    },
  },
});
