import tailwindcss from "@tailwindcss/vite";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite-plus";

// Deployed by the API's Alchemy stack (`Services/api/alchemy.run.ts`), which adds Cloudflare's
// Vite plugin to build the server for Workers.
export default defineConfig({
  plugins: [tailwindcss(), tanstackStart(), react()],
  test: {
    include: ["test/**/*.test.ts"],
  },
});
