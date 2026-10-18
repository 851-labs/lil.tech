// Generates a core D1 migration (migrations/core) when src/core/Schema.ts has changed, or with
// --check fails if it has changed without one. drizzle-kit only writes a migration when the
// schema differs from the latest snapshot, so the check runs it against a copy.
import { execFileSync } from "node:child_process";
import { cpSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL("..", import.meta.url));
const migrations = join(here, "migrations/core");
const drizzleKit = (config?: string) =>
  execFileSync(
    join(here, "node_modules/.bin/drizzle-kit"),
    ["generate", ...(config === undefined ? [] : ["--config", config])],
    {
      cwd: here,
      stdio: process.argv.includes("--check") ? "pipe" : "inherit",
    },
  );

if (process.argv.includes("--check")) {
  const scratch = mkdtempSync(join(tmpdir(), "lil-migrations-"));
  try {
    const out = join(scratch, "core");
    cpSync(migrations, out, { recursive: true });
    const config = join(scratch, "drizzle.config.mjs");
    writeFileSync(
      config,
      `export default ${JSON.stringify({ dialect: "sqlite", schema: join(here, "src/core/Schema.ts"), out })};\n`,
    );
    const before = readdirSync(out).length;
    drizzleKit(config);
    if (readdirSync(out).length !== before) {
      console.error(
        "src/core/Schema.ts has changes without a migration. Run scripts/format to generate one.",
      );
      process.exit(1);
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
} else {
  drizzleKit();
}
