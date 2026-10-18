import { defineConfig } from "drizzle-kit";

// The core D1 database's schema and migrations. `scripts/format` generates a migration whenever
// the schema changes; Alchemy applies them on deploy (`src/core/CoreDatabase.ts`).
export default defineConfig({
  dialect: "sqlite",
  schema: "./src/core/Schema.ts",
  out: "./migrations/core",
});
